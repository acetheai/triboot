# TriBoot QA Report

**Reviewer:** Queen (QA & Testing)
**Date:** 2026-03-03
**Script Version:** 1.2.0
**Status:** ⚠️ NEEDS ATTENTION (no critical blockers, several warnings)

---

## 1. Syntax & Shell Quality

### ✅ `bash -n triboot.sh` — PASS (no syntax errors)

### Shell Quality Issues

| Severity | Issue | Location |
|----------|-------|----------|
| **Warning** | `sgdisk -n 2:0:+${ISO_PERCENT}%` — sgdisk does not support percentage-based sizing. This will fail at runtime. | Line ~328 (partition_drive, sgdisk branch) |
| **Warning** | `MOUNT_POINTS=("${MOUNT_POINTS[@]/$boot_mount}")` — This pattern substitution replaces the string but leaves an empty element in the array, not a clean removal. Harmless but sloppy. | Lines ~410, ~460, ~505, ~530, ~575, ~612 |
| **Warning** | `$GRUB_INSTALL` used unquoted — if variable is empty (shouldn't happen given flow, but defensive coding matters), this would cause errors. | Lines ~395, ~403, ~473, ~481 |
| **Suggestion** | Shellcheck would flag: `$TUI_CMD` used unquoted in multiple places. Safe here but not best practice. | Throughout TUI helpers |
| **Suggestion** | `set -euo pipefail` with the ERR trap can cause double-firing of cleanup. The EXIT trap alone is sufficient since it fires on both success and failure. | Line ~17, ~155 |

---

## 2. Logic Review

### USB Detection
| Severity | Issue |
|----------|-------|
| **Warning** | `lsblk -I 8,65,66,67,68,69,70,71` filters by major device numbers. Major 8 = SCSI/SATA (includes internal SATA drives, not just USB). This **will show internal SATA drives** alongside USB drives. The removable flag fallback helps, but the primary lsblk list is too broad. |
| **Suggestion** | Better approach: filter by `TRAN=usb` (e.g., `lsblk -dno NAME,SIZE,MODEL,TRAN | grep usb`), or check `/sys/block/*/removable` as the primary method. |

### Partition Layout Calculation
| Severity | Issue |
|----------|-------|
| **Warning** | **sgdisk branch:** `sgdisk -n 2:0:+${ISO_PERCENT}%` is not valid sgdisk syntax. sgdisk uses sector counts or `+size{K,M,G,T}` notation, not percentages. This entire code path will fail. The parted branch is correct. |
| **Suggestion** | For sgdisk, calculate the sector count manually: get total sectors, subtract boot, then compute ISO_PERCENT of the remainder. |

### GRUB Install
| Severity | Issue |
|----------|-------|
| ✅ | Covers both BIOS (`i386-pc`) and UEFI (`x86_64-efi`) correctly. Uses `--removable` and `--no-nvram` for portability. Looks good. |
| **Suggestion** | No ARM/aarch64 UEFI support. Document as limitation or add `--target=arm64-efi` option. |

### grub.cfg Auto-Scanning
| Severity | Issue |
|----------|-------|
| **Warning** | `regexp --set=isoname '/(.*)\.iso$' "$isofile"` — The GRUB `regexp` module captures group 1, but for a path like `/ubuntu.iso` this would set `isoname` to `ubuntu`. However, for `/subdir/file.iso`, the second `regexp` uses a 2-group pattern but `--set=isoname` only captures group 1 (the subdir name, not the filename). Display name will be the directory name, not the ISO name. |
| **Warning** | Fedora entry uses `root=live:CDLABEL=LIVE` — this hardcodes the CD label. Most Fedora ISOs use their own label (e.g., `Fedora-WS-Live-40`). This will likely fail to find the root filesystem. Should use `findiso=` or read the label from the ISO. |
| **Suggestion** | The subdirectory scan block duplicates most of the root-level scan block but with fewer distro templates (missing openSUSE, Manjaro). Consider deduplicating into a GRUB function. |
| **Suggestion** | No Kali, Pop!_OS, or Tails templates. These are popular and have non-standard paths. |

### Reinstall/Update Mode
| Severity | Issue |
|----------|-------|
| ✅ | `detect_existing_triboot` uses `blkid -L` which is correct. |
| **Warning** | In the `main()` function, when `MODE` is empty (default), `check_root`, `check_dependencies`, and `detect_grub_install` are called. Then if no existing install is found, the flow falls through to the TUI/plain branch which calls `check_root`, `check_dependencies`, `detect_grub_install` **again**. Redundant but harmless. |

### ISO Verification
| Severity | Issue |
|----------|-------|
| ✅ | Handles SHA256 and MD5 with sidecar files (`.sha256`, `.md5`). |
| **Warning** | Checksum files sometimes contain the filename (e.g., `abc123  ubuntu.iso`). The `awk '{print $1}'` handles this. But some checksum files contain multiple entries (e.g., `SHA256SUMS` for an entire release). The current approach only supports per-ISO sidecar files, not shared checksum files. |
| **Suggestion** | Support `SHA256SUMS` / `MD5SUMS` files in the same directory as the ISOs. |

---

## 3. Error Handling

| Severity | Issue |
|----------|-------|
| ✅ | `set -euo pipefail` is set. Cleanup trap on EXIT and ERR. |
| ✅ | `run_logged` and `run_step` provide structured error handling. |
| **Warning** | `partprobe "$dev" 2>/dev/null || true` — if partprobe fails, partitions may not be visible to the kernel. The retry loop in `format_partitions` mitigates this, but if all retries fail, the fatal error message doesn't mention partprobe as a possible cause. |
| **Warning** | GRUB install failures are caught with `|| { warn ... }` but due to `set -e`, the `run_logged` call will still cause a non-zero exit that triggers the ERR trap. The `||` prevents script exit, but the ERR trap still fires. This could cause confusing double-error messages. |
| **Suggestion** | `mkfs` failures are caught by `run_logged` → `set -e`, which will trigger cleanup. This is fine, but a friendlier message would help. |

---

## 4. TUI Flow

| Severity | Issue |
|----------|-------|
| ✅ | Flow: Welcome → Drive Selection → Partition Customization → Confirmation → Progress → Success. Logical and complete. |
| **Warning** | `run_with_gauge` runs all steps in a subshell `(...)`. Due to the subshell, if any step fails, `set -e` exits the subshell but the pipe to whiptail may still show "Done!" briefly before the parent detects the error. |
| **Warning** | The `tui_gauge` function outputs gauge protocol format, but `run_with_gauge` also calls the actual functions (e.g., `partition_drive`) which produce their own stdout output (`info`, `success` messages). These will corrupt the gauge protocol. The `2>/dev/null` only suppresses stderr. |
| **Suggestion** | Redirect stdout of the actual work functions to the log file inside the gauge subshell, only emitting gauge protocol lines to stdout. |

---

## 5. Edge Cases

| Scenario | Handling | Severity |
|----------|----------|----------|
| No USB drives | ✅ Detected and reported with TUI or fatal message | OK |
| USB < 2GB | ⚠️ No minimum size check. A 512MB drive would leave 0 space for ISOs after boot partition. | **Warning** |
| `grub-install` missing | ✅ Caught by `check_dependencies` | OK |
| NVMe partition naming | ✅ Handled: `if [[ "$dev" =~ [0-9]$ ]]` adds `p` prefix | OK |
| Device disappears mid-operation | Partially handled by `set -e` + cleanup trap. No explicit check. | **Suggestion** |
| No TUI tool and non-interactive terminal | Falls back to plain text mode. OK. | OK |
| `--device` with non-existent device | ✅ Checked with `-b` test | OK |
| `--device /dev/sda` (internal drive) | ⚠️ No protection against wiping the system disk. The script trusts the user. | **Warning** |

---

## 6. README Review

| Severity | Issue |
|----------|-------|
| **Warning** | README says partition labels are `TBBOOT`, `TBISO`, `TBFILES`. Script uses `TRIBOOT_BOOT`, `TRIBOOT_ISO`, `TRIBOOT_FILES`. **Mismatch.** |
| **Warning** | README doesn't mention `--reinstall`, `--update-grub`, `--verify`, or `--list` flags, which are implemented in the script. |
| **Suggestion** | README mentions "Optional zenity/yad GUI wrapper" in the roadmap context but the script doesn't implement this. Should clarify it's a future feature or remove. |
| **Suggestion** | The GitHub URL is a placeholder (`your-user/triboot`). |

---

## Summary of Issues

| Severity | Count |
|----------|-------|
| Critical | 0 |
| Warning | 13 |
| Suggestion | 8 |

### Top Priority Fixes

1. **sgdisk percentage syntax** — Will fail at runtime on systems without parted. Needs manual sector calculation.
2. **README label mismatch** — Confusing for users. Labels in README must match script constants.
3. **USB detection shows SATA drives** — Could lead to accidental data loss on internal drives.
4. **TUI gauge stdout corruption** — Gauge display will be garbled during actual operation.
5. **Fedora CDLABEL hardcoded** — Fedora ISOs will likely fail to boot.

### Recommendations

1. Fix sgdisk partition sizing to use sector math instead of unsupported `%` syntax
2. Update README labels to match script (`TRIBOOT_BOOT`, `TRIBOOT_ISO`, `TRIBOOT_FILES`)
3. Document `--reinstall`, `--update-grub`, `--verify`, `--list` in README
4. Add minimum USB size check (e.g., 2GB minimum)
5. Filter USB drives by transport type (`TRAN=usb`) instead of major numbers
6. Add system disk protection (warn if device appears to be a system disk)
7. Fix gauge subshell to suppress work function stdout
8. Fix Fedora boot entry to not hardcode CDLABEL

---

*No critical (script-breaking) issues found. The script is well-structured and handles most cases properly. The warnings above should be addressed before real-world use, particularly the sgdisk path and USB detection logic.*
