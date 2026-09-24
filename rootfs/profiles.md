# rootfs 三口味（同设备基座，不同上层）

```text
build-server.sh  无头 + Orbital（当前主线）：multi-user，无桌面，
                 烤入 overlay/ + orbital-pkg/ + dsp-bin/。
build-gnome.sh   纯桌面 GNOME（GDM 自动登录），无 overlay、无 server 栈。
build-xfce.sh    纯桌面 XFCE（LightDM 自动登录），无 overlay、无 server 栈。
```

三者设备基座完全相同：modem/WLAN 固件（`firmware/`，md5 校验）、
`pd-mapper`、rmtfs/tqftpserv、wifi-shutdown、ADSP 不恢复规则、
sysrq、wlan0 命名、蓝牙 UART 自加载、RNDIS usb0 静态地址。

- 输入：`SIRIUS_BASE`（纯净 trixie arm64 树，如 linuxcontainers
  `rootfs.tar.xz` 解开）、`SIRIUS_KMOD`（对准手机 `uname -r` 的模块包，
  来自内核 Release）、`SIRIUS_WORK`（输出目录，默认 `<distro>/work`）。
  缺谁 fail-fast，不猜路径。
- `overlay/` 只属于 server 口味：开机会 `cp -a` 进 `/` 的文件
  （服务、脚本、配置），改动先改这里。
- 产物（`*.tar.zst`/`*.simg`）不进库，走 GitHub Releases。