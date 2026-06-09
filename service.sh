#!/system/bin/sh
# ========================================================
# Boot Integrity Mask v3.5 – Watchdog
# ========================================================

MODDIR="${0%/*}"
STOCK_IMG="$MODDIR/common/stock_boot.img"
DISABLE_FLAG="$MODDIR/disable"
CONFIG="$MODDIR/common/watchdog.conf"
FREEZE_FLAG="$MODDIR/.frozen"
MONITOR_FLAG="$MODDIR/.monitor"
STEALTH_FLAG="$MODDIR/.stealth"
HOOKS_DIR="$MODDIR/common/hooks"
WATCHDOG_PIDFILE="$MODDIR/.watchdog_pid"

# Проверка, что модуль не удалён
if [ ! -f "$MODDIR/module.prop" ]; then
  BYNAME_DIR=$(cat "$MODDIR/.byname_dir" 2>/dev/null)
  [ -n "$BYNAME_DIR" ] && umount "$BYNAME_DIR" 2>/dev/null
  exit 0
fi

[ -f "$DISABLE_FLAG" ] && exit 0
[ -f "$FREEZE_FLAG" ] && exit 0

BYNAME_DIR=$(cat "$MODDIR/.byname_dir" 2>/dev/null)
[ -z "$BYNAME_DIR" ] && exit 0

TARGET_PART=$(cat "$MODDIR/.target_part" 2>/dev/null)
[ -z "$TARGET_PART" ] && TARGET_PART="boot"

SLOT=$(getprop ro.boot.slot_suffix)

# Типы дополнительных подменяемых разделов (помимо основного TARGET_PART)
EXTRA_PARTS="vbmeta vendor_boot recovery dtbo"

# --------------------------------------------------------
# Регистрация PID watchdog (для restart-watchdog)
# --------------------------------------------------------
echo $$ > "$WATCHDOG_PIDFILE"
cleanup_pidfile() {
  rm -f "$WATCHDOG_PIDFILE" 2>/dev/null
}
trap cleanup_pidfile EXIT INT TERM

# --------------------------------------------------------
# Конфигурация и статистика
# --------------------------------------------------------
BASE_INTERVAL=30
MIN_INTERVAL=30
MAX_INTERVAL=600
RESTORE_COUNT_FILE="$MODDIR/.restore_count"
LOOP_ERROR_FILE="$MODDIR/.loop_error_count"

[ ! -f "$RESTORE_COUNT_FILE" ] && echo 0 > "$RESTORE_COUNT_FILE"
[ ! -f "$LOOP_ERROR_FILE" ] && echo 0 > "$LOOP_ERROR_FILE"

increment_restore_count() {
  local c=$(cat "$RESTORE_COUNT_FILE" 2>/dev/null)
  echo $((c + 1)) > "$RESTORE_COUNT_FILE"
}
increment_loop_error() {
  local c=$(cat "$LOOP_ERROR_FILE" 2>/dev/null)
  echo $((c + 1)) > "$LOOP_ERROR_FILE"
}

# Чтение конфига в отдельной функции (local допустим только внутри функции)
DEBUG_LOG=0
read_config() {
  [ -f "$CONFIG" ] || return 0
  local cfg_interval
  cfg_interval=$(head -1 "$CONFIG" | tr -d ' \t\r\n')
  if [ -n "$cfg_interval" ] && [ "$cfg_interval" -ge 10 ] 2>/dev/null; then
    MIN_INTERVAL=$cfg_interval
    BASE_INTERVAL=$cfg_interval
    [ "$MIN_INTERVAL" -lt 10 ] && MIN_INTERVAL=30
  fi
  local debug_flag
  debug_flag=$(tail -n +2 "$CONFIG" | head -1 | tr -d ' \t\r\n')
  [ "$debug_flag" = "debug" ] && DEBUG_LOG=1
}
read_config

# --------------------------------------------------------
# Вспомогательные функции
# --------------------------------------------------------
log() {
  [ ! -f "$STEALTH_FLAG" ] && echo "[BootMask] $1" > /dev/kmsg
}
log_to_file() {
  [ -f "$STEALTH_FLAG" ] && return
  local msg="$1"
  if [ $DEBUG_LOG -eq 1 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$MODDIR/bootmask.log"
  else
    case "$msg" in
      *failed*|*restored*|*error*|*FAILED*|*OTA*|*frozen*|*monitor*|*recreated*|*hook*)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$MODDIR/bootmask.log"
        ;;
    esac
  fi
}

