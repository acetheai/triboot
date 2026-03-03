#!/usr/bin/env bash
#
# TriBoot — Multi-Boot USB Creator
# Turns any USB drive into a multi-boot device capable of booting multiple ISOs.
#
# Usage: sudo ./triboot.sh [OPTIONS]
#
# Options:
#   -h, --help          Show usage info
#   -d, --device DEV    Skip drive selection, use specified device
#   -n, --no-tui        Run in plain text mode (no gum TUI)
#   -y, --yes           Skip confirmation prompts
#
# Requirements: bash, parted/sgdisk, grub-install, mkfs.fat, mkfs.exfat, lsblk
# Must be run as root.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────────────
VERSION="1.2.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/tmp/triboot.log"

BOOT_LABEL="TBOOT"
ISO_LABEL="TBOOT_ISO"
FILES_LABEL="TBOOT_FILES"

BOOT_SIZE_MB=512
ISO_PERCENT=60  # percent of remaining space after boot

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# CLI flags
USE_TUI=auto
AUTO_YES=false
TARGET_DEVICE=""
NO_TUI_FLAG=false
MODE=""  # "", "reinstall", "update-grub", "verify", "list"

# TUI tool (gum only)
TUI_CMD=""

# ──────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────
log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] $*" >> "$LOG_FILE"
}

# Run a command logging stdout/stderr to log file, exit on failure with error
run_logged() {
    local desc="$1"
    shift
    log "EXEC [$desc]: $*"
    local tmpout
    tmpout=$(mktemp /tmp/triboot_cmd.XXXXXX)
    if "$@" > "$tmpout" 2>&1; then
        cat "$tmpout" >> "$LOG_FILE"
        rm -f "$tmpout"
        return 0
    else
        local rc=$?
        cat "$tmpout" >> "$LOG_FILE"
        log "FAILED [$desc]: exit code $rc"
        rm -f "$tmpout"
        return $rc
    fi
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
    log "INFO: $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
    log "OK: $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "WARN: $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR: $*"
}

fatal() {
    error "$*"
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# TUI helpers (gum-based)
# ──────────────────────────────────────────────────────────────────────────────
detect_tui() {
    if [[ "$NO_TUI_FLAG" == "true" ]]; then
        USE_TUI=false
        return
    fi
    if [[ "$USE_TUI" == "auto" ]]; then
        if [[ -t 1 ]] && command -v gum &>/dev/null; then
            TUI_CMD="gum"
            USE_TUI=true
        else
            USE_TUI=false
        fi
    fi
}

# Legacy whiptail/dialog detection — kept for reference:
# detect_tui_legacy() {
#     if command -v whiptail &>/dev/null; then
#         TUI_CMD="whiptail"; USE_TUI=true
#     elif command -v dialog &>/dev/null; then
#         TUI_CMD="dialog"; USE_TUI=true
#     else
#         USE_TUI=false
#     fi
# }

gum_banner() {
    # Display a styled banner box
    local title="$1" body="$2" border_fg="${3:-212}"
    gum style --border double --border-foreground "$border_fg" --padding "1 2" --bold "$title" "" "$body"
}

gum_success_msg() {
    gum style --foreground 82 "$1"
}

gum_error_msg() {
    gum style --foreground 196 --bold "$1"
}

tui_error() {
    local text="$1"
    if [[ "$USE_TUI" == "true" ]]; then
        gum_error_msg "ERROR: $text"
    fi
    error "$text"
}

gum_step_done() {
    gum style --foreground 82 "✓ $1"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup trap
# ──────────────────────────────────────────────────────────────────────────────
MOUNT_POINTS=()

cleanup() {
    local exit_code=$?
    log "Cleanup triggered (exit code: $exit_code)"

    # Restore terminal in case TUI left it messy
    stty sane 2>/dev/null || true
    echo -e "${NC}" 2>/dev/null || true

    for mp in "${MOUNT_POINTS[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount "$mp" 2>/dev/null || true
            log "Unmounted $mp"
        fi
        rmdir "$mp" 2>/dev/null || true
    done
    if [[ $exit_code -ne 0 ]]; then
        log "FAILURE: TriBoot exited with code $exit_code"
        if [[ "$USE_TUI" == "true" ]]; then
            gum style --border rounded --border-foreground 196 --padding "1 2" --foreground 196 --bold \
                "TriBoot failed!" "" "Check $LOG_FILE for details." 2>/dev/null || true
        fi
        error "TriBoot exited with errors. Check $LOG_FILE for details."
    fi
}

trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Usage
# ──────────────────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
${BOLD}TriBoot v${VERSION}${NC} — Multi-Boot USB Creator

${BOLD}USAGE${NC}
    sudo $SCRIPT_NAME [OPTIONS]

${BOLD}OPTIONS${NC}
    -h, --help          Show this help message
    -d, --device DEV    Skip drive selection, use specified device (e.g., /dev/sdb)
    -n, --no-tui        Run in plain text mode (no gum TUI)
    -y, --yes           Skip confirmation prompts (for scripting)
    --reinstall         Show reinstall menu (GRUB only / grub.cfg only / full)
    --update-grub       Regenerate grub.cfg only (no install)
    --verify            Verify ISO checksums on TBOOT_ISO partition
    --list              List ISOs and disk usage on TBOOT_ISO partition

${BOLD}DESCRIPTION${NC}
    TriBoot partitions a USB drive into 3 sections:
      1. Boot partition (${BOOT_SIZE_MB}MB, FAT32) — GRUB2 bootloader (BIOS + UEFI)
      2. ISO partition (exFAT) — drop .iso files here to boot them
      3. Files partition (exFAT) — general-purpose storage

    On boot, GRUB2 auto-detects all ISOs on the ISO partition and builds
    a menu dynamically. Supports both legacy BIOS and UEFI boot.

${BOLD}REQUIREMENTS${NC}
    Root access, parted/sgdisk, grub-install (grub2-install),
    mkfs.fat, mkfs.exfat, lsblk

${BOLD}EXAMPLES${NC}
    sudo ./triboot.sh                    # Interactive mode (TUI if available)
    sudo ./triboot.sh -d /dev/sdb -y     # Non-interactive, target /dev/sdb
    sudo ./triboot.sh --no-tui           # Force plain text mode

EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Parse CLI arguments
# ──────────────────────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -d|--device)
                TARGET_DEVICE="$2"
                shift 2
                ;;
            -n|--no-tui)
                NO_TUI_FLAG=true
                USE_TUI=false
                shift
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            --reinstall)
                MODE="reinstall"
                shift
                ;;
            --update-grub)
                MODE="update-grub"
                shift
                ;;
            --verify)
                MODE="verify"
                shift
                ;;
            --list)
                MODE="list"
                shift
                ;;
            *)
                fatal "Unknown option: $1 (try --help)"
                ;;
        esac
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# Root check
# ──────────────────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "TriBoot must be run as root. Try: sudo $SCRIPT_NAME"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Dependency check
# ──────────────────────────────────────────────────────────────────────────────
check_dependencies() {
    local missing=()

    # GRUB install — check for either name
    if ! command -v grub-install &>/dev/null && ! command -v grub2-install &>/dev/null; then
        missing+=("grub-install (or grub2-install)")
    fi

    # Partitioning — need parted or sgdisk
    if ! command -v parted &>/dev/null && ! command -v sgdisk &>/dev/null; then
        missing+=("parted or sgdisk")
    fi

    for cmd in mkfs.fat mkfs.exfat lsblk; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        local msg="Missing required dependencies:"
        for dep in "${missing[@]}"; do
            msg+="\n  ✗ $dep"
        done
        if [[ "$USE_TUI" == "true" ]]; then
            tui_error "$msg"
        else
            error "$msg"
            echo ""
            info "Install them with your package manager, e.g.:"
            echo "  apt install parted grub-pc-bin grub-efi-amd64-bin dosfstools exfatprogs"
            echo "  pacman -S parted grub dosfstools exfatprogs"
        fi
        exit 1
    fi

    success "All dependencies found"
}

