# sirius-distro

小米 8 SE（sirius / sdm710）Linux 发行工程：把内核变成能用的系统。
内核源码在 [57UU/linux-sirius](https://github.com/57UU/linux-sirius)（分支 `feat/sirius-7.2`），

```text
boot/       boot.img 组装脚本以及inited源码
firmware/   设备固件
rootfs/     rootfs 烘焙：overlay（开机会拷进 / 的文件）+ 构建脚本
src/        自研源码（sirius-remodeset）；第三方源码只留获取说明
orbital/    上游仪表盘（获取说明，用于server系统的简易管理GUI）
kernel/     上游内核引用（获取说明 + 需要的产物清单）
docs/       相关文档以及一些修复经验
```
制作过程见：https://blog.57u.tech/2026/03/18/install-linux-on-android-device-mi8se/

# 刷机指南
解锁bootloader并进入fastboot模式

## step1: 刷写 boot.img
```bash
fastboot erase dtbo
fastboot flash boot boot.img
```
需要清空dtbo，设备才会加载boot中的设备树。

## step2：刷写 rootfs.img

自行构建或者在release中下载rootfs，解压出simg文件

```bash
#格式化userdata为ext4
fastboot format:ext4 userdata
fastboot flash userdata xxxxx.simg
```
刷写 userdata 可能出现卡住的情况，这是正常的，eMMC没办法。
刷完后，请使用fastboot reboot重启，耐心等待，避免eMMC还没完成写入。

首次进系统后务必扩容，否则很快没空间：

```bash
#在线扩容（/ 已挂载也能执行），mmcblk0p81 即 userdata，见 boot/build_both.sh
sudo /sbin/resize2fs /dev/mmcblk0p81  #要用全路径，默认PATH里没/sbin
df -h /   #确认已撑满整个 userdata 分区
```

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

USB工作在gadget模式，作为usb虚拟网卡被电脑接入。