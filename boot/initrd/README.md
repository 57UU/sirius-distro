# initrd（来源与本地修改）

- 上游：https://gitlab.com/sdm845-mainline/initrd.git
- 本地修改见 `LOCAL-CHANGES.diff`（相对上游 HEAD：telnet hang、timeout 修复、sirius 参数，共 +40/-2）。
- 更新上游后如有冲突，以本目录实测为准，diff 重打一份。

# initrd目录说明

- initrd/build.sh: 把 initramfs/ 打成 cpio.gz (用法: cd initrd && ./build.sh; mv initrd.cpio.gz ../)
- initrd/initramfs/: cpio根。bin/是busybox全家桶;init/init_functions.sh是RNDIS+telnet+udhcpd逻辑。
- initrd 不放任何固件（触屏/GPU 都不需要：调试走 RNDIS+telnet，正常启动走 rootfs 的 /lib/firmware）。
