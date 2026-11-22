#!/bin/bash
# sirius-device.sh: shared device bring-up for all rootfs flavors.
# Sourced (not executed) by build-*.sh; the caller sets R (target rootfs tree)
# and DISTRO (repo root). Device/kernel-coupled files live in glue/ and are
# packed into the system image, so the rootfs only gets rootfs/overlay/ plus
# the 4-line systemd generator stub.
# Flavor-specific bits stay in each build-*.sh chroot section.

# Default device user baked into every flavor (device-lab convention).
# Override at build time: sudo SIRIUS_USER=foo SIRIUS_PASS=bar ./build-server.sh
# Exported so the quoted chroot heredocs in build-*.sh resolve them at runtime.
SIRIUS_USER=${SIRIUS_USER:-u57u}
SIRIUS_PASS=${SIRIUS_PASS:-1234}
export SIRIUS_USER SIRIUS_PASS

# Shared audio bring-up (docs/AUDIO-BRINGUP.md §6): every flavor needs the full
# ALSA userspace (aplay/amixer/alsaucm from alsa-utils, UCM data from
# alsa-ucm-conf) and the default user in the audio group (/dev/snd is
# root:audio 660; without it plain `aplay -l` says no soundcards while root
# still sees SE). Exported so the quoted chroot heredocs in build-*.sh
# resolve them at runtime (same mechanism as SIRIUS_USER/SIRIUS_PASS).
# Service enables stay per-flavor: each build-*.sh enable list must still
# include sirius-audio-init (UCM HiFi/Speaker route at boot).
SIRIUS_GROUPS=${SIRIUS_GROUPS:-video,audio,render,input}
SIRIUS_AUDIO_PKGS=${SIRIUS_AUDIO_PKGS:-"alsa-utils alsa-ucm-conf"}
export SIRIUS_GROUPS SIRIUS_AUDIO_PKGS

# Shared Vulkan spare (Turnip sees Adreno 615; Orbital stays on OpenGL ES,
# switch later with QSG_RHI_BACKEND=vulkan). Same export-into-chroot
# mechanism as above.
SIRIUS_VULKAN_PKGS=${SIRIUS_VULKAN_PKGS:-"mesa-vulkan-drivers vulkan-tools"}
export SIRIUS_VULKAN_PKGS

# Mesa 默认取 trixie-backports 的版本（当前 26.1.6）：OpenGL 客户端比 trixie 自带的
# 25.0.7 快约 15%，Vulkan 持平，没有发现回退（见 docs/GRAPHICS-BENCHMARK.md）。
# 想固定用 trixie 自带版本时，构建前设 SIRIUS_MESA_BACKPORTS=0。
# 这 6 个包必须同版本一起装：libgbm1/mesa-libgallium/libgl1-mesa-dri/libegl-mesa0/
# libglx-mesa0 之间是 "=" 依赖；mesa-vulkan-drivers 可独立，但同批升级更一致。
SIRIUS_MESA_BACKPORTS=${SIRIUS_MESA_BACKPORTS:-1}
SIRIUS_MESA_PKGS=${SIRIUS_MESA_PKGS:-"libgbm1 mesa-libgallium libgl1-mesa-dri libegl-mesa0 libglx-mesa0 mesa-vulkan-drivers"}
# 开关关闭时不把它们并进基础包列表，保持 trixie 自带版本。
if [ "$SIRIUS_MESA_BACKPORTS" = 1 ]; then
  SIRIUS_MESA_SEL=$SIRIUS_MESA_PKGS
else
  SIRIUS_MESA_SEL=
fi
export SIRIUS_MESA_BACKPORTS SIRIUS_MESA_PKGS SIRIUS_MESA_SEL

