#!/bin/bash
# build.sh: sirius-distro 统一构建入口。
#   最终产物(.img/.simg) -> build/          （入库约定：img/simg 放 build/）
#   中间产物(其余一切)   -> workspace/build/ （.gitignore 已忽略 workspace/）
#   主机架构自适应：aarch64 原生（无需 qemu）；其余交叉（rootfs 需 qemu-user + binfmt）。
#
# 用法:
#   ./build.sh initrd        initramfs -> workspace/build/initrd.cpio.gz
#   ./build.sh boot          U-Boot    -> build/boot.img（中间件 workspace/build/uboot/）
#   ./build.sh kernel        模块+固件 -> build/kernel.img（需先 ./build.sh initrd）
#   ./build.sh rootfs-gnome  构建+打包 GNOME rootfs（需 sudo + SIRIUS_BASE）
#   ./build.sh rootfs-server 构建+打包 server rootfs（需 sudo + SIRIUS_BASE）
#   ./build.sh all           依次 initrd -> boot -> kernel -> rootfs-gnome -> rootfs-server
#   ./build.sh clean         清 workspace/build/（中间产物；build/ 下的 img/simg 不动）
#
# 环境变量:
#   OUT_DIR      最终产物目录（默认 <repo>/build）
#   SCRATCH      中间产物目录（默认 <repo>/workspace/build）
#   TAG          rootfs 镜像版本后缀（默认 date +%Y%m%d-%H%M）
#   SIRIUS_BASE  原始 trixie arm64 树（默认 $SCRATCH/base；rootfs 目标必需）
#   CROSS_COMPILE 交叉前缀（默认按主机架构：aarch64 空 / 其他 aarch64-linux-gnu-）
#   KERNEL_SRC / IMG_SIZE / IMG_LABEL / ARCH / JOBS 等透传给子脚本
set -euo pipefail
DISTRO="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR=${OUT_DIR:-$DISTRO/build}
SCRATCH=${SCRATCH:-$DISTRO/workspace/build}
export OUT_DIR SCRATCH
mkdir -p "$OUT_DIR" "$SCRATCH"
# 子脚本里的 mktemp -d 就地建中转目录，指到 SCRATCH 下，别再散到 /tmp
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"

# 主机架构自适应：不硬编码 qemu。
# 原生 arm64 主机不传 CROSS_COMPILE；否则默认 aarch64 交叉前缀。
# 用 ${VAR-default}（不是 :-）以便显式传空值仍被尊重。
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  aarch64|arm64) DEF_CROSS= ;;
  *)             DEF_CROSS=aarch64-linux-gnu- ;;
esac
CROSS_COMPILE=${CROSS_COMPILE-$DEF_CROSS}
export CROSS_COMPILE HOST_ARCH

TAG=${TAG:-$(date +%Y%m%d-%H%M)}
SIRIUS_BASE=${SIRIUS_BASE:-$SCRATCH/base}
export TAG SIRIUS_BASE

as_root() {
  # `sudo -E` is not universally supported (WSL sudo silently ignores it, so the
  # exported vars never reach the root child); pass them explicitly via `env`.
  # sbin dirs are appended because a normal user PATH often lacks them (chroot,
  # mkfs.f2fs... live in /usr/sbin), and sudo's own secure_path is not used once
  # we override PATH.
  # TMPDIR is dropped on purpose: rootfs builds chroot into the tree, where the
  # host scratch path does not exist (dpkg postinsts would fail on mktemp).
  if [ "$(id -u)" = 0 ]; then "$@"; else
    sudo env -u TMPDIR PATH="$PATH:/usr/sbin:/sbin" \
      OUT_DIR="$OUT_DIR" SCRATCH="$SCRATCH" HOST_ARCH="$HOST_ARCH" \
      SIRIUS_BASE="${SIRIUS_BASE:-}" SIRIUS_WORK="${SIRIUS_WORK:-}" \
      TAG="${TAG:-}" CROSS_COMPILE="${CROSS_COMPILE:-}" "$@"
  fi
}

cmd_initrd() { bash "$DISTRO/boot/initrd/build.sh" "$SCRATCH/initrd.cpio.gz"; }

cmd_boot() { OUT="$SCRATCH/uboot" IMG="$OUT_DIR/boot.img" bash "$DISTRO/uboot/sirius-build.sh"; }

cmd_kernel() {
  test -f "$SCRATCH/initrd.cpio.gz" || { echo "缺 $SCRATCH/initrd.cpio.gz，先 ./build.sh initrd"; exit 1; }
  bash "$DISTRO/kernel/build-kernel-img.sh"      # OUT 默认已是 build/kernel.img
}

cmd_rootfs() {                                    # $1 = gnome | server
  local flavor=$1 tree=debian-trixie-$1
  test -d "$SIRIUS_BASE" || { echo "缺 SIRIUS_BASE=$SIRIUS_BASE（原始 trixie arm64 树）"; exit 1; }
  # 非 arm64 主机需要 qemu-user 模拟（arm64 主机原生 chroot，完全不碰 qemu）
  case "$HOST_ARCH" in
    aarch64|arm64) : ;;
    *)
      test -f /usr/bin/qemu-aarch64-static || {
        echo "缺 /usr/bin/qemu-aarch64-static（装 qemu-user-static）"; exit 1; }
      test -e /proc/sys/fs/binfmt_misc/qemu-aarch64 || \
        echo "注意：binfmt_misc 未见 qemu-aarch64 条目，chroot 可能跑不起来（sudo systemctl restart systemd-binfmt）"
      ;;
  esac
  export SIRIUS_WORK="$SCRATCH/rootfs"
  as_root bash "$DISTRO/rootfs/build-$flavor.sh"
  # packing runs host-side (mktemp for the loop mount), so keep it in the scratch dir
  as_root env TMPDIR="$TMPDIR" bash "$DISTRO/rootfs/pack-image.sh" "$SCRATCH/rootfs/$tree" \
    "$OUT_DIR" "debian-trixie-sirius-$flavor-$TAG"
}

cmd_clean() { rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"; }   # build/ 下 img/simg 是交付物，不删

case "${1:-help}" in
  initrd)        cmd_initrd ;;
  boot)          cmd_boot ;;
  kernel)        cmd_kernel ;;
  rootfs-gnome)  cmd_rootfs gnome ;;
  rootfs-server) cmd_rootfs server ;;
  all)           cmd_initrd; cmd_boot; cmd_kernel; cmd_rootfs gnome; cmd_rootfs server ;;
  clean)         cmd_clean ;;
  *|help|-h)     sed -n '2,/^set -/p' "$0"; exit 1 ;;
esac
