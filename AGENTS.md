# AI Policy
如果用户没有明确说明commit push，请不要私自commit，用户可能会自己验收。

无需sha校验码，不用校验文件。

## Forbidden

禁止write手机persist、modem 等不可恢复分区，只允许只读挂载。

# Fastboot 刷机

使用flash,reboot命令时设备可能在写emmc，很慢，假死是正常现象。等待十几分钟就好，不要强制停止。

刷机的时候使用形如如下的命令，在最后面接上fastboot reboot放入后台shell执行。不需要busy waiting。
```sh
fastboot flash boot xxx.img && fastboot flash userdata xxx.simg && fastboot reboot
```

# locations

- boot,system,rootfs打包得到最终的 img/simg 产物应当移动到:build/ 下
- 中间产物（initrd、U-Boot 构建目录、rootfs 工作树、SIRIUS_BASE 原始树、临时目录）统一放 workspace/build/ 下；构建走仓库根 ./build.sh <target>，不要在别处新建临时目录

工作区：如果当前目录存在workspace/ 文件夹，直接去里面工作，如果不存在，则自行创建文件夹。.gitignore已经加入了，不用担心污染git仓库。

# SSH 连手机

- USB 直连：ssh u57u@172.16.42.1；（默认密码 1234）或让用户链接wifi后告知ip地址
- 首次/重刷后先铺 key，以后免密码：WSL 里跑 ./scripts/sirius-ssh-init.sh user@host pubkey（需 sshpass）
- 重刷后 host key 会变，连不上先清旧 key，再重连