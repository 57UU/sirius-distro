# rootfs 构建（两口味，同基座）

## 底包下载（用最新）

`SIRIUS_BASE` 要一棵纯净 trixie arm64 树：去
`https://images.linuxcontainers.org/images/debian/trixie/arm64/default/`
找日期最新的目录，下载里面的 `rootfs.tar.xz`
以 root 解开即用：

```bash
sudo tar -xpJf rootfs.tar.xz -C /path/to/base   # 必须 root 解，属主不能展平
sudo SIRIUS_BASE=/path/to/base ./build-server.sh
```


## 公用基座（两口味完全相同）


1. `rootfs/sirius-device.sh`（被各 build-*.sh source）：`SIRIUS_USER/PASS`（默认 `u57u`/`1234`，uid 1000，sudo 免密，首次开机后改密码）、`SIRIUS_GROUPS`（默认 `video,audio,render,input`）、`SIRIUS_AUDIO_PKGS`（`alsa-utils + alsa-ucm-conf`）；函数 `sirius_overlay`（`overlay/` + `dsp-bin/` 烤入、rmtfs partlabel 软链、`.ssh` 骨架）、`sirius_netconf`（主机名 `sirius`、RNDIS usb0 静态 `172.16.42.1/16`）、`sirius_apt_mirror`（强制切 CERNET 镜像，`SIRIUS_MIRROR` 可改地址）。改通用逻辑改这里；flavor 私有留在各脚本。
2. `overlay/`：两个口味都会 `cp -a` 进 `/`（服务、脚本、udev、sysctl、logind、NetworkManager 配置），改动先改这里。`orbital.service` 文件也在 overlay 里，但只有 server 口味会 enable。
3. 共同软件包：`$SIRIUS_BASE_PKGS`（openssh/NM/bluez/rmtfs/tqftpserv/qrtr-tools/pipewire/wireplumber/`$SIRIUS_AUDIO_PKGS`/`$SIRIUS_VULKAN_PKGS`（Turnip 认 Adreno 615，备用；Orbital 暂不切后端）/timesyncd/resolved/e2fsprogs 等，定义在 sirius-device.sh），各口味只加自己的（server：evtest/rfkill/auditd/kbd + Qt 运行库；gnome：gnome-core/gdm3/firmware-atheros/firmware-qcom-soc）；共同 enable：`$SIRIUS_BASE_UNITS`（ssh/networkd/rmtfs/pd-mapper/adsprpcd×3/蓝牙/usb-bind/zram/audio-init 等，定义在 sirius-device.sh），各口味只加自己的（server：orbital；gnome：gdm）；时区 `Asia/Shanghai`。

基座设备能力：modem/WLAN 固件`firmware/`、`pd-mapper`、rmtfs/tqftpserv、wifi-shutdown、ADSP 不恢复规则、sysrq、wlan0 命名+固定 MAC、蓝牙 UART 自加载+固定地址、RNDIS usb0 静态地址（见 docs/STABLE-MAC.md）；音频基线：用户进 audio 组（/dev/snd 属主 root:audio，否则用户态报 no soundcards）、`sirius-audio-init` 开机挂 Speaker 路由（见 docs/AUDIO-BRINGUP.md §6）。

## 两口味差异（只差上层）

```text
build-server.sh  无头 + Orbital（当前主线）：multi-user，无桌面；
                 加装 evtest/rfkill/auditd/kbd + Qt 运行库，烤入 orbital-pkg/。
build-gnome.sh   GNOME 桌面（GDM 自动登录）：加装 gnome-core/gdm3/firmware-atheros/
                 firmware-qcom-soc；GDM 自动登录 u57u；mask suspend 全套。
```

电源键/息屏（见 docs/SERVER-MODE.md）：server 由 Orbital 内建 idle 计时 + 电源键处理
（设置→Screen Off Time 可调）；gnome 用 `sirius-gnome-blank`（--user 服务）跟随
GNOME 屏保状态，计时以 `org.gnome.desktop.session idle-delay` 为准（默认 120s，
用户可在设置里改，设为从不则不自动息屏）。电源键短按经 logind 锁屏触发屏保，
再由 sirius-gnome-blank 切背光（免密，任意输入唤醒），长按照旧关机。
mutter 的 blank 关不掉本机 DSI 背光（只画黑屏），所以 gnome 的跟随动作仍走
`sirius-screen` 切真背光（真机实测结论；server 上它只留手动救援）。

## 输入、产物

- 输入：`SIRIUS_BASE`、`SIRIUS_WORK`（输出目录，默认 `<distro>/work`）。缺谁 fail-fast，不猜路径。内核模块 + 固件不住 rootfs，住 vendor 分区仓库（`kernel/build-vendormod.sh` 打，见 docs/VENDORMOD-STORE.md），所以没有模块包输入。
- 产物（`*.tar.zst`/`*.simg`）不进库。