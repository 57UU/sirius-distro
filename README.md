# sirius-distro

小米 8 SE（sirius / sdm710）Linux 发行工程：把内核变成能用的系统。
内核源码在 [57UU/linux-sirius](https://github.com/57UU/linux-sirius)（分支 `feat/sirius-7.2`），

```text
boot/       boot_sys.img 组装脚本以及initrd源码
firmware/   设备固件
rootfs/     rootfs 烘焙：overlay（开机会拷进 / 的文件）+ 构建脚本
src/        自研源码（sirius-remodeset）；第三方源码只留获取说明
orbital/    上游仪表盘（获取说明，用于server系统的简易管理GUI）
kernel/     上游内核submodule（57UU/linux-sirius feat/sirius-7.2，需git submodule update --init）
docs/       相关文档以及一些修复经验
```
制作过程见：https://blog.57u.tech/2026/03/18/install-linux-on-android-device-mi8se/

# 刷机指南
解锁bootloader并进入fastboot模式

## step1: 刷写 boot_sys.img
```bash
fastboot erase dtbo
fastboot flash boot boot_sys.img
```
需要清空dtbo，设备才会加载boot中的设备树。

## step2：刷写 vendor（模块+固件仓库 vendormod）

内核模块和设备固件不住 rootfs，住在闲置的 vendor 分区（mmcblk0p80，
3GB），开机由 initrd 绑定进系统。仓库镜像用 rootfs/build-vendormod.sh
打出（详见 docs/VENDORMOD-STORE.md），刷机：

```bash
fastboot flash vendor vendormod.img
```

只换内核时：重编内核 → 重打 vendormod.img → 刷 vendor + boot 即可，
userdata 不动。rootfs 里旧 /lib/modules 留作回落，别删。

## step3：刷写 rootfs.img

自行构建或者在release中下载rootfs，解压出simg文件

```bash
fastboot flash userdata xxxxx.simg
```
刷写 userdata 可能出现卡住的情况，这是正常的，eMMC没办法。
刷完后，请使用fastboot reboot重启，耐心等待，避免eMMC还没完成写入。


# status



| Components  | Status  |
| ----------- | ------- |
| CPU         | Working |
| GPU         | Working |
| eMMC        | Working |
| USB         | Partial |
| Bluetooth   | Working |
| WiFi        | Working |
| Thermal     | Working |
| Touchscreen | Working |
| Battery     | Working |
| Audio       | Broken  |
| Speaker     | Broken  |

USB 自动切换目前有缺陷：普通线连电脑走 gadget 网卡，OTG 线接外设走 host；部分线材可能要翻面插才认得出来。详情见 docs/USB-HOST-FIX.md，切换一律用 sirius-otg。

## USB 切换速查

```bash
sudo sirius-otg on      # host + 自供电（OTG 头+外设）
sudo sirius-otg off     # 关供电，尽力回 gadget（RNDIS 用普通线）
sudo sirius-otg status  # 看角色/供电/usb0
```


# Acknowledgements
Thanks many opensource projects:

kernel for sdm710: https://gitlab.com/sdm670-mainline/linux
initrd: https://gitlab.com/sdm845-mainline/initrd
orbital(lite panel): https://github.com/AthBe1337/Orbital
firmware & config: https://wiki.nura.eco/wiki/Xiaomi_Mi_9_Lite_(xiaomi-pyxis)

## Other upstream dependencies

remote proc tools: https://github.com/andersson (pd-mapper, tqftpserv, rmtfs, qrtr)
base system: Debian trixie (rootfs builds, firmware-qcom-soc / firmware-atheros packages)
qca-swiss-army-knife
initrd userspace: busybox
