# 更新日志

本文件记录 sirius-distro 的所有显著变更。

注意：本页的更新日志应当存放一些通俗显著的更新内容，而非技术更新或者内部优化，请勿搬运git log记录。

本文档格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
本项目遵循[语义化版本规范](https://semver.org/spec/v2.0.0.html)。

## [Unreleased]

### 新增

- **蜂窝网络（4G 上网）**：插入 SIM 卡即可通过移动网络上网，无需手动配置——
  系统会自动识别运营商并选择 APN（移动/电信/联通均支持），开机自动建立连接，
  运行中插拔卡也会自动恢复。当前仅支持单张 SIM 卡。

### 变更

- gnome version:**息屏与锁屏全面回归 GNOME 原生**：移除了旧版的自制电源管理和背光组件，
  「设置 → 电源 → 屏幕空白」现在真正生效，空闲后自动锁屏、灭屏、按键唤醒
  全部按 GNOME 标准行为工作。
- gnome version:**电源键改为「按一下锁屏息屏」**：亮屏时按一下立即锁屏并息屏；灭屏时
  按一下点亮屏幕回到锁屏界面；长按仍为硬件关机。电源键不会再触发
  「60 秒后自动关机」的确认框。

### 修复

- gnome version:锁屏状态下按电源键现在会立即息屏-= **息屏后触摸屏不再误触界面**。 **锁屏界面唤醒后不再黑屏**，无需盲输密码。

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

[Unreleased]: https://github.com/57UU/sirius-distro/compare/v2.0...HEAD
[2.0]: https://github.com/57UU/sirius-distro/compare/v1.3.2...v2.0
