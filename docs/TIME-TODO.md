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

## 实测结论（2026-10-20，已排除软件层）

- `rtc0` 是 `rtc-pm8xxx`，读时间正常；alarm 也能写（`wakealarm` 生效）。
- 驱动默认走 offset 分支：没有 `allow-set-time` 时 `hwclock -w` 报
  `ioctl(RTC_SET_TIME) ... No such device`（`pm8xxx_rtc_update_offset()` 里
  `!nvmem_cell && !use_uefi` 直接返回 `-ENODEV`）。
- DT 加上 `allow-set-time` 后报错变成 **`Operation not permitted`** —— 这时已经走进真正的
  写寄存器流程，被 PMIC 拒绝：调试打印显示**第一步写 `alarm_ctrl`（0x6146）就返回 -1**
  （SPMI 的 `SPMI_CMD_DENIED` 映射成 EPERM），后面的关 RTC / 写 WDATA 根本没执行到。
- 对照 CAF 的 `qpnp-rtc.c`，写序列完全一样（也是关 alarm → 关 RTC → WDATA），没有额外解锁，
  所以不是驱动写法问题，**是 PM660 的 PMIC 固件不允许从 AP 侧写 RTC**。
- **`allow-set-time` 已从 DT 移除**（2026-10-20）：留着它每次 `hwclock -w` 都会让 SPMI 层打
  `spmi spmi-0: disallowed SPMI write to sid=0, addr=0x6046`，一次写刷十几行内核日志，
  而结果一样写不进去。去掉后驱动走 offset 分支直接返回 `No such device`，不再碰硬件、不再刷屏。
- 结论：这条路走不通，不要再花时间。时间靠 NTP + 用户态兜底。

## 修复方向（只剩 B 可用）

- ~~A：让内核 RTC 生效（DT + 驱动）~~ —— 见上，PMIC 拒绝，不可行。
- B：用户态兜底：`fake-hwclock`（关机存时间、开机恢复）+ timesyncd 配好 NTP 源。

## 验收

- 断网重启后 `date` 落在合理范围（不再是 1970），`journalctl --list-boots` 时间连续；
- 有网时 NTP 对时正常，不打架。

## 相关

- U-Boot 侧 RTC 显示正常，问题只在 Linux 侧。
- 动 DT（如 rtc 节点）走 dtb 测试流程：WSL 编 dtb → 手机 remount 替换 → reboot 验证。
