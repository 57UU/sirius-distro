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

- ABL 直启已退役（`boot/build_boot.sh` 已删）。dtbo 分区必须清空（`fastboot erase dtbo`，实测留着 stock dtbo 会起不来：ABL 交接前仍会碰它）。
- vendor 分区（mmcblk0p80）已清空为 spare，仓库内容住 system 分区，见 `KERNEL-IMG-STORE.md`。

## 2. 构建（`uboot/sirius-build.sh`）

配方（照 tauchgang/pyxis 参考流程，适配 sirius）：

```bash
make O=$OUT qcom_defconfig qcom-phone.config sirius.config
make O=$OUT -j$JOBS DEVICE_TREE=qcom/sdm710-xiaomi-sirius
gzip -c u-boot-nodtb.bin > u-boot-nodtb.bin.gz
cat u-boot-nodtb.bin.gz sdm710-xiaomi-sirius.dtb > uboot-payload
mkbootimg --kernel_offset 0x00008000 --pagesize 4096 --kernel uboot-payload -o boot.img
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

1. `fastboot boot boot.img`（只进内存，不刷机，挂了重启就回来）。
2. 看屏幕：U-Boot 日志直接打在显示屏上（vidconsole）。`sysboot` 会打印读 conf 和加载三件套，成功则进内核 earlycon 日志。
3. 进系统后看 `cat /proc/cmdline` 有 `sysmod_part=mmcblk0p79` 即走的 U-Boot/extlinux 路径；`mount | grep sysmod` 应为 p79。
4. 确认无误再落盘：`fastboot flash boot boot.img && fastboot reboot`（eMMC 慢，写完等一会儿）。

失败时屏幕就是诊断器：`Invalid partition 128`→分区号进制错；`bootflow ... efi_mgr ... failed`→没扫到盘（查 preboot/sysboot）；UFS 报错→dts 里没关干净；`Loading Boot0001 failed`→`bootefi bootmgr` 找不到 ESP，正常（sysboot 成功就不会走到它）。

## 6. 已知限制

- `bootflow scan` 扫不到 30 号以后的分区，不要用它找内核。
- 熄屏/电源键在 U-Boot 下不管用，卡住就长按电源强制重启（boot 分区没刷坏就还能进，原系统不受影响；刷坏了进 fastboot 重刷）。

## 7. U-Boot fastboot 直刷（`sirius-reboot`，2026-10-16 验证可用）

U-Boot 自带 fastboot（`CONFIG_USB_FUNCTION_FASTBOOT` + `FASTBOOT_FLASH`），但实测刷机失败（见本节末尾结论），目前仅进 fastboot 验证可用，刷机仍走 ABL fastboot。
system/userdata 不用回 ABL，直接在这里刷。`sirius.env` 里 `fastboot=fastboot usb 0`
（用编译进的默认缓冲地址；带 `$fastboot_addr_r` 空变量的旧写法已删）。

进入方式（三选一）：

- `sudo sirius-reboot fastboot`（推荐）：往 misc 分区写 BCB 命令后重启，
  U-Boot `check_bcb` 读到就进 fastboot；`sudo sirius-reboot menu` 进 bootmenu。
  BCB 用完即清（读→清→存回），下次正常开机；未知命令直接正常启动。
  注意 systemd 的 `reboot` 传不了参数，所以必须走这个 helper。
- bootmenu 第 2 项 `Enable fastboot mode`（开机 1 秒内按音量键打断 autoboot）。
- 按键：`BOOTDELAY=1` + `button-kbd`，超时自动进系统。

屏幕看着像"冻住"（重要）：屏本身是活的（vidconsole 照常刷新），但 fastboot 模式**本身静默**（等 USB 命令，不打屏），所以一直停在
`autoboot: 0` 那一帧——不是卡死。以电脑端为准：
设备管理器冒出 `USB download gadget` 即已进入。

Windows 驱动：gadget 是 `VID_18D1&PID_4EE0`，Google 驱动只认 ABL 的 `D00D`，
绑不上。手动装：设备管理器 → USB download gadget → 更新驱动程序 →
浏览我的电脑 → 从列表选取 → 按实测可选 **WinUSB 厂商的 ADB 设备**
（装完 `fastboot devices` 出设备，`getvar version` 回 `0.4`）。


实测结论（2026-10-16）：U-Boot fastboot 目前**不可用于刷机**，只保留进 fastboot 验证过，退回 ABL fastboot 刷机：
- `fastboot flash boot`（596KB）即失败：`AdbWriteEndpointSync failed (121)`，host 端超时；随后 gadget 挂死，`getvar` 也不回。
- 屏上刷屏 `dwc3-generic-peripheral usb@a600000: request ... was not queued to ep1in-bulk`（IN 回包队列丢包，偶发变必现）。
- 更深一层：屏上还出现 `Bad device specification mmc boot_a` / `Couldn't find partition mmc boot_a`——U-Boot fastboot 按 Android A/B 逻辑找 `boot_a`，而本机 GPT 用的是无后缀名（boot/system/userdata），即使下载成功也会落空。
- 疑似诱因有二待查：`FASTBOOT_BUF_ADDR=0x1A000000` 在 sirius 上可能不是可写内存（download 一写就 abort）；dwc3 gadget 本身不稳。
- 屏上半截还叠了 MI logo + 花屏：疑似失败传输后反复重启/帧缓冲重叠。恢复：长按电源硬重启（BCB 为空则正常进系统）；fastboot 相关验证先冻结，不再试刷。

已知告警（2026-10-16 实测）：屏上偶见 `dwc3-generic-peripheral usb@a600000: request ... was not queued to ep1in-bulk`，即一次 USB IN 回包被丢弃。小包（`getvar`）连打 8 次全过，大包传输（256MB system）尚未验证，刷完务必重启进系统验 md5/功能，不要假设一次成功。

刷机（eMMC 慢，后台跑完再 `fastboot reboot`，见 AGENTS.md 刷机节）：

```bash
fastboot flash system kernel.img && fastboot reboot
fastboot flash userdata xxxx.simg && fastboot reboot
```