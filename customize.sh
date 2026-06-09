#!/system/bin/sh
# ========================================================
# Boot Integrity Mask v3.6 – Установщик
# ========================================================

PREFIX="[BootMask]"
ui_print() { echo "$1"; }

ui_print "${PREFIX} Installing Boot Integrity Mask v3.6..."

ARCH=$(getprop ro.product.cpu.abi)
case "$ARCH" in
  arm64*|aarch64*) ;;
  *) ui_print "${PREFIX} ! Unsupported architecture: $ARCH"; exit 1;;
esac

for util in losetup blockdev dd stat md5sum sha256sum gzip; do
  command -v "$util" >/dev/null 2>&1 || {
    ui_print "${PREFIX} ! $util not found. Aborting."
    exit 1
  }
done

BYNAME_DIR=""
if [ -d "/dev/block/by-name" ]; then
  BYNAME_DIR="/dev/block/by-name"
else
  BYNAME_DIR=$(find /dev/block -type d -name by-name 2>/dev/null | head -1)
fi
if [ -z "$BYNAME_DIR" ]; then
  ui_print "${PREFIX} ! Cannot find any by-name directory."
  exit 1
fi

SLOT=$(getprop ro.boot.slot_suffix)

STOCK_IMG="$MODPATH/common/stock_boot.img"
STOCK_IMG_GZ="$MODPATH/common/stock_boot.img.gz"

if [ -f "$STOCK_IMG_GZ" ]; then
  ui_print "${PREFIX} Decompressing stock_boot.img.gz..."
  gzip -d -c "$STOCK_IMG_GZ" > "$STOCK_IMG" 2>/dev/null
  if [ $? -ne 0 ] || [ ! -f "$STOCK_IMG" ]; then
    ui_print "${PREFIX} ! Failed to decompress stock_boot.img.gz"
    exit 1
  fi
  [ ! -s "$STOCK_IMG" ] && {
    ui_print "${PREFIX} ! Decompressed image is empty"
    exit 1
  }
  rm -f "$STOCK_IMG_GZ"
fi

if [ ! -f "$STOCK_IMG" ]; then
  ui_print "${PREFIX} ! stock_boot.img not found in common/. Aborting."
  exit 1
fi

STOCK_SIZE=$(stat -c%s "$STOCK_IMG")
STOCK_HASH=$(sha256sum "$STOCK_IMG" | awk '{print $1}')

MAGIC=$(dd if="$STOCK_IMG" bs=8 count=1 2>/dev/null)
[ "$MAGIC" != "ANDROID!" ] && {
  ui_print "${PREFIX} ! Invalid boot image magic: $MAGIC"
  exit 1
}

FREE_SPACE=$(df -k /data | tail -1 | awk '{print $4}')
[ "$FREE_SPACE" -lt 102400 ] && {
  ui_print "${PREFIX} ! Insufficient free space in /data (need at least 100 MB, available: $((FREE_SPACE/1024)) MB)"
  exit 1
}

CANDIDATES="boot"
[ -n "$SLOT" ] && CANDIDATES="$CANDIDATES init_boot"

FOUND_DEV=""
FOUND_NAME=""
for name in $CANDIDATES; do
  LINK="$BYNAME_DIR/$name"
  [ -n "$SLOT" ] && LINK="${LINK}${SLOT}"
  DEV=$(readlink -f "$LINK" 2>/dev/null)
  [ -z "$DEV" ] && DEV=$(find /dev/block -name "$(basename "$LINK")" -type b 2>/dev/null | head -1)
  if [ -n "$DEV" ]; then
    SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null)
    [ "$SIZE" = "$STOCK_SIZE" ] && {
      FOUND_DEV="$DEV"
      FOUND_NAME="$name"
      break
    }
  fi
done

if [ -z "$FOUND_DEV" ]; then
  ui_print "${PREFIX} ! No partition matches stock image size ($STOCK_SIZE bytes)."
  ui_print "${PREFIX}   Available partitions:"
  for name in $CANDIDATES; do
    LINK="$BYNAME_DIR/$name"
    [ -n "$SLOT" ] && LINK="${LINK}${SLOT}"
    DEV=$(readlink -f "$LINK" 2>/dev/null)
    [ -z "$DEV" ] && DEV=$(find /dev/block -name "$(basename "$LINK")" -type b 2>/dev/null | head -1)
    if [ -n "$DEV" ]; then
      SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null)
      ui_print "${PREFIX}     $name: $SIZE bytes"
    else
      ui_print "${PREFIX}     $name: device not found"
    fi
  done
  exit 1
fi

BOOT_DEV="$FOUND_DEV"
TARGET_PART="$FOUND_NAME"

ui_print "${PREFIX} Target partition: $TARGET_PART ($BOOT_DEV) size: $STOCK_SIZE bytes"
ui_print "${PREFIX} Stock image SHA256: $STOCK_HASH"

