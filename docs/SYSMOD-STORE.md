# system 分区仓库（sysmod）：内核模块 + 固件与 rootfs 解耦

`userdata` 上的 rootfs 只装系统；内核模块和设备固件住在闲置的
`system` 分区（3GB，`fastboot getvar partition-size:system` = `0xC0000000`），
开机由 initrd 绑定进新根。内核、模块、固件三者同版本一起走，
rootfs 随便重刷不影响驱动。

## 布局（system 分区内）

```text
lib/modules/<uname -r>/   内核模块 + depmod 数据库（构建机 modules_install 产物）
lib/firmware/...          设备固件（映射关系见 rootfs/lib/sirius-device.sh 的
                          sirius_firmware_pre：a615_zap/a630_sqe/a630_gmu、
                          st_fts_v521.ftb、pyxis-phone 整包、ath10k WCN3990 三件套、
                          qca 蓝牙两件套；pd-mapper 二进制仍在 rootfs，不搬）
```

## 启动流程（boot/initrd/initramfs/init）

1. `find_sysmod_dev`：直接用 `/dev/mmcblk0p79`（真机验证过），cmdline `sysmod_part=` 可覆盖。
2. `mount --move` 把仓库挪进新根 `/mnt/sysmod`（不然 switch_root 会丢），
   再把 `lib/modules/<uname -r>` 和 `lib/firmware` bind 进新根。
3. 每步都写 kmsg：`dmesg | grep sysmod` 可查命中哪条分支。

## 版本号 `+` 后缀说明

`uname -r` 形如 `7.2.3-sdm670-gcbbdbeb2ca53+` 时，末尾 `+` 是 kbuild
给**脏树**（有未提交改动）打的标记。模块目录名必须带 `+` 才对得上。
教训：内核和模块必须同一次构建一起发布；`qcom-battery`、`ath10k`、
`qcom_smbx` 全是模块，目录错一位就全灭（WiFi 消失、无电池、otg 报错），
且静默无日志——排错先看 `ls /lib/modules/$(uname -r)` 是否存在。

## 构建与刷机

```bash
# 远程构建机（内核树已编过）：
./rootfs/build-sysmod.sh
# 产物默认 rootfs/build/sysmod.img（256M，gitignored），附 md5。

# init 改过则重打 boot（Image.gz/dtb 先就位）：
(cd boot/initrd && ./build.sh && mv initrd.cpio.gz ../) && cd boot && ./build_both.sh

# 刷机（fastboot）：
fastboot erase dtbo
fastboot flash system sysmod.img
fastboot flash boot boot_sys.img
fastboot reboot
```

## 验证（进系统后，WiFi 或 USB 任一 shell）

```bash
uname -r; ls /lib/modules/$(uname -r) | head
dmesg | grep -E "sysmod|kmod store"
cat /sys/class/power_supply/qcom-battery/charge_full_design  # 期望 3120000
lsmod | grep -E "ath10k_snoc|qcom_fg|qcom_smbx"
sudo sirius-otg status
```

## rootfs 侧配合

- 新 rootfs 构建可加 `SIRIUS_SYSMOD=1` 跳过 kmod/固件烘焙
  （`build-server.sh`/`build-gnome.sh` 已支持，默认仍烘焙，行为不变）。
- rootfs 里旧 `/lib/modules/*` 保留当 fallback，别删。
- system 分区挂载点开机后在 `/mnt/sysmod`（只读绑定的源头），
  想往仓库加东西：重新跑 `build-sysmod.sh` 并 fastboot 重刷 system。
