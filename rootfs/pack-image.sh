# Pack a built rootfs tree into tar.zst + f2fs + simg (server/gnome share it).
# Run on the x86_64 build host (needs sudo, zstd, f2fs-tools, img2simg).
# Usage: ./pack-image.sh <tree-dir> <images-dir> <basename>
# e.g.: ./pack-image.sh ~/sirius-build/work/debian-trixie-server ~/sirius-build/images debian-trixie-sirius-server-v6
set -e
TREE=$1; IMGDIR=$2; BASE=$3
test -n "$TREE" -a -n "$IMGDIR" -a -n "$BASE" || { echo "usage: pack-image.sh <tree-dir> <images-dir> <basename>"; exit 1; }
test -d "$TREE" || { echo "missing tree $TREE"; exit 1; }
mkdir -p "$IMGDIR"
echo "=== tar (sudo: keep root-owned files, plain tar as user drops them) ==="
sudo tar -I 'zstd -19 -T0' -cf "$IMGDIR/$BASE.tar.zst" -C "$(dirname "$TREE")" "$(basename "$TREE")"
sudo chown "$(id -u):$(id -g)" "$IMGDIR/$BASE.tar.zst"
echo "=== f2fs (5G, label rootfs; auto-expands to full partition on first boot) ==="
truncate -s 5368709120 "$IMGDIR/$BASE.f2fs"
mkfs.f2fs -l rootfs "$IMGDIR/$BASE.f2fs" >/dev/null
MNT="$(mktemp -d)"
sudo mount -o loop "$IMGDIR/$BASE.f2fs" "$MNT"
sudo cp -a "$TREE/." "$MNT/"
sudo umount "$MNT" && rmdir "$MNT"
fsck.f2fs -f "$IMGDIR/$BASE.f2fs" >/dev/null
echo "=== simg + sha256 ==="
img2simg "$IMGDIR/$BASE.f2fs" "$IMGDIR/$BASE.simg"; rm -f "$IMGDIR/$BASE.f2fs"
(cd "$IMGDIR" && sha256sum "$BASE.simg" | tee "$BASE.simg.sha256")
echo PACK-DONE
