#!/bin/bash
# Build Debian trixie GNOME rootfs for xiaomi-sirius (pure desktop).
# Device base (WiFi/BT bake + screen/power stack) comes from overlay/
# via sirius-device.sh sirius_overlay (shared by all flavors);
# this script only adds: GNOME packages, default user, GDM autologin, enables.
#
# External inputs (fail fast if missing):
#   SIRIUS_BASE  pristine debian-trixie arm64 tree (e.g. linuxcontainers rootfs)
#   Kernel modules + firmware are NOT baked here; they live in the vendor-partition
#   store built by kernel/build-vendormod.sh (see docs/VENDORMOD-STORE.md).
#   SIRIUS_WORK  scratch/output dir for the tree (default: <distro>/work)
# Run on an x86_64 Linux host with qemu-user + binfmt (needs sudo):
#   sudo SIRIUS_BASE=/path/to/base ./build-gnome.sh
#
# NOTE: default user/password come from sirius-device.sh (SIRIUS_USER /
# SIRIUS_PASS, device-lab convention). Change the password on first boot.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
DSP_BIN=$DISTRO/rootfs/dsp-bin
OVERLAY=$DISTRO/rootfs/overlay
WORK=${SIRIUS_WORK:-$DISTRO/work}
SRC=${SIRIUS_BASE:-}
test -n "$SRC" || { echo "set SIRIUS_BASE to a pristine trixie arm64 tree"; exit 1; }
test -d $SRC || { echo "missing base tree $SRC"; exit 1; }
test "$(stat -c %u "$SRC")" = 0 || { echo "extract SIRIUS_BASE as root (sudo tar -xpJf rootfs.tar.xz)"; exit 1; }
R=$WORK/debian-trixie-gnome
. $DISTRO/rootfs/sirius-device.sh
echo "=== gnome build start $(date) ==="
mkdir -p $WORK
rm -rf $R
cp -a $SRC $R
rm -f $R/etc/machine-id $R/var/lib/dbus/machine-id
rm -f $R/usr/bin/qemu-aarch64-static
sirius_overlay
sirius_netconf
sirius_apt_mirror
# Idle + power key are native GNOME/logind on this flavor. Give logind the
# GNOME key policy: short-press power = lock -> screensaver blank ->
# sirius-gnome-blank cuts backlight (lock asks no password, see gschema
# below, so any input wakes); long-press = poweroff. Touch/volume wake by
# resetting GNOME idle like a normal desktop.
rm -f $R/etc/systemd/logind.conf.d/sirius-server.conf
cat > $R/etc/systemd/logind.conf.d/sirius-gnome.conf <<'EOF2'
[Login]
HandlePowerKey=lock
HandlePowerKeyLongPress=poweroff
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF2
sirius_chroot_begin
chroot $R /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y $SIRIUS_BASE_PKGS gnome-core gdm3 firmware-atheros firmware-qcom-soc
useradd -m -u 1000 -U -G sudo -s /bin/bash "$SIRIUS_USER" || true
echo "$SIRIUS_USER:$SIRIUS_PASS" | chpasswd
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SIRIUS_USER" > /etc/sudoers.d/"$SIRIUS_USER"
chmod 0440 /etc/sudoers.d/"$SIRIUS_USER"
usermod -aG "$SIRIUS_GROUPS" "$SIRIUS_USER" || true
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
mkdir -p /etc/gdm3
cat > /etc/gdm3/daemon.conf <<EOF3
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=$SIRIUS_USER
EOF3
systemctl enable $SIRIUS_BASE_UNITS gdm || true
# Blank timing AND power key belong to GNOME/logind on this flavor
# (server uses the Orbital built-in timer instead).
# The real backlight follows the screensaver via the --user hook below;
# idle timeout stays user-adjustable (Settings -> Power -> Screen Blank).
mkdir -p /home/$SIRIUS_USER/.config/systemd/user/graphical-session.target.wants
ln -sf /etc/systemd/user/sirius-gnome-blank.service /home/$SIRIUS_USER/.config/systemd/user/graphical-session.target.wants/sirius-gnome-blank.service
chown -R "$SIRIUS_USER":"$SIRIUS_USER" /home/$SIRIUS_USER/.config
# Logind policy is sirius-gnome.conf (written above, replaces the overlay server one).
# GNOME-side knobs only: never suspend, never demand unlock password,
# settings-daemon takes no power-button action (logind owns the key).
systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
cat > /usr/share/glib-2.0/schemas/90-sirius-power.gschema.override <<'EOF3'
[org.gnome.settings-daemon.plugins.power]
power-button-action="nothing"
sleep-inactive-ac-type="nothing"
sleep-inactive-battery-type="nothing"
[org.gnome.desktop.session]
idle-delay=uint32 120
[org.gnome.desktop.screensaver]
# Power key = logind lock, so the blank must not ask for
# a password (same no-auth toggle semantics as before; any input wakes).
lock-enabled=false
idle-activation-enabled=true
EOF3
glib-compile-schemas /usr/share/glib-2.0/schemas/
ldconfig
apt-get clean
rm -f /etc/resolv.conf
mv /etc/resolv.conf.srv-link /etc/resolv.conf
echo CHROOT-DONE
CHROOT_EOF
sirius_chroot_end
echo "=== gnome build done $(date) ==="
du -sh $R
