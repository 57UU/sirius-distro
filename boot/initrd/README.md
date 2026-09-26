# initrd目录说明

- initrd/build.sh: 把 initramfs/ 打成 cpio.gz (用法: cd initrd && ./build.sh; mv initrd.cpio.gz ../)
- initrd/initramfs/: cpio根。bin/是busybox全家桶;init/init_functions.sh是RNDIS+udhcpd逻辑。
- initrd 不放任何固件（触屏/GPU 都不需要：RNDIS 早联网，进系统后走 ssh；固件走 rootfs 的 /lib/firmware）。

this module is a forked version from https://gitlab.com/sdm845-mainline/initrd