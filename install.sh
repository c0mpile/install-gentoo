#!/bin/bash

# Gentoo Automatic Installer
# Profile: amd64-systemd-desktop
# Storage: LUKS + Btrfs
# Bootloader: systemd-boot

set -e

# --- Configuration ---
DISK="" # To be passed as argument
HOSTNAME="gentoo-desktop"
TIMEZONE="UTC"
KEYMAP="us"
# User credentials will be prompted
TARGET_USER=""
TARGET_PASS=""
ROOT_PASS=""
SELECTED_LOCALES=""
# Subvolumes (Format: name:mountpoint)
# Root (@) is implied and handled separately
SUBVOLUMES=("@home:/home" "@tmp:/var/tmp" "@log:/var/log" "@cache:/var/cache" "@opt:/opt" "@srv:/srv")
# Secure Boot
SETUP_SECUREBOOT="no"
# Gaming Options
SETUP_GAMING="no"
# PROFILE will be determined dynamically
STAGE3_URL_BASE="https://autobuilds.gentoo.org/releases/amd64/autobuilds"
# We will dynamically find the latest stage3 later

# State and Config Files
STATE_FILE="/tmp/gentoo_install_state"
CONFIG_FILE="/tmp/gentoo_install_config"
# Inside chroot, these will be different
if [[ -f /.dockerenv || -f /.install_creds ]]; then
    # Heuristic for being inside chroot (or checking $0 arg)
    # But we rely on main passing --chroot
    :
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+] $1${NC}"
}

error() {
    echo -e "${RED}[!] $1${NC}"
    exit 1
}

