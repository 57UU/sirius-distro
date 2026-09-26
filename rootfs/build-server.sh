#!/bin/bash
# Build Debian trixie server rootfs for xiaomi-sirius (headless + Orbital).
# Device base (WiFi/BT bake + screen/power stack) comes from overlay/
# via lib/sirius-device.sh sirius_overlay (shared by all flavors);
# this script only adds: /opt/orbital, Qt runtime, server enables.
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
test "$(stat -c %u "$SRC")" = 0 || { echo "extract SIRIUS_BASE as root (sudo tar -xpJf rootfs.tar.xz)"; exit 1; }
test -f $KMOD_TGZ || { echo "missing kmod $KMOD_TGZ"; exit 1; }
test -d $OVERLAY || { echo "missing overlay $OVERLAY"; exit 1; }
R=$WORK/debian-trixie-server
. $DISTRO/rootfs/lib/sirius-device.sh
echo "=== server build start $(date) ==="
mkdir -p $WORK
rm -rf $R
cp -a $SRC $R
rm -f $R/etc/machine-id $R/var/lib/dbus/machine-id
rm -f $R/usr/bin/qemu-aarch64-static
sirius_firmware_pre
sirius_kmod
sirius_netconf
sirius_apt_mirror
sirius_overlay
# Orbital owns idle auto-off + power/volume/touch keys now (built-in idle timer).
# Drop the triggerhappy key rules on this flavor so thd never fights Orbital
# (gnome flavor keeps them: no Orbital there). sirius-screen stays as manual rescue.
rm -f $R/etc/triggerhappy/triggers.d/sirius-power.conf
mkdir -p $R/opt/orbital
cp -f $ORBITAL_PKG/Orbital $ORBITAL_PKG/run.sh $R/opt/orbital/
chmod 755 $R/opt/orbital/Orbital $R/opt/orbital/run.sh
sirius_chroot_begin
chroot $R /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y triggerhappy evtest rfkill auditd kbd e2fsprogs bluez sudo openssh-server network-manager nano wpasupplicant rmtfs tqftpserv qrtr-tools wireless-tools systemd-timesyncd util-linux-extra
apt-get install -y qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-shapes qml6-module-qtquick-window qt6-svg-plugins libgl1 libegl1 libgles2 libgl1-mesa-dri libegl-mesa0
apt-get purge -y lightdm lightdm-gtk-greeter xfce4 network-manager-gnome blueman mesa-vulkan-drivers || true
apt-get autoremove --purge -y || true
rm -rf /etc/lightdm
rm -f /etc/systemd/system/display-manager.service
useradd -m -u 1000 -U -G sudo -s /bin/bash u57u || true
echo "u57u:1234" | chpasswd
printf "u57u ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/u57u
chmod 0440 /etc/sudoers.d/u57u
usermod -aG video,render,input u57u || true
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
systemctl disable lightdm gdm display-manager 2>/dev/null || true
systemctl set-default multi-user.target
systemctl enable ssh systemd-networkd systemd-resolved rmtfs tqftpserv pd-mapper wifi-shutdown bluetooth bt-addr systemd-timesyncd NetworkManager triggerhappy sirius-bt-auto orbital || true
apt-get clean
rm -f /etc/resolv.conf
mv /etc/resolv.conf.srv-link /etc/resolv.conf
echo CHROOT-DONE
CHROOT_EOF
sirius_chroot_end
sirius_firmware_post
echo "=== server build done $(date) ==="
du -sh $R