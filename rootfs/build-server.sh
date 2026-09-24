#!/bin/bash
# Build Debian trixie server rootfs for xiaomi-sirius (headless + Orbital).
# Device base (WiFi/BT bake) comes from lib/sirius-device.sh;
# this script only adds: overlay/, /opt/orbital, Qt runtime, server enables.
#
# External inputs (fail fast if missing):
#   SIRIUS_BASE  pristine debian-trixie arm64 tree (e.g. linuxcontainers rootfs)
#   SIRIUS_KMOD  kernel modules tarball matching the phone kernel (uname -r)
#   SIRIUS_WORK  scratch/output dir for the tree (default: <distro>/work)
# Run on an x86_64 Linux host with qemu-user + binfmt (needs sudo):
#   sudo SIRIUS_BASE=/path/to/base SIRIUS_KMOD=/tmp/kmod.tgz ./build-server.sh
#
# NOTE: default user u57u password 1234 (device-lab convention).
# Change it on first boot: passwd u57u.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE=$DISTRO/firmware
DSP_BIN=$DISTRO/rootfs/dsp-bin
OVERLAY=$DISTRO/rootfs/overlay
ORBITAL_PKG=$DISTRO/rootfs/orbital-pkg
WORK=${SIRIUS_WORK:-$DISTRO/work}
SRC=${SIRIUS_BASE:-}
KMOD_TGZ=${SIRIUS_KMOD:-}
test -n "$SRC" || { echo "set SIRIUS_BASE to a pristine trixie arm64 tree"; exit 1; }
test -n "$KMOD_TGZ" || { echo "set SIRIUS_KMOD to a kernel modules tarball"; exit 1; }
test -d $SRC || { echo "missing base tree $SRC"; exit 1; }
test -f $KMOD_TGZ || { echo "missing kmod $KMOD_TGZ"; exit 1; }
test -d $OVERLAY || { echo "missing overlay $OVERLAY"; exit 1; }
R=$WORK/debian-trixie-server
. $DISTRO/rootfs/lib/sirius-device.sh
echo "=== server build start $(date) ==="
rm -rf $R
cp -a $SRC $R
rm -f $R/usr/bin/qemu-aarch64-static
sirius_firmware_pre
sirius_helpers_units
sirius_kmod
sirius_netconf
cp -a $OVERLAY/. $R/
chmod 755 $R/usr/local/sbin/sirius-screen $R/usr/local/sbin/sirius-idle-watch $R/usr/local/sbin/sirius-remodeset $R/usr/local/sbin/sirius-bt-auto $R/usr/local/sbin/sirius-wifi-add
mkdir -p $R/opt/orbital
cp -f $ORBITAL_PKG/Orbital $ORBITAL_PKG/run.sh $R/opt/orbital/
chmod 755 $R/opt/orbital/Orbital $R/opt/orbital/run.sh
sirius_chroot_begin
chroot $R /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y triggerhappy evtest rfkill auditd kbd
apt-get install -y qt6-base qt6-declarative qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-shapes qml6-module-qtquick-window libgl1 libegl1
apt-get purge -y lightdm lightdm-gtk-greeter xfce4 network-manager-gnome blueman mesa-vulkan-drivers || true
apt-get autoremove --purge -y || true
rm -rf /etc/lightdm
rm -f /etc/systemd/system/display-manager.service
printf "u57u ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/u57u
chmod 0440 /etc/sudoers.d/u57u
systemctl disable lightdm gdm display-manager 2>/dev/null || true
systemctl set-default multi-user.target
systemctl enable ssh systemd-networkd systemd-resolved rmtfs tqftpserv pd-mapper wifi-shutdown bluetooth systemd-timesyncd NetworkManager triggerhappy sirius-idle-watch sirius-bt-auto orbital || true
apt-get clean
rm -f /etc/resolv.conf
mv /etc/resolv.conf.srv-link /etc/resolv.conf
echo CHROOT-DONE
CHROOT_EOF
sirius_chroot_end
sirius_firmware_post
echo "=== server build done $(date) ==="
du -sh $R