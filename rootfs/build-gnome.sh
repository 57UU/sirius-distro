#!/bin/bash
# Build Debian trixie GNOME rootfs for xiaomi-sirius (pure desktop).
# Device base (WiFi/BT bake + screen/power stack) comes from overlay/
# via sirius-device.sh sirius_overlay (shared by all flavors);
# this script only adds: GNOME packages, default user, GDM autologin, enables.
#
# External inputs (fail fast if missing):
#   SIRIUS_BASE  pristine debian-trixie arm64 tree (e.g. linuxcontainers rootfs)
#   Kernel modules + firmware are NOT baked here; they live in the system-partition
#   store built by kernel/build-kernel-img.sh (see docs/KERNEL-IMG-STORE.md).
#   SIRIUS_WORK  scratch/output dir for the tree (default: <distro>/workspace/build/rootfs)
# Run on x86_64 (qemu-user + binfmt) or aarch64 Linux (native, no qemu); needs sudo:
#   sudo SIRIUS_BASE=/path/to/base ./build-gnome.sh
#
# NOTE: default user/password come from sirius-device.sh (SIRIUS_USER /
# SIRIUS_PASS, device-lab convention). Change the password on first boot.
set -e
DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
DSP_BIN=$DISTRO/rootfs/dsp-bin
OVERLAY=$DISTRO/rootfs/overlay
POWERKEY_PKG=$DISTRO/rootfs/powerkey-pkg
WORK=${SIRIUS_WORK:-${SCRATCH:-$DISTRO/workspace/build}/rootfs}
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
# Idle/lock/blank are 100% GNOME native on this flavor; the power key is
# handled by the sirius-powerkey shim (see docs/POWER.md for the rationale).
mkdir -p $R/usr/local/bin $R/etc/systemd/user
cp -f $POWERKEY_PKG/sirius-powerkey $R/usr/local/bin/sirius-powerkey
cp -f $POWERKEY_PKG/sirius-powerkey.service $R/etc/systemd/user/sirius-powerkey.service
chmod 755 $R/usr/local/bin/sirius-powerkey
rm -f $R/etc/systemd/logind.conf.d/sirius-server.conf
cat > $R/etc/systemd/logind.conf.d/sirius-gnome.conf <<'EOF2'
[Login]
# gsd blocks the key before logind sees it, so this only fires when gsd is
# gone (crash / manual stop) — same "lock instead of power off" policy.
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
# sirius-powerkey is a --user unit (talks to gnome-shell's ScreenSaver).
mkdir -p /home/$SIRIUS_USER/.config/systemd/user/graphical-session.target.wants
ln -sf /etc/systemd/user/sirius-powerkey.service /home/$SIRIUS_USER/.config/systemd/user/graphical-session.target.wants/sirius-powerkey.service
chown -R "$SIRIUS_USER":"$SIRIUS_USER" /home/$SIRIUS_USER/.config
# GNOME-side knobs: stock GNOME defaults so a fresh image is predictable
# (blank+lock after 120 s, never suspend, no dimming; see docs/POWER.md).
systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
cat > /usr/share/glib-2.0/schemas/90-sirius-power.gschema.override <<'EOF3'
[org.gnome.settings-daemon.plugins.power]
# power key handled by sirius-powerkey (see docs/POWER.md)
power-button-action="nothing"
sleep-inactive-ac-type="nothing"
sleep-inactive-battery-type="nothing"
idle-dim=false
[org.gnome.desktop.session]
idle-delay=uint32 120
[org.gnome.desktop.screensaver]
lock-enabled=true
idle-activation-enabled=true
EOF3
glib-compile-schemas /usr/share/glib-2.0/schemas/
ldconfig
apt-get clean
# resolv.conf is finalized host-side by sirius_chroot_end (stub symlink);
# do not restore the stashed base file here, it may carry host DNS.
echo CHROOT-DONE
CHROOT_EOF
sirius_chroot_end
echo "=== gnome build done $(date) ==="
du -sh $R
