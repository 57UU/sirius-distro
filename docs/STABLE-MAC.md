# 稳定 MAC（WiFi / 蓝牙钉死）

> 2026-09-25 定稿，手机实测通过。主线驱动读不到出厂 MAC，
> WiFi 每次重启随机、蓝牙恒为全零假地址，故在 OS 层钉死，
> 两口味 rootfs 共享同一套做法。

## 1. 现象与根因

```text
- WiFi：ath10k_snoc 报 invalid MAC address; choosing random，
  重启一次换一个地址，路由器 DHCP 预留全部失效。
  主线拿不到出厂地址：BDF 校准文件里没有，设备树没有 mac-address，
  安卓靠基带/NV 传递的那条路主线没打通。
- 蓝牙：btqca 缺省 BD 00:00:00:00:5A:AD，所有没修的主线机都一样，
  同网撞车，部分对端直接拒绝。
```

## 2. 地址（自编 LAA，与任何真机 OUI 不撞）

```text
wlan0  02:57:55:08:5E:01   （02 开头为本地管理单播；57U/8SE 谐音好记）
hci0   02:57:55:08:5E:02
```

出厂地址仍在本地 persist 备份里，本次有意不用、不进库。
此前本库误烤过出厂地址，已替换为上表自编地址。

## 3. 落点（本库改了哪里）

```text
rootfs/lib/sirius-device.sh  sirius_overlay()(静态文件在 rootfs/overlay/)：
  /etc/systemd/network/10-wlan0.link       udev 层钉 wlan0
  /etc/systemd/system/bt-addr.service      开机改 hci0 公有地址
rootfs/build-server.sh                     apt 加 bluez，各 enable 行加 bt-addr
rootfs/build-gnome.sh                      enable 行加 bt-addr
rootfs/overlay/usr/local/sbin/sirius-bt-auto  只做 power on
```

## 4. bt-addr 流程（Before=bluetooth，趁 daemon 未启动改 virgin 地址）

```text
daemon 未启动前改地址，改完它正常启动即带新地址，全程不 stop/start daemon。
等 hci0 出现加 settle → 改地址（带重试）→ 校验地址存在即成功。
任一步失败都不挡开机（蓝牙回落缺省地址，看 journal 定位）。
v6 曾用 After 加 stop/set/start，在 GNOME 首启撞上 daemon 初始化竞态
（1 秒大的 daemon 被 stop，中断其固件流程，后续 set 被默认值覆盖），故退回 virgin 路径。
```

## 5. 教训（每一条都是实测换来的）

- btmgmt 在 stdin 为 /dev/null 时 hang 死：实测 6 秒零输出，
  无视 SIGTERM，只能 SIGKILL。systemd unit 默认 stdin 就是 null，
  所以 unit 里裸调 btmgmt 必卡，还曾连带卡住 bluetooth 启动。
  修复：`sleep 4 | timeout -s KILL 3 btmgmt ... info` 喂一个常开
  无数据的 stdin，并统一用 `timeout -s KILL` 兜底。
- 禁止在 daemon 运行时用 `btmgmt power off/on` 拨弄控制器：
  WCN3990 上观察到刚改好的地址被重置回缺省。启停一律走
  `systemctl stop/start bluetooth`。
- `pkill -f btmgmt` 会杀掉自己的 shell（命令行里也含 btmgmt），
  用 `pkill -9 -x btmgmt` 精确匹配进程名。
- PowerShell 下写远程 heredoc：单引号、dollar 符、反引号都会被层层转义，
  unit 正文只用双引号加字面数字列表才一次写对。unit 以手机实物为准，
  本库只做字节级同步，不手搓。
- stop/set/start 只在 daemon 完全 steady 时可用；开机时 daemon 年龄不可控，
  一律走 virgin 路径。daemon 初始化中的 stop 会打断固件流程。

## 6. 验证（2026-09-25，手机）

```text
- WiFi 连续三次重启同一地址，连回 HexGing，
  udev 日志 ID_NET_LINK_FILE=/etc/systemd/network/10-wlan0.link。
- bt-addr 在干净启动下走完 stop/set/start，hci0 地址正确，
  UP RUNNING，daemon 存活。入库的最终版另加了重试校验循环
  （只涉及 grep 与 sleep），随下次启动确认。
- 换 MAC 后路由器 DHCP 重分（末段两位变化），要固定 IP 按新 MAC 重做预留。
```

## 7. 注意事项

- 分享 rootfs 镜像给别的机器前必须换掉这两个地址，否则撞车。
- 出厂 MAC、密码、内部机器地址一律不进库。
- WiFi 密码等 NM 连接配置不在本库（首次开机用 sirius-wifi-add 烤）。
