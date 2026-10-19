# sirius U-Boot 启动链（v2.0 起唯一启动方式）

> 2026-10-14 定稿，已上机验证。U-Boot 源码见 `../uboot`（57UU/u-boot `sirius/v2.0`），一键构建 `../uboot/sirius-build.sh`。

## 1. 启动链

```text
PBL（ROM）→ XBL → ABL（官 fastboot 仍在，只做下载/启动跳转）
  └─ boot 分区：U-Boot（`boot.img`）
      └─ sysboot 直读 system 分区（mmcblk0p79，U-Boot 视角 `mmc 0:4f`）
          `/boot/extlinux/extlinux.conf` → `/boot/Image` + `/boot/initrd.cpio.gz` + `/boot/dtb/*.dtb`
              └─ Linux（root=/dev/mmcblk0p81 userdata）
```

- ABL 直启已退役（`boot/build_boot.sh` 已删）；dtbo 分区必须清空 `fastboot erase dtbo`（留 stock dtbo 起不来）。
- vendor 分区（mmcblk0p80）清空为 spare；仓库住 system 分区，见 `KERNEL-IMG-STORE.md`。

## 2. 构建（`uboot/sirius-build.sh`）

配方：

```bash
make O=$OUT qcom_defconfig qcom-phone.config sirius.config
make O=$OUT -j$JOBS DEVICE_TREE=qcom/sdm710-xiaomi-sirius
gzip -c u-boot-nodtb.bin > u-boot-nodtb.bin.gz
cat u-boot-nodtb.bin.gz sdm710-xiaomi-sirius.dtb > uboot-payload
mkbootimg --kernel_offset 0x00008000 --pagesize 4096 --kernel uboot-payload -o boot.img
```

- `qcom_defconfig + qcom-phone.config`：带 `PANIC_HANG`、console record、`FASTBOOT_BUF_ADDR=0x1A000000`、`BUTTON_REMAP_PHONE_KEYS`；勿用手写 `xiaomi-sirius_defconfig`（已删，缺这些）。
- `sirius.config`（`board/xiaomi/sirius/`）：比上游多三行 `BLKMAP`、`CMD_BLKMAP`、`ENV_DEFAULT_ENV_TEXT_FILE`→`sirius.env`。
- payload 必须 `gzip(nodtb)+dtb`；用 `u-boot.bin` 当 kernel → `fastboot boot` 回 OKAY 但没起。
- `mkbootimg` 参数照抄参考；`ARCH=arm64` **不要传**（源码无 `arch/arm64` → `asm/config.h` 报错）；CROSS_COMPILE 保持 `aarch64-linux-gnu-`。

## 3. 环境变量（`board/xiaomi/sirius/sirius.env`）

```text
preboot=scsi scan; mmc rescan; usb start      # 缺 mmc rescan 则 bootflow 啥也扫不到
kernel_addr_r=0x80080000                       # Image（37M）
ramdisk_addr_r=0x83000000                      # initrd
fdt_addr_r=0x82a00000                            # dtb
scriptaddr=0x82800000                            # extlinux.conf 加载地址
do_boot=sysboot mmc 0:4f any ${scriptaddr} /boot/extlinux/extlinux.conf; bootefi bootmgr
bootcmd=run do_boot
```

- `mmc 0:4f`：分区号**十六进制**，`4f`=79=system；写 `0:80` 被当成 `0x80`=128 → `Invalid partition 128`。
- 不用 `bootflow scan -b`：每盘只扫前 30 分区（`MAX_PART_PER_BOOTDEV=30` 写死），p79/p80 扫不到；`qcom_defconfig` 的 `BOOTDEV_*` 只有 ETH、无 MMC hunter。sysboot 直指分区最稳。
- `extlinux.conf` 源在主库 `boot/extlinux.conf`，`build-kernel-img.sh` 连同 Image/dtb/initrd 打进 system 镜像 `/boot`。

## 4. 设备树（`dts/upstream/src/arm64/qcom/`）

- `sdm710.dtsi + sdm710-xiaomi-pyxis.dts`：搬自 `https://gitlab.postmarketos.org/ellyq/u-boot` 分支 `release/v2026.04` commit `545daab1`。
- `sdm710-xiaomi-sirius.dts`（pyxis 改）：framebuffer `1080x2240`（pyxis 是 2340）；eMMC 在 `sdhc_1` 开 `HS400`（`vmmc=l8b_3p3`、`vqmmc=l5b_1p8`，pyxis 那路 LDO5 是 2.95V、sirius 必须 1.8V）；`UFS` 关（sirius 无 UFS 硬件）；`SDHC_2`（MicroSD）保持关。

## 5. 上机测试流程

1. `fastboot boot boot.img`（只进内存、不刷机、挂了重启即回）。
2. 屏幕即日志：U-Boot 输出打屏（vidconsole），`sysboot` 打印读 conf + 加载三件套，成功进内核 earlycon。
3. `cat /proc/cmdline` 有 `sysmod_part=mmcblk0p79` 即走 U-Boot/extlinux；`mount | grep sysmod` 应为 p79。
4. 确认后落盘：`fastboot flash boot boot.img && fastboot reboot`（eMMC 慢，写完等一会儿）。

失败屏幕即诊断器：`Invalid partition 128`→分区号进制错；`bootflow ... efi_mgr ... failed`→没扫到盘；UFS 报错→dts 没关干净；`Loading Boot0001 failed`→`bootefi bootmgr` 找不到 ESP，正常。

## 6. 已知限制

- `bootflow scan` 扫不到 30 号以后的分区。
- 熄屏/电源键在 U-Boot 下不管用，卡住长按电源强制重启（boot 没刷坏就还能进原系统；刷坏进 fastboot 重刷）。

## 7. U-Boot fastboot 直刷（`sirius-reboot`，2026-10-16 验证可用）

U-Boot 自带 fastboot（`CONFIG_USB_FUNCTION_FASTBOOT` + `FASTBOOT_FLASH`），**不可用于刷机**，仅"进 fastboot"验证可用，刷机仍走 ABL fastboot。`sirius.env` 里 `fastboot=fastboot usb 0`（带 `$fastboot_addr_r` 空变量的旧写法已删）。

进入方式（三选一）：

- `sudo sirius-reboot fastboot`（推荐）：写 misc 分区 BCB 后重启，U-Boot `check_bcb` 读到即进 fastboot；`sudo sirius-reboot menu` 进 bootmenu；BCB 用完即清（读→清→存回）。systemd `reboot` 传不了参数，必须走它。
- bootmenu 第 2 项 `Enable fastboot mode`（开机 1 秒内按音量键打断 autoboot）。
- 按键：`BOOTDELAY=1` + `button-kbd`，超时自动进系统。

屏看着像"冻住"属正常：vidconsole 照常刷新，fastboot 模式静默（不打屏），停在 `autoboot: 0` 一帧；设备管理器出现 `USB download gadget` 即已进入。

Windows 驱动：gadget 是 `VID_18D1&PID_4EE0`，Google 驱动只认 ABL 的 `D00D`。手动装：设备管理器 → USB download gadget → 更新驱动 → 浏览我的电脑 → 从列表选取 → 选 **WinUSB 厂商的 ADB 设备**（装完 `fastboot devices` 出设备、`getvar version` 回 `0.4`）。

结论（2026-10-16 起验证冻结、不再试刷）：

- `fastboot flash boot`（596KB）失败：`AdbWriteEndpointSync failed (121)`、host 超时、gadget 挂死、`getvar` 不回。
- 屏上刷屏 `dwc3-generic-peripheral usb@a600000: request ... was not queued to ep1in-bulk`（IN 回包队列丢包，偶发变必现）。
- 更下层 `Bad device specification mmc boot_a` / `Couldn't find partition mmc boot_a`：U-Boot fastboot 按 A/B 找 `boot_a`，本机 GPT 用无后缀名（boot/system/userdata）。
- 疑似诱因：`FASTBOOT_BUF_ADDR=0x1A000000` 可能不可写；dwc3 gadget 不稳。
- 屏上半截 MI logo + 花屏；恢复：长按电源硬重启（BCB 为空则正常进系统）。

告警：`ep1in-bulk` 丢包，小包（`getvar`）连打 8 次全过，大包（256MB system）未验证；刷完务必重启验 md5/功能。

刷机

```bash
fastboot flash system kernel.img && fastboot reboot
fastboot flash userdata xxxx.simg && fastboot reboot
```
