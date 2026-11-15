# glue/lib: FastRPC 支持库（system 分区）

`adsprpcd` 及其运行期 `dlopen` 的 FastRPC 库都属于设备层，随 `kernel.img`
打进 system 分区（`/mnt/sysmod/glue/lib`）；rootfs 不再携带任何 Qualcomm 私有库。

| 文件 | 作用 |
|---|---|
| `libadsp_default_listener.so.1` | `adsprpcd` 通过 `dlopen("libadsp_default_listener.so.1")` 加载的 listener（失败才回退无版本名） |
| `libadsprpc.so.1` | FastRPC 用户态 RPC 客户端库（listener 的 `NEEDED libadsprpc.so.1`） |
| `libyaml-0.so.2` | libadsprpc 的私有依赖（`NEEDED libyaml-0.so.2`） |

库文件直接以**运行时文件名（SONAME）**提交在本目录，不建任何软链——loader 按
`DT_NEEDED`/dlopen 里的名字精确查找，实名文件最简单，也不怕 Windows 检出丢软链。
上游原始文件名是 `libadsp_default_listener.so.1.0.0`、`libadsprpc.so.1.0.0`、
`libyaml-0.so.2.0.9`（见 git 历史）。

`glue/units/adsprpcd-{rootpd,audiopd}.service` 通过
`LD_LIBRARY_PATH=/mnt/sysmod/glue/lib` 找到这些库，并保留
`ADSP_LIBRARY_PATH=/usr/lib/firmware/qcom/sdm710/pyxis/adsp` 给 DSP 侧固件。

来源：https://github.com/qualcomm/fastrpc 自编译（`main@2026-10-02`，手机现行验证版）。
构建机需 `libyaml-dev:arm64 libbsd-dev:arm64 libmd-dev:arm64` +
`PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig`，在本仓库外构建后拷回本目录。

运行时依赖 `libbsd0` 仍由 rootfs 的 Debian 包提供（build-gnome.sh / build-server.sh
的 apt 列表里已显式钉死，勿删）。
