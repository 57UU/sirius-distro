# sirius U-Boot 启动链（v2.0+）

U-Boot 源码见 `../uboot`（`57UU/u-boot` `sirius/v2.0`），构建入口 `./build.sh boot`（产物 `build/boot.img`，中间目录 `workspace/build/uboot/`）。

## 1. 启动链

```text
PBL → XBL → ABL（官方 fastboot）
  └─ boot 分区：U-Boot（boot.img）
       ├─ EFI 直启（默认）：/boot/efi/BOOTAA64.EFI + initrd + dtb → bootefi
       └─ 回落 sysboot：mmc 0:4f（p79 system）→ /boot/extlinux/extlinux.conf
            → /boot/Image + initrd.cpio.gz + dtb → Linux（root=/dev/mmcblk0p81）
```

- ABL 直启已退役；**`dtbo` 分区必须清空**（`fastboot erase dtbo`），否则留存的 stock dtbo 会阻断启动。

## 2. 构建配方（`uboot/sirius-build.sh`）

```bash
make O=$OUT qcom_defconfig qcom-phone.config sirius.config
make O=$OUT -j$JOBS DEVICE_TREE=qcom/sdm710-xiaomi-sirius \
     CONFIG_ENV_DEFAULT_ENV_TEXT_FILE=<由 boot/bootargs 渲染的 env 副本>
gzip -c u-boot-nodtb.bin > u-boot-nodtb.bin.gz
cat u-boot-nodtb.bin.gz sdm710-xiaomi-sirius.dtb > uboot-payload
mkbootimg --kernel_offset 0x00008000 --pagesize 4096 --kernel uboot-payload -o boot.img
```

- 勿传 `ARCH=arm64`（会报 `asm/config.h` 错）；`CROSS_COMPILE` 在 x86_64 主机用 `aarch64-linux-gnu-`。
- payload 必须为 `gzip(nodtb) + dtb`（直接用 `u-boot.bin` 会导致 `fastboot boot` 返回 OKAY 但黑屏不启）。
- **cmdline 单一来源**：`boot/bootargs` 同时渲染进 U-Boot `efi_args` 与 `boot/extlinux.conf` 的 `@BOOTARGS@`，改分区参数只改一处。

## 3. 环境变量与设备树要点

- **`sirius.env`**：`preboot=scsi scan; mmc rescan; usb start`（缺 `mmc rescan` 则扫不到盘）；`mmc 0:4f` 为**十六进制**（`0x4f` = 79）；不用 `bootflow scan -b`（`MAX_PART_PER_BOOTDEV=30` 写死，扫不到 p79/p81）。
- **设备树（`sdm710-xiaomi-sirius.dts`，基于 pyxis）**：framebuffer `1080×2240`；eMMC `sdhc_1` 开 `HS400`（`vmmc=l8b_3p3`、`vqmmc=l5b_1p8`，**必须 1.8V**）；关闭 `UFS` 与 `SDHC_2`。

## 4. 测试与刷机

```bash
fastboot boot build/boot.img                            # 仅进内存试跑（vidconsole 输出日志）
fastboot flash boot build/boot.img && fastboot reboot   # 确认后落盘
```

- 进入系统后确认：`cat /proc/cmdline` 含 `sysmod_part=mmcblk0p79`，`mount | grep sysmod` 为 p79。
- **已知限制**：熄屏/电源键在 U-Boot 下无效（卡住长按电源强重启）；`Loading Boot0001 failed` 属正常（无 ESP）。
- **刷机一律走 ABL fastboot（音量下 + 电源）**：U-Boot 自带 fastboot 存在 `dwc3` `ep1in-bulk` 丢包与 A/B 分区名错配（找 `boot_a`）问题，不可用于刷机；bootmenu（开机 1s 内按音量键进入）内的 `Enable fastboot mode`（`VID_18D1&PID_4EE0`，Windows 需手动选 WinUSB ADB 驱动）仅作调试。
