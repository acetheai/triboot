```
  ___________   _ ____              _
 |_   _| _ (_) | __ )  ___   ___ | |_
   | | |  _/ | |  _ \ / _ \ / _ \| __|
   | | | | | | | |_) | (_) | (_) | |_
   |_| |_| |_| |____/ \___/ \___/ \__|

  Multi-Boot USB Creator
```

# TriBoot

**TriBoot** is a Bash CLI tool that turns any USB drive into a multi-boot
device capable of booting multiple Linux distributions from a single stick.
It handles partitioning, GRUB2 installation (dual BIOS + UEFI), and
automatic ISO detection -- all from one script.

No more reflashing your USB every time you need a different distro.
Drop ISOs onto the drive and boot whichever one you need.

---

## Features

- **Multi-boot USB** -- boot multiple Linux ISOs from a single drive
- **GRUB2 dual-mode** -- supports both legacy BIOS and UEFI boot
- **Auto-scanning ISOs** -- GRUB configuration automatically detects ISOs on the drive
- **3-partition layout** -- dedicated partitions for boot, ISOs, and general file storage
- **TUI interface** -- guided setup via whiptail/dialog (graphical zenity/yad wrapper planned for a future release)
- **CLI flags** -- fully scriptable with `--device`, `--yes`, `--no-tui`
- **Single file** -- everything lives in `triboot.sh`

---

## Requirements

**Operating System:** Linux (tested on Debian/Ubuntu and Arch)

**Root access** is required for partitioning and GRUB installation.

**Packages:**

| Package              | Purpose                     |
|----------------------|-----------------------------|
| `parted` / `sgdisk`  | GPT partitioning            |
| `grub-pc-bin`        | GRUB for BIOS boot          |
| `grub-efi-amd64-bin` | GRUB for UEFI boot          |
| `dosfstools`         | FAT32 filesystem creation   |
| `exfatprogs`         | exFAT filesystem creation   |

On Arch, the GRUB packages are `grub` and `efibootmgr`.

---

## Installation

```bash
git clone https://github.com/acetheai/triboot.git
cd triboot
chmod +x triboot.sh
```

---

## Usage

**Basic (interactive TUI):**

```bash
sudo ./triboot.sh
```

**Specify device:**

```bash
sudo ./triboot.sh -d /dev/sdb
```

**Non-interactive (skip confirmations):**

```bash
sudo ./triboot.sh -d /dev/sdb -y
```

**Disable TUI (plain terminal output):**

```bash
sudo ./triboot.sh --no-tui
```

**Reinstall GRUB or update config (without wiping the drive):**

```bash
sudo ./triboot.sh --reinstall
```

**Regenerate grub.cfg only:**

```bash
sudo ./triboot.sh --update-grub
```

**Verify ISO checksums:**

```bash
sudo ./triboot.sh --verify
```

**List ISOs on the drive with sizes:**

```bash
sudo ./triboot.sh --list
```

**Help:**

```bash
./triboot.sh --help
```

---

## Partition Layout

TriBoot creates a GPT partition table with three partitions:

| #  | Label    | Size     | Filesystem | Purpose                                  |
|----|----------|----------|------------|------------------------------------------|
| 1  | `TBOOT`  | 512 MB   | FAT32      | GRUB bootloader and EFI system partition |
| 2  | `TBOOT_ISO`   | Variable | exFAT      | ISO image storage                        |
| 3  | `TBOOT_FILES` | Remaining| exFAT      | General-purpose file storage             |

The boot partition is small and dedicated to GRUB. The ISO partition holds
your Linux images. The files partition is free space you can use for
anything -- it remains accessible from any OS.

---

## How It Works

1. **Partitioning** -- TriBoot wipes the target USB and creates the
   3-partition GPT layout described above.

2. **GRUB installation** -- GRUB2 is installed in dual mode: a BIOS boot
   record for legacy systems and an EFI binary for UEFI systems. Both
   point to the same configuration.

3. **ISO scanning** -- At boot time, GRUB's configuration script scans
   the ISO partition for `.iso` files. For each recognized image, it
   generates a menu entry.

4. **Loopback boot** -- When you select an ISO, GRUB loopback-mounts it
   and passes the appropriate kernel and initrd parameters. The live
   system boots directly from the ISO file without extraction.

---

## Supported Distros

TriBoot includes GRUB menu entry templates for:

- Ubuntu (and derivatives: Kubuntu, Xubuntu, Linux Mint)
- Debian (live and installer ISOs)
- Fedora
- Arch Linux
- openSUSE
- Manjaro

A **generic fallback** entry is generated for unrecognized ISOs, which
attempts standard loopback parameters. Many distributions will work
even without a dedicated template.

---

## Known Limitations

- **Loopback support required** -- ISOs that do not support loopback
  booting (mounting from a file rather than a raw device) will not work.

- **Windows ISOs** -- Windows installation media requires a different
  boot chain and is not currently supported. This may be addressed in
  a future release.

- **Secure Boot** -- GRUB is installed unsigned. Systems with Secure Boot
  enforced will need it disabled in firmware settings.

- **Drive size** -- Very small USB drives (under 2 GB) may not have
  enough space for the boot partition plus any useful ISO storage.

- **Some hybrid ISOs** -- A small number of ISOs use non-standard
  filesystem layouts that prevent GRUB from locating the kernel.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

*Built by the Ace team.*
