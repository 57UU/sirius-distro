# glue/lib: 设备层私有运行库（system 分区）

`glue/bin` 里的二进制要用的库都在这里（除 glibc 外全部自带），真实文件按 SONAME 命名，
不建软链。`kernel/build-kernel-img.sh` 打包时用 `patchelf` 写入 RPATH：
bin → `$ORIGIN/../lib`，lib → `$ORIGIN`；运行时不需要 `LD_LIBRARY_PATH`。

| 类别 | 文件 |
|---|---|
| FastRPC | `libadsp_default_listener.so.1`、`libadsprpc.so.1`、`libyaml-0.so.2` |
| Sensor Core | `libhexagonrpc.so.0.5`、`libssc.so.2`、`libprotobuf-c.so.1` |
| GLib/QMI/QRTR 闭包 | `libglib-2.0.so.0`、`libgio-2.0.so.0`、`libgobject-2.0.so.0`、`libgmodule-2.0.so.0`、`libffi.so.8`、`libpcre2-8.so.0`、`libqmi-glib.so.5`、`libmbim-glib.so.4`、`libqrtr-glib.so.0`、`libqrtr.so.1` |
| 其它依赖 | `libbsd.so.0`、`libmd.so.0`、`liblzma.so.5`、`libmount.so.1`、`libblkid.so.1`、`libselinux.so.1`、`libz.so.1`、`libatomic.so.1` |

来源：

- FastRPC 库：https://github.com/qualcomm/fastrpc 自编译（`main@2026-10-02`，手机验证版）。
  构建机需 `libyaml-dev:arm64 libbsd-dev:arm64 libmd-dev:arm64` +
  `PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig`。
- Sensor Core 库：`linux-msm/hexagonrpc`、`DylanVanAssche/libssc` 自编译；`libprotobuf-c` 来自 Debian trixie。
- GLib/QMI/QRTR 等闭包：Debian trixie（`libglib2.0-0`、`libqmi-glib5`、`libqrtr-glib0`、`libqrtr1`、
  `libbsd0`、`liblzma5`、`libprotobuf-c1` 等）。

这样 system 分区对 rootfs 的 ABI 依赖只剩 glibc；rootfs 自己仍保留对应 Debian 库给
BlueZ/NetworkManager/ModemManager/PipeWire 用，但 glue 不依赖它们。

## 依赖契约（改这个目录前必读）

- **rootfs glibc 必须 ≥ 2.38**：本目录里的 Debian trixie 库（`libglib`、`libgio`、`libmount`、
  `libselinux`、`libbsd`、`libblkid`、`libadsprpc`、`libadsp_default_listener`）用了
  `GLIBC_2.38` 符号，所以 trixie（2.41）及以后可以，bookworm（2.36）会直接起不来。
- **除 glibc 外的依赖必须都在本目录**：`glue/bin` 里新增一个依赖（`readelf -d` 的 NEEDED）
  就必须把对应 `.so` 拷进来，否则只有上设备才会发现（服务重启循环）。刷机后可用
  `ldd /mnt/sysmod/glue/bin/* | grep 'not found'` 自检。
- **RPATH 只在打镜像时写**：本目录和 `glue/bin` 里提交的文件本身没有被 patchelf 改过。
  在设备上临时替换二进制/加库时，必须自己补
  `patchelf --set-rpath '$ORIGIN/../lib' <bin>` 或 `'$ORIGIN' <lib>`，否则 loader 找不到库。
- **安全更新**：本目录的库不随 rootfs 的 apt 升级，glib/qmi 等的 CVE 需要重新取库并重刷
  system 镜像。
