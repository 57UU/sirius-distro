# sirius U-Boot 启动链（v2.0 起唯一启动方式）

> 2026-10-14 定稿，已上机验证。U-Boot 源码见 `../uboot`（57UU/u-boot `sirius/v2.0`），一键构建 `../uboot/sirius-build.sh`。

## 1. 启动链

```text
PBL（ROM）→ XBL → ABL（官 fastboot 仍在，只做下载/启动跳转）
  └─ boot 分区：U-Boot（`boot_uboot_extlinux.img`）
      └─ sysboot 直读 system 分区（mmcblk0p79，U-Boot 视角 `mmc 0:4f`）
          `/boot/extlinux/extlinux.conf` → `/boot/Image` + `/boot/initrd.cpio.gz` + `/boot/dtb/*.dtb`
              └─ Linux（root=/dev/mmcblk0p81 userdata）
```

- ABL 直启已退役（`boot/build_boot.sh` 已删）。dtbo 不用擦，U-Boot 路径与它无关。
- vendor 分区（mmcblk0p80）已清空为 spare，仓库内容住 system 分区，见 `KERNEL-IMG-STORE.md`。

## 2. 构建（`uboot/sirius-build.sh`）

配方（照 tauchgang/pyxis 参考流程，适配 sirius）：

```bash
make O=$OUT qcom_defconfig qcom-phone.config sirius.config
make O=$OUT -j$JOBS DEVICE_TREE=qcom/sdm710-xiaomi-sirius
gzip -c u-boot-nodtb.bin > u-boot-nodtb.bin.gz
cat u-boot-nodtb.bin.gz sdm710-xiaomi-sirius.dtb > uboot-payload
mkbootimg --kernel_offset 0x00008000 --pagesize 4096 --kernel uboot-payload -o boot_uboot_extlinux.img
```

- `qcom_defconfig + qcom-phone.config`：上游手机基座，带 `PANIC_HANG`（挂了停在屏上，log 可读）、console record、`FASTBOOT_BUF_ADDR=0x1A000000`、`BUTTON_REMAP_PHONE_KEYS`。不要用手写的 `xiaomi-sirius_defconfig`（已删，缺这些，挂了悄悄复位）。
- `sirius.config`（`board/xiaomi/sirius/`）：相对上游只差三行——`BLKMAP`、`CMD_BLKMAP`、`ENV_DEFAULT_ENV_TEXT_FILE` 指向 `sirius.env`。
- payload 必须是 `gzip(nodtb)+dtb`：ABL 只认这种（内部解压后跳转），直接拿 `u-boot.bin` 当 kernel 会 `fastboot boot` 返回 OKAY 但根本没起，手机还停在 fastboot。
- `mkbootimg` 参数照抄参考即可；`ARCH=arm64` **不要传**（U-Boot 源码没有 `arch/arm64`，传了编出来 `include/asm` 指向空目录，`asm/config.h` 报错）。CROSS_COMPILE 保持 `aarch64-linux-gnu-`。

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

- `mmc 0:4f`：U-Boot 分区号是**十六进制**，`4f`=79=system。写 `0:80` 会被当成 `0x80`=128 → `Invalid partition 128`。
- 不用 `bootflow scan -b`：每盘只扫前 30 分区（`MAX_PART_PER_BOOTDEV=30` 写死），p79/p80 永远扫不到；且 `qcom_defconfig` 的 `BOOTDEV_*` 只有 ETH，没有 MMC hunter。sysboot 直指分区最稳。
- `extlinux.conf` 源在主库 `boot/extlinux.conf`，`build-kernel-img.sh` 会把它和 Image/dtb/initrd 一起打进 system 镜像 `/boot`。

## 4. 设备树（`dts/upstream/src/arm64/qcom/`）

- `sdm710.dtsi + sdm710-xiaomi-pyxis.dts`：从 `https://gitlab.postmarketos.org/ellyq/u-boot` 分支 `release/v2026.04` commit `545daab1` 原样搬运（当时未合入上游），文件头有出处。
- `sdm710-xiaomi-sirius.dts`（pyxis 改）：framebuffer `1080x2240`（pyxis 是 2340）；eMMC 在 `sdhc_1` 上开 `HS400`（`vmmc=l8b_3p3`，`vqmmc=l5b_1p8`——pyxis 那路 LDO5 是 2.95V，sirius 必须 1.8V）；`UFS` 关（sirius 无 UFS 硬件，开着会刷屏报错但不致命）；`SDHC_2`（MicroSD）保持关。

## 5. 上机测试流程

1. `fastboot boot boot_uboot_extlinux.img`（只进内存，不刷机，挂了重启就回来）。
2. 看屏幕：U-Boot 日志直接打在显示屏上（vidconsole）。`sysboot` 会打印读 conf 和加载三件套，成功则进内核 earlycon 日志。
3. 进系统后看 `cat /proc/cmdline` 有 `vendor_part=mmcblk0p79` 即走的 U-Boot/extlinux 路径；`mount | grep vendormod` 应为 p79。
4. 确认无误再落盘：`fastboot flash boot boot_uboot_extlinux.img && fastboot reboot`（eMMC 慢，写完等一会儿）。

失败时屏幕就是诊断器：`Invalid partition 128`→分区号进制错；`bootflow ... efi_mgr ... failed`→没扫到盘（查 preboot/sysboot）；UFS 报错→dts 里没关干净；`Loading Boot0001 failed`→`bootefi bootmgr` 找不到 ESP，正常（sysboot 成功就不会走到它）。

## 6. 已知限制

- `bootflow scan` 扫不到 30 号以后的分区，不要用它找内核。
- 熄屏/电源键在 U-Boot 下不管用，卡住就长按电源强制重启（boot 分区没刷坏就还能进，原系统不受影响；刷坏了进 fastboot 重刷）。
