# Pack a built rootfs tree into f2fs + simg (server/gnome share it).
# Run on x86_64 or aarch64 host (needs sudo, f2fs-tools, img2simg).
# Usage: ./pack-image.sh <tree-dir> <images-dir> <basename>
# e.g. (what ./build.sh rootfs-server runs):
#   ./pack-image.sh workspace/build/rootfs/debian-trixie-server build debian-trixie-sirius-server-20261020-1530
set -e
TREE=$1; IMGDIR=$2; BASE=$3
test -n "$TREE" -a -n "$IMGDIR" -a -n "$BASE" || { echo "usage: pack-image.sh <tree-dir> <images-dir> <basename>"; exit 1; }
test -d "$TREE" || { echo "missing tree $TREE"; exit 1; }
mkdir -p "$IMGDIR"
echo "=== f2fs (5G, label rootfs; auto-expands to full partition on first boot) ==="
truncate -s 5368709120 "$IMGDIR/$BASE.f2fs"
mkfs.f2fs -l rootfs "$IMGDIR/$BASE.f2fs" >/dev/null
MNT="$(mktemp -d)"
sudo mount -o loop "$IMGDIR/$BASE.f2fs" "$MNT"
sudo cp -a "$TREE/." "$MNT/"
sudo umount "$MNT" && rmdir "$MNT"
fsck.f2fs -f "$IMGDIR/$BASE.f2fs" >/dev/null
echo "=== simg ==="
img2simg "$IMGDIR/$BASE.f2fs" "$IMGDIR/$BASE.simg"; rm -f "$IMGDIR/$BASE.f2fs"
echo PACK-DONE
