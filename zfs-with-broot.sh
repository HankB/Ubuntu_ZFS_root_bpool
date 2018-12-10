#!/bin/bash
#
# install ZFS on Root, Ubuntu 18.04.1 following modified instructions provided
# by Richard Laager. This script performs 
#  - UEFI install
#  - dataset for /tmp
#  - unencrypted install
#  - ...


# Provide the following variables in the environment
# export DRIVE_ID=
# export ETHERNET=
# export NEW_HOSTNAME=
# export YOURUSERNAME=$USERNAME

# Overall strategy - Execute commands through 1.3 (installing SSH server)
# SSH in, sudo to root and then either execute this script or copy/paste commands
# from this script into the terminal.
# some other commands are required to identify the drive ID and ethernet ID.

# 1.2 Setup and update the repositories:
apt-add-repository universe

# 1.5 Install ZFS in the Live CD environment:
apt install --yes debootstrap gdisk zfs-initramfs

# 2.2 Partition your disk. (Assumes disk has already been cleared.)
sgdisk     --zap-all             /dev/disk/by-id/$DRIVE_ID
# Run this for UEFI booting (for use now or in the future):     -part3
sgdisk     -n3:1M:+512M -t3:EF00 /dev/disk/by-id/$DRIVE_ID
# Run this for the boot pool                                    -part4
sgdisk     -n4:0:+512M  -t4:BF01 /dev/disk/by-id/$DRIVE_ID
# root pool                                                     -part1
sgdisk     -n1:0:0      -t1:BF01 /dev/disk/by-id/$DRIVE_ID

# 2.3 Create the boot pool
zpool create -o ashift=12 -d \
      -o feature@async_destroy=enabled \
      -o feature@bookmarks=enabled \
      -o feature@embedded_data=enabled \
      -o feature@empty_bpobj=enabled \
      -o feature@enabled_txg=enabled \
      -o feature@extensible_dataset=enabled \
      -o feature@filesystem_limits=enabled \
      -o feature@hole_birth=enabled \
      -o feature@large_blocks=enabled \
      -o feature@lz4_compress=enabled \
      -o feature@spacemap_histogram=enabled \
      -o feature@userobj_accounting=enabled \
      -O atime=off -O canmount=off -O compression=lz4 -O devices=off \
      -O normalization=formD -O xattr=sa -O mountpoint=/ -R /mnt \
      bpool /dev/disk/by-id/${DRIVE_ID}-part4

# 2.4 Create the root pool: (unencrypted)
zpool create -o ashift=12 \
      -O atime=off -O canmount=off -O compression=lz4 -O normalization=formD \
      -O xattr=sa -O mountpoint=/ -R /mnt \
      rpool /dev/disk/by-id/${DRIVE_ID}-part1

# 3.1 Create a filesystem dataset to act as a container:
zfs create -o canmount=off -o mountpoint=none rpool/ROOT

# 3.2 Create a filesystem dataset for the root filesystem:
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu

# 3.3 Create datasets:
zfs create                                -o exec=off bpool/boot

zfs create                 -o setuid=off              rpool/home
zfs create -o mountpoint=/root                        rpool/home/root
zfs create -o canmount=off -o setuid=off  -o exec=off rpool/var
zfs create -o com.sun:auto-snapshot=false             rpool/var/cache
zfs create -o acltype=posixacl -o xattr=sa            rpool/var/log
zfs create                                            rpool/var/spool
zfs create -o com.sun:auto-snapshot=false -o exec=on  rpool/var/tmp

# If you use /srv on this system:
zfs create                                            rpool/srv

# If this system will have games installed:
zfs create                                            rpool/var/games

# If this system will store local email in /var/mail:
zfs create                                            rpool/var/mail

# If you will use Postfix, it requires exec=on for its chroot.  Choose:
# zfs inherit exec rpool/var
# OR
zfs create -o exec=on rpool/var/spool/postfix

# If this system will use NFS (locking):
zfs create -o com.sun:auto-snapshot=false \
             -o mountpoint=/var/lib/nfs                 rpool/var/nfs

# If you want a separate /tmp dataset (choose this now or tmpfs later):
zfs create -o com.sun:auto-snapshot=false \
             -o setuid=off                              rpool/tmp
chmod 1777 /mnt/tmp


# 3.4 Install the minimal system:
chmod 1777 /mnt/var/tmp
debootstrap bionic /mnt
zfs set devices=off rpool


# 4.1 Configure the hostname (change HOSTNAME to the desired hostname).
echo $NEW_HOSTNAME > /mnt/etc/hostname

vi /mnt/etc/hosts
# Add a line:
# 127.0.1.1       HOSTNAME
# or if the system has a real name in DNS:
# 127.0.1.1       FQDN HOSTNAME

# 4.2 Configure the network interface:
# Find the interface name:
ip addr show

cat >/mnt/etc/netplan/${ETHERNET}.yaml <<EOF
network:
  version: 2
  ethernets:
    ${ETHERNET}:
      dhcp4: true
EOF

vi /mnt/etc/netplan/${ETHERNET}.yaml

# 4.3  Configure the package sources:
sed -i 's/^/# /' /mnt/etc/apt/sources.list
    # vi /mnt/etc/apt/sources.list

