#!/bin/bash
# Build Debian trixie server rootfs for xiaomi-sirius (headless + Orbital).
# Device base (WiFi/BT bake + screen/power stack) comes from overlay/
# via sirius-device.sh sirius_overlay (shared by all flavors);
# this script only adds: /opt/orbital, Qt runtime, server enables.
#
# External inputs (fail fast if missing):
#   SIRIUS_BASE  pristine debian-trixie arm64 tree (e.g. linuxcontainers rootfs)
#   Kernel modules + firmware are NOT baked here; they live in the vendor-partition
#   store built by kernel/build-vendormod.sh (see docs/VENDORMOD-STORE.md).
#   SIRIUS_WORK  scratch/output dir for the tree (default: <distro>/work)
# Run on an x86_64 Linux host with qemu-user + binfmt (needs sudo):
#   sudo SIRIUS_BASE=/path/to/base ./build-server.sh
#
# NOTE: default user/password come from sirius-device.sh (SIRIUS_USER /
# SIRIUS_PASS, device-lab convention). Change the password on first boot.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
DSP_BIN=$DISTRO/rootfs/dsp-bin
OVERLAY=$DISTRO/rootfs/overlay
ORBITAL_PKG=$DISTRO/rootfs/orbital-pkg
WORK=${SIRIUS_WORK:-$DISTRO/work}
SRC=${SIRIUS_BASE:-}
test -n "$SRC" || { echo "set SIRIUS_BASE to a pristine trixie arm64 tree"; exit 1; }
test -d $SRC || { echo "missing base tree $SRC"; exit 1; }
test "$(stat -c %u "$SRC")" = 0 || { echo "extract SIRIUS_BASE as root (sudo tar -xpJf rootfs.tar.xz)"; exit 1; }
test -d $OVERLAY || { echo "missing overlay $OVERLAY"; exit 1; }
R=$WORK/debian-trixie-server
. $DISTRO/rootfs/sirius-device.sh
echo "=== server build start $(date) ==="
mkdir -p $WORK
rm -rf $R
cp -a $SRC $R
rm -f $R/etc/machine-id $R/var/lib/dbus/machine-id
rm -f $R/usr/bin/qemu-aarch64-static
sirius_netconf
sirius_apt_mirror
sirius_overlay
# Server flavor: Orbital owns idle auto-off + power/volume/touch keys
# (built-in idle timer). sirius-screen stays as manual rescue.
mkdir -p $R/opt/orbital
cp -f $ORBITAL_PKG/Orbital $ORBITAL_PKG/run.sh $R/opt/orbital/
chmod 755 $R/opt/orbital/Orbital $R/opt/orbital/run.sh
sirius_chroot_begin
chroot $R /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y $SIRIUS_BASE_PKGS evtest rfkill auditd kbd
apt-get install -y qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-shapes qml6-module-qtquick-window qt6-svg-plugins libgl1 libegl1 libgles2 libgl1-mesa-dri libegl-mesa0

useradd -m -u 1000 -U -G sudo -s /bin/bash "$SIRIUS_USER" || true
echo "$SIRIUS_USER:$SIRIUS_PASS" | chpasswd
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SIRIUS_USER" > /etc/sudoers.d/"$SIRIUS_USER"
chmod 0440 /etc/sudoers.d/"$SIRIUS_USER"
usermod -aG "$SIRIUS_GROUPS" "$SIRIUS_USER" || true
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
systemctl set-default multi-user.target
systemctl enable $SIRIUS_BASE_UNITS orbital || true
ldconfig
apt-get clean
rm -f /etc/resolv.conf
mv /etc/resolv.conf.srv-link /etc/resolv.conf
echo CHROOT-DONE
CHROOT_EOF
sirius_chroot_end
echo "=== server build done $(date) ==="
du -sh $R
