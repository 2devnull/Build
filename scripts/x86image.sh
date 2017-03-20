#!/bin/sh

while getopts ":v:p:" opt; do
  case $opt in
    v)
      VERSION=$OPTARG
      ;;
    p)
      PATCH=$OPTARG
      ;;

  esac
done
BUILDDATE=$(date -I)
IMG_FILE="Volumio${VERSION}-${BUILDDATE}-x86.img"

echo "Creating Image Bed"
echo "Image file: ${IMG_FILE}"
dd if=/dev/zero of=${IMG_FILE} bs=1M count=3900
LOOP_DEV=`losetup -f --show ${IMG_FILE}`

parted -s "${LOOP_DEV}" mklabel gpt
parted -s "${LOOP_DEV}" mkpart primary 1 512		    #legacy and uefi boot
parted -s "${LOOP_DEV}" mkpart primary 512 3500		#volumio
parted -s "${LOOP_DEV}" mkpart primary 3500 100%		#data
parted -s "${LOOP_DEV}" set 1 legacy_boot on
parted -s "${LOOP_DEV}" set 1 esp on
partprobe "${LOOP_DEV}"
kpartx -s -a "${LOOP_DEV}"

BOOT_PART=`echo /dev/mapper/"$( echo $LOOP_DEV | sed -e 's/.*\/\(\w*\)/\1/' )"p1`
IMG_PART=`echo /dev/mapper/"$( echo $LOOP_DEV | sed -e 's/.*\/\(\w*\)/\1/' )"p2`
DATA_PART=`echo /dev/mapper/"$( echo $LOOP_DEV | sed -e 's/.*\/\(\w*\)/\1/' )"p3`

if [ ! -b "$BOOT_PART" ]
then
	echo "$BOOT_PART doesn't exist"
	exit 1
fi

echo "Creating filesystems"
#mkdosfs "${BOOT_PART}"
mkfs -t vfat -F 32 -n volumioboot "${BOOT_PART}"
mkfs.ext4 -E stride=2,stripe-width=1024 -b 4096 "${IMG_PART}" -L volumioimg
mkfs.ext4 -E stride=2,stripe-width=1024 -b 4096 "${DATA_PART}" -L volumio_data
parted -s "${LOOP_DEV}" print

sync

if [ -d /mnt ]
then
    echo "/mnt folder exist"
else
    mkdir /mnt
