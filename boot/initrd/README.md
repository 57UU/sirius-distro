# initrd目录说明

- initrd/build.sh: 把 initramfs/ 打成 cpio.gz (用法: cd initrd && ./build.sh; mv initrd.cpio.gz ../)
- initrd/initramfs/: cpio根。bin/是busybox全家桶;init/init_functions.sh是RNDIS+telnet+udhcpd逻辑。
- initrd 不放任何固件（触屏/GPU 都不需要：调试走 RNDIS+telnet，正常启动走 rootfs 的 /lib/firmware）。
