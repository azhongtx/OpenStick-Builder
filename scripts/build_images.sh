#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}

# package rootfs
rm -f rootfs.raw
mkdir -p files mnt

# create root img (1024MB ext4, partition label "rootfs")
# The flash package's rootfs partition is >= 1139 MiB (original rootfs.img decodes
# to 1139 MiB raw), so 1024 MiB is safely smaller than the partition; the first-boot
# resize-rootfs.local script grows the fs to fill the partition.
truncate -s 1073741824 rootfs.raw
mkfs.ext4 -F -L rootfs rootfs.raw
mount rootfs.raw mnt
tar xpf alpine_rootfs.tgz -C mnt --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'
umount mnt

# create sparse android image for fastboot
img2simg rootfs.raw files/alpine_rootfs.bin
