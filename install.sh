#!/bin/bash

# Walian's Tech/Linux Blog - Arch Linux Install Script
# Tutorial: Arch Install with Secure Boot, btrfs, TPM2 LUKS encryption, Unified Kernel Images
# Published: Fri 25 August 2023
# By Walian

# Tags: ["arch linux" "secure boot" "btrfs" "tpm2" "luks" "arch" "linux"]

# Disk preparation
echo "Disk preparation..."
lsblk
DRIVE="/dev/vda"
sgdisk -Z $DRIVE
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -N2 -t2:8304 -c2:LINUXROOT $DRIVE
partprobe -s $DRIVE
lsblk $DRIVE

echo "Encrypting root partition with LUKS..."
cryptsetup luksFormat --type luks2 ${DRIVE}2
cryptsetup luksOpen ${DRIVE}2 linuxroot

echo "Creating filesystems..."
mkfs.vfat -F32 -n EFI ${DRIVE}1
mkfs.btrfs -f -L linuxroot /dev/mapper/linuxroot

echo "Mounting partitions and creating btrfs subvolumes..."
mount /dev/mapper/linuxroot /mnt
mkdir /mnt/efi
mount ${DRIVE}1 /mnt/efi
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/srv
btrfs subvolume create /mnt/var
btrfs subvolume create /mnt/var/log
btrfs subvolume create /mnt/var/cache
btrfs subvolume create /mnt/var/tmp

# Base install
echo "Base install..."
reflector --country GB --age 24 --protocol http,https --sort rate --save /etc/pacman.d/mirrorlist
pacstrap -K /mnt base base-devel linux linux-firmware amd-ucode vim nano cryptsetup btrfs-progs dosfstools util-linux git unzip sbctl kitty networkmanager sudo

echo "Updating locale settings..."
sed -i -e "/^#"en_GB.UTF-8"/s/^#//" /mnt/etc/locale.gen
systemd-firstboot --root /mnt --prompt

echo "User creation..."
arch-chroot /mnt locale-gen
arch-chroot /mnt useradd -G wheel -m walian
arch-chroot /mnt passwd walian
sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' /mnt/etc/sudoers

# Unified Kernel fun
echo "Unified Kernel setup..."
echo "quiet rw" >/mnt/etc/kernel/cmdline
mkdir -p /mnt/efi/EFI/Linux

echo "Updating mkinitcpio.conf..."
sed -i -e 's/MODULES=()/MODULES=()/;s/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)/' /mnt/etc/mkinitcpio.conf

echo "Updating linux.preset..."
cat <<EOF > /mnt/etc/mkinitcpio.d/linux.preset
# mkinitcpio preset file to generate UKIs

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
ALL_microcode=(/boot/*-ucode.img)

PRESETS=('default' 'fallback')

default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF

echo "Generating UKIs..."
arch-chroot /mnt mkinitcpio -P

# Services and Boot Loader
echo "Enabling services and installing bootloader..."
systemctl --root /mnt enable systemd-resolved systemd-timesyncd NetworkManager
systemctl --root /mnt mask systemd-networkd
arch-chroot /mnt bootctl install --esp-path=/efi

# Reboot and finish installation
echo "Rebooting to finish installation..."
sync
systemctl reboot --firmware-setup

# Secure Boot with TPM2 Unlocking
echo "Checking Secure Boot status..."
sbctl status

echo "Creating and enrolling Secure Boot keys..."
sudo sbctl create-keys
sudo sbctl enroll-keys -m

echo "Signing .efi files..."
sudo sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
sudo sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
sudo sbctl sign -s /efi/EFI/Linux/arch-linux.efi
sudo sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi

echo "Reinstalling the kernel..."
sudo pacman -S linux

echo "Rebooting to save Secure Boot settings..."
sync
systemctl reboot

# Automatic unlocking of root filesystem with TPM
echo "Configuring automatic unlocking of the root filesystem..."
sudo systemd-cryptenroll /dev/gpt-auto-root-luks --recovery-key
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/gpt-auto-root-luks

echo "Rebooting to test automatic unlocking..."
sudo systemctl reboot