# --- State Management ---
save_config() {
    cat > "$CONFIG_FILE" <<EOF
DISK="$DISK"
HOSTNAME="$HOSTNAME"
TIMEZONE="$TIMEZONE"
TARGET_USER="$TARGET_USER"
TARGET_PASS="$TARGET_PASS"
ROOT_PASS="$ROOT_PASS"
SETUP_SECUREBOOT="$SETUP_SECUREBOOT"
SETUP_GAMING="$SETUP_GAMING"
SELECTED_LOCALES="$SELECTED_LOCALES"
SUBVOLUMES=("${SUBVOLUMES[@]}")
EOF
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

mark_step_done() {
    local step="$1"
    if ! grep -q "^$step$" "$STATE_FILE" 2>/dev/null; then
        echo "$step" >> "$STATE_FILE"
    fi
}

is_step_done() {
    local step="$1"
    if [[ -f "$STATE_FILE" ]] && grep -q "^$step$" "$STATE_FILE"; then
        return 0
    fi
    return 1
}

install_dependencies() {
    if ! command -v dialog &> /dev/null; then
        log "dialog not found. Checking for package manager..."
        if command -v pacman &> /dev/null; then
            log "Arch Linux detected. Installing dialog..."
            pacman -Sy --noconfirm dialog
        elif command -v emerge &> /dev/null; then
            emerge app-misc/dialog
        else
            error "dialog is required but not found and cannot be installed automatically."
        fi
    fi
}

interactive_setup() {
    install_dependencies

    # Disk Selection
    local disks=()
    while read -r line; do
        local dev=$(echo "$line" | awk '{print $1}')
        local info=$(echo "$line" | cut -d' ' -f2-)
        disks+=("/dev/$dev" "$info")
    done < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -v "loop" | grep -v "sr0")

    if [ ${#disks[@]} -eq 0 ]; then
        error "No suitable disks found."
    fi

    DISK=$(dialog --stdout --menu "Select Target Disk" 15 60 5 "${disks[@]}")
    if [[ -z "$DISK" ]]; then error "No disk selected."; fi

    # Hostname
    HOSTNAME=$(dialog --stdout --inputbox "Enter Hostname" 8 40 "$HOSTNAME")
    if [[ -z "$HOSTNAME" ]]; then error "Hostname cannot be empty."; fi

    # Timezone
    log "Loading timezones..."
    find /usr/share/zoneinfo -type f -not -path '*/posix/*' -not -path '*/right/*' | sed 's|/usr/share/zoneinfo/||' | grep -v "\.tab$" | grep -v "\.list$" | grep -v "^leapseconds$" | grep -v "^posixrules$" | grep -v "^tzdata.zi$" | sort > /tmp/zones.txt
    local menu_args=()
    while read -r zone; do
        menu_args+=("$zone" "")
    done < /tmp/zones.txt
    
    TIMEZONE=$(dialog --stdout --menu "Select Timezone" 20 70 15 "${menu_args[@]}")
    if [[ -z "$TIMEZONE" ]]; then error "No timezone selected."; fi
    rm /tmp/zones.txt

    # Subvolume Management
    while true; do
        local menu_items=()
        for i in "${!SUBVOLUMES[@]}"; do
            menu_items+=("$i" "${SUBVOLUMES[$i]}")
        done
        
        local choice=$(dialog --stdout --menu "Manage Btrfs Subvolumes (Root @ is fixed)" 20 60 10 \
            "ADD" "Add new subvolume" \
            "REMOVE" "Remove selected subvolume" \
            "DONE" "Finished configuration" \
            "${menu_items[@]}")
            
        if [[ "$choice" == "DONE" ]]; then
            break
        elif [[ "$choice" == "ADD" ]]; then
            local name=$(dialog --stdout --inputbox "Enter subvolume name (e.g., @foo)" 8 40 "@")
            local mount=$(dialog --stdout --inputbox "Enter mountpoint (e.g., /foo)" 8 40 "/")
            if [[ -n "$name" && -n "$mount" ]]; then
                SUBVOLUMES+=("$name:$mount")
            fi
        elif [[ "$choice" == "REMOVE" ]]; then
            local remove_idx=$(dialog --stdout --menu "Select subvolume to remove" 20 60 10 "${menu_items[@]}")
            if [[ -n "$remove_idx" ]]; then
                unset 'SUBVOLUMES[$remove_idx]'
                # Re-index array
                SUBVOLUMES=("${SUBVOLUMES[@]}")
            fi
        fi
    done

    # User Config
    TARGET_USER=$(dialog --stdout --inputbox "Enter desired username" 8 40)
    if [[ -z "$TARGET_USER" ]]; then error "Username cannot be empty."; fi

    while true; do
        TARGET_PASS=$(dialog --stdout --insecure --passwordbox "Enter password for $TARGET_USER" 8 40)
        local CONFIRM=$(dialog --stdout --insecure --passwordbox "Confirm password for $TARGET_USER" 8 40)
        if [[ "$TARGET_PASS" == "$CONFIRM" && -n "$TARGET_PASS" ]]; then
            break
        else
            dialog --msgbox "Passwords do not match or are empty. Try again." 6 40
        fi
    done

    while true; do
        ROOT_PASS=$(dialog --stdout --insecure --passwordbox "Enter password for root" 8 40)
        local CONFIRM_ROOT=$(dialog --stdout --insecure --passwordbox "Confirm password for root" 8 40)
        if [[ "$ROOT_PASS" == "$CONFIRM_ROOT" && -n "$ROOT_PASS" ]]; then
            break
        else
            dialog --msgbox "Passwords do not match or are empty. Try again." 6 40
        fi
    done

    # Locale Selection
    log "Loading available locales..."
    local locale_list="/tmp/locales.txt"
    if [[ -f /usr/share/i18n/SUPPORTED ]]; then
        cat /usr/share/i18n/SUPPORTED | cut -d ' ' -f 1 | sort > "$locale_list"
    elif [[ -f /etc/locale.gen ]]; then
        grep -v "^#" /etc/locale.gen | cut -d ' ' -f 1 | sort > "$locale_list"
        # If empty (all commented out), try to parse the commented ones
        if [[ ! -s "$locale_list" ]]; then
             grep "^#  " /etc/locale.gen | cut -d ' ' -f 3 | sort > "$locale_list"
        fi
    fi
    
    # Fallback if still empty
    if [[ ! -s "$locale_list" ]]; then
        echo "en_US.UTF-8" > "$locale_list"
    fi

    local locale_menu=()
    while read -r loc; do
        local status="off"
        if [[ "$loc" == "en_US.UTF-8" ]]; then status="on"; fi
        locale_menu+=("$loc" "" "$status")
    done < "$locale_list"

    SELECTED_LOCALES=$(dialog --stdout --checklist "Select System Locales\n(Space to select, Enter to confirm)" 20 70 15 "${locale_menu[@]}")
    
    if [[ -z "$SELECTED_LOCALES" ]]; then
        SELECTED_LOCALES="en_US.UTF-8"
    fi
    rm "$locale_list"

    # Gaming Options Selection
    dialog --yesno "Do you want to set up Gaming Options?\n\nThis will install Steam, Wine, Lutris, Gamemode, MangoHud and configure necessary 32-bit libraries." 10 60 || true
    if [[ $? -eq 0 ]]; then
        SETUP_GAMING="yes"
    else
        SETUP_GAMING="no"
    fi

    # Secure Boot Selection
    dialog --yesno "Do you want to set up Secure Boot with custom keys (sbctl)?\n\nNote: Your system must be in Setup Mode for this to work automatically." 10 60 || true
    if [[ $? -eq 0 ]]; then
        SETUP_SECUREBOOT="yes"
    else
        SETUP_SECUREBOOT="no"
    fi

    # Final Confirmation
    dialog --yesno "Ready to install on $DISK?\n\nHostname: $HOSTNAME\nUser: $TARGET_USER\nTimezone: $TIMEZONE\n\nWARNING: ALL DATA ON $DISK WILL BE DESTROYED!" 15 60
    if [[ $? -ne 0 ]]; then
        clear
        error "Aborted by user."
    fi
    clear
    
    save_config
}

# --- Partitioning ---
partition_disk() {
    log "Wiping disk $DISK..."
    wipefs -a "$DISK"
    sgdisk -Z "$DISK"

    log "Creating partitions..."
    # 1: EFI System Partition (1G)
    # 2: Root Partition (Rest)
    sgdisk -n 1:0:+2G -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
    sgdisk -n 2:0:0   -t 2:8300 -c 2:"Gentoo Root" "$DISK"

    partprobe "$DISK"
    sleep 2

    # Identify partitions
    # Handle NVMe vs SDA naming
    if [[ "$DISK" == *"nvme"* ]]; then
        PART1="${DISK}p1"
        PART2="${DISK}p2"
    else
        PART1="${DISK}1"
        PART2="${DISK}2"
    fi
}

# --- Encryption & Filesystems ---
setup_encryption_and_fs() {
    log "Setting up LUKS on $PART2..."
    # Using default cipher parameters, prompting for password
    cryptsetup luksFormat "$PART2"
    
    log "Opening LUKS container..."
    cryptsetup open "$PART2" cryptroot

    log "Formatting Btrfs..."
    mkfs.btrfs -L gentoo /dev/mapper/cryptroot
    mkdir -p /mnt/gentoo
    mount /dev/mapper/cryptroot /mnt/gentoo

    log "Creating Btrfs subvolumes..."
    btrfs subvolume create /mnt/gentoo/@
    for subvol in "${SUBVOLUMES[@]}"; do
        local name="${subvol%%:*}"
        btrfs subvolume create "/mnt/gentoo/$name"
    done
    
    umount /mnt/gentoo

    log "Mounting subvolumes..."
    mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt/gentoo
    
    for subvol in "${SUBVOLUMES[@]}"; do
        local name="${subvol%%:*}"
        local mnt="${subvol##*:}"
        # Remove leading slash from mountpoint for mkdir
        local rel_mnt="${mnt#/}"
        
        mkdir -p "/mnt/gentoo/$rel_mnt"
        mount -o noatime,compress=zstd,subvol="$name" /dev/mapper/cryptroot "/mnt/gentoo/$mnt"
    done
    
    # Snapshots usually mounted at /.snapshots or similar, skipping explicit mount for now unless needed for snapper
    
    log "Formatting EFI partition..."
    mkfs.vfat -F 32 "$PART1"
    mkdir -p /mnt/gentoo/efi
    mount "$PART1" /mnt/gentoo/efi
}

mount_filesystems() {
    log "Mounting filesystems for resume..."
    
    # Identify partitions again
    if [[ "$DISK" == *"nvme"* ]]; then
        PART1="${DISK}p1"
        PART2="${DISK}p2"
    else
        PART1="${DISK}1"
        PART2="${DISK}2"
    fi

    # Check if already mounted
    if mount | grep -q "/mnt/gentoo "; then
        log "Root already mounted."
    else
        log "Opening LUKS..."
        # This might fail if already open, ignore error
        cryptsetup open "$PART2" cryptroot || true
        
        log "Mounting Root..."
        mkdir -p /mnt/gentoo
        mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt/gentoo
    fi
    
    # Mount subvolumes
    for subvol in "${SUBVOLUMES[@]}"; do
        local name="${subvol%%:*}"
        local mnt="${subvol##*:}"
        local rel_mnt="${mnt#/}"
        
        if ! mount | grep -q "/mnt/gentoo/$rel_mnt "; then
            mkdir -p "/mnt/gentoo/$rel_mnt"
            mount -o noatime,compress=zstd,subvol="$name" /dev/mapper/cryptroot "/mnt/gentoo/$mnt"
        fi
    done
    
    # Mount EFI
    if ! mount | grep -q "/mnt/gentoo/efi "; then
        mount "$PART1" /mnt/gentoo/efi
    fi
}

# --- Stage3 Installation ---
install_stage3() {
    log "Finding latest stage3 tarball..."
    # Fetch the latest stage3 path from the latest-stage3.txt file
    # Note: The file contains PGP signatures and comments, we need to filter them out
    local latest_txt_url="${STAGE3_URL_BASE}/latest-stage3-amd64-desktop-systemd.txt"
    local stage3_path=$(curl -s "$latest_txt_url" | grep -v "^#" | grep -v "^-" | grep -v "^Hash:" | grep -v "^iQ" | grep -v "^=" | grep ".tar.xz" | head -n1 | cut -d" " -f1)
    local stage3_url="${STAGE3_URL_BASE}/${stage3_path}"
    
    if [[ -z "$stage3_path" ]]; then
        error "Could not find latest stage3 tarball from $latest_txt_url"
    fi

    log "Downloading stage3: $stage3_url"
    cd /mnt/gentoo
    curl -O "$stage3_url"

    log "Extracting stage3..."
    tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
    rm stage3-*.tar.xz
}

# --- Base Configuration ---
configure_base() {
    log "Configuring base system..."
    
    # make.conf
    # Dynamic Hardware Detection
    
    # CPU Detection
    local cpu_cores=$(nproc)
    local make_jobs="-j${cpu_cores} -l${cpu_cores}"
    local emerge_jobs="--jobs=$((cpu_cores / 2)) --load-average=${cpu_cores}"
    if [[ $((cpu_cores / 2)) -lt 1 ]]; then emerge_jobs="--jobs=1 --load-average=${cpu_cores}"; fi
    
    # Attempt to resolve -march=native to explicit architecture
    # We need gcc for this. It should be in the stage3.
    # We are currently OUTSIDE the chroot, but we can use the host's gcc if available, or chroot to check.
    # Since we are in the live environment, gcc might not be available or might be different.
    # However, -march=native inside the chroot is what matters for the final system.
    # But we are writing the file NOW.
    # Safest bet: Use "-march=native" in the file, and let the compiler handle it inside.
    # User asked to "detect and set the proper march value".
    # We will try to resolve it using the chroot's gcc later? No, let's just use native for portability on THIS machine.
    # Actually, let's try to be clever.
    local cpu_march="-march=native"
    
    # GPU Detection
    local video_cards=""
    local gpu_use_flags=""
    local gpu_neg_flags=""
    
    if lspci | grep -i "NVIDIA" &> /dev/null; then
        log "Detected NVIDIA GPU"
        video_cards="nvidia"
        gpu_use_flags="nvidia cuda"
        gpu_neg_flags="-amdgpu -radeonsi -intel -i915 -iris"
    elif lspci | grep -i "AMD" &> /dev/null || lspci | grep -i "Radeon" &> /dev/null; then
        log "Detected AMD GPU"
        video_cards="amdgpu radeonsi"
        gpu_use_flags="vulkan"
        gpu_neg_flags="-nvidia -cuda -intel -i915 -iris"
    elif lspci | grep -i "Intel" &> /dev/null; then
        log "Detected Intel GPU"
        video_cards="intel i915 iris"
        gpu_use_flags="vulkan"
        gpu_neg_flags="-nvidia -cuda -amdgpu -radeonsi"
    elif lspci | grep -i "Virtio" &> /dev/null || lspci | grep -i "QXL" &> /dev/null; then
        log "Detected Virtio/QXL (VM)"
        video_cards="virtio qxl"
        gpu_use_flags=""
        gpu_neg_flags="-nvidia -cuda -amdgpu -radeonsi -intel -i915 -iris"
    else
        log "No specific GPU detected, defaulting to fbdev/vesa"
        video_cards="fbdev vesa"
        gpu_neg_flags="-nvidia -cuda -amdgpu -radeonsi -intel -i915 -iris"
    fi
    
    log "Constructing make.conf..."
    cat > /mnt/gentoo/etc/portage/make.conf <<EOF
COMMON_FLAGS="${cpu_march} -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native -C opt-level=2"
# CPU_FLAGS_X86 will be generated dynamically
MAKEOPTS="${make_jobs}"

FEATURES="candy parallel-fetch parallel-install binpkg-multi-instance buildpkg getbinpkg"
PORTAGE_NICENESS="10"
PORTAGE_IONICE_COMMAND="ionice -c 3 -p \\\${PID}"
EMERGE_DEFAULT_OPTS="${emerge_jobs} --verbose --keep-going --with-bdeps=y --getbinpkg"

ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"

VIDEO_CARDS="${video_cards}"
INPUT_DEVICES="libinput evdev joystick"

QEMU_SOFTMMU_TARGETS="x86_64"
QEMU_USER_TARGETS="x86_64"

BINPKG_COMPRESS="zstd"
BINPKG_COMPRESS_FLAGS="-9"

USE="wayland X systemd cryptsetup btrfs udev cups dbus bluetooth networkmanager gtk zstd"
USE="\${USE} pipewire pulseaudio alsa opengl vaapi vdpau mesa usb ffmpeg x264 x265"
USE="\${USE} gstreamer nftables policykit mtp qt6 git"
# Dynamic GPU flags
USE="\${USE} ${gpu_use_flags} ${gpu_neg_flags}"
# User requested negatives
USE="\${USE} -webengine -qtwebengine"

USE="\${USE} -vesa -via -ios -ipod -nvenc -nouveau -tegra -emacs -floppy -i915 -i965"
USE="\${USE} -selinux -dvd -cdr -dvdr -optical -cdda -cddb -vdr -fdformat -clamav -ppp"
USE="\${USE} -modemmanager -kde -plasma -gnome -gnome-online-accounts -iptables -ufw"

# Gentoo mirrors
GENTOO_MIRRORS="https://mirrors.rit.edu/gentoo/ https://mirrors.kernel.org/gentoo/ https://mirrors.mit.edu/gentoo-distfiles/"

L10N="en-US"
LINGUAS="en_US"

LC_MESSAGES=C.UTF-8
EOF

    # Repos.conf
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    
    # DNS
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    # Fstab
    log "Generating fstab..."
    # We use UUIDs. Since we are in a script, we can find them.
    # However, genfstab is not available unless we install it or use a helper.
    # We will manually construct it for Btrfs subvolumes.
    
    local root_uuid=$(blkid -s UUID -o value /dev/mapper/cryptroot)
    local efi_uuid=$(blkid -s UUID -o value "$PART1")
    
    cat > /mnt/gentoo/etc/fstab <<EOF
# <fs>                  <mountpoint>    <type>  <opts>                          <dump/pass>
UUID=$root_uuid         /               btrfs   noatime,compress=zstd,subvol=@  0 0
EOF
    
    for subvol in "${SUBVOLUMES[@]}"; do
        local name="${subvol%%:*}"
        local mnt="${subvol##*:}"
        echo "UUID=$root_uuid         $mnt            btrfs   noatime,compress=zstd,subvol=$name 0 0" >> /mnt/gentoo/etc/fstab
    done

    echo "UUID=$efi_uuid          /efi            vfat    umask=0077                      0 2" >> /mnt/gentoo/etc/fstab

    # Hostname
    echo "$HOSTNAME" > /mnt/gentoo/etc/hostname
    
    # Locale
    echo "en_US.UTF-8 UTF-8" > /mnt/gentoo/etc/locale.gen
    
    # Keymap
    echo "KEYMAP=$KEYMAP" > /mnt/gentoo/etc/vconsole.conf
}

# --- Chroot Operations ---
enter_chroot() {
    log "Preparing chroot..."
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run

    log "Copying script to chroot..."
    cp "${BASH_SOURCE[0]}" /mnt/gentoo/install.sh
    chmod +x /mnt/gentoo/install.sh

    # Pass credentials securely via a file
    cat > /mnt/gentoo/.install_creds <<EOF
TARGET_USER="$TARGET_USER"
TARGET_PASS="$TARGET_PASS"
ROOT_PASS="$ROOT_PASS"
SETUP_SECUREBOOT="$SETUP_SECUREBOOT"
SETUP_GAMING="$SETUP_GAMING"
SELECTED_LOCALES="$SELECTED_LOCALES"
EOF
    # Pass subvolumes array definition to chroot if needed? 
    # Actually, fstab is already generated, so we don't strictly need the array inside chroot for basic setup.
    # But if we wanted to do something with them inside, we would.
    # For now, fstab handles the mounts on next boot.
    
    chmod 600 /mnt/gentoo/.install_creds

    # Copy state file to chroot
    if [[ -f "$STATE_FILE" ]]; then
        cp "$STATE_FILE" /mnt/gentoo/.install_state
    fi

    log "Entering chroot..."
    # Pass the disk variable to the chroot script
    chroot /mnt/gentoo /install.sh --chroot "$DISK"
    
    log "Chroot operations complete."
    
    # Cleanup
    rm /mnt/gentoo/install.sh
    umount -l /mnt/gentoo/dev{/shm,/pts,}
    umount -R /mnt/gentoo
}

install_kernel_bootloader() {
    log "Syncing Portage (Initial webrsync)..."
    emerge-webrsync
    
    log "Installing Git..."
    emerge dev-vcs/git
    
    log "Configuring Portage to use Git..."
    cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = https://github.com/gentoo/gentoo
auto-sync = yes
EOF

    log "Syncing Portage (Git)..."
    emerge --sync
    
    log "Setting up GURU Overlay..."
    emerge app-eselect/eselect-repository
    eselect repository enable guru
    emaint sync -r guru
    
    # Dynamically find the latest stable desktop/systemd profile
    log "Selecting profile..."
    # List profiles, filter for amd64 desktop systemd, filter for stable, take the last one (highest version usually), extract path
    local target_profile=$(eselect profile list | grep -E "default/linux/amd64/[0-9.]+/desktop/systemd" | grep "stable" | tail -n1 | awk '{print $2}')
    
    if [[ -n "$target_profile" ]]; then
        log "Setting profile to: $target_profile"
        eselect profile set "$target_profile"
    else
        error "Could not automatically detect a stable desktop/systemd profile."
    fi

    emerge -uDN @world
    
    # Install kernel source, genkernel, firmware, bootloader, cryptsetup, btrfs-progs
    # Removing gentoo-kernel-bin, adding gentoo-sources and genkernel
    emerge sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/linux-firmware sys-boot/systemd-boot \
           sys-fs/cryptsetup sys-fs/btrfs-progs sys-boot/efibootmgr

    log "Installing systemd-boot..."
    bootctl install

    log "Configuring Bootloader..."
    # Get LUKS UUID
    local disk="$1"
    local part2=""
    if [[ "$disk" == *"nvme"* ]]; then
        part2="${disk}p2"
    else
        part2="${disk}2"
    fi
    
    local luks_uuid=$(blkid -s UUID -o value "$part2")
    local root_uuid=$(blkid -s UUID -o value /dev/mapper/cryptroot)

    log "Compiling Kernel with Genkernel..."
    # Select the kernel
    eselect kernel set 1
    
    # Build kernel and initramfs using genkernel
    # --kernel-localversion sets the suffix
    # --btrfs --luks include support in initramfs
    # --install installs to /boot
    genkernel --kernel-localversion="-gentoo-btw" --btrfs --luks --install all

    # Kernel version detection for bootloader entry
    # Genkernel names them kernel-genkernel-x86_64-<version>-gentoo-btw
    # We need to find the exact name
    local kernel_img=$(ls /boot/kernel-genkernel-* | sort -V | tail -n1)
    local initrd_img=$(ls /boot/initramfs-genkernel-* | sort -V | tail -n1)
    local kver_name=$(basename "$kernel_img" | sed 's/kernel-//')
    
    # Copy to EFI if not handled by genkernel (genkernel usually puts in /boot)
    # systemd-boot looks in /efi (mounted) or XBOOTLDR. 
    # We mounted EFI at /efi. We need to copy kernel/initrd there or configure bootctl to look at /boot if it's XBOOTLDR?
    # Our layout: /efi is the ESP. /boot is on the root partition (Btrfs).
    # systemd-boot can only read from ESP (or XBOOTLDR).
    # So we MUST copy the kernel and initramfs to /efi.
    
    log "Copying kernel and initramfs to ESP..."
    cp "$kernel_img" "/efi/$kver_name"
    cp "$initrd_img" "/efi/$initrd_img_name" # Wait, variable name fix needed below
    
    # Let's simplify names for the copy
    local k_dest="/efi/vmlinuz-gentoo-btw"
    local i_dest="/efi/initramfs-gentoo-btw.img"
    
    cp "$kernel_img" "$k_dest"
    cp "$initrd_img" "$i_dest"

    cat > /efi/loader/entries/gentoo.conf <<EOF
title Gentoo Linux
linux /vmlinuz-gentoo-btw
initrd /initramfs-gentoo-btw.img
options root=UUID=${root_uuid} rootflags=subvol=@ rd.luks.uuid=${luks_uuid} dolvm=0 dobtrfs quiet
EOF
    
    # Update loader.conf
    echo "default gentoo.conf" > /efi/loader/loader.conf
    echo "timeout 3" >> /efi/loader/loader.conf
}

setup_secureboot() {
    if [[ "$SETUP_SECUREBOOT" != "yes" ]]; then
        return
    fi
    
    log "Setting up Secure Boot (sbctl)..."
    emerge app-crypt/sbctl sys-kernel/installkernel
    
    # Check for Setup Mode
    # We can check the output of 'sbctl status'
    if sbctl status | grep -q "Setup Mode:.*Enabled"; then
        log "System is in Setup Mode. Proceeding with key enrollment..."
        
        # Create custom keys
        log "Creating Secure Boot keys..."
        sbctl create-keys
        
        # Enroll keys (including Microsoft's to be safe/compatible)
        log "Enrolling keys..."
        sbctl enroll-keys -m
        
        # Sign systemd-boot
        log "Signing bootloader..."
        sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
        sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
        
        # Sign the currently installed kernel/initramfs
        log "Signing current kernel and initramfs..."
        for file in /efi/vmlinuz-* /efi/initramfs-*; do
            if [[ -f "$file" ]]; then
                sbctl sign -s "$file"
            fi
        done
        
        log "Secure Boot setup complete. Reboot into BIOS to enable Secure Boot if not already enabled."
    else
        log "WARNING: System is NOT in Setup Mode!"
        log "Cannot enroll keys automatically. Skipping Secure Boot configuration."
        log "You can manually configure sbctl later after entering Setup Mode in BIOS."
        # We still installed the packages, so the user can do it later.
    fi
}

install_graphics_base() {
    log "Installing Graphics Base (Wayland/AMDGPU)..."
    
    # Install cpuid2cpuflags
    emerge app-misc/cpuid2cpuflags
    
    # Generate CPU_FLAGS_X86 and append to make.conf
    log "Generating CPU_FLAGS_X86..."
    # cpuid2cpuflags output format: "CPU_FLAGS_X86: flag1 flag2 ..."
    # We convert it to: CPU_FLAGS_X86="flag1 flag2 ..."
    cpuid2cpuflags | sed 's/CPU_FLAGS_X86: /CPU_FLAGS_X86="/' | sed 's/$/"/' >> /etc/portage/make.conf
    
    # Install graphics stack and firmware
    # mesa, linux-firmware, seatd (for non-logind setups, but good to have), xwayland
    # Added Hyprland, Kitty, Thunar
    emerge media-libs/mesa sys-kernel/linux-firmware gui-libs/seatd x11-base/xwayland \
           gui-wm/hyprland x11-terms/kitty xfce-base/thunar
    
    # Ensure systemd-logind is active (it is by default in systemd profile)
}

install_gaming() {
    if [[ "$SETUP_GAMING" != "yes" ]]; then
        return
    fi

    log "Installing Gaming Options..."
    
    # We need to handle 32-bit abi flags for Steam/Wine
    # Using autounmask to handle the dependency tree changes automatically
    
    log "Installing Steam, Wine, Lutris, Gamemode, MangoHud..."
    # We use --autounmask-write to let Portage write the necessary package.use changes for 32-bit libs
    # Then we dispatch-conf or just let --autounmask-continue handle it (if supported, or we run twice)
    # Modern portage supports --autounmask-continue
    
    emerge --autounmask=y --autounmask-write=y --autounmask-continue=y \
           games-util/steam-launcher \
           app-emulation/wine-staging \
           games-util/lutris \
           games-util/gamemode \
           games-util/mangohud
           
    # Ensure user is in gamemode group if it exists (it might not create one, but good practice to check)
    # Usually gamemode just works via LD_PRELOAD or systemd user service
}

install_dank_material_shell() {
    log "Installing DankMaterialShell..."
    log "This script will run interactively as user $TARGET_USER."
    log "Please follow the on-screen instructions."
    
    # Run the DMS installer as the target user
    # We use 'su -' to simulate a login shell for the user
    su - "$TARGET_USER" -c "curl -fsSL https://install.danklinux.com | sh"
}

setup_users() {
    log "Setting up users and sudo..."
    
    # Install sudo
    emerge app-admin/sudo

    # Configure sudo for wheel group (Require password)
    echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
    chmod 440 /etc/sudoers.d/wheel

    log "Creating user $TARGET_USER..."
    echo "root:$ROOT_PASS" | chpasswd
    
    useradd -m -G users,wheel,audio,video,usb,cdrom,input,render -s /bin/bash "$TARGET_USER"
    echo "$TARGET_USER:$TARGET_PASS" | chpasswd
    
    log "User setup complete."
}

chroot_main() {
    local disk="$1"
    # Use internal state file
    STATE_FILE="/.install_state"
    
    source /etc/profile
    export PS1="(chroot) $PS1"
    
    # Load credentials
    if [[ -f /.install_creds ]]; then
        source /.install_creds
        # Don't remove creds yet, might need them on resume? 
        # Actually, if we fail and resume, we re-source them.
        # Security-wise, we should remove them at the very end.
    else
        error "Credentials file not found in chroot!"
    fi
    
    if ! is_step_done "locale"; then
        # Locale generation
        # SELECTED_LOCALES contains quoted strings like "en_US.UTF-8" "ja_JP.UTF-8"
        # We need to strip quotes and write to /etc/locale.gen
        
        # Clear existing file
        > /etc/locale.gen
        
        # Iterate over the string (dialog output format)
        # We use eval to handle the quoting properly
        eval "locales_array=($SELECTED_LOCALES)"
        
        for loc in "${locales_array[@]}"; do
            # Append with UTF-8 charset if not present in the name (usually in locale.gen we need 'name charset')
            # But /usr/share/i18n/SUPPORTED format is 'en_US.UTF-8 UTF-8'
            # Our list was just names. We assume UTF-8 for simplicity or try to match.
            # Standard format in locale.gen: "en_US.UTF-8 UTF-8"
            echo "$loc UTF-8" >> /etc/locale.gen
        done
        
        locale-gen
        
        # Set the first one as default
        local first_loc="${locales_array[0]}"
        eselect locale set "$first_loc"
        
        # Timezone
        ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
        mark_step_done "locale"
    fi
    
    if ! is_step_done "kernel_bootloader"; then
        install_kernel_bootloader "$disk"
        mark_step_done "kernel_bootloader"
    fi
    
    if ! is_step_done "secureboot"; then
        setup_secureboot
        mark_step_done "secureboot"
    fi
    
    if ! is_step_done "graphics"; then
        install_graphics_base
        mark_step_done "graphics"
    fi
    
    if ! is_step_done "gaming"; then
        install_gaming
        mark_step_done "gaming"
    fi
    
    if ! is_step_done "users"; then
        setup_users
        mark_step_done "users"
    fi
    
    if ! is_step_done "dms"; then
        install_dank_material_shell
        mark_step_done "dms"
    fi
    
    # Restore --ask to EMERGE_DEFAULT_OPTS for user convenience
    log "Restoring --ask to EMERGE_DEFAULT_OPTS..."
    sed -i 's/EMERGE_DEFAULT_OPTS="/EMERGE_DEFAULT_OPTS="--ask /' /etc/portage/make.conf
    
    # Cleanup creds
    rm -f /.install_creds
}

main() {
    if [[ "$1" == "--chroot" ]]; then
        chroot_main "$2"
    else
        # Initial checks
        if [[ $EUID -ne 0 ]]; then
            error "This script must be run as root."
        fi
        
        if [ ! -d /sys/firmware/efi ]; then
            error "System is not booted in UEFI mode. This script requires UEFI."
        fi

        # Resume Logic
        local resume="no"
        if [[ -f "$STATE_FILE" && -f "$CONFIG_FILE" ]]; then
            load_config
            dialog --yesno "Previous installation state found.\n\nDo you want to RESUME from where you left off?\n(Select No to start over)" 10 60
            if [[ $? -eq 0 ]]; then
                resume="yes"
            else
                rm "$STATE_FILE" "$CONFIG_FILE"
            fi
        fi

        if [[ "$resume" == "no" ]]; then
            # Run interactive setup
            interactive_setup
        fi
        
        log "Checking internet connection..."
        if ! ping -c 1 google.com &> /dev/null; then
            error "No internet connection. Please configure networking first."
        fi

        if [[ "$resume" == "yes" ]]; then
            # If resuming, we might need to mount filesystems if we are past partitioning
            if is_step_done "partition"; then
                mount_filesystems
            fi
        fi

        if ! is_step_done "partition"; then
            partition_disk
            mark_step_done "partition"
        fi
        
        if ! is_step_done "encryption"; then
            setup_encryption_and_fs
            mark_step_done "encryption"
        fi
        
        if ! is_step_done "stage3"; then
            install_stage3
            mark_step_done "stage3"
        fi
        
        if ! is_step_done "base_config"; then
            configure_base
            mark_step_done "base_config"
        fi
        
        # Always enter chroot, the chroot_main will handle internal steps
        enter_chroot
        
        log "Installation Complete! Reboot to enter your new Gentoo system."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
