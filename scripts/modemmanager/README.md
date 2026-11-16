# ModemManager LOC indication ordering

Base: Debian trixie `modemmanager 1.24.0-1+deb13u1` (including Debian patches).
The patch changes only the daemon. Debian's matching plugins, package scripts,
rules, policies and dependencies are retained; local version is `+sirius1`.

On this phone LOC Get Server and Get Predicted Orbits Data Source indications
can arrive before their successful request responses. Upstream 1.24 subscribes
after the response, loses the indication, and waits 10 seconds per operation.
Subscribe before sending; retain an early indication until the request response
is validated. A response failure still fails the task, and an actually missing
indication still times out. GNSS capabilities remain enabled.

Build via `bash scripts/build-modemmanager.sh` (automatically uses sudo). It creates an isolated arm64
build sysroot from `SIRIUS_BASE` under `workspace/build/modemmanager/`, downloads
the matching Debian source/binary packages, builds with the host cross compiler,
and repacks the daemon into `modemmanager-sirius.deb` in that directory.
Host prerequisites: Python 3, ninja, pkg-config, patch, patchelf, GLib codegen
tools, and aarch64 GNU compiler/binutils; non-arm64 hosts also need registered
qemu-aarch64-static binfmt support, as for the rootfs build.

This is an optional investigation tool; it is not part of `build.sh` or either
rootfs build. To install the resulting package on an existing phone:

```sh
scp workspace/build/modemmanager/modemmanager-sirius.deb u57u@172.16.42.1:/tmp/
ssh u57u@172.16.42.1 'sudo dpkg -i /tmp/modemmanager-sirius.deb'
```

Flashing kernel.img alone updates the UIM helper but cannot replace the distro's
ModemManager. Build trees, downloaded sources, packages and traces stay under
`workspace/build/modemmanager/`.

Run the UIM helper's offline regression checks with
`python3 scripts/test-modem-uim.py`. It uses mock commands and a temporary copy
of the helper, without connecting to the phone.

When rebasing to a new Debian version, update the source/package version in the
builder, recheck the patch against the upstream callbacks, and repeat a boot
trace with early LOC indications. Keep source and binary package versions equal
so the preserved dynamically loaded plugins match the daemon ABI.
