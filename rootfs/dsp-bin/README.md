# dsp-bin:FastRPC 支持库(烤进 rootfs)

**可执行文件 `adsprpcd` 已迁到 `../../glue/bin/`**(随 `kernel.img` 打进 system 分区,
升级不用重刷 rootfs);本目录只保留它运行期 `dlopen` 的库,因为 rootfs 的
`/usr/local/lib` 是 glibc/glibc-ldconfig 的搜索路径,放在这里最省事:

| 文件 | 作用 |
|---|---|
| `libadsp_default_listener.so.1.0.0` | `adsprpcd` 通过 `dlopen("libadsp_default_listener.so")` 加载的 listener |
| `libadsprpc.so.1.0.0` | FastRPC 用户态 RPC 客户端库(listener 依赖) |
| `libyaml-0.so.2.0.9` | libadsprpc 的私有依赖,装到 `/usr/local/lib/sirius-dsp/`,由 adsprpcd 单元 `LD_LIBRARY_PATH` 指向 |

来源:https://github.com/qualcomm/fastrpc 自编译(`main@2026-10-02`,手机现行验证版)。
构建机需 `libyaml-dev:arm64 libbsd-dev:arm64 libmd-dev:arm64` +
`PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig`,在本仓库外构建后拷回本目录。

`rootfs/sirius-device.sh` 的 `sirius_overlay()` 会把它们装到 `/usr/local/lib` 与
`/usr/local/lib/sirius-dsp`,并建 `.so.1`/`.so` 软链后 `ldconfig`。

运行时依赖:`libbsd0`(已显式钉死在 build-gnome.sh / build-server.sh 的 apt 列表,勿删)。

对应 unit 在 `../../glue/units/adsprpcd-{rootpd,audiopd,sensorspd}.service`
(`ADSP_LIBRARY_PATH=/usr/lib/firmware/qcom/sdm710/pyxis/adsp`)。