# Shared base packages for every flavor: each build-*.sh runs
# `apt-get install -y $SIRIUS_BASE_PKGS` first, then its flavor-only extras
# (server: evtest/rfkill/auditd/kbd + Qt runtime; gnome:
# gnome-core/gdm3/firmware). Flavor lines must not repeat these.
SIRIUS_BASE_PKGS=${SIRIUS_BASE_PKGS:-"sudo openssh-server network-manager nano wpasupplicant bluez rmtfs tqftpserv qrtr-tools libbsd0 wireless-tools pipewire wireplumber modemmanager libqmi-utils mobile-broadband-provider-info iw $SIRIUS_AUDIO_PKGS $SIRIUS_VULKAN_PKGS $SIRIUS_MESA_SEL systemd-timesyncd systemd-resolved util-linux-extra e2fsprogs"}
export SIRIUS_BASE_PKGS

# Shared service enables for every flavor: each build-*.sh runs
# `systemctl enable $SIRIUS_BASE_UNITS <flavor-extra>` (server: orbital;
# gnome: gdm). Flavor lines must not repeat these.
SIRIUS_BASE_UNITS=${SIRIUS_BASE_UNITS:-"ssh systemd-networkd systemd-resolved rmtfs tqftpserv bluetooth systemd-timesyncd NetworkManager ModemManager"}
export SIRIUS_BASE_UNITS
# Common device base for every flavor. Static files live in rootfs/overlay/
# (edit there, not here); this only copies them in and fixes exec bits.
# Kernel/device-coupled files live in glue/ and are packed into the system
# image; flavor policy (e.g. logind power-key handling) stays in the overlay of
# each build-*.sh so one system image works for both flavors.
# Requires: R, DISTRO. OVERLAY defaults to $DISTRO/rootfs/overlay.
sirius_overlay() {
  OVERLAY=${OVERLAY:-$DISTRO/rootfs/overlay}
  test -d $OVERLAY || { echo "missing overlay $OVERLAY"; exit 1; }
  # Overlay checkout is user-owned; plain cp -a would stamp that owner onto every
  # shipped dir (phone / once ended up u57u, apt refused it). Copy as root instead.
  cp -a --no-preserve=ownership $OVERLAY/. $R/
  # NetworkManager 只加载属主 root 且权限 600 的 keyfile；蜂窝连接的 keyfile 在
  # system 分区 glue/run 里（由打包脚本置 600），这里只兜底 rootfs 自带的。
  chmod 600 $R/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
  # preset/unit 在 git 里保持 0644，打包前再确认一次。
  chmod 644 $R/etc/systemd/system-preset/*.preset 2>/dev/null || true
  # /usr/local/sbin/* 现在是指向 /mnt/sysmod/glue/{bin,scripts}/ 的软链，不在这里 chmod
  # （host 侧软链目标不存在会报错，权限由 system 分区打包脚本统一置 755）。
  # 4 行 generator stub；实现在 system 分区（见 docs/KERNEL-IMG-STORE.md）。
  GLUE_STUB=$R/usr/lib/systemd/system-generators/sirius-kernel-glue
  test -f "$GLUE_STUB" || { echo "missing glue generator stub $GLUE_STUB"; exit 1; }
  chmod 755 "$GLUE_STUB"
  # Empty authorized_keys for the default user (uid/gid fixed at 1000 in the
  # build scripts) so a public key can be dropped in over ssh right after
  # first boot. Runs outside chroot, so chown by number works before the user
  # exists; useradd -m keeps the existing tree.
  mkdir -p $R/home/$SIRIUS_USER/.ssh
  # Builds never run useradd -m on a home that already exists here,
  # so seed every skel entry for a normal interactive login
  # (Debian color prompt, aliases, logout handling).
  for f in $R/etc/skel/.[!.]* $R/etc/skel/*; do
    test -e "$f" || continue
    cp -a "$f" $R/home/$SIRIUS_USER/
    chown 1000:1000 $R/home/$SIRIUS_USER/"$(basename "$f")"
  done
  : > $R/home/$SIRIUS_USER/.ssh/authorized_keys
  chmod 755 $R/home/$SIRIUS_USER
  chown 1000:1000 $R/home/$SIRIUS_USER
  chmod 700 $R/home/$SIRIUS_USER/.ssh
  chmod 600 $R/home/$SIRIUS_USER/.ssh/authorized_keys
  chown -h 1000:1000 $R/home/$SIRIUS_USER/.ssh $R/home/$SIRIUS_USER/.ssh/authorized_keys
  # for rootless containers
  mkdir -p $R/var/lib/systemd/linger
  touch $R/var/lib/systemd/linger/$SIRIUS_USER
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
  # backports 是 NotAutomatic（默认优先级 100），普通 install 不会选它。
  # 这里只把上面 6 个 Mesa 包钉到 990，其余包仍留在 trixie，不会整体漂到 backports。
  PREF=$R/etc/apt/preferences.d/sirius-mesa-backports
  rm -f "$PREF"
  if [ "$SIRIUS_MESA_BACKPORTS" = 1 ]; then
    echo "deb $MIRROR/debian trixie-backports main contrib non-free non-free-firmware" >> $R/etc/apt/sources.list
    # 只把这 6 个包钉到 backports（其余仍走 trixie）。backports 本身是 NotAutomatic，
    # 不加这段的话普通 apt-get install 仍会选 trixie 的旧版。
    mkdir -p $R/etc/apt/preferences.d
    : > "$PREF"
    for _p in $SIRIUS_MESA_PKGS; do
      cat >> "$PREF" <<PREF_EOF
Package: $_p
Pin: release n=trixie-backports
Pin-Priority: 990

PREF_EOF
    done
  fi
}

sirius_cleanup() {
  umount -R $R/dev 2>/dev/null || true
  umount -R $R/sys 2>/dev/null || true
  umount $R/proc 2>/dev/null || true
}

# qemu + mounts + resolv, with EXIT trap. Pair with sirius_chroot_end.
sirius_chroot_begin() {
  # Native arm64 hosts (e.g. the phone itself) need no qemu; the cp would
  # fail under set -e, so only stage the static binary when emulating.
  case "$(uname -m)" in
    aarch64|arm64) : ;;
    *) cp -f /usr/bin/qemu-aarch64-static $R/usr/bin/ ;;
  esac
  trap sirius_cleanup EXIT
  mount -t proc /proc $R/proc 2>/dev/null || true
  mount --rbind /sys $R/sys
  mount --make-rslave $R/sys
  mount --rbind /dev $R/dev
  mount --make-rslave $R/dev
  # Stash whatever the base ships (file or symlink) so apt gets a working
  # build-time DNS. Never restored verbatim: sirius_chroot_end() installs
  # the stock systemd-resolved stub symlink instead, so a host-polluted
  # base (e.g. WSL resolv.conf copied in by debootstrap) cannot leak
  # into the shipped image.
  rm -f $R/etc/resolv.conf.srv-link
  if [ -e $R/etc/resolv.conf ] || [ -L $R/etc/resolv.conf ]; then
    mv $R/etc/resolv.conf $R/etc/resolv.conf.srv-link
  fi
  echo "nameserver 8.8.8.8" > $R/etc/resolv.conf
}

sirius_chroot_end() {
  umount -R $R/dev || true
  umount -R $R/sys || true
  umount $R/proc || true
  trap - EXIT
  rm -f $R/usr/bin/qemu-aarch64-static
  # Finalize resolv.conf host-side (chroot bodies must not restore the
  # stashed file themselves): stock Debian with systemd-resolved expects
  # the stub symlink. This matches what systemd-resolved.postinst does on
  # a fresh install (regular resolv.conf -> .resolv.conf.systemd-resolved.bak
  # plus this same symlink).
  rm -f $R/etc/resolv.conf $R/etc/resolv.conf.srv-link
  ln -s ../run/systemd/resolve/stub-resolv.conf $R/etc/resolv.conf
}
