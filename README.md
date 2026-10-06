# sirius-distro

小米 8 SE（sirius / sdm710）Linux 发行工程：把内核变成能用的系统。
内核源码在 [57UU/linux-sirius](https://github.com/57UU/linux-sirius)（分支 `feat/sirius-7.2`），

```text
boot/       boot_sys.img 组装脚本以及initrd源码
firmware/   设备固件
rootfs/     rootfs 烘焙：overlay（开机会拷进 / 的文件）+ 构建脚本
src/        自研源码（sirius-remodeset）；第三方源码只留获取说明
orbital/    上游仪表盘（获取说明，用于server系统的简易管理GUI）
kernel/     内核区：build-vendormod.sh（vendor 分区仓库打包）+ linux-sirius/（上游内核submodule，57UU/linux-sirius feat/sirius-7.2，需git submodule update --init）
docs/       相关文档以及一些修复经验
```
制作过程见：https://blog.57u.tech/2026/03/18/install-linux-on-android-device-mi8se/

# 刷机指南
在Release中下载boot,vendormod以及rootfs(debian-xxx)镜像。
解锁bootloader并进入fastboot模式

## step1: 刷写 boot_sys.img
```bash
fastboot erase dtbo
fastboot flash boot boot_sys.img
```
需要清空dtbo，设备才会加载boot中的设备树。

## step2：刷写 vendor（模块+固件仓库 vendormod）

内核模块和设备固件在 vendor 分区，刷入：
```bash
fastboot flash vendor vendormod.img
```
只换内核时： 刷 vendor + boot 即可。但注意boot与vendor必须成对刷入，因为内核模块与内核版本强绑定。

## step3：刷写 rootfs.img
解压出simg文件

```bash
fastboot flash userdata xxxxx.simg
fastboot reboot
```
刷写 userdata 可能出现卡住的情况，这是正常的，eMMC没办法。

刷完后，使用fastboot reboot重启，可能会有假死的状态，请耐心等待，避免eMMC还没完成写入。


# status

| Components  | Status  |
| ----------- | ------- |
| CPU         | Working |
| GPU         | Working |
| eMMC        | Working |
| USB         | Partial, auto mode is partially implemented in userspace |
| Bluetooth   | Working |
| WiFi        | Working* |
| Thermal     | Working |
| Touchscreen | Working |
| Battery     | Working |
| LED         | Working |
| Speaker     | Working |
| Microphone  | Broken |

USB 自动切换目前有缺陷：普通线连电脑走 gadget 网卡，OTG 线接外设走 host；部分线材可能要翻面插才认得出来。详情见 docs/USB-HOST-FIX.md，切换一律用 sirius-otg。

*: 5GHz WiFi 在开启帧保护后，会造成IO缓慢、延迟增大，详情见`docs/WIFI-5G-BDF-MFP.md`。

## 自制服务速查（`/usr/local/sbin`，需 root）

```bash
sudo sirius-otg on|off|auto|status  # 默认 auto（事件跟随，开机跑一次）：on=host+自供电（OTG 头+外设），off=回 gadget（RNDIS 用普通线）
sudo sirius-wifi-auto on|off|status # 默认 on（开机即看门狗，timer 每 5 分钟一轮）：开/关/看状态
sudo sirius-zram start|stop|status  # 默认 on（开机即有 1.7G swap）：lz4，50% 内存
sudo sirius-screen off|on|toggle|status  # 默认亮屏（只动背光，不碰 SoC/WiFi/BT/SSH）
sudo sirius-wifi-add SSID [PASSWORD] # 一次性：无头加 WiFi 配置
sudo safe-reboot                     # 一次性：sysrq 安全重启（sync→remount-ro→reboot）
sirius-remodeset                     # 手动救援：无头启动显示卡住时跑一次（DSI modeset 解卡）
```

开机自启、无需手动（以下默认全开）：`sirius-usb-bind`（USB 角色事件跟随，udev 驱动）、
`sirius-bt-auto` + `sirius-bt-addr`（蓝牙上电+固定地址）、
`wifi-shutdown`（关机前干净下线 WiFi 卸载驱动）、
`sirius-gnome-blank`（仅 gnome 口味：跟随系统息屏切真背光）。
线材问题与原理见 `docs/USB-HOST-FIX.md`。


# Acknowledgements
Thanks many opensource projects:

kernel for sdm710: https://gitlab.com/sdm670-mainline/linux
initrd: https://gitlab.com/sdm845-mainline/initrd
orbital(lite panel): https://github.com/AthBe1337/Orbital
firmware & config: https://wiki.nura.eco/wiki/Xiaomi_Mi_9_Lite_(xiaomi-pyxis)

android reference: https://github.com/Rocky7842/android_kernel_xiaomi_sdm710

## Other upstream dependencies

remote proc tools: https://github.com/andersson (pd-mapper, tqftpserv, rmtfs, qrtr)
base system: Debian trixie (rootfs builds, firmware-qcom-soc / firmware-atheros packages)
qca-swiss-army-knife
initrd userspace: busybox
