# Pack a built rootfs tree into tar.zst + ext4 + simg (server/gnome share it).
# Run on the x86_64 build host (needs sudo, zstd, e2fsprogs, img2simg).
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
echo "=== ext4 (3G, label sirius-debian) ==="
truncate -s 3221225472 "$IMGDIR/$BASE.ext4"
sudo mke2fs -t ext4 -L sirius-debian -d "$TREE" "$IMGDIR/$BASE.ext4"
sudo e2fsck -f -y "$IMGDIR/$BASE.ext4"
echo "=== simg + sha256 ==="
img2simg "$IMGDIR/$BASE.ext4" "$IMGDIR/$BASE.simg"
(cd "$IMGDIR" && sha256sum "$BASE.simg" | tee "$BASE.simg.sha256")
echo PACK-DONE
