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
# Normalize payload modes: fresh checkouts (and Windows transfers) may
# lack +x on dirs/files, which fails exec with EACCES in initramfs.
chmod 755 "$STAGE"/sbin "$STAGE"/lib
# The dynamic loader itself must be +x: the kernel execs it as the ELF
# interpreter, and without +x every dynamically linked tool dies with
# EACCES (static busybox applets are unaffected, which hides this).
chmod 755 "$STAGE"/lib/* "$STAGE"/sbin/resize.f2fs "$STAGE"/sbin/resize2fs
chmod 755 "$STAGE"/init "$STAGE"/bin/busybox "$STAGE"/init_functions.sh "$STAGE"/sbin/resize.f2fs "$STAGE"/sbin/resize2fs "$STAGE"/expand-part
mkinitfs "$STAGE" "$OUT"
