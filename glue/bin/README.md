# glue/bin:内核耦合/设备层可执行文件与脚本(打进 system 分区)

> 详细机制见 `../../docs/KERNEL-IMG-STORE.md`。这里只记录“这些二进制从哪来、怎么重编”。

## 预编译二进制(随仓库走,构建不重编)

| 文件 | 作用 | 源码/上游 | 运行期库依赖 |
|---|---|---|---|
| `adsprpcd` | Qualcomm FastRPC ADSP 用户态装载服务(一式三份:rootpd/audiopd/sensorspd) | https://github.com/qualcomm/fastrpc ,自编译 `main@2026-10-02` | 动态链接 rootfs 的 glibc;`dlopen` 根分区里的 `libadsp_default_listener.so` / `libadsprpc.so` / `libyaml`(见 `rootfs/dsp-bin/README.md`) |
| `pd-mapper` | Qualcomm PD 映射服务(读 firmware 里的 servreg `.jsn`,建 QRTR PD 映射) | https://github.com/andersson/pd-mapper ,按 `src/pd-mapper/README.md` 自编译(带 query 日志) | 动态链接 rootfs 的 `libqrtr.so.1`、`liblzma.so.5`、glibc |
| `uimsel` | 直接发 QMI `ChangeProvisioningSession`,绕过 qmicli 的 power-off 步骤 | `../../src/modem/uimsel.c` | 动态链接 rootfs 的 `libqmi-glib.so.5`、`libqrtr-glib.so.0`、glib/gobject/gio、glibc |
| `uimwatch` | 常驻订阅 UIM `card-status`/`slot-status`,事件触发 `sirius-modem-uim` | `../../src/modem/uimwatch.c` | 同上 |

设计选择(2026-11-15):**不携带 libc/运行库**,设备二进制直接复用 rootfs 的
Debian 库(glibc ABI 向下兼容;libqmi/glib 等由 `ModemManager`/`libqmi-utils` 包带到
rootfs)。这样做体积为 0,代价是这些库必须存在于 rootfs;若以后要彻底解耦,可把
13.6 MiB 第三方库闭包(或 16.3 MiB 含 libc)拷进 `glue/lib` 并给 unit 加
`LD_LIBRARY_PATH`——方案与实测数据见 `../../docs/KERNEL-IMG-STORE.md`。

## 怎么重新编译

在设备上(arm64 原生,最快):

```sh
# uimsel / uimwatch
sudo apt-get install -y gcc libc6-dev pkg-config libqmi-glib-dev libqrtr-glib-dev
gcc -O2 -o uimsel   uimsel.c   $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
gcc -O2 -o uimwatch uimwatch.c $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
```

`uimwatch` 里触发脚本的路径由编译期宏 `SIRIUS_MODEM_UIM` 决定,默认
`/mnt/sysmod/glue/bin/sirius-modem-uim`;本地测试可
`-DSIRIUS_MODEM_UIM=/usr/local/bin/sirius-modem-uim` 覆盖。

`adsprpcd` 与 `pd-mapper` 的重编方式见 `rootfs/dsp-bin/README.md` 和
`src/pd-mapper/README.md`(构建机没有 arm64 开发包时可直接沿用本目录成品)。

改完源码后记得把新产物替换回本目录——**这些二进制随仓库走,构建不会重新编译**。

## systemd 单元与驱动脚本

- 单元:`../units/adsprpcd-{rootpd,audiopd,sensorspd}.service`、`pd-mapper.service`、
  `sirius-modem-uim{,.timer,-watch}*`
- 脚本:`sirius-modem-uim`(其中 `UIMSEL=/mnt/sysmod/glue/bin/uimsel`)

启动顺序、坑位见 `../../docs/AUDIO-BRINGUP.md`、`../../docs/CELLULAR.md`。
