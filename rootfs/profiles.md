# rootfs 两口味（同设备基座，不同上层）

```text
build-server.sh  无头 + Orbital（当前主线）：multi-user，无桌面，
                 烤入 overlay/ + orbital-pkg/ + dsp-bin/。
build-gnome.sh   GNOME 桌面（GDM 自动登录）：同样烤入 overlay/，不装 Orbital。
                 电源键/蓝牙自启与 server 同栈；息屏计时归 GNOME
                （设置→电源→屏幕空白），背光由 sirius-gnome-blank 跟随。
```

两者设备基座完全相同：modem/WLAN 固件（`firmware/`，md5 校验）、
`pd-mapper`、rmtfs/tqftpserv、wifi-shutdown、ADSP 不恢复规则、
sysrq、wlan0 命名+固定 MAC、蓝牙 UART 自加载+固定地址、RNDIS usb0 静态地址（见 docs/STABLE-MAC.md），
以及息屏/电源键栈（见 docs/SERVER-MODE.md）：
server 由 Orbital 内建 idle 计时 + 电源键处理（设置→Screen Off Time 可调）；
gnome 用 `sirius-gnome-blank`（--user 服务）跟随 GNOME 屏保状态，计时以
`org.gnome.desktop.session idle-delay` 为准（默认 120s，用户可在设置里改，
设为从不则不自动息屏）。电源键短按经 logind 锁屏触发屏保，再由 sirius-gnome-blank 切背光（免密，任意输入唤醒），长按照旧关机。mutter 的 blank 关不掉本机
DSI 背光（只画黑屏），所以 gnome 的跟随动作仍走 `sirius-screen` 切真背光
（真机实测结论；server 上它只留手动救援）。

- 输入：`SIRIUS_BASE`（纯净 trixie arm64 树，如 linuxcontainers
  `rootfs.tar.xz` 解开）、`SIRIUS_WORK`（输出目录，默认 `<distro>/work`）。
  缺谁 fail-fast，不猜路径。内核模块 + 固件不住 rootfs，住 vendor 分区仓库
  （`kernel/build-vendormod.sh` 打，见 docs/VENDORMOD-STORE.md），所以没有模块包输入。
- `overlay/` 是公共基座：两个口味构建时都会 `cp -a` 进 `/`
  （服务、脚本、udev、sysctl、logind、NetworkManager 配置），改动先改这里。
  `orbital.service` 文件也在 overlay 里，但只有 server 口味会 enable。
- 共享基座实现：`rootfs/sirius-device.sh`（被各 build-*.sh source）：`SIRIUS_USER/PASS`、`SIRIUS_GROUPS`（含 audio）、`SIRIUS_AUDIO_PKGS`（alsa-utils + alsa-ucm-conf）、`sirius_overlay` 等。改通用逻辑改这里；flavor 私有（桌面包、DM 登录、service enable 列表）留在各脚本。
- 音频基线（两口味相同）：默认用户进 audio 组（/dev/snd 属主 root:audio，否则用户态报 no soundcards）、均装 alsa-utils、均 enable `sirius-audio-init`（开机挂 Speaker 路由）。enable 列表本身是 flavor-specific，见 docs/AUDIO-BRINGUP.md §6。
- 产物（`*.tar.zst`/`*.simg`）不进库，走 GitHub Releases。
- apt 源：构建脚本强制切 CERNET 镜像（含 security），`SIRIUS_MIRROR` 环境变量可改地址。
