#!/bin/bash
# test-glue.sh: host-side offline test for the system-partition glue layer.
#
# Exercises the unit generator and early runtime setup against a throwaway
# glue tree. Factory data and /etc are fixtures; no partition is mounted.
#
# Usage: ./scripts/test-glue.sh
set -euo pipefail

DISTRO=$(cd "$(dirname "$0")/.." && pwd)
GENMAN=$DISTRO/kernel/gen-glue-manifest.sh
GEN=$DISTRO/glue/bin/sirius-kernel-glue
SETUP=$DISTRO/glue/bin/sirius-glue-setup
mkdir -p "$DISTRO/workspace/build/tmp"
TMP=$(mktemp -d "${TMPDIR:-$DISTRO/workspace/build/tmp}/test-glue.XXXXXX")
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
ETC=$TMP/etc
PERSIST=$TMP/persist
mkdir -p "$OUT" "$RUN" "$ETC/systemd/network" "$PERSIST"
printf 'wlan0=025755085e10\n' > "$PERSIST/wlan_mac.bin"
LEGACY=$ETC/systemd/network/10-wlan0.link
DROP=$RUN/systemd/network/10-wlan0.link.d/50-factory-mac.conf
printf '[Match]\nOriginalName=wlan0\n\n[Link]\nMACAddress=02:57:55:08:5e:10\n' > "$LEGACY"
setup_runtime() {
    SIRIUS_GLUE_ROOT=$FIX SIRIUS_GLUE_RUN_ROOT=$RUN \
        SIRIUS_GLUE_ETC_ROOT=$ETC SIRIUS_GLUE_PERSIST_ROOT=$PERSIST \
        sh "$SETUP" 2>/dev/null
}
SIRIUS_GLUE_ROOT=$FIX SIRIUS_GLUE_RUN_ROOT=$RUN \
    sh "$GEN" "$OUT" 2>/dev/null
check "generator exit 0 on valid manifest" test -d "$OUT"
check "generator writes no runtime config" test -z "$(find "$RUN" -mindepth 1 -print -quit)"
setup_runtime
check "factory MAC drop-in" grep -qx 'MACAddress=02:57:55:08:5e:10' "$DROP"
check "factory MAC disables generated MAC policy" grep -qx 'MACAddressPolicy=none' "$DROP"
check "drop-in contains no Match override" test "$(grep -c '^\[Match\]' "$DROP" || true)" = 0
check "exact legacy .link migrated" test ! -e "$LEGACY"

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

# tmp.mount is masked by the store's /dev/null symlink, so the phone uses
# the /tmp directory on userdata instead of mounting a memory filesystem.
check "tmp.mount resolves to a mask" test "$(readlink -f "$OUT/tmp.mount")" = /dev/null
# --root keeps this read-only query offline; SYSTEMD_UNIT_PATH makes it use
# the actual generator output without touching the host's system manager.
if command -v systemctl >/dev/null; then
    state=$(SYSTEMD_UNIT_PATH="$OUT" systemctl --root=/ is-enabled tmp.mount 2>/dev/null || true)
    check "systemd recognizes generated tmp.mount mask" test "$state" = masked
fi

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

# ---- 6. runtime configuration lifecycle and user overrides ----------------
cp "$FIX/manifest" "$TMP/runtime.manifest"
stale=$RUN/sysctl.d/60-sysrq.conf
sed '\|^run sysctl.d |d' "$TMP/runtime.manifest" > "$FIX/manifest"
setup_runtime
check "removed runtime record cleans up its old link" test ! -L "$stale"
cp "$TMP/runtime.manifest" "$FIX/manifest"
setup_runtime
rm "$stale"
printf 'kernel.sysrq=0\n' > "$stale"
setup_runtime
check "consumer-written runtime override preserved" grep -qx 'kernel.sysrq=0' "$stale"
sed '\|^run sysctl.d |d' "$TMP/runtime.manifest" > "$FIX/manifest"
setup_runtime
check "removing a record preserves consumer-written file" test -f "$stale"
cp "$TMP/runtime.manifest" "$FIX/manifest"

printf '[Match]\nOriginalName=wlan0\n\n[Link]\nMACAddress=02:57:55:08:5e:10\nMTUBytes=1400\n' > "$LEGACY"
setup_runtime
check "legacy file with user settings preserved" grep -qx 'MTUBytes=1400' "$LEGACY"
check "factory drop-in does not override user settings" test ! -e "$DROP"
printf '[Match]\nOriginalName=wlan0\n\n[Link]\nMACAddress=02:57:55:08:5e:20\n' > "$LEGACY"
setup_runtime
check "user MAC override preserved" grep -qx 'MACAddress=02:57:55:08:5e:20' "$LEGACY"
check "factory drop-in does not override user MAC" test ! -e "$DROP"
rm "$LEGACY"
ln -s /dev/null "$LEGACY"
setup_runtime
check "user .link mask preserved" test -L "$LEGACY"
check "factory drop-in does not override user mask" test ! -e "$DROP"
rm "$LEGACY"

# Invalid/missing factory data must remove a previous managed drop-in and
# leave the base .link in place. Test the actual multicast bit (second digit).
for value in 035755085e10 000000000000 025755085e1 invalid ''; do
    printf 'wlan0=%s\n' "$value" > "$PERSIST/wlan_mac.bin"
    setup_runtime
    check "invalid MAC '$value' uses fallback" test ! -e "$DROP"
    check "invalid MAC keeps base rule" test -L "$RUN/systemd/network/10-wlan0.link"
done
printf 'wlan0=A45046085E10\r\n' > "$PERSIST/wlan_mac.bin"
setup_runtime
check "valid unicast with odd first nibble and CRLF" grep -qx 'MACAddress=a4:50:46:08:5e:10' "$DROP"
rm "$PERSIST/wlan_mac.bin"
setup_runtime
check "missing factory data removes previous drop-in" test ! -e "$DROP"

echo
echo "test-glue: $pass passed, $fail failed"
test "$fail" -eq 0
