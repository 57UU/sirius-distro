#!/bin/bash
# sirius-device.sh: shared device bring-up for all rootfs flavors.
# Sourced (not executed) by build-*.sh. Requires caller to set:
#   R         target tree being built
#   FIRMWARE  $DISTRO/firmware
#   DSP_BIN   $DISTRO/rootfs/dsp-bin
#   KMOD_TGZ  kernel modules tarball (checked by caller)
# Flavor-specific bits (desktop packages, DM login, service enables)
# stay in each build-*.sh chroot section.

# Firmware first pass (apt may overwrite some files, see _post).
sirius_firmware_pre() {
  mkdir -p $R/lib/firmware/qcom/sdm710/pyxis
  cp -f $FIRMWARE/gpu/a615_zap.mbn $R/lib/firmware/qcom/sdm710/pyxis/a615_zap.mbn
  cp -f $FIRMWARE/touch/st_fts_v521.ftb $R/lib/firmware/st_fts_v521.ftb
  chmod 644 $R/lib/firmware/qcom/sdm710/pyxis/a615_zap.mbn $R/lib/firmware/st_fts_v521.ftb
  cp -rf $FIRMWARE/pyxis-phone/. $R/lib/firmware/qcom/sdm710/pyxis/
  mkdir -p $R/lib/firmware/ath10k/WCN3990/hw1.0 $R/lib/firmware/qca
  cp -f $FIRMWARE/ath10k/board-2.bin.sirius $R/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
  cp -f $FIRMWARE/qca/ubuntu25-crbtfw21.tlv $R/lib/firmware/qca/crbtfw21.tlv
  rm -f $R/lib/firmware/qca/crnv21.bin
  cp -f $DSP_BIN/pd-mapper $R/usr/local/bin/pd-mapper
  chmod 755 $R/usr/local/bin/pd-mapper
}

# Firmware re-overlay after apt (packages reinstall stock blobs) + checks.
sirius_firmware_post() {
  cp -f $FIRMWARE/ath10k/board-2.bin.sirius $R/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
  cp -f $FIRMWARE/qca/ubuntu25-crbtfw21.tlv $R/lib/firmware/qca/crbtfw21.tlv
  rm -f $R/lib/firmware/qca/crnv21.bin
  test "$(md5sum < $R/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin | cut -d " " -f1)" = 4002bddb9476f322754405ccf284eda3
  test "$(md5sum < $R/lib/firmware/qca/crbtfw21.tlv | cut -d " " -f1)" = a590087df8f7ba34053956e9b5243bc9
  test ! -e $R/lib/firmware/qca/crnv21.bin
}

# Common device base for every flavor. Static files live in rootfs/overlay/
# (edit there, not here); this only copies them in, fixes exec bits, and
# creates the rmtfs partlabel symlinks (kept in code so re-bakes always
# track the current partlabel names).
# Requires: R, DISTRO. OVERLAY defaults to $DISTRO/rootfs/overlay.
sirius_overlay() {
  OVERLAY=${OVERLAY:-$DISTRO/rootfs/overlay}
  test -d $OVERLAY || { echo "missing overlay $OVERLAY"; exit 1; }
  cp -a $OVERLAY/. $R/
  chmod 755 $R/usr/local/sbin/sirius-screen $R/usr/local/sbin/sirius-idle-watch $R/usr/local/sbin/sirius-remodeset $R/usr/local/sbin/sirius-bt-auto $R/usr/local/sbin/sirius-wifi-add $R/usr/local/sbin/safe-reboot $R/usr/local/bin/wifi-shutdown $R/usr/local/sbin/sirius-gnome-blank
  mkdir -p $R/var/lib/rmtfs
  ln -sf /dev/disk/by-partlabel/modemst1 $R/var/lib/rmtfs/modem_fs1
  ln -sf /dev/disk/by-partlabel/modemst2 $R/var/lib/rmtfs/modem_fs2
  ln -sf /dev/disk/by-partlabel/fsc $R/var/lib/rmtfs/modem_fsc
  ln -sf /dev/disk/by-partlabel/fsg $R/var/lib/rmtfs/modem_fsg
}

# Old name kept as an alias (build scripts call sirius_overlay now).
sirius_helpers_units() {
  sirius_overlay
}

sirius_kmod() {
  mkdir -p $R/lib/modules && tar xzf $KMOD_TGZ -C $R/lib/modules/
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
  MIRROR=${SIRIUS_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn}
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