# sirius-distro

小米 8 SE（sirius / sdm710）Linux 发行工程：把内核变成能用的系统。
内核源码在 [57UU/linux-sirius](https://github.com/57UU/linux-sirius)（分支 `feat/sirius-7.2`），

```text
boot/       U-Boot 启动镜像（uboot/sirius-build.sh 打包）以及initrd源码
firmware/   设备固件
rootfs/     rootfs 烘焙：overlay（开机会拷进 / 的文件）+ 构建脚本
src/        自研源码（sirius-remodeset）；第三方源码只留获取说明
orbital/    上游仪表盘（获取说明，用于server系统的简易管理GUI）
kernel/     内核区：build-kernel-img.sh（system 分区仓库打包）+ linux-sirius/（上游内核submodule，57UU/linux-sirius feat/sirius-7.2，需git submodule update --init）
docs/       相关文档以及一些修复经验
```
制作过程见：https://blog.57u.tech/2026/03/18/install-linux-on-android-device-mi8se/

# 刷机指南
在Release中下载boot,kernel.img以及rootfs(debian-xxx)镜像。
解锁bootloader并进入fastboot模式

## step1: 刷写 U-Boot（boot 分区）
```bash
fastboot erase dtbo
fastboot flash boot boot.img
```
需要清空dtbo，启动连才会加载boot中的设备树

只换内核时不用重刷 boot，只刷 system 即可。

## step2：刷写 system（kernel.img：内核+模块+固件）

内核模块和设备固件在 system 分区，刷入：
```bash
fastboot flash system kernel.img
```

## step3：刷写 rootfs.img
解压出simg文件

```bash
fastboot flash userdata xxxxx.simg
fastboot reboot
```
刷写 userdata 可能出现卡住的情况，这是正常的，eMMC没办法。

刷完后，使用fastboot reboot重启，可能会有假死的状态，请耐心等待，避免eMMC还没完成写入。

default password is 1234.

# status

| Components   | Status        | Note |
| ------------ | ------------- | ---- |
| CPU          | Working       |      |
| GPU          | Working       |      |
| eMMC         | Working       |      |
| USB/USB-C    | Working       |      |
| Thermal      | Working       |      |
| Touchscreen  | Working       |      |
| Battery      | Working       |      |
| LED          | Working       | notification, rear flash, front fill |
| Speaker      | Working       |      |
| Headphone    | Broken        |      |
| Haptics      | Working       |      |
| Microphone   | Broken        |      |
| Bluetooth    | Working       |      |
| WiFi         | Working*      | 5GHz slow IO / high latency with MFP on, see `*` |
| Modem/IPA    | Working       | single SIM only |
| GPS/GNSS     | Broken        |  |
| NFC          | Broken        | driver probes but no chardev/userland |
| IR TX        | Working       |      |
| Camera       | Broken        | CAMSS is up but no sensor driver |
| Fingerprint  | Broken        | no driver / no DT node |
| Video decode | Working       | H.264 VP8 VP9 HEVC MPEG-2 |
| Video encode | Partial       | verified via v4l2-ctl, ffmpeg segfaults |
| Suspend      | Not supported | s2idle too shallow |

## Sensors

| Sensor | Status |
| ----------- | ------- |
| Accelerometer | Working |
| Gyroscope | Working |
| Magnetometer | Working |
| Compass | Working |
| Ambient Light | Broken |
| Proximity | Broken |


*: 5GHz WiFi 在开启帧保护后，会造成IO缓慢、延迟增大，详情见`docs/WIFI-5G-BDF-MFP.md`。

## 自制服务速查（`/usr/local/sbin`，需 root）

```bash
sudo sirius-otg status|watch  # 只读诊断：角色归属、power/data role、boost、usb0（角色本身由内核自动管）
sudo sirius-wifi-auto on|off|status # 默认 on（开机即看门狗，timer 每 5 分钟一轮）：开/关/看状态
sudo sirius-zram start|stop|status  # 默认 on（开机即有 1.7G swap）：lz4，50% 内存
sudo sirius-screen off|on|toggle|status  # 默认亮屏（只动背光，不碰 SoC/WiFi/BT/SSH）
sudo sirius-wifi-add SSID [PASSWORD] # 一次性：无头加 WiFi 配置
sudo safe-reboot                     # 一次性：sysrq 安全重启（sync→remount-ro→reboot）
sirius-remodeset                     # 手动救援：无头启动显示卡住时跑一次（DSI modeset 解卡）
```

开机自启、无需手动（以下默认全开）：`sirius-bt-auto` + `sirius-bt-addr`（蓝牙上电+固定地址）、
`wifi-shutdown`（关机前干净下线 WiFi 卸载驱动）。

# Extra Content

if you want to change splash screen, refer to boot-logo/ folder.

infrared / haptics: see `docs/HAPTICS-IR.md`.

# 构建

```bash
./build.sh initrd        # initramfs  -> workspace/build/initrd.cpio.gz
./build.sh boot          # U-Boot     -> build/boot.img
./build.sh kernel        # 模块+固件  -> build/kernel.img（需先 initrd）
./build.sh rootfs-gnome  # GNOME rootfs -> build/debian-trixie-sirius-gnome-<日期时间>.simg
./build.sh rootfs-server # server rootfs -> build/debian-trixie-sirius-server-<日期时间>.simg
./build.sh all           # initrd -> boot -> kernel -> 两个 rootfs
./build.sh clean         # 清 workspace/build/（中间产物；build/ 下的 img/simg 不动）
```

产物分两级：**最终产物（`*.img` / `*.simg`）落 `build/`**；其余中间产物（initrd、U-Boot 构建目录、
rootfs 工作树、SIRIUS_BASE 原始树、临时目录）全部在 `workspace/build/` 下。

内核 Image/dtb 仍需先在 `kernel/linux-sirius/`（submodule）里 `make` 出来，`build_kernel` 只做
system 分区镜像的汇编。


# Acknowledgements
Thanks many opensource projects:

kernel for sdm710: https://gitlab.com/sdm670-mainline/linux
initrd: https://gitlab.com/sdm845-mainline/initrd
orbital(lite panel): https://github.com/AthBe1337/Orbital
firmware & config: https://wiki.nura.eco/wiki/Xiaomi_Mi_9_Lite_(xiaomi-pyxis)
uboot: https://gitlab.postmarketos.org/ellyq/u-boot

android reference: https://github.com/Rocky7842/android_kernel_xiaomi_sdm710

## Other upstream dependencies

remote proc tools: https://github.com/andersson (pd-mapper, tqftpserv, rmtfs, qrtr)
base system: Debian trixie (rootfs builds, firmware-qcom-soc / firmware-atheros packages)
qca-swiss-army-knife
initrd userspace: busybox
