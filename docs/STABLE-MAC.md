# 稳定 MAC（WiFi / 蓝牙钉死）

> 2026-09-26 定稿（蓝牙机制重写，手机冷重启实测通过）；2026-10-13 起改为从 persist 读出厂地址自动应用（§8）。
> 主线读不到出厂 MAC（WiFi 随机、蓝牙缺省假地址），故先钉死自编 LAA，两口味 rootfs 共用一套做法。

## 1. 现象与根因

```text
WiFi：ath10k_snoc 报 invalid MAC address; choosing random，重启即变，DHCP 预留失效；主线拿不到出厂地址（BDF 无、设备树无 mac-address、安卓基带/NV 未打通）。
蓝牙：btqca 缺省 BD 00:00:00:00:5A:AD，同网撞车，部分对端拒绝。
```

## 2. 地址（自编 LAA，与任何真机 OUI 不撞）

```text
wlan0  02:57:55:08:5E:01   （02 开头为本地管理单播；57U/8SE 谐音好记）
hci0   02:57:55:08:5E:02
```

出厂地址在本地 persist 备份，本次不用、不进库；本库此前误烤已替换为上表。分享 rootfs 镜像给别的机器前必须换掉这两个地址。

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
证伪：bt-addr 的 mgmt 改地址在该版 QCA 固件（ubuntu25-crbtfw21.tlv）从未成功（grep 大小写错、0x0b Rejected、EDL_WRITE_BD_ADDR 假成功）；内核 DT local-bd-address 同路径无效。
真因：btqca 从 qca/crnv21.bin 的 TLV tag 2（EDL_TAG_ID_BD_ADDR）读地址随 NVM 下发，驱动核对即认定（btqca.c qca_set_bdaddr / quirk）。
改法：原版 crnv21 仅改 6 字节——tag 2/len 6 值在偏移 0x14，原厂 00 07 64 21 90 39 → LSB-first 02 5E 08 55 57 02；md5 3947c734ced07630d9c2c4ba48f72157（MANIFEST.sha256）。
坑：删 crnv21.bin 因 Debian tlv 初始化死在 0x204B（archive/HANDOFF-2026-09-19）；Ubuntu tlv＋仅改 tag 2 一次通过，换 tlv 须重验。
```

## 5. 教训

- btmgmt 在 stdin=/dev/null 时 hang 死（实测 6s 零输出、无视 SIGTERM，只能 SIGKILL）；systemd unit 默认 stdin=null，裸调必卡。修复：`sleep 4 | timeout -s KILL 3 btmgmt ... info`，统一用 `timeout -s KILL`。
- 禁止 daemon 运行时用 `btmgmt power off/on`：WCN3990 上地址被重置回缺省。启停走 `systemctl stop/start bluetooth`。
- `pkill -f btmgmt` 会杀掉自己的 shell，用 `pkill -9 -x btmgmt` 精确匹配；pgrep 自匹配用 bracket 写法。
- bluetoothctl 显示的地址可能是 BlueZ 缓存假象，以 `btmgmt info` / `hciconfig` 为准。
- PowerShell 双引号会吞噬远程命令里的 $？、$2、[...]：远程复杂命令一律单引号。
- 出厂 MAC、密码、内部机器地址不进库；原厂 NVM 值仅作格式定位。WiFi 密码等 NM 连接配置不在本库（sirius-wifi-add 烤）。

## 6. 验证（2026-09-26，手机冷重启，v5）

```text
- WiFi 连续三次重启同一地址，udev 日志 ID_NET_LINK_FILE 生效。
- hci0 冷重启即 02:57:55:08:5E:02，UP RUNNING，bt-addr / bluetooth 均 active，--failed 为空。
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

出厂地址在 persist（mmcblk0p68，备份 p69，只读挂载）：`wlan_mac.bin` 文本 `wlan0=482ca04bc60d`、`wlan_bt/wlan.mac`（`48:2C:A0:4B:C6:0D`）、`wlan_bt/bt.mac`（`48:2C:A0:0B:C6:0D`，LSB-first 即 NVM 字节序）。

```text
机制（boot/initrd/initramfs/init_functions.sh 新增 apply_persist_macs，跟 bind_sysmod 后对新 root 执行）：
- WiFi：校验文本地址（12 位 hex、单播、非零）→ 写 <新root>/etc/systemd/network/10-wlan0.link，udev 首见 wlan0 即生效。
- 蓝牙：校验 bt.mac（6 字节、非零），与 vendor crnv21.bin 0x14 处比对，有差异才短暂 remount rw 打补丁再改回 ro。
- 幂等：一致零写入（实测第二轮两条都是 already）；读不到保留 baked-in LAA（fail-soft）。
- 暂存走 /run/persistmac（initramfs 无 /tmp）。
sirius-bt-addr 改 persist 感知：与 btmgmt info 当前址一致直接 VERIFIED，不一致才 public-addr 一次再验；实测开机两次均 SET 后 VERIFIED。
```

```text
踩坑：
- initramfs 无 /tmp：`cat 暂存 > 目标` 重定向先截断目标 → 0 字节 10-wlan0.link，udev 忽略，wlan0 随机地址（a6:xx）。修复：暂存改 /run/persistmac + `-s` 非空守卫；BT 提取失败不盲打补丁。
- cmp 与 /dev/zero 比永远报 EOF-differ：全零判断改用 dd 取 6 字节有限零文件再比。
- btmgmt public-addr 并非从没成功：开机时序（pre-config）下实测两次 SET complete；power on 下报 0x0b Rejected。NVM 补丁是否被固件采用未确证，两层都留，以实测为准。
- NM 扫描随机改 MAC：`wifi.scan-rand-mac-address` 默认 yes，扫描时改 wlan0 随机地址、扫完改回（日志 `set-hw-addr ... (scanning)`），实测撞停随机址（`7a:..`）致 DHCP 拿错 IP。修：`rootfs/overlay/etc/NetworkManager/conf.d/sirius-server.conf` 加 `[device] wifi.scan-rand-mac-address=no`。
- 换出厂 MAC 后路由器 DHCP 重分（本次 .216），固定 IP 绑定按新 MAC（48:2C:A0:4B:C6:0D）重做，旧 LAA 绑定失效。
```
