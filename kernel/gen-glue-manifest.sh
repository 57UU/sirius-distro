#!/bin/bash
# gen-glue-manifest.sh: generate the internal manifest consumed by the unit
# generator and sirius-glue-setup runtime service (schema v1).
#
# Usage: ./gen-glue-manifest.sh <glue-src-dir> <output-manifest>
#
# Runs on the build host as part of ./build.sh kernel.  The manifest is derived
# from the actual glue tree, so it cannot drift from what is shipped in the
# system image; a malformed tree fails the build instead of the boot.
set -euo pipefail

GLUE=${1:?usage: gen-glue-manifest.sh <glue-src-dir> <output-manifest>}
OUT=${2:?usage: gen-glue-manifest.sh <glue-src-dir> <output-manifest>}

test -d "$GLUE" || { echo "missing glue source dir $GLUE"; exit 1; }
test -f "$GLUE/ABI" || { echo "missing $GLUE/ABI"; exit 1; }
test -f "$GLUE/bin/sirius-kernel-glue" || { echo "missing $GLUE/bin/sirius-kernel-glue"; exit 1; }
test -f "$GLUE/units.enable" || { echo "missing $GLUE/units.enable"; exit 1; }

TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

ABI=$(tr -d '[:space:]' < "$GLUE/ABI")
case "$ABI" in
    ''|*[!0-9]*) echo "bad $GLUE/ABI content: '$ABI'"; exit 1 ;;
esac

{
    printf 'abi %s\n' "$ABI"

    # Unit files.  Drop-in directories (*.d) are handled separately below.
    UNITS=$(for f in "$GLUE"/units/*; do
        [ -e "$f" ] || continue
        case "${f##*/}" in *.d) continue ;; esac
        printf 'unit units/%s\n' "${f##*/}"
    done | LC_ALL=C sort)
    printf '%s\n' "$UNITS"

    # Drop-ins, grouped under units/<name>.d/.
    for d in "$GLUE"/units/*.d; do
        [ -d "$d" ] || continue
        unit=${d##*/}
        unit=${unit%.d}
        for c in "$d"/*; do
            [ -e "$c" ] || continue
            case "${c##*/}" in *.conf) ;; *) continue ;; esac
            printf 'dropin %s units/%s/%s\n' "$unit" "${d##*/}" "${c##*/}"
        done
    done

    # Enablement.  The unit must actually exist in the store.
    while read -r unit target rest; do
        case "${unit:-}" in ''|\#*) continue ;; esac
        [ -n "${target:-}" ] || { echo "units.enable: incomplete line for '$unit'"; exit 1; }
        test -f "$GLUE/units/$unit" || { echo "units.enable: missing unit $unit"; exit 1; }
        printf 'wants %s %s\n' "$target" "$unit"
    done < "$GLUE/units.enable"

    # Runtime configuration directories that systemd/udev/kmod read from /run.
    for d in udev/rules.d modules-load.d modprobe.d tmpfiles.d; do
        for f in "$GLUE/$d"/*; do
            [ -e "$f" ] || continue
            printf 'run %s %s\n' "$d" "$d/${f##*/}"
        done
    done

    # udev/networkd .link files.
    for f in "$GLUE"/network/*; do
        [ -e "$f" ] || continue
        printf 'run systemd/network network/%s\n' "${f##*/}"
    done

    # Arbitrary runtime config trees: glue/run/<dir under /run>/<file>.
    if [ -d "$GLUE/run" ]; then
        ( cd "$GLUE" && find run -type f | LC_ALL=C sort ) | while read -r f; do
            rel=${f#run/}
            dest=${rel%/*}
            [ "$dest" = "$rel" ] && dest="."
            printf 'run %s %s\n' "$dest" "$f"
        done
    fi
} > "$TMP"

mv -f "$TMP" "$OUT"
chmod 644 "$OUT"
echo "glue manifest: $OUT"
