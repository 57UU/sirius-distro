#!/bin/bash
# build-kernel-img.sh: assemble the sirius kernel store image (system partition).
#
# The store decouples kernel modules + device firmware from the userdata
# rootfs. Layout inside the image:
#   lib/modules/<uname -r>/   modules + depmod db, from a built kernel tree
#   lib/firmware/...          device blobs (same mapping as sirius_firmware_pre)
#
# Run on the kernel build host (needs the kernel tree already built).
# Host arch is auto-detected: aarch64 builds natively (empty CROSS_COMPILE),
# anything else (x86_64) uses the aarch64 cross toolchain.
#   ./build-kernel-img.sh
# Env overrides:
#   KERNEL_SRC  built kernel tree (default: <distro>/kernel/linux-sirius)
#   INITRD      packed initramfs (default: <distro>/workspace/build/initrd.cpio.gz)
#   OUT         output image (default: <distro>/build/kernel.img, gitignored)
#   IMG_SIZE    ext4 size (default: 256M; content is ~55M)
#   IMG_LABEL   fs label (default: sirius_vendor)
#   ARCH / CROSS_COMPILE / DEPMOD / MKFS as usual.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC=${KERNEL_SRC:-$DISTRO/kernel/linux-sirius}
FIRMWARE=$DISTRO/firmware
OUT=${OUT:-$DISTRO/build/kernel.img}
IMG_SIZE=${IMG_SIZE:-256M}
IMG_LABEL=${IMG_LABEL:-sirius_vendor}
ARCH=${ARCH:-arm64}
case "$(uname -m)" in
  aarch64|arm64) DEF_CROSS= ;;
  *)             DEF_CROSS=aarch64-linux-gnu- ;;
