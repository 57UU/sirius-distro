#!/bin/bash
# sirius-device.sh: shared device bring-up for all rootfs flavors.
# Sourced (not executed) by build-*.sh. Requires caller to set:
#   R         target tree being built
#   FIRMWARE  $DISTRO/firmware
#   DSP_BIN   $DISTRO/rootfs/dsp-bin
#   Kernel modules + firmware live in the vendor-partition store
#   (rootfs/build-vendormod.sh), not in the rootfs tree.
# Flavor-specific bits (desktop packages, DM login, service enables)
# stay in each build-*.sh chroot section.



# Default device user baked into every flavor (device-lab convention).
# Override at build time: sudo SIRIUS_USER=foo SIRIUS_PASS=bar ./build-server.sh
# Exported so the quoted chroot heredocs in build-*.sh resolve them at runtime.
SIRIUS_USER=${SIRIUS_USER:-u57u}
SIRIUS_PASS=${SIRIUS_PASS:-1234}
export SIRIUS_USER SIRIUS_PASS

# Common device base for every flavor. Static files live in rootfs/overlay/
# (edit there, not here); this only copies them in, fixes exec bits, and
# creates the rmtfs partlabel symlinks (kept in code so re-bakes always
# track the current partlabel names).
# Requires: R, DISTRO. OVERLAY defaults to $DISTRO/rootfs/overlay.
sirius_overlay() {
  OVERLAY=${OVERLAY:-$DISTRO/rootfs/overlay}
  test -d $OVERLAY || { echo "missing overlay $OVERLAY"; exit 1; }
  cp -f $DSP_BIN/pd-mapper $R/usr/local/bin/pd-mapper
  chmod 755 $R/usr/local/bin/pd-mapper
  chmod 755 $R/usr/local/sbin/sirius-screen $R/usr/local/sbin/sirius-remodeset $R/usr/local/sbin/sirius-bt-auto $R/usr/local/sbin/sirius-wifi-add $R/usr/local/sbin/safe-reboot $R/usr/local/bin/wifi-shutdown $R/usr/local/sbin/sirius-gnome-blank $R/usr/local/sbin/sirius-otg $R/usr/local/sbin/sirius-usb-bind $R/usr/local/sbin/sirius-bt-addr $R/usr/local/sbin/sirius-wifi-auto $R/usr/local/sbin/sirius-zram
  # Overlay checkout is user-owned; plain cp -a would stamp that owner onto every
  # shipped dir (phone / once ended up u57u, apt refused it). Copy as root instead.
  cp -a --no-preserve=ownership $OVERLAY/. $R/
  mkdir -p $R/var/lib/rmtfs
  ln -sf /dev/disk/by-partlabel/modemst1 $R/var/lib/rmtfs/modem_fs1
  ln -sf /dev/disk/by-partlabel/modemst2 $R/var/lib/rmtfs/modem_fs2
  ln -sf /dev/disk/by-partlabel/fsc $R/var/lib/rmtfs/modem_fsc
  ln -sf /dev/disk/by-partlabel/fsg $R/var/lib/rmtfs/modem_fsg
  # Empty authorized_keys for the default user (uid/gid fixed at 1000 in the
  # build scripts) so a public key can be dropped in over ssh right after
  # first boot. Runs outside chroot, so chown by number works before the user
  # exists; useradd -m keeps the existing tree.
  mkdir -p $R/home/$SIRIUS_USER/.ssh
  : > $R/home/$SIRIUS_USER/.ssh/authorized_keys
  chmod 755 $R/home/$SIRIUS_USER
  chown 1000:1000 $R/home/$SIRIUS_USER
  chmod 700 $R/home/$SIRIUS_USER/.ssh
  chmod 600 $R/home/$SIRIUS_USER/.ssh/authorized_keys
  chown -h 1000:1000 $R/home/$SIRIUS_USER/.ssh $R/home/$SIRIUS_USER/.ssh/authorized_keys
}

# Old name kept as an alias (build scripts call sirius_overlay now).
sirius_helpers_units() {
  sirius_overlay
}


sirius_netconf() {
  echo "sirius" > $R/etc/hostname
  cat > $R/etc/hosts <<'EOF2'
127.0.0.1	localhost
127.0.1.1	sirius
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF2
  cat > $R/etc/systemd/network/10-usb0.network <<'EOF2'
[Match]
Name=usb0 rndis0

[Network]
Address=172.16.42.1/16
DHCP=no
LinkLocalAddressing=no
EOF2
}

sirius_apt_mirror() {
  MIRROR=${SIRIUS_MIRROR:-https://mirrors.cernet.edu.cn}
  rm -f $R/etc/apt/sources.list.d/*.sources
  cat > $R/etc/apt/sources.list <<EOF2
deb $MIRROR/debian trixie main contrib non-free non-free-firmware
deb $MIRROR/debian trixie-updates main contrib non-free non-free-firmware
deb $MIRROR/debian-security trixie-security main contrib non-free non-free-firmware
EOF2
}

sirius_cleanup() {
  umount -R $R/dev 2>/dev/null || true
  umount -R $R/sys 2>/dev/null || true
  umount $R/proc 2>/dev/null || true
}

# qemu + mounts + resolv, with EXIT trap. Pair with sirius_chroot_end.
sirius_chroot_begin() {
  cp -f /usr/bin/qemu-aarch64-static $R/usr/bin/
  trap sirius_cleanup EXIT
  mount -t proc /proc $R/proc 2>/dev/null || true
  mount --rbind /sys $R/sys
  mount --make-rslave $R/sys
  mount --rbind /dev $R/dev
  mount --make-rslave $R/dev
  mv $R/etc/resolv.conf $R/etc/resolv.conf.srv-link
  echo "nameserver 8.8.8.8" > $R/etc/resolv.conf
}

sirius_chroot_end() {
  umount -R $R/dev || true
  umount -R $R/sys || true
  umount $R/proc || true
  trap - EXIT
  rm -f $R/usr/bin/qemu-aarch64-static
}
