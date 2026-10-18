# 稳定 MAC（WiFi / 蓝牙钉死）

> 2026-09-26 定稿（蓝牙机制重写，手机冷重启实测通过）。
> 主线驱动读不到出厂 MAC，WiFi 每次重启随机、蓝牙恒为缺省假地址，
> 故钉死自编 LAA，两口味 rootfs 共享同一套做法。

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
分享 rootfs 镜像给别的机器前必须换掉这两个地址，否则撞车。

## 3. 落点（本库改了哪里）

```text
WiFi：rootfs/overlay/etc/systemd/network/10-wlan0.link（udev 层钉死）
蓝牙：firmware/qca/crnv21.bin.sirius → /lib/firmware/qca/crnv21.bin
      （NVM tag 2 烤地址，见 §4；sirius_firmware_pre/post 烤入 + md5）
      rootfs/overlay/etc/systemd/system/bt-addr.service（best-effort 守卫）
rootfs/build-server.sh / build-gnome.sh：apt 加 bluez，各 enable 行加 bt-addr
rootfs/overlay/usr/local/sbin/sirius-bt-auto：只做 power on
```

## 4. 蓝牙：NVM 烤地址（mgmt 路径已证伪）

```text
证伪记录：bt-addr 的 mgmt 改地址在该版 QCA 固件（ubuntu25-crbtfw21.tlv）
上从没成功过——①校验 grep 大小写错；②开电时控制器报 0x0b Rejected；
③固件对 EDL_WRITE_BD_ADDR 假装成功（停 daemon、HCI down、power off
全试过，地址纹丝不动）。内核 DT 的 local-bd-address 与 mgmt 走同一条
vendor 命令，同样无效，故没走内核重编。

定案：btqca 从 qca/crnv21.bin 的 TLV tag 2（EDL_TAG_ID_BD_ADDR）读地址
随 NVM 下发，固件带着该地址启动；驱动核对一致即认定权威
（btqca.c qca_set_bdaddr / quirk 确认路径），全程不依赖写命令。
文件：linux-firmware 原版 crnv21 仅改 6 字节——
  tag 2/len 6 的值在文件偏移 0x14，原厂值 00 07 64 21 90 39，
  改为 LSB-first：02 5E 08 55 57 02（即 02:57:55:08:5E:02）。
  md5 3947c734ced07630d9c2c4ba48f72157，见 MANIFEST.sha256。
注意：当年删 crnv21.bin 是因为 Debian 自带版 + Debian tlv 会让初始化
死在 0x204B（archive/HANDOFF-2026-09-19）。现在 tlv 是 Ubuntu 版，
只回填该 NVM 且仅改 tag 2，一次通过——以后换 tlv 版本必须重验。
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
  用 `pkill -9 -x btmgmt` 精确匹配进程名。同理 pgrep 自匹配要用
  bracket 写法。
- bluetoothctl 显示的地址可能是 BlueZ 缓存假象，以
  `btmgmt info` / `hciconfig` 为准（本次被骗过一次）。
- PowerShell 双引号会吞噬远程命令里的 $？、$2、[...]，
  远程复杂命令一律单引号，见上两条的写法。
- 出厂 MAC、密码、内部机器地址一律不进库；原厂 NVM 值仅作格式
  定位用。WiFi 密码等 NM 连接配置不在本库（sirius-wifi-add 烤）。

## 6. 验证（2026-09-26，手机冷重启，v5）

```text
- WiFi 连续三次重启同一地址，udev 日志 ID_NET_LINK_FILE 生效。
- hci0 冷重启即 02:57:55:08:5E:02，UP RUNNING，
  bt-addr / bluetooth 均为 active，--failed 为空。
- v5 镜像用 debugfs 确认 qca/crnv21.bin 在位。
- 换 MAC 后路由器 DHCP 重分（末段两位变化），要固定 IP 按新 MAC 重做预留。
```

## 7. 相关提交

```text
2af3f74  overlay: bt-addr verify grep -i（表层修复）
0952a68  overlay: bt-addr best-effort（里层确认后止损）
24e659f  server: bake QCA BT NVM（根子定案，v5 生效）
```

## 8. 出厂地址自动应用（2026-10-13，persist 读取，已验证）

不再钉死自编 LAA：出厂地址就在 persist 分区里，
`wlan_mac.bin` 文本 `wlan0=482ca04bc60d`、
`wlan_bt/wlan.mac` 与之一致（`48:2C:A0:4B:C6:0D`），
`wlan_bt/bt.mac`（`48:2C:A0:0B:C6:0D`，LSB-first 即 NVM 字节序）。
persist 为 mmcblk0p68（备份 p69），全程只读挂载。

```text
机制：initrd 新增 apply_persist_macs（boot/initrd/initramfs/
init_functions.sh），跟在 bind_sysmod 后面对新 root 执行：
- WiFi：解析文本地址并校验（12 位 hex、单播、非零），写入
  <新root>/etc/systemd/network/10-wlan0.link；udev 首次见到
  wlan0 即生效，无竞态。
- 蓝牙：校验 bt.mac（6 字节、非零），与 vendor 里 crnv21.bin
  0x14 处比对，有差异才短暂 remount rw 打补丁再改回 ro。
- 幂等：内容一致零写入（实测第二轮启动两条都是 already）；
  任何一步读不到就保留 baked-in LAA（fail-soft）。
- 暂存文件走 /run/persistmac（initramfs 里没有 /tmp，
  曾因此写出 0 字节 link 导致随机 MAC，见下）。
sirius-bt-addr 改为 persist 感知：从 persist 读期望地址（读不到
回落 LAA），与 btmgmt info 当前地址一致直接 VERIFIED，不一致才
public-addr 一次再验。实测开机两次都是 SET 后 VERIFIED。
```

```text
踩坑记录：
- initramfs 无 /tmp：暂存写 /tmp 失败，且 `cat 暂存 > 目标` 的重定向
  会先截断目标——结果是 0 字节 10-wlan0.link，udev 忽略，wlan0 随机
  地址（a6:xx）。修复：暂存改 /run/persistmac，加 -s 非空守卫；
  BT 侧提取失败不再盲打补丁。
- cmp 和 /dev/zero 比永远报 EOF-differ：全零判断改用 dd 取 6 字节
  有限零文件再比。
- btmgmt public-addr 并非如之前所记从没成功：开机时序（pre-config）
  下实测两次 SET complete；系统起来后 power on 状态下报 0x0b
  Rejected。NVM 补丁是否真正被固件采用尚未确证（vendor 文件字节
  已对，但开机仍走了 SET 路径），两层都留着，结论以实测为准。

- NM 扫描随机再改 MAC：`wifi.scan-rand-mac-address` 默认 yes，NM 每次扫描
  把 wlan0 改成随机地址、扫完再改回来（日志 `set-hw-addr ... (scanning)`）。
  实测曾撞见正好停在随机地址上（`7a:..`），DHCP 直接拿错 IP。
  修：`rootfs/overlay/etc/NetworkManager/conf.d/sirius-server.conf` 加
  `[device] wifi.scan-rand-mac-address=no`。MAC 是通过 udev 钉的出厂地址，
  不需要扫描期换 MAC 做隐私。
- 换出厂 MAC 后路由器 DHCP 重分（本次分到 .216），固定 IP 绑定要按
  新 MAC（48:2C:A0:4B:C6:0D）重做，旧 LAA 绑定失效。
```
