# glue/lib:设备层私有运行库（system 分区）

`glue/bin` 的依赖，除 glibc 和 glib 家族外都在这里，按 SONAME 实名存放，不建软链。
打包时 `kernel/build-kernel-img.sh` 用 patchelf 写 RPATH：bin → `$ORIGIN/../lib`，
lib → `$ORIGIN`，运行时不需要 `LD_LIBRARY_PATH`。

| 类别 | 文件 |
|---|---|
| FastRPC | `libadsp_default_listener.so.1`、`libadsprpc.so.1`、`libyaml-0.so.2` |
| Sensor Core | `libhexagonrpc.so.0.5`、`libssc.so.2`、`libprotobuf-c.so.1` |
| QMI/QRTR | `libqmi-glib.so.5`、`libmbim-glib.so.4`、`libqrtr-glib.so.0`、`libqrtr.so.1` |
| 其它 | `libbsd.so.0`、`libmd.so.0`、`liblzma.so.5` |

来源：

- FastRPC：https://github.com/qualcomm/fastrpc 自编译（`main@2026-10-02`）
- Sensor Core：`linux-msm/hexagonrpc`、`DylanVanAssche/libssc` 自编译；`libprotobuf-c` 来自 Debian trixie
- QMI/QRTR、libbsd/libmd/liblzma：Debian trixie
- glib 家族（`libglib`/`gio`/`gobject`/`gmodule` 及其依赖）：不打包，用 rootfs 的 Debian 包
  （GLib 2.x ABI 稳定，trixie 2.84.x）

## 改这个目录前必读

- rootfs 必须提供 glibc ≥ 2.38 和 glib 家族（trixie 及以后；两个 flavor 都有）。
- 新增非 glib 依赖（`readelf -d` 的 NEEDED）必须把对应 `.so` 拷进来，否则只有上设备才会发现
  （服务重启循环）。刷机后自检：`ldd /mnt/sysmod/glue/bin/* | grep 'not found'`。
- RPATH 只在打镜像时写；设备上手工替换二进制/加库要自己补 `patchelf --set-rpath`。
- 这里的库不随 rootfs 的 apt 升级；qmi/qrtr 等有更新需重取并重刷 system 镜像。