get_screen_state() {
  local brightness=0
  for b in /sys/class/backlight/*/brightness; do
    [ -f "$b" ] && brightness=$((brightness + $(cat "$b" 2>/dev/null || echo 0)))
  done
  [ "$brightness" -gt 0 ] && echo 1 || echo 0
}

# Возвращает уровень батареи или пустую строку, если узел недоступен
get_battery_level() {
  if [ -f /sys/class/power_supply/battery/capacity ]; then
    cat /sys/class/power_supply/battery/capacity 2>/dev/null
  else
    echo ""
  fi
}

current_interval=$BASE_INTERVAL
get_adaptive_interval() {
  local screen=$(get_screen_state)
  local battery=$(get_battery_level)
  local multiplier=1
  [ "$screen" -eq 0 ] && multiplier=$((multiplier * 2))
  if [ -n "$battery" ] && [ "$battery" -le 20 ] 2>/dev/null; then
    multiplier=$((multiplier * 2))
  fi
  local target=$(( current_interval * multiplier ))
  [ "$target" -gt $MAX_INTERVAL ] && target=$MAX_INTERVAL
  [ "$target" -lt $MIN_INTERVAL ] && target=$MIN_INTERVAL
  echo "$target"
}

increase_interval() {
  # +10% целочисленно, без форка awk
  local new_interval=$(( current_interval + current_interval / 10 ))
  # Защита от стагнации при очень маленьком значении
  [ "$new_interval" -le "$current_interval" ] && new_interval=$(( current_interval + 1 ))
  [ "$new_interval" -gt $MAX_INTERVAL ] && new_interval=$MAX_INTERVAL
  [ "$new_interval" -lt $MIN_INTERVAL ] && new_interval=$MIN_INTERVAL
  current_interval=$new_interval
}

reset_interval() {
  current_interval=$MIN_INTERVAL
}

# --------------------------------------------------------
# Система хуков для событий watchdog
# --------------------------------------------------------
run_event_hooks() {
  local event="$1"
  local target="$2"
  local loop="$3"
  local link="$4"
  local hook_dir="$HOOKS_DIR/$event"
  [ -d "$hook_dir" ] || return 0
  for script in "$hook_dir"/*; do
    [ -x "$script" ] || continue
    log "running event hook: $script (event=$event)"
    (
      HOOK_EVENT="$event" \
      HOOK_TARGET="$target" \
      HOOK_LOOP="$loop" \
      HOOK_LINK="$link" \
      HOOK_TIMESTAMP=$(date +%s) \
      timeout 30 "$script" 2>&1
    ) &
    local pid=$!
    sleep 0.1
    if kill -0 $pid 2>/dev/null; then
      log "hook $script still running, leaving in background"
    else
      wait $pid
      local rc=$?
      [ $rc -ne 0 ] && log "hook $script failed with code $rc"
    fi
  done
}

# --------------------------------------------------------
# Улучшенная проверка loop
# --------------------------------------------------------
ACTIVE_LOOP=$(cat "$MODDIR/.active_loop" 2>/dev/null)
BACKING_FILE="$STOCK_IMG"
STOCK_SIZE=$(cat "$MODDIR/.stock_size" 2>/dev/null)

is_loop_valid() {
  local loop="$1"
  [ -z "$loop" ] && return 1
  [ ! -b "$loop" ] && return 1
  local size=$(blockdev --getsize64 "$loop" 2>/dev/null || stat -c%s "$loop" 2>/dev/null)
  if [ -n "$STOCK_SIZE" ] && [ -n "$size" ] && [ "$STOCK_SIZE" -ne "$size" ]; then
    return 1
  fi
  local magic=$(dd if="$loop" bs=8 count=1 2>/dev/null)
  if [ "$magic" != "ANDROID!" ]; then
    return 1
  fi
  return 0
}

recreate_loop() {
  log "watchdog: attempting to recreate loop"
  log_to_file "recreate: starting"
  losetup -d "$ACTIVE_LOOP" 2>/dev/null
  local new_loop=$(losetup -f 2>/dev/null)
  [ -z "$new_loop" ] && {
    log "recreate: no free loop device"
    return 1
  }
  losetup -r "$new_loop" "$STOCK_IMG" 2>/dev/null || return 1
  ACTIVE_LOOP="$new_loop"
  echo "$new_loop" > "$MODDIR/.active_loop"
  ln -sf "$new_loop" "$BYNAME_DIR/$TARGET_PART" 2>/dev/null
  [ -n "$SLOT" ] && ln -sf "$new_loop" "$BYNAME_DIR/${TARGET_PART}${SLOT}" 2>/dev/null
  touch -r "$STOCK_IMG" "$new_loop" 2>/dev/null
  log "watchdog: loop recreated as $new_loop"
  log_to_file "recreate: success, new loop $new_loop"
  increment_restore_count
  return 0
}

# --------------------------------------------------------
# Восстановление ссылки с вызовом хуков
# --------------------------------------------------------
restore_link() {
  local target_link="$1"
  if [ -L "$target_link" ]; then
    local link_dest=$(readlink "$target_link" 2>/dev/null)
    if is_loop_valid "$link_dest"; then
      return 0
    else
      log "watchdog: existing link $target_link is invalid"
      increment_loop_error
    fi
  fi

  run_event_hooks "on-link-broken" "$TARGET_PART" "$ACTIVE_LOOP" "$target_link"

  if [ -f "$MONITOR_FLAG" ]; then
    log "monitor: link $target_link missing/invalid (not restored)"
    return 1
  fi

  if ! is_loop_valid "$ACTIVE_LOOP"; then
    log "watchdog: active loop $ACTIVE_LOOP is invalid, attempting recreate"
    if ! recreate_loop; then
      log "watchdog: failed to recreate loop, cannot restore"
      return 1
    fi
  fi

  ln -sf "$ACTIVE_LOOP" "$target_link" 2>/dev/null
  if [ $? -eq 0 ]; then
    log "watchdog restored link $target_link -> $ACTIVE_LOOP"
    increment_restore_count
    run_event_hooks "on-link-restored" "$TARGET_PART" "$ACTIVE_LOOP" "$target_link"
    return 0
  else
    return 1
  fi
}

# Восстановление ссылки для дополнительного раздела на его собственный loop
restore_extra_link() {
  local link="$1"
  local type="$2"
  local extra_loop=$(cat "$MODDIR/.active_${type}_loop" 2>/dev/null)
  [ -z "$extra_loop" ] && return 1
  if [ -L "$link" ]; then
    local dest=$(readlink "$link" 2>/dev/null)
    [ "$dest" = "$extra_loop" ] && [ -b "$extra_loop" ] && return 0
  fi
  run_event_hooks "on-link-broken" "$type" "$extra_loop" "$link"
  if [ -f "$MONITOR_FLAG" ]; then
    log "monitor: extra link $link missing/invalid (not restored)"
    return 1
  fi
  [ -b "$extra_loop" ] || return 1
  ln -sf "$extra_loop" "$link" 2>/dev/null || return 1
  log "watchdog restored extra link $link -> $extra_loop"
  increment_restore_count
  run_event_hooks "on-link-restored" "$type" "$extra_loop" "$link"
  return 0
}

# Определение типа раздела по имени ссылки (для выбора нужного loop)
link_extra_type() {
  local base="$1"
  for type in $EXTRA_PARTS; do
    if [ "$base" = "$type" ] || { [ -n "$SLOT" ] && [ "$base" = "${type}${SLOT}" ]; }; then
      echo "$type"; return 0
    fi
  done
  if [ -f "$MODDIR/.super_targets" ]; then
    while IFS= read -r super_part; do
      [ -z "$super_part" ] && continue
      if [ "$base" = "$super_part" ] || { [ -n "$SLOT" ] && [ "$base" = "${super_part}${SLOT}" ]; }; then
        echo "$super_part"; return 0
      fi
    done < "$MODDIR/.super_targets"
  fi
  return 1
}

# --------------------------------------------------------
# Построение списка отслеживаемых ссылок (вызывается ОДИН раз).
# Список разделов статичен после активации, поэтому перестроение
# на каждой итерации цикла не требуется.
# --------------------------------------------------------
build_watch_list() {
  WATCH_LINKS="$BYNAME_DIR/$TARGET_PART"
  [ -n "$SLOT" ] && WATCH_LINKS="$WATCH_LINKS $BYNAME_DIR/${TARGET_PART}${SLOT}"
  WATCH_LINKS="$WATCH_LINKS $BYNAME_DIR/${TARGET_PART}_a $BYNAME_DIR/${TARGET_PART}_b"

  for type in $EXTRA_PARTS; do
    if [ -f "$MODDIR/.active_${type}_loop" ]; then
      WATCH_LINKS="$WATCH_LINKS $BYNAME_DIR/$type"
      [ -n "$SLOT" ] && WATCH_LINKS="$WATCH_LINKS $BYNAME_DIR/${type}${SLOT}"
    fi
  done

  if [ -f "$MODDIR/.super_targets" ]; then
    while IFS= read -r super_part; do
      [ -z "$super_part" ] && continue
      [ -f "$MODDIR/.active_${super_part}_loop" ] || continue
      WATCH_LINKS="$WATCH_LINKS $BYNAME_DIR/$super_part"
      [ -n "$SLOT" ] && WATCH_LINKS="$WATCH_LINKS $BYNAME_DIR/${super_part}${SLOT}"
    done < "$MODDIR/.super_targets"
  fi
}

# --------------------------------------------------------
# Основной цикл: прямая проверка отслеживаемых ссылок
# (без хеша всего каталога — проверяем ровно то, что важно)
# --------------------------------------------------------

# Быстрая проверка одной ссылки: указывает ли она на ожидаемый loop.
# Дешёвая (readlink + тест блок-устройства), без чтения magic.
# Возвращает 0 — ссылка в порядке, 1 — требует внимания.
quick_link_ok() {
  local link="$1"
  local base="$2"
  local dest
  dest=$(readlink "$link" 2>/dev/null)
  [ -z "$dest" ] && return 1
  [ -b "$dest" ] || return 1
  if [ "$base" = "$TARGET_PART" ] || { [ -n "$SLOT" ] && [ "$base" = "${TARGET_PART}${SLOT}" ]; } \
     || [ "$base" = "${TARGET_PART}_a" ] || [ "$base" = "${TARGET_PART}_b" ]; then
    # Целевой раздел: ссылка должна вести на активный loop
    [ "$dest" = "$ACTIVE_LOOP" ] && return 0
    return 1
  else
    # Доп. раздел: сверяем с его собственным активным loop
    local etype
    etype=$(link_extra_type "$base")
    [ -z "$etype" ] && return 0   # не наш раздел — игнорируем
    local eloop
    eloop=$(cat "$MODDIR/.active_${etype}_loop" 2>/dev/null)
    [ -n "$eloop" ] && [ "$dest" = "$eloop" ] && return 0
    return 1
  fi
}

ota_package_present() {
  [ -f /data/ota_package ] && { echo "/data/ota_package"; return 0; }
  [ -f /cache/update.zip ] && { echo "/cache/update.zip"; return 0; }
  [ -f /data/update.zip ] && { echo "/data/update.zip"; return 0; }
  echo ""
  return 1
}

update_engine_active() {
  pgrep -x update_engine >/dev/null 2>&1 || return 1
  if getprop init.svc.update_engine 2>/dev/null | grep -q running; then
    return 0
  fi
  return 1
}

check_ota() {
  local pkg=$(ota_package_present)
  if [ -n "$pkg" ]; then
    log_to_file "OTA package detected: $pkg"
    run_event_hooks "on-ota-detected" "" "" "$pkg"
    return 0
  fi
  if update_engine_active; then
    log_to_file "OTA confirmed via active update_engine"
    run_event_hooks "on-ota-detected" "" "" "update_engine"
    return 0
  fi
  if pgrep -x update_engine >/dev/null 2>&1; then
    log "watchdog: update_engine present but not active, ignoring (no freeze)"
  fi
  return 1
}

main_loop() {
  build_watch_list   # строим список один раз перед циклом
  while true; do
    for i in $(seq 1 5); do
      sleep 1
      [ -f "$DISABLE_FLAG" ] && { log "watchdog: disabled flag detected"; exit 0; }
      [ -f "$FREEZE_FLAG" ] && { log "watchdog: frozen flag detected"; exit 0; }
    done

    if check_ota; then
      log_to_file "OTA detected, freezing module"
      touch "$FREEZE_FLAG"
      umount "$BYNAME_DIR" 2>/dev/null
      exit 0
    fi

    # Быстрый проход: все ли отслеживаемые ссылки на месте?
    local need_action=0
    for link in $WATCH_LINKS; do
      [ -L "$link" ] || continue
      if ! quick_link_ok "$link" "$(basename "$link")"; then
        need_action=1
        break
      fi
    done

    if [ "$need_action" -eq 0 ]; then
      increase_interval
      continue
    fi

    # Обнаружено расхождение — полный проход с восстановлением
    reset_interval
    local issues=0
    for link in $WATCH_LINKS; do
      [ -e "$link" ] || [ -L "$link" ] || continue
      local base=$(basename "$link")
      if [ "$base" = "$TARGET_PART" ] || { [ -n "$SLOT" ] && [ "$base" = "${TARGET_PART}${SLOT}" ]; } \
         || [ "$base" = "${TARGET_PART}_a" ] || [ "$base" = "${TARGET_PART}_b" ]; then
        [ -L "$link" ] || continue
        restore_link "$link" || issues=1
      else
        local etype=$(link_extra_type "$base")
        [ -z "$etype" ] && continue
        restore_extra_link "$link" "$etype" || issues=1
      fi
    done

    [ "$issues" -eq 1 ] && reset_interval
  done
}

log "watchdog v3.5 started"
main_loop
