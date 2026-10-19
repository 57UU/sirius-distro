# 时间/RTC TODO（Linux 掉时间，U-Boot 正常）

## 现象

- U-Boot 屏右上角有时钟显示（直接读 PMIC RTC 硬件），硬件时钟是走的。
- Linux 每次重启掉回 1970（如文件时间戳 `Jan 2`、journal 时间错乱），靠 NTP 对时后才正常。
- rootfs 里时间相关配置缺失，单独立项修。

## 排查步骤（按顺序）

1. `ls /sys/class/rtc/`、`timedatectl status`、`dmesg | grep -i rtc`：确认 rtc 设备、时区/NTP 状态、驱动 probe 日志。
2. 查 DT：`pmic@2` 下 rtc 节点 `status` 是否 okay（`sirius-sdm710.dts` 及 `pm660.dtsi` 引用）。
3. 查内核配置：`CONFIG_RTC_DRV_QPNP`（qpnp-rtc）是否编进/模块，`/lib/modules` 里有没有 `rtc-qpnp.ko`。
4. 查用户态：`systemd-timesyncd` 是否启用、有无 `fake-hwclock`（无网环境保底时间）。

## 修复方向（二选一或都做）

- A：让内核 RTC 生效（DT + 驱动），`hwclock -r` 能读出，开机即有正确时间；
- B：用户态兜底：`fake-hwclock`（关机存时间、开机恢复）+ timesyncd 配好 NTP 源。

## 验收

- 断网重启后 `date` 落在合理范围（不再是 1970），`journalctl --list-boots` 时间连续；
- 有网时 NTP 对时正常，不打架。

## 相关

- U-Boot 侧 RTC 显示正常，问题只在 Linux 侧。
- 动 DT（如 rtc 节点）走 dtb 测试流程：WSL 编 dtb → 手机 remount 替换 → reboot 验证。
