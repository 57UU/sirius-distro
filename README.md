# sirius-distro

小米 8 SE（sirius / sdm710）Linux 发行工程：把内核变成能用的系统。
内核源码在 [57UU/linux-sirius](https://github.com/57UU/linux-sirius)（分支 `feat/sirius-7.3`），

```text
boot/       U-Boot 启动镜像（uboot/sirius-build.sh 打包）以及initrd源码
firmware/   设备固件
rootfs/     rootfs 烘焙：overlay（开机会拷进 / 的文件）+ 构建脚本
src/        自研源码（sirius-remodeset）；第三方源码只留获取说明
orbital/    上游仪表盘（获取说明，用于server系统的简易管理GUI）
kernel/     内核区：build-kernel-img.sh（system 分区仓库打包）+ linux-sirius/（上游内核submodule，57UU/linux-sirius feat/sirius-7.3，需git submodule update --init）
glue/       内核/设备耦合 userspace 层（unit/脚本/设备守护二进制/私有运行库/Sensor Core 配置/自检脚本/udev/模块加载/ALSA UCM/运行期配置/manifest）：随 kernel.img 打进 system 分区，升级内核相关服务只刷 system
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

## step2：刷写 system（kernel.img：内核+模块+固件+内核耦合服务）

内核模块、设备固件，以及随内核走的 systemd 服务/udev 规则/ALSA UCM（`glue/`）都在 system 分区，刷入：

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
| USB/USB-C    | Working       | PD 9V/2A |
| Thermal      | Working       |      |
| Touchscreen  | Working       |      |
| Battery      | Working       |      |
| LED          | Working       | notification, rear flash, front fill |
| Speaker      | Working       |      |
| Headphone    | Broken        |      |
| Haptics      | Working       |      |
| Microphone   | Working       | bottom + top |
| Bluetooth    | Working       |      |
| WiFi         | Working*      | 5GHz high latency with MFP on|
| Modem/IPA    | Working       | single SIM only |
| GPS/GNSS     | Working       | outdoor verified |
| IR TX        | Working       |      |
| Camera       | Partial       | IMX363 rear only, very unstable |
| Fingerprint  | Broken        |      |
| Video decode | Working       | H.264 VP8 VP9 HEVC MPEG-2 |
| Video encode | Working*      | ffmpeg <= 9.1 segfaults on non-32-aligned height (fixed in upstream) |
| Sleep        | Partial       | s2idle works; deep/S3 unsupported |

## Sensors

| Sensor | Status |
| ----------- | ------- |
| Accelerometer | Working |
| Gyroscope | Working |
| Magnetometer | Working |
| Compass | Working |
| Ambient Light | Broken |
| Proximity | Broken |

## Boot

Uboot with UEFI support.


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

charging / battery profile / SMB1355: see `docs/CHARGING.md`.

# 构建

```bash
./build.sh initrd        # initramfs  -> workspace/build/initrd.cpio.gz
./build.sh boot          # U-Boot     -> build/boot.img
./build.sh kernel        # 模块+固件+glue -> build/kernel.img（需先 initrd）
./build.sh rootfs-gnome  # GNOME rootfs -> build/debian-trixie-sirius-gnome-<日期时间>.simg
./build.sh rootfs-server # server rootfs -> build/debian-trixie-sirius-server-<日期时间>.simg
./build.sh rootfs-gnome --no-tmp # 改用 workspace/build/rootfs/，保留工作树
./build.sh all           # initrd -> boot -> kernel -> 两个 rootfs
./build.sh clean         # 清 workspace/build/（中间产物；build/ 下的 img/simg 不动）
```

`kernel` 目标需要 `patchelf`、`file` 和 NOPASSWD sudo（镜像里的 glue 必须是 root 所有）。
system 分区在 ABI 层面只依赖 rootfs 的 glibc（≥2.38）和 glib 家族，见
[docs/KERNEL-IMG-STORE.md](docs/KERNEL-IMG-STORE.md) §4。

最终产物（`*.img` / `*.simg`）在 `build/`。
日志始终保存在 `workspace/build/logs/`, base、initrd、U-Boot 等仍在 `workspace/build/`。
`/tmp` 是 tmpfs 时可减少包安装的同步写盘等待；GNOME 构建和打包同时占用约 8–10 GiB，

内核 Image/dtb 先在 `kernel/linux-sirius/` 里 `make`，`./build.sh kernel` 只做 system 分区镜像。


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
base system: Debian trixie (rootfs builds; device firmware ships in the system-partition store)
qca-swiss-army-knife
initrd userspace: busybox
