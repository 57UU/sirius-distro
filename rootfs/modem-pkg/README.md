# modem-pkg：蜂窝 bring-up 工具（预编译，烤进 rootfs）

| 文件 | 作用 | 源码 |
|---|---|---|
| `uimsel` | 直接发 QMI ChangeProvisioningSession，绕过 qmicli 内部的 power-off（本机 modem 上这步固定返回 `QMI error 3 'Internal'`） | `../../src/modem/uimsel.c` |
| `uimwatch` | 常驻订阅 UIM 的 `card-status` / `slot-status` 事件，事件驱动建会话 | `../../src/modem/uimwatch.c` |

由 `sirius-device.sh` 的 `sirius_overlay()` 装到 `/usr/local/bin/`（`chmod 755`）。
对应单元：`overlay/etc/systemd/system/sirius-modem-uim{,.timer,-watch}*`。
背景与坑位见 `../../docs/CELLULAR.md`。

## 为什么放预编译成品

和 `rootfs/dsp-bin` 同理：构建机通常只有 x86_64 交叉工具链，没有 arm64 的
libqmi-glib / libqrtr-glib / glib 开发包，构建期编译要额外搭 sysroot。
构建只负责装成品，不强制要求编译环境。

## 怎么重新编译

在设备上（arm64 原生，最快）：

```sh
gcc -o uimsel   uimsel.c   $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
gcc -o uimwatch uimwatch.c $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
```

设备上需要 `gcc libc6-dev libqmi-glib-dev pkg-config`。

改完源码后记得把新产物替换到本目录——**这两个二进制是随仓库走的，构建不会重新编译**。

## 运行时依赖

`libqmi-glib.so.5`、`libqrtr-glib.so.0`、`libmbim-glib.so.4`、glib/gobject/gio，
全部由 `modemmanager` 包间接带进来；`qmicli`（脚本里用）由 `libqmi-utils` 提供。
两个包都已加进 `SIRIUS_BASE_PKGS`，别删。
