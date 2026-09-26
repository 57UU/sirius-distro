#!/bin/bash
# 构建 boot_sys.img(进系统版),内核+dtb同源。调试 hang 版已移除。
# 用法: ./build_boot.sh   (先把 Image.gz/dtb 拿过来,或手动放好)
set -e
cd "$(dirname "$0")"
if [ ! -f Image.gz ] || [ ! -f sdm710-xiaomi-sirius.dtb ]; then echo "缺 Image.gz 或 dtb"; exit 1; fi
(cd initrd && ./build.sh && mv initrd.cpio.gz ../)
cat Image.gz sdm710-xiaomi-sirius.dtb > kernel-dtb
BASE="loglevel=6 earlycon=tty0 earlyprintk root=/dev/mmcblk0p81 rootfstype=ext4 rootwait=15 rootfs_part=mmcblk0p81 rw consoleblank=120"
mkbootimg --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --pagesize 4096 --ramdisk initrd.cpio.gz --cmdline "$BASE" --kernel kernel-dtb -o boot_sys.img
md5sum boot_sys.img kernel-dtb
echo BUILD-BOOT-DONE