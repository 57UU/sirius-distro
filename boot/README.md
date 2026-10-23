# boot：U-Boot 启动镜像（脚本进库，产物进 Releases）

只维护 U-Boot 启动链，不再维护 ABL 直启（boot/build_boot.sh 已删除）。

- U-Boot 源码：`../uboot`（57UU/u-boot submodule），构建：`../uboot/sirius-build.sh`（统一入口 `./build.sh boot`；
 中间件落 `workspace/build/uboot/`）
 （`qcom_defconfig + qcom-phone.config + sirius.config`，`DEVICE_TREE=qcom/sdm710-xiaomi-sirius`）。
- 产物 `boot.img`（gzip nodtb + sirius dtb，经 mkbootimg 打包），刷入 boot 分区：
  `fastboot flash boot boot.img && fastboot reboot`
- 默认走 EFI：U-Boot 从 system 分区（mmcblk0p79，U-Boot 视角 `mmc 0:4f`）加载
  `/boot/efi/BOOTAA64.EFI` + `/boot/initrd.cpio.gz` + `/boot/dtb/sdm710-xiaomi-sirius.dtb`；
  失败回落到 sysboot 读 `/boot/extlinux/extlinux.conf`（本目录的同名文件是其模板）。
- **内核命令行唯一来源是本目录的 `bootargs`**：`build.sh boot` 把它替换进 U-Boot 默认环境的
  `efi_args`，`build-kernel-img.sh` 把它替换进 `extlinux.conf` 的 `@BOOTARGS@`。改 root/分区参数只改这里。
- `initrd/`：initramfs 源（RNDIS 早联网 + 挂载 rootfs/system 后 switch_root，打包进 system 分区 /boot）。
