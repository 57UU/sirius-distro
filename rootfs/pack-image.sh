# Pack a built rootfs tree into f2fs + simg (server/gnome share it).
# Run on x86_64 or aarch64 host (needs sudo, f2fs-tools, img2simg).
# Usage: ./pack-image.sh <tree-dir> <images-dir> <basename>
# e.g. (what ./build.sh rootfs-server runs):
#   ./pack-image.sh workspace/build/rootfs/debian-trixie-server build debian-trixie-sirius-server-20261020-1530
set -e
TREE=$1; IMGDIR=$2; BASE=$3
test -n "$TREE" -a -n "$IMGDIR" -a -n "$BASE" || { echo "usage: pack-image.sh <tree-dir> <images-dir> <basename>"; exit 1; }
test -d "$TREE" || { echo "missing tree $TREE"; exit 1; }
DISTRO=$(cd "$(dirname "$0")/.." && pwd)
PACK_TMP=${TMPDIR:-${SCRATCH:-$DISTRO/workspace/build}/tmp}
mkdir -p "$IMGDIR" "$PACK_TMP"
WORK=$(mktemp -d "$PACK_TMP/sirius-pack.XXXXXX")
RAW=$WORK/rootfs.f2fs
MNT=$WORK/mnt
mounted=0
mkdir "$MNT"
cleanup() {
    # A failed copy must not leave the loop mount attached. If unmount fails,
    # retain its backing file and mount directory for manual recovery.
    if [ "$mounted" = 1 ] && ! sudo umount "$MNT"; then
        echo "无法卸载打包目录，保留：$WORK" >&2
        return
    fi
    rm -f "$RAW"
    rmdir "$MNT" "$WORK"
}
trap cleanup EXIT
echo "=== f2fs (5G, label rootfs; auto-expands to full partition on first boot) ==="
truncate -s 5368709120 "$RAW"
mkfs.f2fs -l rootfs "$RAW" >/dev/null
sudo mount -o loop "$RAW" "$MNT"
mounted=1
sudo cp -a "$TREE/." "$MNT/"
sudo umount "$MNT"
mounted=0
fsck.f2fs -f "$RAW" >/dev/null
echo "=== simg ==="
img2simg "$RAW" "$IMGDIR/$BASE.simg"
# build.sh runs this script under sudo; hand the artifact (and the images dir,
# which may have been created by root) back to the invoking user, otherwise
# later non-root builds, `clean` and fastboot file access break.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$IMGDIR/$BASE.simg" "$IMGDIR" 2>/dev/null || true
fi
echo PACK-DONE