fi
if [ -d /mnt/volumio ]
then
    echo "Volumio Temp Directory Exists - Cleaning it"
    rm -rf /mnt/volumio/*
else
    echo "Creating Volumio Temp Directory"
    mkdir /mnt/volumio
fi

echo "Creating mount point for the images partition"
mkdir /mnt/volumio/images
mount -t ext4 "${IMG_PART}" /mnt/volumio/images
mkdir /mnt/volumio/rootfs
echo "Copying Volumio RootFs"
cp -pdR build/x86/root/* /mnt/volumio/rootfs

echo "Copying the Syslinux boot sector"
#syslinux "${BOOT_PART}"
dd conv=notrunc bs=440 count=1 if=/mnt/volumio/rootfs/usr/lib/syslinux/mbr/gptmbr.bin of=${LOOP_DEV}

sync

echo "Entering Chroot Environment"
mkdir /mnt/volumio/boot
mount -t vfat "${BOOT_PART}" /mnt/volumio/rootfs/boot

cp scripts/x86config.sh /mnt/volumio/rootfs
if [ ! -d platform-x86 ]; then
  echo "Platform files (packages) not available yet, getting them from the repo"
  git clone http://github.com/volumio/platform-x86
fi
cp platform-x86/packages/linux-image-*.deb /mnt/volumio/rootfs
cp platform-x86/packages/linux-firmware-*.deb /mnt/volumio/rootfs
cp platform-x86/Intel-e1000e-3.3.4/e1000e.ko /mnt/volumio/rootfs

cp volumio/splash/volumio.png /mnt/volumio/rootfs/boot

cp scripts/initramfs/init-x86 /mnt/volumio/rootfs/root/init
cp scripts/initramfs/mkinitramfs-custom.sh /mnt/volumio/rootfs/usr/local/sbin

cp volumio/etc/ata-modules.x86 /mnt/volumio/rootfs/ata-modules.x86

#copy the scripts for updating from usb
wget -P /mnt/volumio/rootfs/root http://repo.volumio.org/Volumio2/Binaries/volumio-init-updater

mount /dev /mnt/volumio/rootfs/dev -o bind
mount /proc /mnt/volumio/rootfs/proc -t proc
mount /sys /mnt/volumio/rootfs/sys -t sysfs

mkdir -p /mnt/volumio/rootfs/boot/efi
mkdir -p /mnt/volumio/rootfs/boot/efi/EFI/debian
mkdir -p /mnt/volumio/rootfs/boot/efi/BOOT/
modprobe efivarfs

UUID_BOOT=$(blkid -s UUID -o value ${BOOT_PART})
UUID_IMG=$(blkid -s UUID -o value ${IMG_PART})
echo "UUID_BOOT=${UUID_BOOT}
UUID_IMG=${UUID_IMG}
LOOP_DEV=${LOOP_DEV}
BOOT_PART=${BOOT_PART}
" >> /mnt/volumio/rootfs/init.sh
chmod +x /mnt/volumio/rootfs/init.sh


echo $PATCH > /mnt/volumio/rootfs/patch
chroot /mnt/volumio/rootfs /bin/bash -x <<'EOF'
/x86config.sh -p
EOF

rm /mnt/volumio/rootfs/init.sh /mnt/volumio/rootfs/linux-image-*.deb
rm /mnt/volumio/rootfs/linux-firmware-*.deb /mnt/volumio/rootfs/e1000e.ko
rm /mnt/volumio/rootfs/root/init /mnt/volumio/rootfs/x86config.sh
rm /mnt/volumio/rootfs/ata-modules.x86
sync

echo "Unmounting Temp Devices"
sudo umount -l /mnt/volumio/rootfs/dev
sudo umount -l /mnt/volumio/rootfs/proc
sudo umount -l /mnt/volumio/rootfs/sys

echo "X86 device installed"

echo "Preparing rootfs base for SquashFS"

if [ -d /mnt/squash ]; then
	echo "Volumio SquashFS Temp Dir Exists - Cleaning it"
	rm -rf /mnt/squash/*
else
	echo "Creating Volumio SquashFS Temp Dir"
	sudo mkdir /mnt/squash
fi

echo "Copying Volumio rootfs to Temp Dir"
cp -rp /mnt/volumio/rootfs/* /mnt/squash/

echo "Removing the Kernel"
rm -rf /mnt/squash/boot/*

echo "Creating SquashFS, removing any previous one"
rm -r Volumio.sqsh
mksquashfs /mnt/squash/* Volumio.sqsh

echo "Squash filesystem created"
echo "Cleaning squash environment"
rm -rf /mnt/squash

#copy the squash image inside the boot partition
cp Volumio.sqsh /mnt/volumio/images/volumio_current.sqsh
sync
echo "Unmounting Temp Devices"
sudo umount -l /mnt/volumio/images
sudo umount -l /mnt/volumio/rootfs/boot

echo "Avoiding fsck errors on boot"
# as the syslinux boot sector has no backup, no idea why (yet), simply fix that by coyping to the backup)
fsck.vfat -r > /dev/null  2>&1 "${BOOT_PART}" <<EOF
1
1
y
EOF

echo "Cleaning build environment"
#rm -rf /mnt/volumio /mnt/boot

sudo dmsetup remove_all
sudo losetup -d ${LOOP_DEV}
sync

echo "X86 Image file created"
# echo "Building VMDK Virtual Image File"
# qemu-img convert ${IMG_FILE} -O vmdk Volumio-dev.vmdk
# md5sum Volumio-dev.vmdk > Volumio-dev.vmdk.md5
# echo "VMDK Virtual Image File generated"

echo "Creating tar.gz for Docker use"
cd /mnt/volumio/rootfs/
sudo tar -czf /home/volumio/VolumioRootFS2.0.tar.gz *