esac
CROSS_COMPILE=${CROSS_COMPILE-$DEF_CROSS}
export PATH="/usr/sbin:/sbin:$PATH"
DEPMOD=${DEPMOD:-depmod}
MKFS=${MKFS:-mkfs.ext4}
test -d "$KERNEL_SRC" || { echo "missing kernel tree $KERNEL_SRC"; exit 1; }
test -d "$FIRMWARE" || { echo "missing firmware $FIRMWARE"; exit 1; }
command -v "$DEPMOD" >/dev/null || { echo "missing depmod"; exit 1; }
command -v "$MKFS" >/dev/null || { echo "missing mkfs.ext4"; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
echo "=== modules_install from $KERNEL_SRC ==="
make -C "$KERNEL_SRC" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  INSTALL_MOD_PATH="$STAGE" modules_install
KVER="$(ls "$STAGE/lib/modules")"
test -n "$KVER" || { echo "no modules installed"; exit 1; }
echo "=== depmod $KVER ==="
"$DEPMOD" -b "$STAGE" -a "$KVER"
echo "=== firmware (mirrors sirius_firmware_pre) ==="
FW=$STAGE/lib/firmware
mkdir -p $FW/qcom/sdm710/pyxis $FW/qcom $FW/ath10k/WCN3990/hw1.0 $FW/qca
cp -f $FIRMWARE/gpu/a615_zap.mbn $FW/qcom/sdm710/pyxis/a615_zap.mbn
cp -f $FIRMWARE/gpu/a630_sqe.fw $FIRMWARE/gpu/a630_gmu.bin $FW/qcom/
cp -f $FIRMWARE/ipa-sirius/ipa_fws.mbn $FIRMWARE/ipa-sirius/ipa_fws.b00 $FIRMWARE/ipa-sirius/ipa_fws.b01 $FIRMWARE/ipa-sirius/ipa_fws.b02 $FIRMWARE/ipa-sirius/ipa_fws.b03 $FIRMWARE/ipa-sirius/ipa_fws.b04 $FW/qcom/sdm710/pyxis/
cp -f $FIRMWARE/cdsp-sirius/cdsp.mbn $FIRMWARE/cdsp-sirius/cdsp.b00 $FIRMWARE/cdsp-sirius/cdsp.b01 $FIRMWARE/cdsp-sirius/cdsp.b02 $FIRMWARE/cdsp-sirius/cdsp.b03 $FIRMWARE/cdsp-sirius/cdsp.b04 $FIRMWARE/cdsp-sirius/cdsp.b05 $FIRMWARE/cdsp-sirius/cdsp.b06 $FIRMWARE/cdsp-sirius/cdsp.b08 $FIRMWARE/cdsp-sirius/cdsp.b10 $FIRMWARE/cdsp-sirius/cdspr.jsn $FW/qcom/sdm710/pyxis/
chmod 644 $FW/qcom/sdm710/pyxis/cdsp.mbn $FW/qcom/sdm710/pyxis/cdsp.b00 $FW/qcom/sdm710/pyxis/cdsp.b01 $FW/qcom/sdm710/pyxis/cdsp.b02 $FW/qcom/sdm710/pyxis/cdsp.b03 $FW/qcom/sdm710/pyxis/cdsp.b04 $FW/qcom/sdm710/pyxis/cdsp.b05 $FW/qcom/sdm710/pyxis/cdsp.b06 $FW/qcom/sdm710/pyxis/cdsp.b08 $FW/qcom/sdm710/pyxis/cdsp.b10 $FW/qcom/sdm710/pyxis/cdspr.jsn
chmod 644 $FW/qcom/sdm710/pyxis/ipa_fws.mbn $FW/qcom/sdm710/pyxis/ipa_fws.b00 $FW/qcom/sdm710/pyxis/ipa_fws.b01 $FW/qcom/sdm710/pyxis/ipa_fws.b02 $FW/qcom/sdm710/pyxis/ipa_fws.b03 $FW/qcom/sdm710/pyxis/ipa_fws.b04
cp -f $FIRMWARE/venus-sirius/venus.mbn $FIRMWARE/venus-sirius/venus.b00 $FIRMWARE/venus-sirius/venus.b01 $FIRMWARE/venus-sirius/venus.b02 $FIRMWARE/venus-sirius/venus.b03 $FIRMWARE/venus-sirius/venus.b04 $FW/qcom/sdm710/pyxis/
chmod 644 $FW/qcom/sdm710/pyxis/venus.mbn $FW/qcom/sdm710/pyxis/venus.b00 $FW/qcom/sdm710/pyxis/venus.b01 $FW/qcom/sdm710/pyxis/venus.b02 $FW/qcom/sdm710/pyxis/venus.b03 $FW/qcom/sdm710/pyxis/venus.b04
cp -f $FIRMWARE/touch/st_fts_v521.ftb $FW/st_fts_v521.ftb
mkdir -p $FW/qcom/sdm710/pyxis/adsp $FW/qcom/sdm710/sirius
cp -rf $FIRMWARE/dsp-adsp/. $FW/qcom/sdm710/pyxis/adsp/
cp -rf $FIRMWARE/rfsa-adsp/. $FW/qcom/sdm710/pyxis/adsp/
cp -f $FIRMWARE/acdb/Forte_Global_cal.acdb $FW/qcom/sdm710/pyxis/Global_cal.acdb
cp -f $FIRMWARE/acdb/Forte/*.acdb $FW/qcom/sdm710/sirius/
cp -f $FIRMWARE/tas2557/tas2557_uCDSP.bin $FW/tas2557_uCDSP.bin
mkdir -p $FW/ti/tas2557
cp -f $FIRMWARE/tas2557/tas2557_cal.bin.sirius $FW/ti/tas2557/tas2557_cal.bin
chmod 644 $FW/qcom/sdm710/pyxis/Global_cal.acdb $FW/qcom/sdm710/sirius/*.acdb $FW/tas2557_uCDSP.bin $FW/ti/tas2557/tas2557_cal.bin
cp -rf $FIRMWARE/pyxis-phone/. $FW/qcom/sdm710/pyxis/
cp -f $FIRMWARE/ath10k/board-2.bin.sirius $FW/ath10k/WCN3990/hw1.0/board-2.bin
cp -f $FIRMWARE/ath10k/firmware-5.bin.WCN3990 $FW/ath10k/WCN3990/hw1.0/firmware-5.bin
cp -f $FIRMWARE/ath10k/wlanmdsp.mbn.WCN3990 $FW/ath10k/WCN3990/hw1.0/wlanmdsp.mbn
cp -f $FIRMWARE/qca/ubuntu25-crbtfw21.tlv $FW/qca/crbtfw21.tlv
cp -f $FIRMWARE/qca/crnv21.bin.sirius $FW/qca/crnv21.bin
chmod 644 $FW/qcom/sdm710/pyxis/a615_zap.mbn $FW/qcom/a630_sqe.fw $FW/qcom/a630_gmu.bin \
  $FW/st_fts_v521.ftb $FW/ath10k/WCN3990/hw1.0/firmware-5.bin $FW/ath10k/WCN3990/hw1.0/wlanmdsp.mbn \
  $FW/ath10k/WCN3990/hw1.0/board-2.bin $FW/qca/crnv21.bin
check_md5() { test "$(md5sum < "$1" | cut -d " " -f1)" = "$2" || { echo "md5 mismatch: $1"; exit 1; }; }
check_md5 $FW/ath10k/WCN3990/hw1.0/firmware-5.bin d16e3444f68ee48c548a891b9f9279e1
check_md5 $FW/ath10k/WCN3990/hw1.0/wlanmdsp.mbn 259b4f9e4aef57a5051f27a201653262
check_md5 $FW/qcom/a630_sqe.fw 9f2540d789d9fd4699a566d97fcabded
check_md5 $FW/qcom/a630_gmu.bin ab20135f7adf48e0f344282a37da80e4
check_md5 $FW/qca/crnv21.bin 3947c734ced07630d9c2c4ba48f72157
check_md5 $FW/ath10k/WCN3990/hw1.0/board-2.bin 63bb8000fe1f64cdecee79076c6d5bc0
check_md5 $FW/qca/crbtfw21.tlv a590087df8f7ba34053956e9b5243bc9
check_md5 $FW/qcom/sdm710/pyxis/venus.mbn 9ca486b43f891d38ccb68e72ee40bfab
check_md5 $FW/qcom/sdm710/pyxis/ipa_fws.mbn 4f3c8cac8e681948b1a3235163a3fa9f
check_md5 $FW/qcom/sdm710/pyxis/cdsp.mbn d0e3a4a90d75d5600b90adeb218595da

echo "=== boot payload for U-Boot (vendor /boot) ==="
PAYLOAD=$STAGE/boot
mkdir -p $PAYLOAD/dtb $PAYLOAD/extlinux $PAYLOAD/efi
KIMG=$KERNEL_SRC/arch/arm64/boot/Image
KDTB=$KERNEL_SRC/arch/arm64/boot/dts/qcom/sdm710-xiaomi-sirius.dtb
test -f "$KIMG" || { echo "missing kernel Image $KIMG (build kernel first?)"; exit 1; }
test -f "$KDTB" || { echo "missing dtb $KDTB"; exit 1; }
cp -f "$KIMG" $PAYLOAD/Image
cp -f "$KIMG" $PAYLOAD/efi/BOOTAA64.EFI # EFI trial: Image is PE/COFF stub, bootefi loads it directly; GRUB replaces this file later
cp -f "$KDTB" $PAYLOAD/dtb/sdm710-xiaomi-sirius.dtb
# initrd is a build intermediate (workspace/build/initrd.cpio.gz), not in build/.
INITRD=${INITRD:-${SCRATCH:-$DISTRO/workspace/build}/initrd.cpio.gz}
test -f "$INITRD" || { echo "missing initrd $INITRD (run ./build.sh initrd first?)"; exit 1; }
cp -f "$INITRD" $PAYLOAD/initrd.cpio.gz
cp -f $DISTRO/boot/extlinux.conf $PAYLOAD/extlinux/extlinux.conf
chmod 644 $PAYLOAD/Image $PAYLOAD/efi/BOOTAA64.EFI $PAYLOAD/dtb/*.dtb $PAYLOAD/initrd.cpio.gz $PAYLOAD/extlinux/extlinux.conf

echo "=== mkfs $OUT ($IMG_SIZE) ==="
mkdir -p "$(dirname "$OUT")"
"$MKFS" -d "$STAGE" -L "$IMG_LABEL" "$OUT" "$IMG_SIZE" >/dev/null
e2fsck -n -f "$OUT" >/dev/null
md5sum "$OUT"
ls -lh "$OUT"
echo KERNEL-IMG-DONE
