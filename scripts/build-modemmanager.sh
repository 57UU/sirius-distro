#!/bin/bash
# Build only the patched daemon; keep Debian's plugins, rules and packaging.
# Optional standalone tool. All build state stays under workspace/build/.
set -euo pipefail
DISTRO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${SCRATCH:-$DISTRO/workspace/build}
SIRIUS_BASE=${SIRIUS_BASE:-$SCRATCH/base}
case "$(uname -m)" in
    aarch64|arm64) DEFAULT_CROSS= ;;
    *) DEFAULT_CROSS=aarch64-linux-gnu- ;;
esac
CROSS_COMPILE=${CROSS_COMPILE-$DEFAULT_CROSS}
if [ "$(id -u)" -ne 0 ]; then
    exec sudo env -u TMPDIR PATH="$PATH:/usr/sbin:/sbin" \
        SCRATCH="$SCRATCH" SIRIUS_BASE="$SIRIUS_BASE" CROSS_COMPILE="$CROSS_COMPILE" \
        SIRIUS_MIRROR="${SIRIUS_MIRROR:-}" JOBS="${JOBS:-}" bash "$0" "$@"
fi
WORK=$SCRATCH/modemmanager
R=$WORK/root
VERSION=1.24.0-1+deb13u1
SOURCE=modemmanager-1.24.0
PATCH=$DISTRO/scripts/modemmanager/0001-loc-handle-early-indications.patch
mkdir -p "$WORK"
if [ ! -d "$R" ]; then
    test -d "${SIRIUS_BASE:?}" || { echo "缺 SIRIUS_BASE=$SIRIUS_BASE"; exit 1; }
    mkdir -p "$R"
    cp -a --reflink=auto "$SIRIUS_BASE/." "$R/"
fi
case "$(uname -m)" in
    aarch64|arm64) : ;;
    *) cp /usr/bin/qemu-aarch64-static "$R/usr/bin/" ;;
esac
# This tree is an isolated build sysroot, never the image shipped to the phone.
rm -f "$R/etc/resolv.conf"
cp -L /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"
chmod 755 "$R/usr/sbin/policy-rc.d"
if [ ! -f "$R/build/.sirius-builddeps" ]; then
    MIRROR=${SIRIUS_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn}
    rm -f "$R/etc/apt/sources.list.d/"*.sources
    cat > "$R/etc/apt/sources.list" <<EOF
deb $MIRROR/debian trixie main
deb $MIRROR/debian-security trixie-security main
deb-src $MIRROR/debian trixie main
deb-src $MIRROR/debian-security trixie-security main
EOF
    env -u TMPDIR chroot "$R" /bin/sh -ec '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y libglib2.0-dev libqmi-glib-dev libqrtr-glib-dev \
            libmbim-glib-dev libgudev-1.0-dev libpolkit-gobject-1-dev \
            libsystemd-dev libdbus-1-dev libc6-dev gettext meson ninja-build dpkg-dev
        mkdir -p /build/source
        touch /build/.sirius-builddeps
    '
fi
if [ ! -d "$R/build/source/$SOURCE" ]; then
    env -u TMPDIR chroot "$R" /bin/sh -ec \
        "mkdir -p /build/source; cd /build/source; apt-get source modemmanager=$VERSION"
fi
DEB=modemmanager_${VERSION}_arm64.deb
if [ ! -f "$R/build/source/$DEB" ]; then
    env -u TMPDIR chroot "$R" /bin/sh -ec \
        "cd /build/source; apt-get download modemmanager=$VERSION"
fi
# Refresh from the exact Debian source on every run; patching never accumulates.
mkdir -p "$WORK/source"
cp -a "$R/build/source/$SOURCE/." "$WORK/source/"
patch -d "$WORK/source" -p1 < "$PATCH"
mkdir -p "$WORK/toolchain"
# Fedora's GCC may inject this name; use the Debian target's atomic runtime.
echo 'INPUT ( AS_NEEDED ( libatomic.so.1 ) )' > "$WORK/toolchain/libatomic_asneeded.a"
CROSS=${CROSS_COMPILE-}
cat > "$WORK/cross.ini" <<EOF
[binaries]
c = ['${CROSS}gcc', '--sysroot=$R', '-isystem', '$R/usr/include/aarch64-linux-gnu', '-isystem', '$R/usr/include', '-B$R/usr/lib/aarch64-linux-gnu/', '-L$WORK/toolchain', '-static-libgcc']
ar = '${CROSS}gcc-ar'
strip = '${CROSS}strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
sys_root = '$R'
pkg_config_libdir = ['$R/usr/lib/aarch64-linux-gnu/pkgconfig', '$R/usr/share/pkgconfig']
needs_exe_wrapper = true
[built-in options]
c_args = ['-fstack-protector-strong', '-D_FORTIFY_SOURCE=2']
c_link_args = ['-Wl,-rpath-link,$R/usr/lib/aarch64-linux-gnu', '-Wl,-z,relro', '-Wl,-z,now']
EOF
# Meson itself runs on the host; dependencies and headers come from arm64.
export PYTHONPATH="$R/usr/lib/python3/dist-packages"
MESON=(python3 -m mesonbuild.mesonmain)
if [ -f "$WORK/build-sirius/meson-private/coredata.dat" ]; then
    SETUP=--reconfigure
else
    SETUP=
fi
"${MESON[@]}" setup ${SETUP:+$SETUP} "$WORK/build-sirius" "$WORK/source" \
    --cross-file "$WORK/cross.ini" --buildtype=release -Doptimization=2 -Db_pie=true \
    --prefix=/usr --libdir=lib/aarch64-linux-gnu --sysconfdir=/etc --localstatedir=/var \
    -Dbuiltin_plugins=false -Dpolkit=permissive -Dsystemd_suspend_resume=true \
    -Dintrospection=false -Dgtk_doc=false -Dvapi=false -Dman=false -Dtests=false \
    -Dexamples=false -Dbash_completion=false -Dudevdir=/usr/lib/udev \
    -Dsystemdsystemunitdir=/usr/lib/systemd/system -Ddbus_policy_dir=/usr/share/dbus-1/system.d
ninja -C "$WORK/build-sirius" -j "${JOBS:-$(nproc)}" src/ModemManager
rm -rf "$R/build/repack"
env -u TMPDIR chroot "$R" dpkg-deb --raw-extract "/build/source/$DEB" /build/repack
install -m755 "$WORK/build-sirius/src/ModemManager" "$R/build/repack/usr/sbin/ModemManager"
"${CROSS}strip" --strip-unneeded "$R/build/repack/usr/sbin/ModemManager"
patchelf --remove-rpath "$R/build/repack/usr/sbin/ModemManager"
sed -i "s/^Version: .*/Version: $VERSION+sirius1/" "$R/build/repack/DEBIAN/control"
# Refresh Debian package metadata for the one replaced file.
python3 - "$R/build/repack" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
filename = 'usr/sbin/ModemManager'
digest = hashlib.md5((root / filename).read_bytes()).hexdigest()
metadata = root / 'DEBIAN/md5sums'
metadata.write_text(''.join(
    f'{digest}  {filename}\n' if line.split()[-1] == filename else line
    for line in metadata.read_text().splitlines(keepends=True)))
PY
env -u TMPDIR chroot "$R" dpkg-deb --build /build/repack /build/modemmanager-sirius.deb
cp "$R/build/modemmanager-sirius.deb" "$WORK/modemmanager-sirius.deb"
if [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$WORK/modemmanager-sirius.deb"
fi
echo "ModemManager package: $WORK/modemmanager-sirius.deb"
