# Gentoo Automatic Installation Script

## Features
- **Profile**: `amd64-systemd-desktop`
- **Storage**: LUKS Encrypted Btrfs with subvolumes (`@`, `@home`, `@tmp`, `@log`, `@cache`, `@opt`, `@srv`)
- **Bootloader**: `systemd-boot` (Unified Kernel Image style configuration)
- **Kernel**: `gentoo-sources` compiled with `genkernel`
- **Partitioning**: 2GB EFI System Partition
- **Graphics**: 
    - **Hyprland** (Wayland Compositor)
    - **Kitty** (Terminal)
    - **Thunar** (File Manager)
    - **DankMaterialShell** (Interactive setup via `install.danklinux.com`)
    - Base: Mesa, XWayland, appropriate gpu vendor firmware
- **Optimization**:
    - **CPU**: Automatically detects core count for `MAKEOPTS` and `EMERGE_DEFAULT_OPTS`. Uses `-march=native`.
    - **GPU**: Automatically detects NVIDIA, AMD, Intel, or QEMU/Virtio and sets `VIDEO_CARDS` and `USE` flags (e.g., `vulkan`, `cuda`). Masks flags for other vendors.
    - `CPU_FLAGS_X86` generated via `cpuid2cpuflags`.
    - Binary packages enabled (`getbinpkg`).
    - **USE Flags**: `-webengine -qtwebengine` explicitly disabled.
- **Portage**: 
    - Initial sync via `webrsync`, configured to use `git` for updates
    - **GURU Overlay** enabled and synced

## Usage

1.  **Boot Arch Linux live environment** (UEFI mode required).
2.  **Download the script**:
    ```bash
    git clone https://github.com/c0mpile/install-gentoo
    cd install-gentoo
    chmod +x install.sh
    ```
3.  **Run the script**:
    ```bash
    ./install.sh
    ```
    *Follow the interactive menu to select your target disk, hostname, and configuration.*

## Script Logic Overview
1.  **Preparation**: Checks for UEFI, root, and internet. Wipes disk.
2.  **Partitioning**: Creates 2GB EFI partition and the rest for LUKS root.
3.  **Encryption**: Formats LUKS, opens it, formats Btrfs, creates subvolumes.
4.  **Stage3**: Fetches the latest `systemd-desktop` stage3 tarball.
5.  **Base Config**: Sets up `make.conf` with hardware optimizations.
6.  **Chroot**: Copies itself into the new system and re-runs in `--chroot` mode.
7.  **Installation**:
    - Installs `gentoo-sources`, `genkernel`, `systemd-boot`, `cryptsetup`, `btrfs-progs`.
    - Installs `mesa`, `linux-firmware`, `seatd`, `xwayland`.
    - Generates correct `CPU_FLAGS_X86`.
    - Compiles kernel and initramfs using `genkernel` (with Btrfs/LUKS support).
    - Installs `sudo` and configures `%wheel` (password required).
    - Creates the specified user and sets passwords.

## Verification
The script includes safety checks and error handling (`set -e`). It verifies internet connectivity and UEFI mode.
It uses an **interactive menu (ncurses)** to prompt for:
- **Target Disk** (lists available disks).
- **Hostname**.
- **Timezone** (selectable list).
- **Locales** (Checklist to select system locales).
- **Btrfs Subvolumes** (add/remove custom subvolumes).
- **User Credentials**.
- **Gaming Options** (Steam, Wine, Lutris, etc.).
- **Secure Boot** (Prompted after credentials).

> [!TIP]
> **Resumable Installation**: If the script fails or is interrupted, run it again. It will detect the previous state and ask if you want to **Resume** from the last successful step or **Start Over**.

> [!NOTE]
> The script detects if it's running on an Arch Linux LiveCD and automatically installs `dialog` using `pacman` if needed.
> Sudo is configured to **require a password** for the `%wheel` group.
> If Secure Boot is enabled, `sbctl` checks for **Setup Mode**. If not in Setup Mode, it skips key enrollment and warns the user.

> [!WARNING]
> This script **WIPES** the selected disk. Use with caution.
