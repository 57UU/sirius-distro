#!/bin/bash
# Build Debian trixie GNOME rootfs for xiaomi-sirius (pure desktop).
# Device base (WiFi/BT bake + screen/power stack) comes from overlay/
# via lib/sirius-device.sh sirius_overlay (shared by all flavors);
# this script only adds: GNOME packages, u57u user, GDM autologin, enables.
#
# External inputs (fail fast if missing):
#   SIRIUS_BASE  pristine debian-trixie arm64 tree (e.g. linuxcontainers rootfs)
#   SIRIUS_KMOD  kernel modules tarball matching the phone kernel (uname -r)
#   SIRIUS_WORK  scratch/output dir for the tree (default: <distro>/work)
# Run on an x86_64 Linux host with qemu-user + binfmt (needs sudo):
#   sudo SIRIUS_BASE=/path/to/base SIRIUS_KMOD=/tmp/kmod.tgz ./build-gnome.sh
#
# NOTE: default user u57u password 1234 (device-lab convention).
# Change it on first boot: passwd u57u.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE=$DISTRO/firmware
DSP_BIN=$DISTRO/rootfs/dsp-bin
OVERLAY=$DISTRO/rootfs/overlay
WORK=${SIRIUS_WORK:-$DISTRO/work}
SRC=${SIRIUS_BASE:-}
KMOD_TGZ=${SIRIUS_KMOD:-}
test -n "$SRC" || { echo "set SIRIUS_BASE to a pristine trixie arm64 tree"; exit 1; }
test -n "$KMOD_TGZ" || { echo "set SIRIUS_KMOD to a kernel modules tarball"; exit 1; }
test -d $SRC || { echo "missing base tree $SRC"; exit 1; }
test "$(stat -c %u "$SRC")" = 0 || { echo "extract SIRIUS_BASE as root (sudo tar -xpJf rootfs.tar.xz)"; exit 1; }
test -f $KMOD_TGZ || { echo "missing kmod $KMOD_TGZ"; exit 1; }
R=$WORK/debian-trixie-gnome
. $DISTRO/rootfs/lib/sirius-device.sh
echo "=== gnome build start $(date) ==="
mkdir -p $WORK
rm -rf $R
cp -a $SRC $R
rm -f $R/etc/machine-id $R/var/lib/dbus/machine-id
rm -f $R/usr/bin/qemu-aarch64-static
sirius_firmware_pre
sirius_overlay
sirius_kmod
sirius_netconf
sirius_apt_mirror
sirius_chroot_begin
chroot $R /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y sudo openssh-server triggerhappy gnome-core gdm3 firmware-atheros firmware-qcom-soc network-manager nano wpasupplicant bluez mesa-vulkan-drivers rmtfs tqftpserv qrtr-tools wireless-tools systemd-timesyncd util-linux-extra
useradd -m -u 1000 -U -G sudo -s /bin/bash u57u || true
echo "u57u:1234" | chpasswd
printf "u57u ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/u57u
chmod 0440 /etc/sudoers.d/u57u
usermod -aG video,render,input u57u || true
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
mkdir -p /etc/gdm3
cat > /etc/gdm3/daemon.conf <<'EOF3'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=u57u
EOF3
systemctl enable ssh gdm systemd-networkd systemd-resolved rmtfs tqftpserv pd-mapper wifi-shutdown bluetooth bt-addr systemd-timesyncd NetworkManager triggerhappy sirius-bt-auto || true
# Blank timing belongs to GNOME (idle-delay, user-adjustable); the real
# backlight follows it via the --user hook below, so the fixed-timer
# system sirius-idle-watch stays OFF on this flavor (server-only).
mkdir -p /home/u57u/.config/systemd/user/graphical-session.target.wants
ln -sf /etc/systemd/user/sirius-gnome-blank.service /home/u57u/.config/systemd/user/graphical-session.target.wants/sirius-gnome-blank.service
chown -R u57u:u57u /home/u57u/.config
# Power-key/idle policy comes from overlay (logind sirius-server.conf:
# HandlePowerKey=ignore so triggerhappy owns the key, like server).
# GNOME-side knobs only: never suspend, settings-daemon takes no action.
systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
cat > /usr/share/glib-2.0/schemas/90-sirius-power.gschema.override <<'EOF3'
[org.gnome.settings-daemon.plugins.power]
power-button-action="nothing"
sleep-inactive-ac-type="nothing"
sleep-inactive-battery-type="nothing"
[org.gnome.desktop.session]
idle-delay=uint32 120
EOF3
glib-compile-schemas /usr/share/glib-2.0/schemas/
apt-get clean
rm -f /etc/resolv.conf
mv /etc/resolv.conf.srv-link /etc/resolv.conf
echo CHROOT-DONE
CHROOT_EOF
sirius_chroot_end
sirius_firmware_post
echo "=== gnome build done $(date) ==="
du -sh $R