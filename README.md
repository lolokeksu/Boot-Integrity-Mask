# Boot Integrity Mask

![Version](https://img.shields.io/badge/version-v3.6-crimson)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)
![Android](https://img.shields.io/badge/android-12--16-brightgreen)
![Architecture](https://img.shields.io/badge/arch-ARM64-orange)
![Magisk](https://img.shields.io/badge/Magisk-27%2B-black)
![KernelSU](https://img.shields.io/badge/KernelSU-supported-green)
![APatch](https://img.shields.io/badge/APatch-supported-green)

Hides modifications to boot partitions (`boot`, `init_boot`, `vbmeta`, `vendor_boot`, `recovery`, `dtbo`) and dynamic partitions (`super`) from applications reading them via `/dev/block/by-name`.

Substitution is activated at early boot stage via loop devices and tmpfs, and maintained by an adaptive watchdog throughout device operation.

> **This is the final release. No further updates are planned.**

---

## Requirements

| Parameter | Value |
|---|---|
| Android | 12 – 16 |
| Root | Magisk 27+, KernelSU, APatch, Magisk Delta |
| Architecture | ARM64 (arm64-v8a) |
| Partition layout | A/B and A-only |
| Kernel | loop devices + tmpfs support |
| Required | `stock_boot.img` placed in `common/` before install |

---

## Installation

### 1. Prepare stock image

Get `stock_boot.img` (or `init_boot.img`) from the **official firmware** for your device. It must match the currently installed firmware version exactly.

Rename it to `stock_boot.img`. Compressed `.img.gz` is supported — extracted automatically.  
Target partition (`boot` or `init_boot`) is detected automatically by image size.

Optional — images for additional partitions:
```
stock_vbmeta.img
stock_vendor_boot.img
stock_recovery.img
stock_dtbo.img
```

### 2. Build the archive

1. Download `BootMask3.6.zip`
2. Open the ZIP **without extracting** (MT Manager, ZArchiver, etc.)
3. Navigate to `common/`
4. Place `stock_boot.img` and optional images there
5. For dynamic partitions, create `.super_targets` (one partition name per line):
```
system
vendor
product
```
6. Close the archive

### 3. Install

Magisk / KernelSU / APatch → **Modules** → **Install from storage** → select archive  
Wait for `Installation complete` and reboot.

### 4. Verify

```sh
su -c "/data/adb/modules/bootmask/bootmask-ctrl status"
```

If status shows **ACTIVE** and a loop device is listed — module is working.  
Full check:
```sh
su -c "/data/adb/modules/bootmask/bootmask-ctrl analyze"
```

---

## Features

- **Auto-detection** of target partition (`boot` / `init_boot`) by image size
- **Optional substitution** of `vbmeta`, `vendor_boot`, `recovery`, `dtbo`
- **Dynamic partitions** (`super`) via `.super_targets`
- **Compressed images** `.img.gz` supported
- **Adaptive watchdog** — interval adapts by screen state and battery level
- **Bootloop protection** — multi-layer verification with automatic compat fallback
- **OTA safety** — module auto-freezes on update detection, does not interfere with flashing
- **Safe Boot** — auto-disable if boot not confirmed within 120 seconds
- **Stealth mode** — disables all logging
- **Monitor mode** — watchdog observes without restoring
- **Hook system** — 7 events with environment variables
- **Interactive control center** `bootmask-ctrl` — diagnostics, reports, mode switching
- **Cross-platform installer** — Magisk / KernelSU / APatch with SELinux policy on all three
- **Partition backup** to `/sdcard/BootMask/backups/`
- **Compatibility mode** for devices with unstable tmpfs

---

## Commands

All commands require root. Prefix: `su -c "/data/adb/modules/bootmask/bootmask-ctrl <command>"`

### Status & Diagnostics

| Command | Description |
|---|---|
| `status` | Dashboard: loop, slot, watchdog status |
| `status --json` | Status in JSON format |
| `analyze` | Full analysis with recommendations |
| `check-integrity` | Hash verification of loop vs stock image |
| `image-info` | Size, SHA256 and magic of stock images |
| `diag` | System diagnostics: utilities, SELinux, loop, tmpfs |
| `logs [N]` | Event log (default: last 50 lines) |
| `report` | Full report → `/sdcard/BootMask/reports/` |
| `diff-report` | Compare two latest reports |

### Management

| Command | Description |
|---|---|
| `enable` | Enable module (+ reboot) |
| `disable` | Disable module (+ reboot) |
| `restore` | Remove substitution and disable immediately |
| `restart-watchdog` | Restart background watchdog |
| `freeze` | Temporarily suspend substitution |
| `thaw` | Resume substitution after freeze |

### Modes

| Command | Description |
|---|---|
| `compatibility-mode on\|off\|status` | symlinks instead of tmpfs |
| `stealth on\|off\|status` | disable all logging |
| `monitor on\|off\|status` | observe without restoring |

---

## Hook System

Place executable scripts (`chmod 755`) into event directories:

```
/data/adb/modules/bootmask/common/hooks/<event>/your_script.sh
```

### Events

| Event | Trigger |
|---|---|
| `pre-activate` | Before substitution (early boot) |
| `post-activate` | After successful activation |
| `pre-deactivate` | Before disable / restore / freeze |
| `post-deactivate` | After deactivation |
| `on-link-broken` | Watchdog detected broken symlink |
| `on-link-restored` | Watchdog restored symlink |
| `on-ota-detected` | System update detected |

### Environment variables

```sh
HOOK_EVENT      # event name
HOOK_TARGET     # target partition: boot or init_boot
HOOK_LOOP       # loop device path: /dev/block/loop42
HOOK_LINK       # symlink path (on-link-broken/restored only)
HOOK_TIMESTAMP  # Unix timestamp
```

### Example

```sh
#!/system/bin/sh
echo "[$(date)] $HOOK_EVENT | $HOOK_TARGET | $HOOK_LOOP" \
  >> /sdcard/BootMask/hooks.log
```

---

## Watchdog Configuration

File: `/data/adb/modules/bootmask/common/watchdog.conf`

```
120
debug
```

| Line | Value |
|---|---|
| 1 | Base check interval in seconds (min 10, default 120) |
| 2 | `debug` — verbose logging to `bootmask.log` |

Interval adapts automatically:
- Screen off → ×2
- Battery ≤ 20% → ×2
- Both → ×4
- Maximum: 600 seconds

---

## Troubleshooting

**Module not activated**
```sh
su -c "/data/adb/modules/bootmask/bootmask-ctrl analyze"
```
Check that `stock_boot.img` size matches the partition and corresponds to current firmware.

**Bootloop after install**
Reboot once more — Safe Boot will have disabled the module automatically.

**Partitions disappear from `/dev/block/by-name`**
```sh
su -c "/data/adb/modules/bootmask/bootmask-ctrl compatibility-mode on"
```
Then reboot.

**Module frozen after OTA**
Expected behavior. Prepare new `stock_boot.img` for the new firmware version, replace it in `common/` and reinstall the module.

**dmesg is empty**
Android 12+ restricts `dmesg` access (`dmesg_restrict`). Use the module log instead:
```sh
su -c "/data/adb/modules/bootmask/bootmask-ctrl logs"
```

---

## Changelog

### v3.6 — Final Release
- Detailed compat fallback logging: shows exact symlink that failed verification
- `analyze` checks firmware fingerprint match against image installed with
- `check-integrity` caches image hash by mtime — no rehashing if unchanged
- Fixed watchdog interval display with non-numeric `watchdog.conf` value
- Added `README.md` to module archive

---

## Discussion

- **4PDA:** [Boot Integrity Mask](https://4pda.to/forum/index.php?showtopic=915158&view=findpost&p=143605196)

---

## License

[GNU General Public License v3.0](LICENSE)
