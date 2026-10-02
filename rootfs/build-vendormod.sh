#!/bin/bash
# build-vendormod.sh: assemble the sirius vendor-partition store image.
#
# The store decouples kernel modules + device firmware from the userdata
# rootfs. Layout inside the image:
#   lib/modules/<uname -r>/   modules + depmod db, from a built kernel tree
#   lib/firmware/...          device blobs (same mapping as sirius_firmware_pre)
#
# Run on the kernel build host (needs the kernel tree already built):
#   ./build-vendormod.sh
# Env overrides:
#   KERNEL_SRC  built kernel tree (default: <distro>/kernel/linux-sirius)
#   OUT         output image (default: <distro>/build/vendormod.img, gitignored)
#   IMG_SIZE    ext4 size (default: 256M; content is ~55M)
#   IMG_LABEL   fs label (default: sirius_vendor)
#   ARCH / CROSS_COMPILE / DEPMOD / MKFS as usual.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC=${KERNEL_SRC:-$DISTRO/kernel/linux-sirius}
FIRMWARE=$DISTRO/firmware
OUT=${OUT:-$DISTRO/build/vendormod.img}
IMG_SIZE=${IMG_SIZE:-256M}
IMG_LABEL=${IMG_LABEL:-sirius_vendor}
ARCH=${ARCH:-arm64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
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
cp -f $FIRMWARE/touch/st_fts_v521.ftb $FW/st_fts_v521.ftb
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

echo "=== mkfs $OUT ($IMG_SIZE) ==="
mkdir -p "$(dirname "$OUT")"
"$MKFS" -d "$STAGE" -L "$IMG_LABEL" "$OUT" "$IMG_SIZE" >/dev/null
e2fsck -n -f "$OUT" >/dev/null
md5sum "$OUT"
ls -lh "$OUT"
echo VENDORMOD-DONE
