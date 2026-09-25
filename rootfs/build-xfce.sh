#!/bin/bash
# Build Debian trixie XFCE rootfs for xiaomi-sirius (pure desktop).
# Device base (WiFi/BT bake) comes from lib/sirius-device.sh;
# this script only adds: XFCE packages, u57u user, LightDM autologin, enables.
#
# External inputs (fail fast if missing):
#   SIRIUS_BASE  pristine debian-trixie arm64 tree (e.g. linuxcontainers rootfs)
#   SIRIUS_KMOD  kernel modules tarball matching the phone kernel (uname -r)
#   SIRIUS_WORK  scratch/output dir for the tree (default: <distro>/work)
# Run on an x86_64 Linux host with qemu-user + binfmt (needs sudo):
#   sudo SIRIUS_BASE=/path/to/base SIRIUS_KMOD=/tmp/kmod.tgz ./build-xfce.sh
#
# NOTE: default user u57u password 1234 (device-lab convention).
# Change it on first boot: passwd u57u.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE=$DISTRO/firmware
DSP_BIN=$DISTRO/rootfs/dsp-bin
WORK=${SIRIUS_WORK:-$DISTRO/work}
SRC=${SIRIUS_BASE:-}
KMOD_TGZ=${SIRIUS_KMOD:-}
test -n "$SRC" || { echo "set SIRIUS_BASE to a pristine trixie arm64 tree"; exit 1; }
test -n "$KMOD_TGZ" || { echo "set SIRIUS_KMOD to a kernel modules tarball"; exit 1; }
test -d $SRC || { echo "missing base tree $SRC"; exit 1; }
test -f $KMOD_TGZ || { echo "missing kmod $KMOD_TGZ"; exit 1; }
R=$WORK/debian-trixie-xfce
. $DISTRO/rootfs/lib/sirius-device.sh
echo "=== xfce build start $(date) ==="
rm -rf $R
cp -a $SRC $R
rm -f $R/etc/machine-id $R/var/lib/dbus/machine-id
rm -f $R/usr/bin/qemu-aarch64-static
sirius_firmware_pre
sirius_helpers_units
sirius_kmod
sirius_netconf
sirius_chroot_begin
chroot $R /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y sudo openssh-server xfce4 lightdm lightdm-gtk-greeter firmware-atheros firmware-qcom-soc network-manager network-manager-gnome blueman nano wpasupplicant bluez mesa-vulkan-drivers rmtfs tqftpserv qrtr-tools wireless-tools systemd-timesyncd util-linux-extra
useradd -m -u 1000 -U -G sudo -s /bin/bash u57u || true
echo "u57u:1234" | chpasswd
printf "u57u ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/u57u
chmod 0440 /etc/sudoers.d/u57u
usermod -aG video,render,input u57u || true
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf <<'EOF3'
[Seat:*]
autologin-user=u57u
autologin-user-timeout=0
EOF3
systemctl enable ssh lightdm systemd-networkd systemd-resolved rmtfs tqftpserv pd-mapper wifi-shutdown bluetooth systemd-timesyncd NetworkManager || true
apt-get clean
rm -f /etc/resolv.conf
mv /etc/resolv.conf.srv-link /etc/resolv.conf
echo CHROOT-DONE
CHROOT_EOF
sirius_chroot_end
sirius_firmware_post
echo "=== xfce build done $(date) ==="
du -sh $R