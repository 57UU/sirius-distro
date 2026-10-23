# 更新日志

本文件记录 sirius-distro 的所有显著变更。

注意：本页的更新日志应当存放一些通俗显著的更新内容，而非技术更新或者内部优化，请勿搬运git log记录。

change分为三大部分：boot,kernel,rootfs，例如 rootfs.gnome: 修复gnome版本下xx的问题

本文档格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
本项目遵循[语义化版本规范](https://semver.org/spec/v2.0.0.html)。

## [Unreleased]

## [2.1] - 2026-10-23

### 新增

- kernel: **USB-C 完整协议栈**：系统现在会自己认角色——插电脑自动当网卡（RNDIS 照旧），插 OTG 头自动切成主机并给外接设备供电。支持 PD 的充电器会自动协商 9V 档。
- kernel: **充电温度保护**：电池温度升高会自动逐级降低充电电流（40°C 起降档，48°C 以上只充 0.5A，55°C 或 0°C 以下直接停充），温度降回来自动恢复，不再一直按满速充。
- rootfs: **蓝牙**：蓝牙芯片偶发固件崩溃导致蓝牙打不开时，系统现在会自动恢复，约 30 秒内恢复。
- rootfs: **蜂窝网络（4G 上网）**：插入 SIM 卡即可通过移动网络上网，无需手动配置——系统会自动识别运营商并选择APN。当前仅支持单张 SIM 卡。
- kernel: **振动马达**：震动器现在可用了，应用通过系统标准的震动接口就能触发。
- kernel: **红外遥控**：手机顶部的红外发射器可用了，可以当遥控器发码（只支持发射，不支持接收）。
- rootfs: **传感器**：加速度计、陀螺仪、磁力计和指南针现在能读了；光线和距离传感器暂不可用。
- kernel: **后置摄像头能出图了**：Sony IMX363 主摄已适配，系统自带「快照」和普通 V4L2 应用
  都能拿到画面，640x480 / 720p / 1080p 预览约 30 fps；前摄与后置副摄暂不支持。
  注意：目前很不稳定——连续预览或录制约 1 分钟后画面会彻底停住，只能重启恢复；
  曝光和白平衡也未标定，室内灯光下亮度和颜色会缓慢漂移。
- boot: **UEFI 启动**：开机默认走 EFI 直启，失败自动回落到原来的 extlinux 启动。

### 变更

- kernel: **内核升级到 7.3**：底座从 7.2.3 前移到上游 Linux 7.3，sirius 驱动与补丁已同步合入，真机验证开机、WiFi、显示、Modem 正常。
- rootfs: **图形驱动默认用新版**：镜像现在默认安装 trixie-backports 里的 Mesa。OpenGL 应用比之前快约 15%，Vulkan 基本不变。
- rootfs.gnome: **息屏与锁屏全面回归 GNOME 原生**：移除了旧版的自制电源管理和背光组件，
  「设置 → 电源 → 屏幕空白」现在真正生效，空闲后自动锁屏、灭屏、按键唤醒
  全部按 GNOME 标准行为工作。
- rootfs.gnome: **电源键改为「按一下锁屏息屏」**：亮屏时按一下立即锁屏并息屏；灭屏时按一下点亮屏幕回到锁屏界面；长按仍为硬件关机。电源键不会再触发「60 秒后自动关机」的确认框。
- boot: **默认启动改为 EFI 优先**：启动菜单新增 `Boot EFI` 项；`kernel.img` 的 `/boot` 下新增 `efi/BOOTAA64.EFI`。

### 移除

- kernel: **NFC 支持已移除**：确认 sirius 没有这颗设备，删掉了设备树里的 NFC 节点。
- rootfs: 删掉了用户态的「伪自动」USB 角色跟随（`sirius-usb-bind` 及其 systemd 服务、udev 规则）。现在内核自己认线，它留着只会和内核抢角色、抢 OTG 供电。
- rootfs: `sirius-otg` 的 `on`/`off`/`auto` 一并删除 ——角色和 OTG 供电都由内核按线缆状态自动处理，脚本只剩 `status`/`watch` 两个只读诊断命令。
- rootfs: **移除 `sirius-reboot`**：它的 fastboot 模式进的是 U-Boot 自带 fastboot，USB 支持不完善，很容易卡在 U-Boot 里，只能长按电源冷启动恢复。刷机请用「音量下 + 电源」进原厂 fastboot；需要启动菜单时开机按音量键打断 autoboot。

### 修复

- **server 版电源键和触摸恢复正常**：振动马达驱动多出一个输入设备，把原来的 event 编号整体挤后一位，Orbital 还在抓旧的 `event0`/`event3`。现在输入设备统一用按设备名生成的固定节点（`/dev/input/sirius-*`），以后新增设备也不会再错位。
- **OTG 外设不再「亮一下又断」**：插鼠标、U 盘时系统会持续给外设供电，不会再出现插上瞬间通电、随后掉电、外设一直认不出来的情况。
- **电量不再卡在 99%**：充满时能正常显示 100%。
- **USB-C 充电电流跟随协商结果**：充电器不再自己按「普通 USB 口」猜一个 500mA 限流，而是按谈下来的电流充。
- gnome version:锁屏状态下按电源键现在会立即息屏，息屏后触摸屏不再误触界面，锁屏界面唤醒后不再黑屏。

## [2.0] - 2026-10-17

> 本次更新重做了引导方式，**升级必须换刷机流程**，请先读完「变更」中的破坏性变更条目。

### 新增

- **U-Boot 启动链**：设备改由 U-Boot 引导，从 system 分区读取内核、initrd 与设备树。
- **重启模式**：新增 `sirius-reboot`，可重启进 fastboot 或启动菜单。
- **自定义开机 logo**：新增可选的 `boot-logo/`。
- **固件**：新增视频编解码、Modem/IPA、CDSP 固件。
- **电源键服务**：新增 sirius-powerd（gnome版专属），独占电源键，
  按一下翻转 OLED（只写 brightness），60 秒无操作自动灭屏；GNOME 退出灭屏链。

### 变更

- **破坏性变更：引导方式更换**。ABL 直启退役，改用 U-Boot。
- **破坏性变更：内核与固件改存 system 分区**。产物镜像改名 `kernel.img`，
  刷写命令由 `fastboot flash vendor ...` 改为 `fastboot flash system ...`；
  `vendor` 分区不再参与启动。
- **刷机流程调整**：从 Release 下载 `boot.img`、`kernel.img` 与 rootfs 三个镜像依次刷入；只换内核时仅刷 system。
- **硬件支持状态更新**：视频解码可用，视频编码部分可用（ffmpeg 会段错误），Modem/IPA 可用。
- 5GHz WiFi 的 BDF 固件换成与手机实测一致的版本。
- WiFi 改用持久化的出厂 MAC，不再随机化，避免 DHCP 与路由器绑定失效。
- rootfs 构建的默认 apt 源改为清华镜像。
- **开机更快**：系统服务改为并行启动，开机就绪 7.5s→5.9s。
- **内核版本号固定**：`uname -r` 恒为 `7.2.3-sdm670+`，不再随构建变化。
- 子模块更新：`kernel/linux-sirius`、`orbital/orbital-src`；新增 `uboot` 子模块。

### 移除

- 移除 ABL 直启方案及其构建脚本。
- vendor 分区不再用于存放内核模块与固件。
- 移除 snd_soc_sm8250 的 modprobe 黑名单（实际声卡驱动是 sdm660-int，黑名单打空）。

### 修复

- 出厂 MAC 地址持久化并保持稳定，此前重启后会变化并导致 IP 漂移。
- USB 网卡识别更稳定。
- 修复开机阶段的 dmesg 报错。
- gnome版本:修复电源键行为：之前按电源只会进出 suspend 空转（多按几次才亮），
  现在按一下灭/亮即时翻转；托盘锁屏后按电源可唤醒。
- 修复 5GHz WiFi 与 USB host 模式的相关问题。
- **关机更快**：关机耗时从 25 秒以上缩短到 5 秒左右。

### known issue

GNOME Version: 目前的电源键方案有点别扭，体验也不是很好

[Unreleased]: https://github.com/57UU/sirius-distro/compare/v2.1...HEAD
[2.1]: https://github.com/57UU/sirius-distro/compare/v2.0...v2.1
[2.0]: https://github.com/57UU/sirius-distro/compare/v1.3.2...v2.0
