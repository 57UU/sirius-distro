#!/bin/bash
# $1: output file
OUT="${1:-initrd.cpio.gz}"
# shellcheck disable=SC2164
mkinitfs () {
	OUT="$(realpath "$2")"
	echo "Creating initramfs: $OUT"
	pushd "$1" > /dev/null
	find . -print0 | cpio --null --create --format=newc | gzip --best > "$OUT"
	popd > /dev/null
}

# Pack from a staging copy with enforced exec bits: cpio preserves
# worktree modes, but fresh checkouts may lack +x (the repo index
# stores 644 for portability). A non-executable /init or busybox
# panics the phone (EACCES, No working init found), so enforce
# here instead of relying on checkout modes.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$(dirname "$0")"/initramfs/. "$STAGE"/
chmod 755 "$STAGE"/init "$STAGE"/bin/busybox "$STAGE"/init_functions.sh
mkinitfs "$STAGE" "$OUT"
