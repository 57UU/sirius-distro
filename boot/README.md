# boot：启动镜像组装（脚本进库，产物进 Releases）

`build_boot.sh` 用同源 `Image.gz` + `sdm710-xiaomi-sirius.dtb` 打出
`boot_sys.img`（进系统版，唯一的刷机用 boot 镜像）.

- cmdline 唯一真源就是脚本里的 `BASE` 行。当前：
  `loglevel=6 earlycon=tty0 earlyprintk root=/dev/mmcblk0p81
  rootfstype=ext4 rootwait=15 rootfs_part=mmcblk0p81 rw consoleblank=120`
- 内核与 dtb 来自 `../kernel`（57UU/linux-sirius `feat/sirius-7.2` 编出，
  拷到本目录再跑脚本）。
- 只刷 `boot` 分区：`fastboot flash boot boot_sys-*.img`。
  兜底镜像见 Releases（`KNOWN-GOOD` 说明随包）。
- `initrd/`：initramfs 源（RNDIS 早联网 + 挂载 rootfs 后 switch_root）。