# ──────────────────────────────────────────────────────────────────────────────
# Detect GRUB install command
# ──────────────────────────────────────────────────────────────────────────────
GRUB_INSTALL=""
detect_grub_install() {
    if command -v grub-install &>/dev/null; then
        GRUB_INSTALL="grub-install"
    elif command -v grub2-install &>/dev/null; then
        GRUB_INSTALL="grub2-install"
    fi
    log "Using GRUB installer: $GRUB_INSTALL"
}

# ──────────────────────────────────────────────────────────────────────────────
# USB Drive Detection & Selection
# ──────────────────────────────────────────────────────────────────────────────
DRIVE_LIST=()      # /dev/sdX entries
DRIVE_INFO_LIST=() # /dev/sdX|size|model entries

gather_usb_drives() {
    DRIVE_LIST=()
    DRIVE_INFO_LIST=()

    # Primary: filter by USB transport
    while IFS= read -r line; do
        local name size model tran
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{print $3}')
        tran=$(echo "$line" | awk '{print $4}')

        [[ "$name" =~ [0-9]$ ]] && continue
        [[ "$tran" == "usb" ]] || continue

        DRIVE_LIST+=("/dev/$name")
        DRIVE_INFO_LIST+=("/dev/$name|$size|${model:-Unknown}")
    done < <(lsblk -dno NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v "^$" || true)

    # Also check by removable flag
    for dev in /sys/block/sd*; do
        [[ -e "$dev" ]] || continue
        local devname removable
        devname=$(basename "$dev")
        removable=$(cat "$dev/removable" 2>/dev/null || echo "0")
        if [[ "$removable" == "1" ]] && [[ ! " ${DRIVE_LIST[*]} " =~ " /dev/$devname " ]]; then
            local size model
            size=$(lsblk -dno SIZE "/dev/$devname" 2>/dev/null || echo "?")
            model=$(lsblk -dno MODEL "/dev/$devname" 2>/dev/null || echo "Unknown")
            DRIVE_LIST+=("/dev/$devname")
            DRIVE_INFO_LIST+=("/dev/$devname|$size|${model:-Unknown}")
        fi
    done

    if [[ ${#DRIVE_LIST[@]} -eq 0 ]]; then
        if [[ "$USE_TUI" == "true" ]]; then
            tui_error "No USB drives detected.\nInsert a USB drive and try again."
        fi
        fatal "No USB drives detected. Insert a USB drive and try again."
    fi
}

detect_usb_drives_tui() {
    gather_usb_drives

    # Build gum choose options: "/dev/sdX  •  32GB  •  Kingston DataTraveler"
    local options=()
    for entry in "${DRIVE_INFO_LIST[@]}"; do
        IFS='|' read -r dev size model <<< "$entry"
        options+=("${dev}  •  ${size}  •  ${model}")
    done

    gum style --foreground 245 "Select a USB drive (ALL DATA will be erased):"
    echo ""

    local selected
    selected=$(gum choose --cursor.foreground 212 --selected.foreground 212 "${options[@]}") || {
        info "Drive selection cancelled."
        exit 0
    }

    # Extract device path (first field before "  •  ")
    TARGET_DEVICE="${selected%%  •  *}"
    log "TUI drive selected: $TARGET_DEVICE"
}

detect_usb_drives_plain() {
    gather_usb_drives

    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  Detected USB Drives${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
    echo ""

    local i=1
    for entry in "${DRIVE_INFO_LIST[@]}"; do
        IFS='|' read -r dev size model <<< "$entry"
        printf "  ${BOLD}[%d]${NC}  %-12s  %-10s  %s\n" "$i" "$dev" "$size" "$model"
        ((i++))
    done
    echo ""

    local selection
    while true; do
        read -rp "$(echo -e "${YELLOW}Select drive [1-${#DRIVE_LIST[@]}]:${NC} ")" selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#DRIVE_LIST[@]} )); then
            TARGET_DEVICE="${DRIVE_LIST[$((selection-1))]}"
            break
        fi
        warn "Invalid selection. Enter a number between 1 and ${#DRIVE_LIST[@]}"
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# Partition size customization (TUI)
# ──────────────────────────────────────────────────────────────────────────────
customize_partitions_tui() {
    gum style --foreground 245 "Boot partition is always ${BOOT_SIZE_MB}MB (FAT32). Choose how to split the rest:"
    echo ""

    local choice
    choice=$(gum choose --cursor.foreground 212 --selected.foreground 212 \
        "Standard (512MB Boot / 60% ISO / Rest Files)" \
        "Custom split") || {
        info "Partition customization cancelled."
        exit 0
    }

    if [[ "$choice" == "Custom split" ]]; then
        local pct
        while true; do
            pct=$(gum input --placeholder "Enter ISO percentage (10-90)" --prompt "> " --prompt.foreground 212 --value "60") || {
                info "Partition customization cancelled."
                exit 0
            }
            if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 10 && pct <= 90 )); then
                ISO_PERCENT=$pct
                log "Custom ISO percent: $ISO_PERCENT"
                break
            fi
            gum_error_msg "Please enter a number between 10 and 90."
        done
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Confirmation
# ──────────────────────────────────────────────────────────────────────────────
confirm_wipe_tui() {
    local dev="$1"
    local size model
    size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "unknown")
    model=$(lsblk -dno MODEL "$dev" 2>/dev/null || echo "unknown")

    local files_pct=$((100 - ISO_PERCENT))

    if [[ "$AUTO_YES" == "true" ]]; then
        warn "Auto-confirm enabled (--yes). Proceeding..."
        return 0
    fi

    echo ""
    gum style --border rounded --border-foreground 196 --padding "1 2" --foreground 196 --bold \
        "⚠  WARNING — DATA LOSS" "" \
        "Device:  $dev" \
        "Size:    $size" \
        "Model:   $model" "" \
        "Partition layout:" \
        "  1. Boot:  ${BOOT_SIZE_MB}MB (FAT32, GRUB2)" \
        "  2. ISO:   ${ISO_PERCENT}% of remaining (exFAT)" \
        "  3. Files: ${files_pct}% of remaining (exFAT)"
    echo ""

    gum confirm "Proceed? ALL DATA will be erased." --affirmative "Yes, erase" --negative "Cancel" --prompt.foreground 196 || {
        info "Aborted by user."
        exit 0
    }
}

confirm_wipe_plain() {
    local dev="$1"
    local size model
    size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "unknown")
    model=$(lsblk -dno MODEL "$dev" 2>/dev/null || echo "unknown")

    echo ""
    echo -e "${RED}${BOLD}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║           ⚠  WARNING — DATA LOSS ⚠           ║${NC}"
    echo -e "${RED}${BOLD}╠═══════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║${NC}  Device:  ${BOLD}$dev${NC}"
    echo -e "${RED}${BOLD}║${NC}  Size:    ${BOLD}$size${NC}"
    echo -e "${RED}${BOLD}║${NC}  Model:   ${BOLD}$model${NC}"
    echo -e "${RED}${BOLD}║${NC}"
    echo -e "${RED}${BOLD}║${NC}  Partition layout:"
    echo -e "${RED}${BOLD}║${NC}    Boot:  ${BOOT_SIZE_MB}MB  |  ISO: ${ISO_PERCENT}%  |  Files: $((100-ISO_PERCENT))%"
    echo -e "${RED}${BOLD}║${NC}"
    echo -e "${RED}${BOLD}║${NC}  ALL DATA on this device will be ${RED}ERASED${NC}."
    echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$AUTO_YES" == "true" ]]; then
        warn "Auto-confirm enabled (--yes). Proceeding..."
        return 0
    fi

    local confirm
    read -rp "$(echo -e "${RED}Type '${BOLD}YES${NC}${RED}' to continue, anything else to abort:${NC} ")" confirm
    if [[ "$confirm" != "YES" ]]; then
        info "Aborted by user."
        exit 0
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Unmount all partitions on device
# ──────────────────────────────────────────────────────────────────────────────
unmount_device() {
    local dev="$1"
    info "Unmounting all partitions on $dev..."
    for part in "${dev}"*; do
        if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^$part "; then
            umount "$part" 2>/dev/null || true
            log "Unmounted $part"
        fi
    done
    sleep 1
    sync
}

# ──────────────────────────────────────────────────────────────────────────────
# Step wrapper — runs a step, catches errors
# ──────────────────────────────────────────────────────────────────────────────
run_step() {
    local step_name="$1"
    shift
    log "STEP START: $step_name"
    if "$@"; then
        log "STEP OK: $step_name"
        return 0
    else
        local rc=$?
        log "STEP FAILED: $step_name (exit $rc)"
        tui_error "Step failed: $step_name\n\nCheck $LOG_FILE for details."
        return $rc
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Partition the drive
# ──────────────────────────────────────────────────────────────────────────────
partition_drive() {
    local dev="$1"

    info "Wiping partition table on $dev..."
    run_logged "wipefs" wipefs -af "$dev"
    run_logged "dd-zero" dd if=/dev/zero of="$dev" bs=1M count=1 status=none
    sync
    log "Partition table wiped"

    info "Creating GPT partition table..."

    if command -v sgdisk &>/dev/null; then
        run_logged "sgdisk-zap" sgdisk --zap-all "$dev"
        run_logged "sgdisk-p1" sgdisk -n 1:0:+${BOOT_SIZE_MB}M -t 1:ef00 -c 1:"$BOOT_LABEL" "$dev"

        # Calculate ISO partition size in sectors (sgdisk doesn't support %)
        local total_sectors sector_size boot_sectors remaining_sectors iso_sectors
        sector_size=$(sgdisk -p "$dev" 2>/dev/null | awk '/^Sector size/{print $4}')
        total_sectors=$(sgdisk -p "$dev" 2>/dev/null | awk '/^Disk \/dev\//{print $3}' | head -1)
        boot_sectors=$(( (BOOT_SIZE_MB * 1024 * 1024) / sector_size ))
        # Account for GPT overhead (~2048 sectors at start, ~34 at end)
        remaining_sectors=$(( total_sectors - boot_sectors - 2048 - 34 ))
        iso_sectors=$(( (remaining_sectors * ISO_PERCENT) / 100 ))

        run_logged "sgdisk-p2" sgdisk -n 2:0:+${iso_sectors} -t 2:0700 -c 2:"$ISO_LABEL" "$dev"
        run_logged "sgdisk-p3" sgdisk -n 3:0:0 -t 3:0700 -c 3:"$FILES_LABEL" "$dev"
        run_logged "sgdisk-hybrid" sgdisk --hybrid 1:2:3 "$dev"
    elif command -v parted &>/dev/null; then
        run_logged "parted-mklabel" parted -s "$dev" mklabel gpt

        local boot_end="${BOOT_SIZE_MB}MiB"
        run_logged "parted-p1" parted -s "$dev" mkpart "$BOOT_LABEL" fat32 1MiB "$boot_end"
        run_logged "parted-esp" parted -s "$dev" set 1 esp on

        local total_mib
        total_mib=$(parted -s "$dev" unit MiB print 2>/dev/null | awk '/Disk.*MiB/{gsub(/MiB/,""); print $3}')
        local remaining=$((total_mib - BOOT_SIZE_MB))
        local iso_size=$(( (remaining * ISO_PERCENT) / 100 ))
        local iso_end=$(( BOOT_SIZE_MB + iso_size ))

        run_logged "parted-p2" parted -s "$dev" mkpart "$ISO_LABEL" ntfs "${boot_end}" "${iso_end}MiB"
        run_logged "parted-p3" parted -s "$dev" mkpart "$FILES_LABEL" ntfs "${iso_end}MiB" 100%
    else
        fatal "No partitioning tool found (need sgdisk or parted)"
    fi

    partprobe "$dev" 2>/dev/null || true
    sleep 2
    sync

    success "Partitioned $dev (Boot: ${BOOT_SIZE_MB}MB, ISO: ${ISO_PERCENT}% remaining, Files: rest)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Format partitions
# ──────────────────────────────────────────────────────────────────────────────
format_partitions() {
    local dev="$1"
    local p1="${dev}1"
    local p2="${dev}2"
    local p3="${dev}3"

    if [[ "$dev" =~ [0-9]$ ]]; then
        p1="${dev}p1"
        p2="${dev}p2"
        p3="${dev}p3"
    fi

    local retries=10
    while [[ ! -b "$p1" ]] && (( retries > 0 )); do
        sleep 1
        partprobe "$dev" 2>/dev/null || true
        ((retries--))
    done

    [[ -b "$p1" ]] || fatal "Partition $p1 not found after partitioning. partprobe may have failed to re-read the partition table — try unplugging and re-inserting the USB drive."
    [[ -b "$p2" ]] || fatal "Partition $p2 not found after partitioning. partprobe may have failed to re-read the partition table — try unplugging and re-inserting the USB drive."
    [[ -b "$p3" ]] || fatal "Partition $p3 not found after partitioning. partprobe may have failed to re-read the partition table — try unplugging and re-inserting the USB drive."

    info "Formatting boot partition ($p1) as FAT32..."
    run_logged "mkfs-boot" mkfs.fat -F 32 -n "$BOOT_LABEL" "$p1"
    success "Boot partition formatted"

    info "Formatting ISO partition ($p2) as exFAT..."
    run_logged "mkfs-iso" mkfs.exfat -n "$ISO_LABEL" "$p2"
    success "ISO partition formatted"

    info "Formatting Files partition ($p3) as exFAT..."
    run_logged "mkfs-files" mkfs.exfat -n "$FILES_LABEL" "$p3"
    success "Files partition formatted"
}

# ──────────────────────────────────────────────────────────────────────────────
# Install GRUB2 (Dual BIOS + UEFI)
# ──────────────────────────────────────────────────────────────────────────────
install_grub() {
    local dev="$1"
    local p1="${dev}1"

    if [[ "$dev" =~ [0-9]$ ]]; then
        p1="${dev}p1"
    fi

    local boot_mount
    boot_mount=$(mktemp -d /tmp/triboot_boot.XXXXXX)
    MOUNT_POINTS+=("$boot_mount")

    run_logged "mount-boot" mount "$p1" "$boot_mount"
    log "Mounted $p1 at $boot_mount"

    mkdir -p "$boot_mount/boot/grub"
    mkdir -p "$boot_mount/EFI/BOOT"

    info "Installing GRUB2 for UEFI..."
    run_logged "grub-uefi" "$GRUB_INSTALL" \
        --target=x86_64-efi \
        --efi-directory="$boot_mount" \
        --boot-directory="$boot_mount/boot" \
        --removable \
        --no-nvram || {
        warn "UEFI GRUB install had issues — check $LOG_FILE"
    }
    success "GRUB2 UEFI installed"

    info "Installing GRUB2 for BIOS..."
    run_logged "grub-bios" "$GRUB_INSTALL" \
        --target=i386-pc \
        --boot-directory="$boot_mount/boot" \
        "$dev" || {
        warn "BIOS GRUB install had issues — check $LOG_FILE"
    }
    success "GRUB2 BIOS installed"

    write_grub_cfg "$boot_mount/boot/grub/grub.cfg"
    success "grub.cfg written"

    sync
    umount "$boot_mount" >> "$LOG_FILE" 2>&1
    rmdir "$boot_mount" 2>/dev/null || true
    local _tmp=(); for _mp in "${MOUNT_POINTS[@]}"; do [[ "$_mp" != "$boot_mount" ]] && _tmp+=("$_mp"); done; MOUNT_POINTS=("${_tmp[@]+"${_tmp[@]}"}")

    success "GRUB2 installation complete (BIOS + UEFI)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Generate grub.cfg with auto-scanning
# ──────────────────────────────────────────────────────────────────────────────
write_grub_cfg() {
    local cfg_path="$1"

    cat > "$cfg_path" << 'GRUBCFG'
# TriBoot — Auto-generated GRUB Configuration
# This file is auto-generated by TriBoot. Do not edit manually.

set timeout=10
set default=0

# Load modules
insmod all_video
insmod gfxterm
insmod png
insmod part_gpt
insmod part_msdos
insmod fat
insmod exfat
insmod iso9660
insmod loopback
insmod search
insmod search_fs_label
insmod search_fs_uuid
insmod regexp

# Set up display
if loadfont /boot/grub/fonts/unicode.pf2 ; then
    set gfxmode=auto
    terminal_output gfxterm
fi

# Colors
set color_normal=light-gray/black
set color_highlight=white/dark-gray
set menu_color_normal=light-gray/black
set menu_color_highlight=white/dark-gray

# TriBoot header
menuentry "═══════════════════════════════════════" {
    true
}
menuentry "   TriBoot — Multi-Boot USB" {
    true
}
menuentry "═══════════════════════════════════════" {
    true
}
menuentry " " {
    true
}

# ──────────────────────────────────────────────────────────
# Auto-scan for ISOs on TBOOT_ISO partition
# ──────────────────────────────────────────────────────────

# Find the ISO partition
search --no-floppy --label TBOOT_ISO --set=isopart

if [ -n "$isopart" ]; then
    set root="$isopart"

    # Scan for .iso files
    for isofile in /*.iso; do
        if [ -e "$isofile" ]; then
            # Extract filename without path for display
            regexp --set=isoname '/(.*)\.iso$' "$isofile"
            if [ -z "$isoname" ]; then
                set isoname="$isofile"
            fi

            menuentry "Boot: ${isoname}" "$isofile" {
                set isofile="$2"
                search --no-floppy --label TBOOT_ISO --set=root
                loopback loop "$isofile"

                # Try common boot configurations
                # Ubuntu/Debian/Mint
                if [ -e "(loop)/casper/vmlinuz" ]; then
                    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename="$isofile" quiet splash --
                    initrd (loop)/casper/initrd
                # Fedora/RHEL
                elif [ -e "(loop)/isolinux/vmlinuz" ]; then
                    linux (loop)/isolinux/vmlinuz iso-scan/filename="$isofile" findiso="$isofile" rd.live.image quiet
                    initrd (loop)/isolinux/initrd.img
                # Arch Linux
                elif [ -e "(loop)/arch/boot/x86_64/vmlinuz-linux" ]; then
                    linux (loop)/arch/boot/x86_64/vmlinuz-linux archisobasedir=arch img_dev=/dev/disk/by-label/TBOOT_ISO img_loop="$isofile" earlymodules=loop
                    initrd (loop)/arch/boot/x86_64/initramfs-linux.img
                # openSUSE
                elif [ -e "(loop)/boot/x86_64/loader/linux" ]; then
                    linux (loop)/boot/x86_64/loader/linux iso-scan/filename="$isofile" splash=silent quiet
                    initrd (loop)/boot/x86_64/loader/initrd
                # Manjaro
                elif [ -e "(loop)/boot/vmlinuz-x86_64" ]; then
                    linux (loop)/boot/vmlinuz-x86_64 img_dev=/dev/disk/by-label/TBOOT_ISO img_loop="$isofile" misobasedir=manjaro
                    initrd (loop)/boot/initramfs-x86_64.img
                # Generic — try common paths
                elif [ -e "(loop)/vmlinuz" ]; then
                    linux (loop)/vmlinuz iso-scan/filename="$isofile" quiet splash --
                    initrd (loop)/initrd.img
                elif [ -e "(loop)/boot/vmlinuz" ]; then
                    linux (loop)/boot/vmlinuz iso-scan/filename="$isofile" quiet splash --
                    initrd (loop)/boot/initrd.img
                # Fallback — chainload
                else
                    chainloader (loop)+1
                fi
            }
        fi
    done

    # Also scan subdirectories one level deep
    for isofile in /*/*.iso; do
        if [ -e "$isofile" ]; then
            regexp --set=isoname '/.*/(.*)\\.iso$' "$isofile"
            if [ -z "$isoname" ]; then
                set isoname="$isofile"
            fi

            menuentry "Boot: ${isoname}" "$isofile" {
                set isofile="$2"
                search --no-floppy --label TBOOT_ISO --set=root
                loopback loop "$isofile"

                if [ -e "(loop)/casper/vmlinuz" ]; then
                    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename="$isofile" quiet splash --
                    initrd (loop)/casper/initrd
                elif [ -e "(loop)/isolinux/vmlinuz" ]; then
                    linux (loop)/isolinux/vmlinuz iso-scan/filename="$isofile" findiso="$isofile" rd.live.image quiet
                    initrd (loop)/isolinux/initrd.img
                elif [ -e "(loop)/arch/boot/x86_64/vmlinuz-linux" ]; then
                    linux (loop)/arch/boot/x86_64/vmlinuz-linux archisobasedir=arch img_dev=/dev/disk/by-label/TBOOT_ISO img_loop="$isofile" earlymodules=loop
                    initrd (loop)/arch/boot/x86_64/initramfs-linux.img
                elif [ -e "(loop)/boot/x86_64/loader/linux" ]; then
                    linux (loop)/boot/x86_64/loader/linux iso-scan/filename="$isofile" splash=silent quiet
                    initrd (loop)/boot/x86_64/loader/initrd
                elif [ -e "(loop)/boot/vmlinuz-x86_64" ]; then
                    linux (loop)/boot/vmlinuz-x86_64 img_dev=/dev/disk/by-label/TBOOT_ISO img_loop="$isofile" misobasedir=manjaro
                    initrd (loop)/boot/initramfs-x86_64.img
                elif [ -e "(loop)/vmlinuz" ]; then
                    linux (loop)/vmlinuz iso-scan/filename="$isofile" quiet splash --
                    initrd (loop)/initrd.img
                else
                    chainloader (loop)+1
                fi
            }
        fi
    done
else
    menuentry "⚠ ISO partition (TBOOT_ISO) not found" {
        true
    }
fi

# ──────────────────────────────────────────────────────────
# Utilities
# ──────────────────────────────────────────────────────────

menuentry " " {
    true
}
menuentry "───────────────────────────────────────" {
    true
}

menuentry "Boot from local disk" {
    search --no-floppy --set=root --hint hd0,gpt1 --fs-uuid --hint-bios=hd0
    chainloader +1
    boot
}

menuentry "Reboot" {
    reboot
}

menuentry "Shutdown" {
    halt
}
GRUBCFG

    log "grub.cfg written to $cfg_path"
}

# ──────────────────────────────────────────────────────────────────────────────
# Detect existing TriBoot installation
# ──────────────────────────────────────────────────────────────────────────────
detect_existing_triboot() {
    # Returns 0 if TRIBOOT_BOOT partition found, sets TRIBOOT_DEVICE
    local dev
    dev=$(blkid -L "$BOOT_LABEL" 2>/dev/null || true)
    if [[ -n "$dev" ]]; then
        # Strip partition number to get the parent device
        TRIBOOT_DEVICE=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
        if [[ -n "$TRIBOOT_DEVICE" ]]; then
            TRIBOOT_DEVICE="/dev/$TRIBOOT_DEVICE"
        fi
        log "Existing TriBoot detected on $dev (disk: $TRIBOOT_DEVICE)"
        return 0
    fi
    return 1
}

# Helper: get partition device from label
get_part_by_label() {
    blkid -L "$1" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Reinstall menu
# ──────────────────────────────────────────────────────────────────────────────
show_reinstall_menu() {
    echo ""
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  TriBoot — Existing Installation Detected${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "  Device: ${BOLD}${TRIBOOT_DEVICE:-unknown}${NC}"
    echo ""
    echo -e "  ${BOLD}[1]${NC}  Reinstall GRUB only (preserves ISOs & files)"
    echo -e "  ${BOLD}[2]${NC}  Update grub.cfg only (regenerate boot menu)"
    echo -e "  ${BOLD}[3]${NC}  Full reinstall (wipe everything)"
    echo -e "  ${BOLD}[4]${NC}  Cancel"
    echo ""

    local choice
    while true; do
        read -rp "$(echo -e "${YELLOW}Select option [1-4]:${NC} ")" choice
        case "$choice" in
            1) do_reinstall_grub; return 0 ;;
            2) do_update_grub; return 0 ;;
            3) return 1 ;;  # signal: proceed with full reinstall
            4) info "Cancelled."; exit 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

do_reinstall_grub() {
    local boot_part
    boot_part=$(get_part_by_label "$BOOT_LABEL")
    [[ -n "$boot_part" ]] || fatal "Cannot find $BOOT_LABEL partition"

    local dev="$TRIBOOT_DEVICE"
    [[ -n "$dev" ]] || fatal "Cannot determine parent device"

    detect_grub_install

    local boot_mount
    boot_mount=$(mktemp -d /tmp/triboot_boot.XXXXXX)
    MOUNT_POINTS+=("$boot_mount")

    info "Mounting $boot_part..."
    run_logged "mount-boot" mount "$boot_part" "$boot_mount"

    mkdir -p "$boot_mount/boot/grub"
    mkdir -p "$boot_mount/EFI/BOOT"

    info "Installing GRUB2 for UEFI..."
    run_logged "grub-uefi" "$GRUB_INSTALL" \
        --target=x86_64-efi \
        --efi-directory="$boot_mount" \
        --boot-directory="$boot_mount/boot" \
        --removable \
        --no-nvram || warn "UEFI GRUB install had issues — check $LOG_FILE"
    success "GRUB2 UEFI installed"

    info "Installing GRUB2 for BIOS..."
    run_logged "grub-bios" "$GRUB_INSTALL" \
        --target=i386-pc \
        --boot-directory="$boot_mount/boot" \
        "$dev" || warn "BIOS GRUB install had issues — check $LOG_FILE"
    success "GRUB2 BIOS installed"

    write_grub_cfg "$boot_mount/boot/grub/grub.cfg"
    success "grub.cfg written"

    sync
    umount "$boot_mount" >> "$LOG_FILE" 2>&1
    rmdir "$boot_mount" 2>/dev/null || true
    local _tmp=(); for _mp in "${MOUNT_POINTS[@]}"; do [[ "$_mp" != "$boot_mount" ]] && _tmp+=("$_mp"); done; MOUNT_POINTS=("${_tmp[@]+"${_tmp[@]}"}")

    success "GRUB reinstall complete — ISOs and files untouched"
}

do_update_grub() {
    local boot_part
    boot_part=$(get_part_by_label "$BOOT_LABEL")
    [[ -n "$boot_part" ]] || fatal "Cannot find $BOOT_LABEL partition"

    local boot_mount
    boot_mount=$(mktemp -d /tmp/triboot_boot.XXXXXX)
    MOUNT_POINTS+=("$boot_mount")

    info "Mounting $boot_part..."
    run_logged "mount-boot" mount "$boot_part" "$boot_mount"

    mkdir -p "$boot_mount/boot/grub"

    write_grub_cfg "$boot_mount/boot/grub/grub.cfg"
    success "grub.cfg regenerated"

    sync
    umount "$boot_mount" >> "$LOG_FILE" 2>&1
    rmdir "$boot_mount" 2>/dev/null || true
    local _tmp=(); for _mp in "${MOUNT_POINTS[@]}"; do [[ "$_mp" != "$boot_mount" ]] && _tmp+=("$_mp"); done; MOUNT_POINTS=("${_tmp[@]+"${_tmp[@]}"}")

    success "Boot menu updated — no other changes made"
}

# ──────────────────────────────────────────────────────────────────────────────
# ISO Verification
# ──────────────────────────────────────────────────────────────────────────────
verify_isos() {
    local iso_part
    iso_part=$(get_part_by_label "$ISO_LABEL")
    [[ -n "$iso_part" ]] || fatal "Cannot find $ISO_LABEL partition. Is TriBoot installed?"

    local iso_mount
    iso_mount=$(mktemp -d /tmp/triboot_iso.XXXXXX)
    MOUNT_POINTS+=("$iso_mount")

    info "Mounting $iso_part..."
    run_logged "mount-iso" mount "$iso_part" "$iso_mount"

    echo ""
    echo -e "${BOLD}${CYAN}ISO Checksum Verification${NC}"
    echo -e "${CYAN}─────────────────────────────────────────${NC}"

    local found=0 pass=0 fail=0 nocheck=0
    while IFS= read -r -d '' isofile; do
        ((found++))
        local basename
        basename=$(basename "$isofile")
        local result=""

        if [[ -f "${isofile}.sha256" ]]; then
            local expected
            expected=$(awk '{print $1}' "${isofile}.sha256")
            local actual
            actual=$(sha256sum "$isofile" | awk '{print $1}')
            if [[ "$expected" == "$actual" ]]; then
                result="${GREEN}PASS${NC} (SHA256)"
                ((pass++))
            else
                result="${RED}FAIL${NC} (SHA256)"
                ((fail++))
            fi
        elif [[ -f "${isofile}.md5" ]]; then
            local expected
            expected=$(awk '{print $1}' "${isofile}.md5")
            local actual
            actual=$(md5sum "$isofile" | awk '{print $1}')
            if [[ "$expected" == "$actual" ]]; then
                result="${GREEN}PASS${NC} (MD5)"
                ((pass++))
            else
                result="${RED}FAIL${NC} (MD5)"
                ((fail++))
            fi
        else
            # Check for shared checksum files (SHA256SUMS, MD5SUMS) in same directory
            local isodir isobase
            isodir=$(dirname "$isofile")
            isobase=$(basename "$isofile")
            local found_shared=false

            if [[ -f "$isodir/SHA256SUMS" ]]; then
                local expected
                expected=$(grep -F "$isobase" "$isodir/SHA256SUMS" 2>/dev/null | awk '{print $1}' | head -1)
                if [[ -n "$expected" ]]; then
                    local actual
                    actual=$(sha256sum "$isofile" | awk '{print $1}')
                    if [[ "$expected" == "$actual" ]]; then
                        result="${GREEN}PASS${NC} (SHA256SUMS)"
                        ((pass++))
                    else
                        result="${RED}FAIL${NC} (SHA256SUMS)"
                        ((fail++))
                    fi
                    found_shared=true
                fi
            fi

            if [[ "$found_shared" == "false" && -f "$isodir/MD5SUMS" ]]; then
                local expected
                expected=$(grep -F "$isobase" "$isodir/MD5SUMS" 2>/dev/null | awk '{print $1}' | head -1)
                if [[ -n "$expected" ]]; then
                    local actual
                    actual=$(md5sum "$isofile" | awk '{print $1}')
                    if [[ "$expected" == "$actual" ]]; then
                        result="${GREEN}PASS${NC} (MD5SUMS)"
                        ((pass++))
                    else
                        result="${RED}FAIL${NC} (MD5SUMS)"
                        ((fail++))
                    fi
                    found_shared=true
                fi
            fi

            if [[ "$found_shared" == "false" ]]; then
                result="${YELLOW}NO CHECKSUM${NC}"
                ((nocheck++))
            fi
        fi

        echo -e "  ${BOLD}$basename${NC}  →  $result"
    done < <(find "$iso_mount" -maxdepth 2 -name '*.iso' -print0 2>/dev/null)

    echo ""
    if [[ $found -eq 0 ]]; then
        warn "No ISO files found on $ISO_LABEL"
    else
        echo -e "  Total: $found  |  ${GREEN}Pass: $pass${NC}  |  ${RED}Fail: $fail${NC}  |  ${YELLOW}No checksum: $nocheck${NC}"
    fi
    echo ""

    sync
    umount "$iso_mount" >> "$LOG_FILE" 2>&1
    rmdir "$iso_mount" 2>/dev/null || true
    local _tmp=(); for _mp in "${MOUNT_POINTS[@]}"; do [[ "$_mp" != "$iso_mount" ]] && _tmp+=("$_mp"); done; MOUNT_POINTS=("${_tmp[@]+"${_tmp[@]}"}")
}

# ──────────────────────────────────────────────────────────────────────────────
# ISO Info / List
# ──────────────────────────────────────────────────────────────────────────────
list_isos() {
    local iso_part
    iso_part=$(get_part_by_label "$ISO_LABEL")
    [[ -n "$iso_part" ]] || fatal "Cannot find $ISO_LABEL partition. Is TriBoot installed?"

    local iso_mount
    iso_mount=$(mktemp -d /tmp/triboot_iso.XXXXXX)
    MOUNT_POINTS+=("$iso_mount")

    info "Mounting $iso_part..."
    run_logged "mount-iso" mount "$iso_part" "$iso_mount"

    echo ""
    echo -e "${BOLD}${CYAN}ISOs on TBOOT_ISO${NC}"
    echo -e "${CYAN}─────────────────────────────────────────${NC}"

    local count=0
    while IFS= read -r -d '' isofile; do
        ((count++))
        local basename size
        basename=$(basename "$isofile")
        size=$(du -h "$isofile" 2>/dev/null | awk '{print $1}')
        printf "  %-50s %8s\n" "$basename" "$size"
    done < <(find "$iso_mount" -maxdepth 2 -name '*.iso' -print0 2>/dev/null | sort -z)

    echo ""
    if [[ $count -eq 0 ]]; then
        warn "No ISO files found"
    else
        echo -e "  ${BOLD}$count ISO(s) found${NC}"
    fi

    # Disk usage
    local used avail
    used=$(df -h "$iso_mount" | awk 'NR==2{print $3}')
    avail=$(df -h "$iso_mount" | awk 'NR==2{print $4}')
    echo -e "  Space used: ${BOLD}$used${NC}  |  Available: ${BOLD}$avail${NC}"
    echo ""

    sync
    umount "$iso_mount" >> "$LOG_FILE" 2>&1
    rmdir "$iso_mount" 2>/dev/null || true
    local _tmp=(); for _mp in "${MOUNT_POINTS[@]}"; do [[ "$_mp" != "$iso_mount" ]] && _tmp+=("$_mp"); done; MOUNT_POINTS=("${_tmp[@]+"${_tmp[@]}"}")
}

# ──────────────────────────────────────────────────────────────────────────────
# Print banner
# ──────────────────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                              ║"
    echo "  ║   ████████╗██████╗ ██╗██████╗  ██████╗  ██████╗ ████████╗   ║"
    echo "  ║   ╚══██╔══╝██╔══██╗██║██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝   ║"
    echo "  ║      ██║   ██████╔╝██║██████╔╝██║   ██║██║   ██║   ██║      ║"
    echo "  ║      ██║   ██╔══██╗██║██╔══██╗██║   ██║██║   ██║   ██║      ║"
    echo "  ║      ██║   ██║  ██║██║██████╔╝╚██████╔╝╚██████╔╝   ██║      ║"
    echo "  ║      ╚═╝   ╚═╝  ╚═╝╚═╝╚═════╝  ╚═════╝  ╚═════╝    ╚═╝      ║"
    echo "  ║                                                              ║"
    echo "  ║            TriBoot v${VERSION} — Multi-Boot USB Creator          ║"
    echo "  ║                                                              ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Print success summary
# ──────────────────────────────────────────────────────────────────────────────
print_success() {
    local dev="$1"
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║           TriBoot Setup Complete!              ║${NC}"
    echo -e "${GREEN}${BOLD}╠════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  Device:  ${BOLD}$dev${NC}"
    echo -e "${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  Partitions created:"
    echo -e "${GREEN}${BOLD}║${NC}    1. ${BOLD}TRIBOOT_BOOT${NC}  — GRUB2 bootloader (BIOS+UEFI)"
    echo -e "${GREEN}${BOLD}║${NC}    2. ${BOLD}TRIBOOT_ISO${NC}   — Drop your .iso files here"
    echo -e "${GREEN}${BOLD}║${NC}    3. ${BOLD}TRIBOOT_FILES${NC} — General file storage"
    echo -e "${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}Next steps:${NC}"
    echo -e "${GREEN}${BOLD}║${NC}    1. Mount or open the ${BOLD}TRIBOOT_ISO${NC} partition"
    echo -e "${GREEN}${BOLD}║${NC}    2. Copy any .iso files you want to boot"
    echo -e "${GREEN}${BOLD}║${NC}    3. Boot from the USB — ISOs appear automatically"
    echo -e "${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  Log: ${LOG_FILE}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Validate target device (min size + system disk protection)
# ──────────────────────────────────────────────────────────────────────────────
validate_target_device() {
    [[ -n "$TARGET_DEVICE" ]] || return 0  # Not selected yet

    # Fix #9: Minimum 2GB size check
    local size_bytes
    size_bytes=$(lsblk -bdno SIZE "$TARGET_DEVICE" 2>/dev/null || echo "0")
    local min_bytes=$((2 * 1024 * 1024 * 1024))  # 2GB
    if (( size_bytes < min_bytes )); then
        local size_human
        size_human=$(lsblk -dno SIZE "$TARGET_DEVICE" 2>/dev/null || echo "?")
        fatal "Device $TARGET_DEVICE is too small ($size_human). Minimum size is 2GB."
    fi

    # Fix #10: System disk protection
    local is_system=false
    while IFS= read -r mountpoint; do
        if [[ "$mountpoint" == "/" || "$mountpoint" == "/home" ]]; then
            is_system=true
            break
        fi
    done < <(lsblk -no MOUNTPOINT "$TARGET_DEVICE" 2>/dev/null | grep -v "^$" || true)

    if [[ "$is_system" == "true" ]]; then
        warn "⚠ $TARGET_DEVICE appears to be a SYSTEM DISK (has / or /home mounted)!"
        if [[ "$USE_TUI" == "true" ]]; then
            gum style --border double --border-foreground 196 --padding "1 2" --foreground 196 --bold \
                "⚠  SYSTEM DISK DETECTED" "" \
                "$TARGET_DEVICE appears to contain your system disk!" \
                "A partition on this device is mounted as / or /home." "" \
                "Continuing WILL DESTROY YOUR OPERATING SYSTEM."
            echo ""
            gum confirm "Are you ABSOLUTELY sure?" --affirmative "DESTROY" --negative "Cancel" --prompt.foreground 196 || {
                info "Aborted — system disk protection."
                exit 0
            }
        elif [[ "$AUTO_YES" != "true" ]]; then
            local confirm
            read -rp "$(echo -e "${RED}${BOLD}THIS IS A SYSTEM DISK! Type 'DESTROY' to continue:${NC} ")" confirm
            if [[ "$confirm" != "DESTROY" ]]; then
                info "Aborted — system disk protection."
                exit 0
            fi
        else
            fatal "Refusing to auto-wipe system disk $TARGET_DEVICE. Remove --yes or use a different device."
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# TUI progress flow (gum spin)
# ──────────────────────────────────────────────────────────────────────────────
run_with_gum_progress() {
    local dev="$1"

    # Each step: show spinner text, run the actual function, show checkmark
    # We use a FIFO so gum spin waits until the real work is done
    local fifo
    fifo=$(mktemp -u /tmp/triboot_fifo.XXXXXX)

    _gum_step() {
        local title="$1" done_msg="$2"
        shift 2
        mkfifo "$fifo"
        gum spin --spinner dot --title "$title" -- bash -c "cat '$fifo' > /dev/null" &
        local spin_pid=$!
        "$@"
        local rc=$?
        echo done > "$fifo"
        wait "$spin_pid" 2>/dev/null || true
        rm -f "$fifo"
        if [[ $rc -eq 0 ]]; then
            gum_step_done "$done_msg"
        else
            gum_error_msg "✗ $done_msg — FAILED"
            return $rc
        fi
    }

    _gum_step "Unmounting device..." "Device unmounted" \
        unmount_device "$dev"

    _gum_step "Wiping & partitioning $dev..." "Partitioning complete" \
        partition_drive "$dev"

    _gum_step "Formatting partitions..." "Formatting complete" \
        format_partitions "$dev"

    _gum_step "Installing GRUB2 (BIOS + UEFI)..." "GRUB2 installed" \
        install_grub "$dev"

    unset -f _gum_step
}

# Legacy whiptail/dialog gauge — kept for reference:
# run_with_gauge() {
#     local dev="$1"
#     (
#         echo -e "XXX\n5\nUnmounting device...\nXXX"
#         unmount_device "$dev" >> "$LOG_FILE" 2>&1
#         echo -e "XXX\n20\nPartitioning $dev...\nXXX"
#         partition_drive "$dev" >> "$LOG_FILE" 2>&1
#         echo -e "XXX\n40\nFormatting...\nXXX"
#         format_partitions "$dev" >> "$LOG_FILE" 2>&1
#         echo -e "XXX\n75\nInstalling GRUB2...\nXXX"
#         install_grub "$dev" >> "$LOG_FILE" 2>&1
#         echo -e "XXX\n100\nDone!\nXXX"
#         sleep 1
#     ) | $TUI_CMD --title "TriBoot — Installing" --gauge "Starting..." 8 60 0
# }

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
    # Initialize log
    echo "=== TriBoot v${VERSION} — $(date) ===" > "$LOG_FILE"

    parse_args "$@"

    # --help exits before anything else (no TUI)
    detect_tui

    # Handle special modes that don't need full install flow
    if [[ "$MODE" == "verify" ]]; then
        check_root
        verify_isos
        exit 0
    fi

    if [[ "$MODE" == "list" ]]; then
        check_root
        list_isos
        exit 0
    fi

    if [[ "$MODE" == "update-grub" ]]; then
        check_root
        do_update_grub
        exit 0
    fi

    if [[ "$MODE" == "reinstall" ]]; then
        check_root
        check_dependencies
        detect_grub_install
        if detect_existing_triboot; then
            local menu_rc=0
            show_reinstall_menu || menu_rc=$?
            if [[ $menu_rc -eq 0 ]]; then
                exit 0  # Handled (options 1, 2, or 4)
            fi
            # Option 3 — fall through to full install
            info "Proceeding with full reinstall..."
            if [[ -n "$TRIBOOT_DEVICE" ]]; then
                TARGET_DEVICE="$TRIBOOT_DEVICE"
            fi
        else
            warn "No existing TriBoot installation found. Proceeding with fresh install..."
        fi
    fi

    # Auto-detect existing installation (unless --reinstall already handled it)
    if [[ -z "$MODE" ]]; then
        check_root
        check_dependencies
        detect_grub_install
        if detect_existing_triboot; then
            local menu_rc=0
            show_reinstall_menu || menu_rc=$?
            if [[ $menu_rc -eq 0 ]]; then
                exit 0  # Handled by reinstall menu (options 1, 2, or 4)
            fi
            # Option 3 (full reinstall) — fall through to normal flow
            info "Proceeding with full reinstall..."
            if [[ -n "$TRIBOOT_DEVICE" ]]; then
                TARGET_DEVICE="$TRIBOOT_DEVICE"
            fi
        fi
    fi

    # Ensure root/deps/grub are checked if we haven't done so yet (e.g. --reinstall fallthrough)
    check_root
    check_dependencies
    detect_grub_install

    # Validate selected device (if already set via --device)
    validate_target_device

    if [[ "$USE_TUI" == "true" ]]; then
        # ── TUI Flow (gum) ──
        log "TUI mode active (using gum)"
        log "Start timestamp: $(date -Iseconds)"

        # 1. Welcome screen
        echo ""
        gum style --border double --border-foreground 212 --padding "1 2" --bold \
            "████████╗██████╗ ██╗██████╗  ██████╗  ██████╗ ████████╗" \
            "╚══██╔══╝██╔══██╗██║██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝" \
            "   ██║   ██████╔╝██║██████╔╝██║   ██║██║   ██║   ██║   " \
            "   ██║   ██╔══██╗██║██╔══██╗██║   ██║██║   ██║   ██║   " \
            "   ██║   ██║  ██║██║██████╔╝╚██████╔╝╚██████╔╝   ██║   " \
            "   ╚═╝   ╚═╝  ╚═╝╚═╝╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   " \
            "" \
            "TriBoot v${VERSION} — Multi-Boot USB Creator"
        echo ""
        gum style --border rounded --border-foreground 196 --padding "1 2" --foreground 196 \
            "⚠  WARNING: ALL DATA on the selected drive" \
            "   will be permanently erased!"
        echo ""

        gum confirm "Continue?" --affirmative "Let's go" --negative "Exit" --prompt.foreground 212 || {
            info "Exited by user."
            exit 0
        }
        echo ""

        # 2. Drive selection
        if [[ -z "$TARGET_DEVICE" ]]; then
            detect_usb_drives_tui
        else
            if [[ ! -b "$TARGET_DEVICE" ]]; then
                tui_error "Device $TARGET_DEVICE does not exist or is not a block device"
                exit 1
            fi
        fi
        log "Device selected: $TARGET_DEVICE"
        validate_target_device
        echo ""

        # 3. Partition customization
        customize_partitions_tui
        log "Partition layout: Boot=${BOOT_SIZE_MB}MB, ISO=${ISO_PERCENT}%, Files=$((100-ISO_PERCENT))%"
        echo ""

        # 4. Confirmation
        confirm_wipe_tui "$TARGET_DEVICE"
        echo ""

        # 5. Progress
        run_with_gum_progress "$TARGET_DEVICE"
        echo ""

        # 6. Success screen
        local dev_size dev_model
        dev_size=$(lsblk -dno SIZE "$TARGET_DEVICE" 2>/dev/null || echo "?")
        dev_model=$(lsblk -dno MODEL "$TARGET_DEVICE" 2>/dev/null || echo "?")

        gum style --border double --border-foreground 82 --padding "1 2" --foreground 82 --bold \
            "TriBoot Setup Complete!" "" \
            "Device:  $TARGET_DEVICE ($dev_size, $dev_model)" "" \
            "Partitions:" \
            "  1. TBOOT       — GRUB2 bootloader (BIOS+UEFI)" \
            "  2. TBOOT_ISO   — Drop your .iso files here" \
            "  3. TBOOT_FILES — General file storage" "" \
            "Next steps:" \
            "  1. Mount or open the TBOOT_ISO partition" \
            "  2. Copy any .iso files you want to boot" \
            "  3. Boot from the USB — ISOs appear automatically" "" \
            "Log: $LOG_FILE"
        echo ""

        log "SUCCESS: TriBoot completed on $TARGET_DEVICE"
    else
        # ── Plain text flow ──
        log "Plain text mode"
        log "Start timestamp: $(date -Iseconds)"

        print_banner

        # Drive selection
        if [[ -z "$TARGET_DEVICE" ]]; then
            detect_usb_drives_plain
        else
            if [[ ! -b "$TARGET_DEVICE" ]]; then
                fatal "Device $TARGET_DEVICE does not exist or is not a block device"
            fi
            info "Using specified device: $TARGET_DEVICE"
        fi
        log "Device selected: $TARGET_DEVICE"
        validate_target_device
        log "Partition layout: Boot=${BOOT_SIZE_MB}MB, ISO=${ISO_PERCENT}%, Files=$((100-ISO_PERCENT))%"

        # Confirmation
        confirm_wipe_plain "$TARGET_DEVICE"

        # Execute steps with error handling
        run_step "Unmount" unmount_device "$TARGET_DEVICE"
        run_step "Partition" partition_drive "$TARGET_DEVICE"
        run_step "Format" format_partitions "$TARGET_DEVICE"
        run_step "GRUB Install" install_grub "$TARGET_DEVICE"

        # Done!
        print_success "$TARGET_DEVICE"
        log "SUCCESS: TriBoot completed on $TARGET_DEVICE"
    fi
}

main "$@"
