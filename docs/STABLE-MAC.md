# 稳定 MAC（WiFi / 蓝牙出厂地址与兜底）

主线默认读不到出厂 MAC（`ath10k_snoc` 随机地址、`btqca` 缺省 `00:00:00:00:5A:AD`），因此采用**「从 `persist` 读出厂地址 + 自编 LAA 兜底」**双层机制（LAA：`wlan0 = 02:57:55:08:5E:01`、`hci0 = 02:57:55:08:5E:02`；分发镜像给其他机器前须更换）。

> `persist`（`mmcblk0p68`，备份 `p69`，永久 `ro` 挂载）内出厂文件：`wlan_mac.bin`（`wlan0=482ca04bc60d`）、`wlan_bt/wlan.mac`、`wlan_bt/bt.mac`（6 字节，LSB-first）。

## 1. WiFi（`wlan0`）

- **基础规则**：`glue/network/10-wlan0.link`（随 `kernel.img` 打包，定义匹配、命名与 LAA 备用地址）。
- **工厂 MAC 注入**：`sirius-glue-setup.service` 在 udev 与网络服务前只读挂载 `persist`，生成 `/run/systemd/network/10-wlan0.link.d/50-factory-mac.conf`（仅设置 `MACAddressPolicy=none` 与 `MACAddress=`；读不到时回落基础规则的 LAA）。
- **旧文件迁移与覆盖**：仅当 `/etc/systemd/network/10-wlan0.link` 与旧 initrd 按当前工厂地址生成的内容逐字一致时移除；用户修改的主文件或 `/etc/systemd/network/10-wlan0.link.d/90-user.conf` 保留并优先。
- **防扫描漂移**：`glue/run/NetworkManager/conf.d/sirius-server.conf`（开机链到 `/run`）配置 `wifi.scan-rand-mac-address=no`，防止 NM 扫描时随机改 MAC 导致 DHCP 拿错 IP。

## 2. 蓝牙（`hci0`）

- **NVM 兜底**：`firmware/qca/crnv21.bin.sirius`（→ `/lib/firmware/qca/crnv21.bin`）在 TLV tag 2（偏移 `0x14`，LSB-first）烤入 LAA；initrd 的 `apply_persist_macs` 校验 `bt.mac` 非零后，仅在 `0x14` 处不一致时短暂 `remount rw` 写入并立即恢复 `ro`。
- **运行时校验/下发**：`glue/units/bt-addr.service`（`Before=bluetooth.service`）调用 `sirius-bt-addr`，对比 `btmgmt info` 与出厂地址，不一致时通过 `btmgmt --index 0 public-addr` 下发。

## 3. 踩坑记录

- **`btmgmt` 卡死**：`stdin=/dev/null` 时 `btmgmt` 无视 `SIGTERM` 永久挂起，必须用 `timeout -s KILL` 包装。
- **运行时禁改 power**：`bluetoothd` 运行中执行 `btmgmt power off/on` 会把 WCN3990 地址重置回缺省；启停走 `systemctl stop/start bluetooth`。
- **时序窗口**：`public-addr` 仅在 pre-config 阶段有效（`power on` 后报 `0x0b Rejected`）；`bluetoothctl` 可能显示 BlueZ 缓存假象，以 `btmgmt info` / `hciconfig` 为准。
- **进程匹配**：`pkill -f btmgmt` 会误杀自身 shell，改用 `pkill -9 -x btmgmt`。
