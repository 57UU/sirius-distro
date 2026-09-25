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
- apt 源：构建脚本强制切清华镜像（含 security），`SIRIUS_MIRROR` 环境变量可改地址。## 底包与镜像源

- Debian rootfs 底包：linuxcontainers 镜像站，按日期取当天构建：
  `https://images.linuxcontainers.org/images/debian/trixie/arm64/default/`
  选日期目录下载 `rootfs.tar.xz`（约 90MB）。解开即为 `SIRIUS_BASE`
  （`tar -xJf rootfs.tar.xz -C /path/to/base`，root 权限）。

- 构建机另需：`qemu-user` + binfmt（`qemu-aarch64`）、root 权限、
  `img2simg/zstd`（仅打镜像阶段，本库构建脚本不管打镜像）。
- apt 源策略：三口味构建脚本统一写清华源
  （`debian` + `debian-updates` + `debian-security` 全套，
  含 `non-free non-free-firmware`，后两者是 QC 固件包必需），
  换地址用 `SIRIUS_MIRROR` 环境变量覆盖。
