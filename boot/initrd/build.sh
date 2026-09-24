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

mkinitfs "$(dirname "$0")"/initramfs "$OUT"