cat >> /mnt/etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu bionic main universe
deb-src http://archive.ubuntu.com/ubuntu bionic main universe

deb http://security.ubuntu.com/ubuntu bionic-security main universe
deb-src http://security.ubuntu.com/ubuntu bionic-security main universe

deb http://archive.ubuntu.com/ubuntu bionic-updates main universe
deb-src http://archive.ubuntu.com/ubuntu bionic-updates main universe
EOF

cat /mnt/etc/apt/sources.list

# 4.4  Bind the virtual filesystems from the LiveCD environment to the new system
# and `chroot` into it:

mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
chroot /mnt /bin/bash --login

# following commands have to be copied/pasted to execute inside the chroot

# 4.5  Configure a basic system environment
ln -s /proc/self/mounts /etc/mtab
apt update
dpkg-reconfigure locales
dpkg-reconfigure tzdata

# 4.6  Install ZFS in the chroot environment for the new system:
apt install --yes --no-install-recommends linux-image-generic
apt install --yes zfs-initramfs

# 4.8b  Install GRUB for UEFI booting

apt install dosfstools
mkdosfs -F 32 -n EFI /dev/disk/by-id/${DRIVE_ID}-part3
mkdir /boot/efi
echo PARTUUID=$(blkid -s PARTUUID -o value \
      /dev/disk/by-id/${DRIVE_ID}-part3) \
      /boot/efi vfat noatime,nofail,x-systemd.device-timeout=1 0 1 >> /etc/fstab
mount /boot/efi
apt install --yes grub-efi-amd64
 
# 4.9 Setup system groups:
addgroup --system lpadmin
addgroup --system sambashare
 
# 4.10 Set a root password
passwd
 
# 4.11 Fix filesystem mount ordering
zfs set mountpoint=legacy rpool/var/log
zfs set mountpoint=legacy rpool/var/tmp
cat >> /etc/fstab << EOF
rpool/var/log /var/log zfs noatime,nodev,noexec,nosuid 0 0
rpool/var/tmp /var/tmp zfs noatime,nodev,nosuid 0 0
EOF
# If you created a /tmp dataset, do the same for it:
zfs set mountpoint=legacy rpool/tmp
cat >> /etc/fstab << EOF
rpool/tmp /tmp zfs noatime,nodev,nosuid 0 0
EOF
 
# 5.1 Verify that the ZFS root filesystem is recognized:
grub-probe /

# 5.2 Refresh the initrd files:
update-initramfs -u -k all

# 5.3 Optional (but highly recommended): Make debugging GRUB easier:
vi /etc/default/grub
# Comment out: GRUB_TIMEOUT_STYLE=hidden
# Remove quiet and splash from: GRUB_CMDLINE_LINUX_DEFAULT
# Uncomment: GRUB_TERMINAL=console
# Save and quit.

# 5.4 Update the boot configuration:
update-grub
# Generating grub configuration file ...
# Found linux image: /boot/vmlinuz-4.15.0-12-generic
# Found initrd image: /boot/initrd.img-4.15.0-12-generic
# done

# 5.5 Install the boot loader
# 5.5b For UEFI booting, install GRUB:
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=ubuntu --recheck --no-floppy

# 5.6 Verify that the ZFS module is installed:
ls /boot/grub/*/zfs.mod

# 6.1 Snapshot the initial installation:
zfs snapshot rpool/ROOT/ubuntu@install

# 6.2 Exit from the chroot environment back to the LiveCD environment:
exit

# 6.3 Run these commands in the LiveCD environment to unmount all filesystems:
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
### must also unmount /mnt/boot
zpool export rpool

# 6.4 Reboot:
reboot

# 6.5 Wait for the newly installed system to boot normally. Login as root.
# 6.6 Create a user account:
zfs create rpool/home/$YOURUSERNAME
adduser $YOURUSERNAME
cp -a /etc/skel/.[!.]* /home/$YOURUSERNAME
chown -R $YOURUSERNAME:$YOURUSERNAME /home/$YOURUSERNAME

# 6.7 Add your user account to the default set of groups for an administrator:
usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo $YOURUSERNAME

# 7.1 Create a volume dataset (zvol) for use as a swap device:
zfs create -V 16G -b $(getconf PAGESIZE) -o compression=zle \
      -o logbias=throughput -o sync=always \
      -o primarycache=metadata -o secondarycache=none \
      -o com.sun:auto-snapshot=false rpool/swap

# 7.2 Configure the swap device:
# Caution: Always use long /dev/zvol aliases in configuration files. Never use a short /dev/zdX device name.
mkswap -f /dev/zvol/rpool/swap
echo /dev/zvol/rpool/swap none swap defaults 0 0 >> /etc/fstab
echo RESUME=none > /etc/initramfs-tools/conf.d/resume

# 7.3 Enable the swap device:
swapon -av

# 8.1 Upgrade the minimal system:
apt dist-upgrade --yes

# 8.2b Install a full GUI environment:
apt install --yes ubuntu-desktop

rm /etc/netplan/$ETHERNET.yaml
vi /etc/netplan/01-netcfg.yaml
# network:
#   version: 2
#   renderer: NetworkManager

# 8.3 Optional: Disable log compression:
for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
    fi
done

# See source instructions for other suggestions
