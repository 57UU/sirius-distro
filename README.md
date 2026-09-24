# sirius-distro

小米 8 SE（sirius / sdm710）Linux 发行工程：把内核变成能用的系统。
内核源码在 [57UU/linux-sirius](https://github.com/57UU/linux-sirius)（分支 `feat/sirius-7.2`），
本仓库只收**集成产物**：启动组装、固件、rootfs、服务、文档。

```text
boot/       boot.img / boot_sys.img 组装脚本（cmdline 唯一真源）+ initrd
firmware/   设备固件（自研小件直接入库；modem 大包见 pyxis-phone/README）
rootfs/     rootfs 烘焙：overlay（开机会拷进 / 的文件）+ 构建脚本
src/        自研源码（sirius-remodeset）；第三方源码只留获取说明
orbital/    上游仪表盘（获取说明，不 vendor 源码）
kernel/     上游内核引用（获取说明 + 需要的产物清单）
docs/       运维文档（过程性交接记录不进库，另行归档）
```

二进制大镜像（`*.simg` `*.tar.zst` `boot_*.img`）不进 git，走 GitHub Releases。
基带备份（modemst/persist 等）不进 git，本地留存。

本库是唯一真源：构建只读本库 + 上游引用，不依赖任何内部机器。