BASE_DIR="/sdcard/BootMask"
BACKUP_DIR="$BASE_DIR/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ -d "$BACKUP_DIR" ]; then
  for part in boot init_boot vendor_boot vbmeta recovery dtbo; do
    LINK="$BYNAME_DIR/$part"
    [ -n "$SLOT" ] && LINK="${LINK}${SLOT}"
    DEV=$(readlink -f "$LINK" 2>/dev/null)
    if [ -n "$DEV" ] && [ -b "$DEV" ]; then
      local dev_size=$(blockdev --getsize64 "$DEV" 2>/dev/null)
      if [ "$dev_size" -gt 0 ] 2>/dev/null; then
        ui_print "${PREFIX} Backing up $part ($DEV)..."
        dd if="$DEV" of="$BACKUP_DIR/${part}.img" bs=1M 2>/dev/null
        if [ $? -eq 0 ] && [ -f "$BACKUP_DIR/${part}.img" ]; then
          BACKUP_SIZE=$(stat -c%s "$BACKUP_DIR/${part}.img")
          if [ "$BACKUP_SIZE" -ne "$dev_size" ]; then
            ui_print "${PREFIX} ! Backup size mismatch for $part, continuing anyway."
          else
            ui_print "${PREFIX}   $part backup OK ($BACKUP_SIZE bytes)"
          fi
        else
          ui_print "${PREFIX} ! Backup of $part failed, continuing anyway."
        fi
      fi
    fi
  done
fi

handle_optional_image() {
  local type="$1"
  local upper_type=$(echo "$type" | tr '[:lower:]' '[:upper:]')
  local img="$MODPATH/common/stock_${type}.img"
  local img_gz="$MODPATH/common/stock_${type}.img.gz"

  if [ -f "$img_gz" ]; then
    ui_print "${PREFIX} Decompressing stock_${type}.img.gz..."
    gzip -d -c "$img_gz" > "$img" 2>/dev/null
    [ $? -eq 0 ] && rm -f "$img_gz"
  fi

  if [ -f "$img" ]; then
    local img_size=$(stat -c%s "$img")
    local link="$BYNAME_DIR/$type"
    [ -n "$SLOT" ] && link="${link}${SLOT}"
    local dev=$(readlink -f "$link" 2>/dev/null)
    [ -z "$dev" ] && dev=$(find /dev/block -name "$(basename "$link")" -type b 2>/dev/null | head -1)
    if [ -n "$dev" ]; then
      local dev_size=$(blockdev --getsize64 "$dev")
      if [ "$img_size" = "$dev_size" ]; then
        ui_print "${PREFIX} - ${upper_type} image found and size matches ($img_size bytes)."
        echo "yes" > "$MODPATH/.${type}_enabled"
      else
        ui_print "${PREFIX} ! ${upper_type} image size mismatch, ignoring."
      fi
    else
      ui_print "${PREFIX} ! ${upper_type} partition not found, ignoring."
    fi
  fi
}

handle_optional_image "vbmeta"
handle_optional_image "vendor_boot"
handle_optional_image "recovery"
handle_optional_image "dtbo"

if [ -f "$MODPATH/.super_targets" ]; then
  ui_print "${PREFIX} Processing super partition targets..."
  while IFS= read -r super_part; do
    [ -z "$super_part" ] && continue
    SUPER_IMG="$MODPATH/common/stock_${super_part}.img"
    SUPER_IMG_GZ="$MODPATH/common/stock_${super_part}.img.gz"
    if [ -f "$SUPER_IMG_GZ" ]; then
      gzip -d -c "$SUPER_IMG_GZ" > "$SUPER_IMG" 2>/dev/null
      [ $? -eq 0 ] && rm -f "$SUPER_IMG_GZ"
    fi
    if [ -f "$SUPER_IMG" ]; then
      local img_size=$(stat -c%s "$SUPER_IMG")
      local link="$BYNAME_DIR/$super_part"
      [ -n "$SLOT" ] && link="${link}${SLOT}"
      local dev=$(readlink -f "$link" 2>/dev/null)
      [ -z "$dev" ] && dev=$(find /dev/block -name "$(basename "$link")" -type b 2>/dev/null | head -1)
      if [ -n "$dev" ]; then
        local dev_size=$(blockdev --getsize64 "$dev")
        if [ "$img_size" = "$dev_size" ]; then
          ui_print "${PREFIX} - ${super_part} image found and size matches ($img_size bytes)."
          echo "yes" > "$MODPATH/.${super_part}_enabled"
        else
          ui_print "${PREFIX} ! ${super_part} image size mismatch, ignoring."
        fi
      else
        ui_print "${PREFIX} ! ${super_part} partition not found, ignoring."
      fi
    fi
  done < "$MODPATH/.super_targets"
fi

echo "$TARGET_PART" > "$MODPATH/.target_part"
echo "$STOCK_SIZE" > "$MODPATH/.stock_size"
echo "$STOCK_HASH" > "$MODPATH/.stock_checksum"
# Сохраняем fingerprint прошивки для проверки соответствия образа в analyze
getprop ro.build.fingerprint > "$MODPATH/.stock_fingerprint" 2>/dev/null

chmod 755 "$MODPATH/bootmask-ctrl"
chmod 755 "$MODPATH/post-fs-data.sh"
chmod 755 "$MODPATH/service.sh"
chmod 644 "$MODPATH/module.prop"
chmod 644 "$MODPATH/common/watchdog.conf" 2>/dev/null
chmod 644 "$STOCK_IMG"

if [ -d "$MODPATH/common/hooks" ]; then
  HOOK_FILES=$(find "$MODPATH/common/hooks" -type f)
  if [ -n "$HOOK_FILES" ]; then
    echo "$HOOK_FILES" | xargs chmod 755
    ui_print "${PREFIX} Hook scripts permissions set to 755"
  else
    ui_print "${PREFIX} No hook scripts found, skipping"
  fi
fi

for extra in vbmeta vendor_boot recovery dtbo; do
  [ -f "$MODPATH/common/stock_${extra}.img" ] && chmod 644 "$MODPATH/common/stock_${extra}.img"
done

ui_print "${PREFIX} Installation complete. Target: $TARGET_PART, backup: $BACKUP_DIR"