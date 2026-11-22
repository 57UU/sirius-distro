# glue/bin: 内核耦合/设备层预编译 ELF 二进制（打进 system 分区）

> 详细机制见 `../../docs/KERNEL-IMG-STORE.md`。脚本已拆至 `../scripts/`，本目录仅保留预编译二进制。

## 预编译二进制(随仓库走,构建不重编)

| 文件 | 作用 | 源码/上游 | 运行期库依赖 |
|---|---|---|---|
| `adsprpcd` | Qualcomm FastRPC ADSP 用户态装载服务(rootpd/audiopd) | https://github.com/qualcomm/fastrpc ,自编译 `main@2026-10-02` | 仅 glibc;FastRPC 库在 `../lib`(RPATH 已指向) |
| `pd-mapper` | Qualcomm PD 映射服务(读 firmware 里的 servreg `.jsn`,建 QRTR PD 映射) | https://github.com/andersson/pd-mapper ,按 `src/pd-mapper/README.md` 自编译(带 query 日志) | 仅 glibc;`libqrtr`/`liblzma` 在 `../lib` |
| `uimsel` | 直接发 QMI `ChangeProvisioningSession`,绕过 qmicli 的 power-off 步骤 | `../../src/modem/uimsel.c` | 仅 glibc + rootfs 的 glib;qmi/qrtr 在 `../lib` |
| `uimwatch` | 常驻订阅 UIM `card-status`/`slot-status`,事件触发 `sirius-modem-uim` | `../../src/modem/uimwatch.c` | 同上 |
| `hexagonrpcd` | Sensor Core(SSC)文件服务,给 ADSP sensor PD 提供 config/registry/socinfo/dsp 文件 | https://github.com/linux-msm/hexagonrpc 自编译 | 仅 glibc;`libhexagonrpc` 在 `../lib` |
| `ssccli` | Sensor Core 读取 CLI(加速度计/磁力计/指南针) | https://codeberg.org/DylanVanAssche/libssc 自编译 | 仅 glibc + rootfs 的 glib/gobject;libssc/protobuf-c/qmi/qrtr 在 `../lib` |
| `sirius-remodeset` | 无头启动显示解卡工具（裸 DRM ioctl，无 libdrm 依赖；rootfs `/usr/local/sbin/sirius-remodeset` 软链至此） | `../../src/sirius-remodeset/sirius-remodeset.c` | 仅 glibc |

设计选择：运行库只依赖 rootfs 的 glibc 和 glib 家族，其余自带的都在 `../lib`
（见 [`../lib/README.md`](../lib/README.md)）；`patchelf` 打包时写入 RPATH，不需要
`LD_LIBRARY_PATH`。运行期仍会调用 rootfs 的底座服务，见
`../../docs/KERNEL-IMG-STORE.md` §1 第 5 项。

## 怎么重新编译

在设备上(arm64 原生,最快):

```sh
# uimsel / uimwatch
sudo apt-get install -y gcc libc6-dev pkg-config libqmi-glib-dev libqrtr-glib-dev
gcc -O2 -o uimsel   uimsel.c   $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
gcc -O2 -o uimwatch uimwatch.c $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
```

`uimwatch` 里触发脚本的路径由编译期宏 `SIRIUS_MODEM_UIM` 决定,默认
`/mnt/sysmod/glue/scripts/sirius-modem-uim`;本地测试可
`-DSIRIUS_MODEM_UIM=/usr/local/bin/sirius-modem-uim` 覆盖。

`adsprpcd` 的重编方式见 `../lib/README.md`，`pd-mapper` 见 `src/pd-mapper/README.md` 和
`src/pd-mapper/README.md`(构建机没有 arm64 开发包时可直接沿用本目录成品)。

改完源码后记得把新产物替换回本目录——**这些二进制随仓库走,构建不会重新编译**。

## systemd 单元与驱动脚本

- 单元:`../units/adsprpcd-{rootpd,audiopd,sensorspd}.service`、`pd-mapper.service`、
  `sirius-modem-uim{,.timer,-watch}*`
- 脚本:`sirius-modem-uim`(其中 `UIMSEL=/mnt/sysmod/glue/bin/uimsel`)

启动顺序、坑位见 `../../docs/AUDIO-BRINGUP.md`、`../../docs/CELLULAR.md`。
