#!/system/bin/sh
# ========================================================
# Boot Integrity Mask v3.6 – Ранняя активация
# ========================================================

MODDIR="${0%/*}"
DISABLE_FLAG="$MODDIR/disable"
COMPAT_FLAG="$MODDIR/common/compat_mode"
FREEZE_FLAG="$MODDIR/.frozen"
HOOKS_DIR="$MODDIR/common/hooks"
SAFE_BOOT_FAILED="$MODDIR/.safe_boot_failed"
SAFE_BOOT_OK="$MODDIR/.safe_boot_ok"
STEALTH_FLAG="$MODDIR/.stealth"

# --------------------------------------------------------
# Базовые функции
# --------------------------------------------------------
log() {
  [ ! -f "$STEALTH_FLAG" ] && echo "[BootMask] $1" > /dev/kmsg
}
disable_module() {
  log "fatal error: $1, disabling module"
  touch "$DISABLE_FLAG"
  exit 1
}

run_hooks() {
  local event="$1"
  local dir="$HOOKS_DIR/$event"
  [ -d "$dir" ] || return 0
  for script in "$dir"/*; do
    [ -x "$script" ] || continue
    log "running hook: $script (event=$event)"
    (
      HOOK_EVENT="$event" \
      HOOK_TARGET="$TARGET_PART" \
      HOOK_LOOP="$FREE_LOOP" \
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

# loop0–15 (расширен с 7)
generate_unique_loop() {
  local candidate
  candidate=$(losetup -f 2>/dev/null)
  if [ -z "$candidate" ]; then
    for i in $(seq 0 15); do
      if [ ! -e "/dev/block/loop$i" ] || ! losetup "/dev/block/loop$i" >/dev/null 2>&1; then
        candidate="/dev/block/loop$i"
        break
      fi
    done
  fi
  [ -z "$candidate" ] && return 1
  echo "$candidate"
}

# Чтение флага compat в отдельной функции (local допустим только внутри функции)
read_compat_flag() {
  [ -f "$COMPAT_FLAG" ] || { echo 0; return; }
  local flag_value
  flag_value=$(cat "$COMPAT_FLAG" 2>/dev/null | tr -d ' \t\r\n')
  if [ -z "$flag_value" ] || [ "$flag_value" = "on" ]; then
    echo 1
  else
    echo 0
  fi
}

# Инжект SELinux-политики: пробуем все доступные инструменты.
# Отсутствие инструмента НЕ фатально.
inject_selinux_policy() {
  local rule="allow loop_device block_device file { read write open }"
  if command -v magiskpolicy >/dev/null 2>&1; then
    magiskpolicy --live "$rule" 2>/dev/null && {
      log "SELinux policy injected via magiskpolicy"; return 0; }
  fi
  if command -v ksud >/dev/null 2>&1; then
    ksud sepolicy patch "$rule" 2>/dev/null && {
      log "SELinux policy injected via ksud"; return 0; }
  fi
  if [ -x /data/adb/ap/bin/magiskpolicy ]; then
    /data/adb/ap/bin/magiskpolicy --live "$rule" 2>/dev/null && {
      log "SELinux policy injected via APatch magiskpolicy"; return 0; }
  fi
  log "SELinux policy NOT injected (no compatible tool); relying on sepolicy.rule"
  return 1
}

# Проверка, что критичная ссылка указывает на блок-устройство
verify_target_link() {
  local dir="$1"
  local name="$2"
  local link="$dir/$name"
  [ -L "$link" ] || return 1
  local dest
  dest=$(readlink -f "$link" 2>/dev/null)
  [ -z "$dest" ] && return 1
  [ -b "$dest" ] || return 1
  return 0
}

# --------------------------------------------------------
# Проверки перед активацией
# --------------------------------------------------------
[ -f "$DISABLE_FLAG" ] && exit 0

if [ -f "$SAFE_BOOT_FAILED" ]; then
  log "previous boot failed, disabling module"
  rm -f "$SAFE_BOOT_FAILED"
  disable_module "safe boot: previous boot failed"
fi

if [ ! -f "$SAFE_BOOT_OK" ]; then
  log "safe boot: marking as failed for next boot"
  touch "$SAFE_BOOT_FAILED"
fi

BYNAME_DIR="/dev/block/by-name"
[ ! -d "$BYNAME_DIR" ] && BYNAME_DIR=$(find /dev/block -type d -name by-name 2>/dev/null | head -1)
[ -z "$BYNAME_DIR" ] && disable_module "cannot find by-name directory"

SLOT=$(getprop ro.boot.slot_suffix)
TARGET_PART=$(cat "$MODDIR/.target_part" 2>/dev/null)
[ -z "$TARGET_PART" ] && TARGET_PART="boot"

# Дополнительные разделы: overlay-ветки и setup_optional_loop
OVERLAY_PARTS="vbmeta vendor_boot"
SETUP_LOOP_PARTS="recovery dtbo"

PART_LINK="$BYNAME_DIR/$TARGET_PART"
[ -n "$SLOT" ] && PART_LINK="${PART_LINK}${SLOT}"

BOOT_DEV=$(readlink -f "$PART_LINK" 2>/dev/null)
[ -z "$BOOT_DEV" ] && BOOT_DEV=$(find /dev/block -name "$(basename "$PART_LINK")" -type b 2>/dev/null | head -1)
[ -z "$BOOT_DEV" ] && disable_module "cannot locate $TARGET_PART block device"

# --------------------------------------------------------
# Обработка стокового образа
# --------------------------------------------------------
STOCK_IMG="$MODDIR/common/stock_boot.img"
STOCK_IMG_GZ="$MODDIR/common/stock_boot.img.gz"

if [ ! -f "$STOCK_IMG" ]; then
  if [ -f "$STOCK_IMG_GZ" ]; then
    if command -v gzip >/dev/null 2>&1; then
      log "decompressing stock_boot.img.gz"
      gzip -d -c "$STOCK_IMG_GZ" > "$STOCK_IMG" 2>/dev/null
      [ $? -ne 0 ] && disable_module "failed to decompress stock_boot.img.gz"
      rm -f "$STOCK_IMG_GZ"
    else
      disable_module "gzip not found"
    fi
  else
    disable_module "stock_boot.img not found"
  fi
fi

STOCK_SIZE=$(stat -c%s "$STOCK_IMG")
BOOT_SIZE=$(blockdev --getsize64 "$BOOT_DEV" 2>/dev/null)

OLD_SIZE=$(cat "$MODDIR/.stock_size" 2>/dev/null)
if [ "$STOCK_SIZE" != "$BOOT_SIZE" ] || [ "$OLD_SIZE" != "$BOOT_SIZE" ]; then
  log "size mismatch, updating stock image from current boot"
  dd if="$BOOT_DEV" of="$STOCK_IMG" bs=1M 2>/dev/null
  [ -s "$STOCK_IMG" ] || disable_module "stock image dump failed (empty)"
  STOCK_SIZE=$(stat -c%s "$STOCK_IMG")
fi

[ "$STOCK_SIZE" != "$BOOT_SIZE" ] && disable_module "size mismatch"

MAGIC=$(dd if="$STOCK_IMG" bs=8 count=1 2>/dev/null)
[ "$MAGIC" != "ANDROID!" ] && disable_module "invalid boot image magic"

# Хеш образа зафиксирован при установке — берём из файла, не пересчитываем
STORED_HASH=$(cat "$MODDIR/.stock_checksum" 2>/dev/null)

run_hooks "pre-activate"

# --------------------------------------------------------
# Монтирование loop
# --------------------------------------------------------
FREE_LOOP=$(generate_unique_loop)
[ -z "$FREE_LOOP" ] && disable_module "no free loop device"

log "using loop device: $FREE_LOOP"
losetup -r "$FREE_LOOP" "$STOCK_IMG" || disable_module "losetup failed"

inject_selinux_policy

touch -r "$BOOT_DEV" "$FREE_LOOP" 2>/dev/null
log "time attributes synced"

echo "$STOCK_SIZE" > "$MODDIR/.stock_size"
[ -n "$STORED_HASH" ] && echo "$STORED_HASH" > "$MODDIR/.stock_checksum"
echo "$STOCK_IMG" > "$MODDIR/.backing_file"

if [ -f "$FREEZE_FLAG" ]; then
  log "module is frozen, not activating overlay"
  exit 0
fi

# --------------------------------------------------------
# Опциональные loop для recovery и dtbo
# --------------------------------------------------------
setup_optional_loop() {
  local type="$1"
  if [ -f "$MODDIR/.${type}_enabled" ]; then
    local img="$MODDIR/common/stock_${type}.img"
    [ -f "$img" ] || return 0
    local loop
    loop=$(generate_unique_loop)
    [ -z "$loop" ] && return 1
    losetup -r "$loop" "$img" || return 1
    ln -sf "$loop" "$BYNAME_DIR/$type"
    [ -n "$SLOT" ] && ln -sf "$loop" "$BYNAME_DIR/${type}${SLOT}"
    echo "$loop" > "$MODDIR/.active_${type}_loop"
    log "${type} overlay enabled on $loop"
  fi
  return 0
}

for _part in $SETUP_LOOP_PARTS; do
  setup_optional_loop "$_part"
done

COMPAT_MODE=$(read_compat_flag)

# --------------------------------------------------------
# Режим совместимости: прямые symlink'и (без tmpfs)
# --------------------------------------------------------
activate_overlay_compat() {
  log "compatibility mode: using direct symlinks"
  ln -sf "$FREE_LOOP" "$BYNAME_DIR/$TARGET_PART"
  [ -n "$SLOT" ] && ln -sf "$FREE_LOOP" "$BYNAME_DIR/${TARGET_PART}${SLOT}"

  for extra in $OVERLAY_PARTS; do
    if [ -f "$MODDIR/.${extra}_enabled" ]; then
      local img="$MODDIR/common/stock_${extra}.img"
      [ -f "$img" ] || continue
      local loop
      loop=$(generate_unique_loop)
      [ -z "$loop" ] && continue
      losetup -r "$loop" "$img" && \
        ln -sf "$loop" "$BYNAME_DIR/$extra" && \
        echo "$loop" > "$MODDIR/.active_${extra}_loop"
      [ -n "$SLOT" ] && ln -sf "$loop" "$BYNAME_DIR/${extra}${SLOT}"
    fi
  done

  if [ -f "$MODDIR/.super_targets" ]; then
    while IFS= read -r super_part; do
      [ -z "$super_part" ] && continue
      local img="$MODDIR/common/stock_${super_part}.img"
      [ -f "$img" ] || continue
      local loop
      loop=$(generate_unique_loop)
      [ -z "$loop" ] && continue
      losetup -r "$loop" "$img" && \
        ln -sf "$loop" "$BYNAME_DIR/$super_part" && \
        echo "$loop" > "$MODDIR/.active_${super_part}_loop"
      [ -n "$SLOT" ] && ln -sf "$loop" "$BYNAME_DIR/${super_part}${SLOT}"
    done < "$MODDIR/.super_targets"
  fi
}

# --------------------------------------------------------
# Основная ветка активации
# --------------------------------------------------------
if [ "$COMPAT_MODE" -eq 1 ]; then
  activate_overlay_compat
else
  # -------------------------------------------------------
  # Оптимизация #1: снапшот ВМЕСТО бэкапа внутри BYNAME_DIR
  #
  # Прежний подход хранил бэкап-директорию ВНУТРИ $BYNAME_DIR.
  # После монтирования tmpfs поверх $BYNAME_DIR бэкап скрывался
  # под ней и становился недоступным — цикл восстановления
  # читал пустой каталог и ничего не восстанавливал.
  #
  # Новый подход: снапшот записывается в $MODDIR (вне $BYNAME_DIR),
  # mount его не затрагивает, восстановление надёжно работает.
  # -------------------------------------------------------

  SNAPSHOT="$MODDIR/.byname_snapshot"
  rm -f "$SNAPSHOT" 2>/dev/null

  # Фаза 1: снимаем все ссылки ДО монтирования tmpfs
  for link in "$BYNAME_DIR"/*; do
    [ -L "$link" ] || continue
    _name=$(basename "$link")
    _target=$(readlink "$link" 2>/dev/null)
    [ -z "$_target" ] && continue
    printf '%s %s\n' "$_name" "$_target" >> "$SNAPSHOT"
  done

  if [ ! -s "$SNAPSHOT" ]; then
    log "snapshot empty, switching to compatibility mode"
    rm -f "$SNAPSHOT"
    echo "on" > "$COMPAT_FLAG"
    activate_overlay_compat
  elif ! mount -t tmpfs none "$BYNAME_DIR"; then
    log "tmpfs mount failed, switching to compatibility mode"
    rm -f "$SNAPSHOT"
    echo "on" > "$COMPAT_FLAG"
    activate_overlay_compat
  else
    # Фаза 2: восстанавливаем ссылки из снапшота (tmpfs уже смонтирована)
    while read -r _name _target; do
      [ -z "$_name" ] || [ -z "$_target" ] && continue
      if [ "$_name" = "$TARGET_PART" ] || \
         { [ -n "$SLOT" ] && [ "$_name" = "${TARGET_PART}${SLOT}" ]; }; then
        ln -sf "$FREE_LOOP" "$BYNAME_DIR/$_name"
      else
        ln -sf "$_target" "$BYNAME_DIR/$_name"
      fi
    done < "$SNAPSHOT"
    rm -f "$SNAPSHOT"

    # Подменяем дополнительные разделы (vbmeta, vendor_boot)
    for extra in $OVERLAY_PARTS; do
      if [ -f "$MODDIR/.${extra}_enabled" ]; then
        img="$MODDIR/common/stock_${extra}.img"
        [ -f "$img" ] || continue
        loop=$(generate_unique_loop)
        [ -z "$loop" ] && continue
        losetup -r "$loop" "$img" || continue
        for _name in "$extra" "${extra}${SLOT}"; do
          [ -L "$BYNAME_DIR/$_name" ] && ln -sf "$loop" "$BYNAME_DIR/$_name"
        done
        echo "$loop" > "$MODDIR/.active_${extra}_loop"
        log "${extra} overlay enabled on $loop"
      fi
    done

    # Динамические разделы (super)
    if [ -f "$MODDIR/.super_targets" ]; then
      while IFS= read -r super_part; do
        [ -z "$super_part" ] && continue
        img="$MODDIR/common/stock_${super_part}.img"
        [ -f "$img" ] || continue
        loop=$(generate_unique_loop)
        [ -z "$loop" ] && continue
        losetup -r "$loop" "$img" || continue
        for _name in "$super_part" "${super_part}${SLOT}"; do
          [ -L "$BYNAME_DIR/$_name" ] && ln -sf "$loop" "$BYNAME_DIR/$_name"
        done
        echo "$loop" > "$MODDIR/.active_${super_part}_loop"
        log "${super_part} overlay enabled on $loop"
      done < "$MODDIR/.super_targets"
    fi

    # Защита от bootloop: проверяем критичную ссылку до отдачи управления
    TARGET_OK=0
    FAILED_LINK=""
    if verify_target_link "$BYNAME_DIR" "$TARGET_PART"; then
      TARGET_OK=1
    else
      FAILED_LINK="$BYNAME_DIR/$TARGET_PART"
    fi
    if [ -n "$SLOT" ] && verify_target_link "$BYNAME_DIR" "${TARGET_PART}${SLOT}"; then
      TARGET_OK=1
    elif [ -n "$SLOT" ] && [ "$TARGET_OK" -ne 1 ]; then
      FAILED_LINK="$BYNAME_DIR/${TARGET_PART}${SLOT}"
    fi

    if [ "$TARGET_OK" -ne 1 ]; then
      log "target link verification FAILED: $FAILED_LINK — rolling back to compat"
      umount "$BYNAME_DIR" 2>/dev/null
      echo "on" > "$COMPAT_FLAG"
      activate_overlay_compat
    fi
  fi
fi

# --------------------------------------------------------
# Быстрая верификация loop (размер + magic, без полного хеша)
# --------------------------------------------------------
LOOP_SIZE=$(blockdev --getsize64 "$FREE_LOOP" 2>/dev/null)
LOOP_MAGIC=$(dd if="$FREE_LOOP" bs=8 count=1 2>/dev/null)

if [ -n "$LOOP_SIZE" ] && [ "$STOCK_SIZE" -eq "$LOOP_SIZE" ] && [ "$LOOP_MAGIC" = "ANDROID!" ]; then
  log "loop quick-check PASSED (size+magic)"
  echo "$FREE_LOOP" > "$MODDIR/.active_loop"
  echo "$BYNAME_DIR" > "$MODDIR/.byname_dir"
  date +%s > "$MODDIR/.last_check"
  log "module activated (loop: $FREE_LOOP, slot: ${SLOT:-none}, target: $TARGET_PART)"
  run_hooks "post-activate"

  (
    sleep 120
    rm -f "$SAFE_BOOT_FAILED"
    touch "$SAFE_BOOT_OK"
    log "safe boot: system booted successfully"
  ) &
else
  log "loop quick-check FAILED"
  losetup -d "$FREE_LOOP" 2>/dev/null
  [ "$COMPAT_MODE" -eq 0 ] && umount "$BYNAME_DIR" 2>/dev/null
  disable_module "loop verification failed"
fi
