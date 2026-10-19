# system 分区仓库（kernel.img）：内核模块 + 固件与 rootfs 解耦

`userdata` 的 rootfs 只装系统；内核模块 + 设备固件住 `system` 分区（`mmcblk0p79`），开机由 initrd 绑定进新根；内核/模块/固件同版本一起走。

> 历史：曾在 system（mmcblk0p79，sysmod）↔ vendor（mmcblk0p80，vendormod）间搬迁；2026-10-14 为 U-Boot sysboot mmc 0:4f 搬回 system；2026-10-18 名改回 sysmod（cmdline `sysmod_part=`、挂载点 `/mnt/sysmod`），旧名 `vendor_part=` 在 initrd 里仍兼容。刷机 `fastboot flash system kernel.img`。

## 布局（system 分区内）

```text
lib/modules/<uname -r>/   内核模块 + depmod 数据库（构建机 modules_install 产物）
lib/firmware/...          设备固件（映射见 rootfs/lib/sirius-device.sh 头注释：
                          a615_zap/a630_sqe/a630_gmu、
                          st_fts_v521.ftb、pyxis-phone 整包、ath10k WCN3990 三件套、
                          qca 蓝牙两件套；pd-mapper 二进制仍在 rootfs，不搬）
```

## 启动流程（boot/initrd/initramfs/init）

1. `find_sysmod_dev`：用 `/dev/mmcblk0p79`（system 分区），cmdline `sysmod_part=` 可覆盖（旧名 `vendor_part=` 兼容）。
2. `mount --move` 仓库进新根 `/mnt/sysmod`；再把 `lib/modules/<uname -r>`、`lib/firmware` bind 进新根。
3. 每步写 kmsg：`dmesg | grep sysmod` 查命中分支。

## 版本号 `+` 后缀说明

`uname -r` 形如 `7.2.3-sdm670-gcbbdbeb2ca53+`，末尾 `+` 是 kbuild 给**脏树**（有未提交改动）打的标记，模块目录名必须带 `+`。内核与模块必须同一次构建一起发布；`qcom-battery`、`ath10k`、`qcom_smbx` 全是模块，目录错一位就全灭（WiFi 消失、无电池、otg 报错）且静默无日志——排错先看 `ls /lib/modules/$(uname -r)`。

## 构建与刷机

```bash
# 远程构建机（内核树已编过）：
./kernel/build-kernel-img.sh
# 产物默认 build/kernel.img（256M，gitignored；首刷开机由 initrd 自动扩到整个 system 分区），附 md5。

# init/extlinux 改过则重打 system 镜像（initrd 先就位）：
(cd boot/initrd && ./build.sh ../initrd.cpio.gz) && ./kernel/build-kernel-img.sh

# 刷机（fastboot）：
fastboot flash system kernel.img && fastboot reboot
```

注意：刷 system 会清空该分区原厂数据（Android 侧已无用）

## 验证（进系统后，WiFi 或 USB 任一 shell）

```bash
uname -r; ls /lib/modules/$(uname -r) | head
dmesg | grep -E "sysmod|kmod store"
cat /sys/class/power_supply/qcom-battery/charge_full_design  # 期望 3120000
lsmod | grep -E "ath10k_snoc|qcom_fg|qcom_smbx"
sudo sirius-otg status
```

## rootfs 侧配合

- rootfs 里旧 `/lib/modules/*` 保留当 fallback，别删。
- 仓库挂载点开机后在 `/mnt/sysmod`；加内容：重跑 `build-kernel-img.sh` 并 fastboot 重刷 system。
