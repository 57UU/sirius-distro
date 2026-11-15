#!/bin/bash
# test-glue.sh: host-side offline test for the system-partition glue layer.
#
# Runs kernel/gen-glue-manifest.sh and glue/bin/sirius-kernel-glue against a
# throwaway copy of the glue tree.  Nothing outside the temporary directory is
# touched: the generator's /mnt/sysmod and /run roots are redirected with its
# test-only environment hooks.
#
# Usage: ./scripts/test-glue.sh
set -euo pipefail

DISTRO=$(cd "$(dirname "$0")/.." && pwd)
GENMAN=$DISTRO/kernel/gen-glue-manifest.sh
GEN=$DISTRO/glue/bin/sirius-kernel-glue
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $*"; }
check() {
    local what=$1; shift
    if "$@"; then ok; else bad "$what"; fi
}

# ---- fixture: copy of the real glue tree, manifest generated for it --------
FIX=$TMP/glue
cp -a "$DISTRO/glue/." "$FIX/"
chmod 755 "$FIX"/bin/*
bash "$GENMAN" "$FIX" "$FIX/manifest" >/dev/null
check "manifest generated" test -s "$FIX/manifest"

# ---- 1. happy path: every manifest record turns into the expected symlink ---
OUT=$TMP/out1
RUN=$TMP/run1
mkdir -p "$OUT" "$RUN"
SIRIUS_GLUE_ROOT=$FIX SIRIUS_GLUE_RUN_ROOT=$RUN \
    sh "$GEN" "$OUT" 2>/dev/null
check "generator exit 0 on valid manifest" test -d "$OUT"

units=0
while read -r kind a b; do
    case "$kind" in
        unit)
            units=$((units + 1))
            check "unit link ${a##*/}" test -L "$OUT/${a##*/}"
            check "unit link target ${a##*/}" test "$(readlink "$OUT/${a##*/}")" = "$FIX/$a"
            ;;
        dropin)
            check "dropin link $a ${b##*/}" test -L "$OUT/$a.d/${b##*/}"
            ;;
        wants)
            check "wants link $a $b" test -L "$OUT/$a.wants/$b"
            ;;
        run)
            check "run link $a ${b##*/}" test -L "$RUN/$a/${b##*/}"
            ;;
    esac
done < "$FIX/manifest"
check "at least one unit linked" test "$units" -gt 0

# Every units.enable entry must have produced a .wants link.
while read -r unit target rest; do
    case "${unit:-}" in ''|\#*) continue ;; esac
    check "enablement link $target/$unit" test -L "$OUT/$target.wants/$unit"
done < "$FIX/units.enable"

# Sanity: the generator must not have leaked anything into the fixture.
check "fixture units untouched" test ! -e "$FIX/manifest.bak"

# ---- 2. unknown record kinds are ignored, other records still applied ------
OUT2=$TMP/out2
mkdir -p "$OUT2"
{ cat "$FIX/manifest"; echo "futurekind whatever here"; } > "$FIX/manifest.unknown"
cp -f "$FIX/manifest.unknown" "$TMP/manifest.keep"
cp -f "$TMP/manifest.keep" "$FIX/manifest"
SIRIUS_GLUE_ROOT=$FIX SIRIUS_GLUE_RUN_ROOT=$RUN sh "$GEN" "$OUT2" 2>/dev/null
check "unknown kind: exit 0" test -d "$OUT2"
check "unknown kind: units still linked" test "$(find "$OUT2" -maxdepth 1 -type l | wc -l)" -gt 0
cp -f "$TMP/manifest.keep" "$FIX/manifest"

# ---- 3. ABI mismatch: fail open, link nothing ------------------------------
OUT3=$TMP/out3
mkdir -p "$OUT3"
cp -f "$FIX/manifest" "$TMP/manifest.keep"
sed 's/^abi .*/abi 99/' "$TMP/manifest.keep" > "$FIX/manifest"
SIRIUS_GLUE_ROOT=$FIX SIRIUS_GLUE_RUN_ROOT=$RUN sh "$GEN" "$OUT3" 2>/dev/null
check "ABI mismatch: exit 0 (output dir exists)" test -d "$OUT3"
check "ABI mismatch: nothing linked" test -z "$(find "$OUT3" -maxdepth 1 -type l -print -quit)"
cp -f "$TMP/manifest.keep" "$FIX/manifest"

# ---- 4. missing manifest: fail open ----------------------------------------
EMPTY=$TMP/empty-glue
mkdir -p "$EMPTY"
OUT4=$TMP/out4
mkdir -p "$OUT4"
SIRIUS_GLUE_ROOT=$EMPTY SIRIUS_GLUE_RUN_ROOT=$RUN sh "$GEN" "$OUT4" 2>/dev/null
check "missing manifest: exit 0 (output dir exists)" test -d "$OUT4"
check "missing manifest: nothing linked" test -z "$(find "$OUT4" -maxdepth 1 -type l -print -quit)"

# ---- 5. broken units.enable fails the build, not the boot ------------------
BROKEN=$TMP/broken-glue
cp -a "$DISTRO/glue/." "$BROKEN/"
printf 'no-such-unit.service multi-user.target\n' >> "$BROKEN/units.enable"
if bash "$GENMAN" "$BROKEN" "$TMP/broken.manifest" >/dev/null 2>&1; then
    bad "broken units.enable: manifest generator should have failed"
else
    ok
fi

echo
echo "test-glue: $pass passed, $fail failed"
test "$fail" -eq 0
