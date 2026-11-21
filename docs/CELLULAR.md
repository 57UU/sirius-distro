# 蜂窝 bringup（基带 + SIM + LTE 数据）

状态：**LTE 信令与单卡数据均可用**（电信卡实测注册 CHN-CT、`qmapmux0.0` 拿 IP 正常）。检查命令：`sudo mmcli -m any | grep -E 'state|access tech|operator|packet service'`。

## 1. 启动链路

```text
modem 分区 mmcblk0p76（192M FAT，NON-HLOS 固件包）
  └── remoteproc2 (q6v5-mss, 4080000) ← /lib/firmware/qcom/sdm710/pyxis/（与原厂 NON-HLOS md5 一致）
        ├── rmtfs      ← /var/lib/rmtfs/ 4 项软链（modem_fs1/fs2/fsc/fsg → modemst1/2, fsc, fsg）
        ├── tqftpserv  ← PD 文件传输
        └── pd-mapper  ← PD 域映射
              ↓
ModemManager（qcom-soc 插件，需 /dev/qrtr0 节点 + UIM provisioning session）
  └── NetworkManager（cellular.nmconnection）→ Bearer → qmapmux0.0（QMAP mux over rmnet_ipa0）
```

- **rmtfs 已知噪音**：`request for unknown partition '/boot/modem_fsg_oem_1', rejecting` 属正常（分区表硬编码），勿修。
- **IPA 限制**：主线 `ipa_modem.c` 无 mux 层，手工 `ip link add ... type rmnet` 不通，多路 mux 仅走 ModemManager 的 QMAP。

## 2. 必踩的坑与边界

| 问题 | 根因 | 处理方式 |
|---|---|---|
| `SimFileNotFound` | 套用了通用 USIM AID 模板（第 12 字节 `FF`） | 先跑 `qmicli --uim-get-card-status` 抄真实 `Application ID`（如电信卡第 12 字节为 `03`） |
| `sim-missing` / `GW primary session index unknown` | 卡上电后仅 `detected`，MM 不会建 provisioning session；`qmicli --uim-change-provisioning-session` 先 power-off 报 `QMI error 3 'Internal'` | 用 `uimsel` 直调 libqmi 跳过 power-off：`sudo env UIMSEL_AID=<AID> UIMSEL_ST=0 uimsel 1`（`ST=0` Primary GW；`ST=1` 1X；`DEACT=1` 撤销） |
| MM 放弃 modem（`No modems were found`） | MM 初始化检查 `/dev/qrtr0`，而 QRTR 走 socket 无设备节点 | `sudo ln -sf /dev/null /dev/qrtr0 && sudo systemctl restart ModemManager` |
| 纯 `qmicli` 拉不起数据面 | libqmi 1.36 缺 `WDS BindSubscription`，且 `--client-cid` 不可跨进程 | 走 ModemManager，勿用纯 qmicli |
| **双卡不工作（不支）** | UIM 可认双卡，但 MM `qcom-soc` 在双 active slot 下反复 `enabled → disabling` 重建 | **只插单卡**；拔到单卡后 `sirius-modem-uim` 自动恢复 |
| 物联网卡 `searching` 循环 | 归属 PLMN（如 46015）无小区被拒，卡死搜网 | 临时指定网络：`sudo mmcli -m 0 --3gpp-register-in-operator=46000`（勿固化进 NM 配置） |

## 3. 正式方案：NetworkManager + 自动脚本

### NetworkManager 配置

`glue/run/NetworkManager/system-connections/cellular.nmconnection`（开机链到 `/run/NetworkManager/system-connections/`，**必须 `root:0600`** 否则 NM 静默忽略）：

```ini
[connection]
id=cellular
type=gsm
interface-name=qrtr0

[gsm]
auto-config=true          # 按 MCC/MNC 查 mobile-broadband-provider-info，换卡免改

[ipv4]
method=auto
[ipv6]
method=auto
```

### 自动化单元（围绕幂等脚本 `sirius-modem-uim`）

| 单元 | 触发时机 | 职责 |
|---|---|---|
| `sirius-modem-uim.service` | 开机（`Before=ModemManager`） | 读卡 → 取 AID → 建 primary-gw 会话 → 按需恢复 MM |
| `sirius-modem-uim.timer` | 每 60s | 事件丢失兜底 |
| `sirius-modem-uim-watch` | 常驻（`Restart=always`） | 订阅 UIM `card-status`/`slot-status`，变化时直接 exec 同一脚本 |

- **并发与时序**：脚本入口带 `flock` 防拔插并发；卡 `present` 但应用列表为空时重试最多 10s；开机等 modem 最多 40s（单调时间）。
- **MM 恢复与冷却**：MM 取得总线名后有 90s 宽限等待导出 modem 对象；仅在已有有效 SIM 会话但报 `sim-missing` 或宽限超时仍无对象时重启 MM（60s 冷却记 `/run/sirius-modem-uim.monotonic`）。

## 4. 手工拉起（排障用）

```sh
systemctl is-active qrtr-ns rmtfs tqftpserv pd-mapper
sudo ln -sf /dev/null /dev/qrtr0
sudo qmicli -d qrtr://0 --dms-set-operating-mode=online
sudo env UIMSEL_AID=<卡上的 usim AID> UIMSEL_ST=0 uimsel 1
sudo systemctl restart ModemManager
sudo mmcli -m any --simple-connect=apn=ctnet,ip-type=ipv4
sudo mmcli -b 1   # 查 address / prefix / gateway / mtu
sudo ip addr add <address>/<prefix> dev qmapmux0.0
sudo ip link set qmapmux0.0 up mtu 1410
sudo ip route replace default via <gateway> dev qmapmux0.0 metric 700
ping -I qmapmux0.0 223.5.5.5   # 注：运营商网关通常不回 ping
```

## 5. 危险操作（会导致整机硬死机）

| 禁止操作 | 后果 |
|---|---|
| `systemctl restart rmtfs`（modem 运行中） | 系统冻死，只能长按电源 |
| `echo stop > /sys/class/remoteproc/remoteproc2/state` | 系统冻死 |
| 基带运行时挂载/遍历 `modem` 分区（`p76`） | AP 与基带争抢存储，硬挂死 |

重启基带只能整机重启（SSH 可用时执行 `sync && reboot -f` 绕开 rmtfs stop hang）。

## 6. 工具与构建

- **生产组件**（`src/modem/` → 预编译在 `glue/bin/`）：
  - `uimsel.c`：libqmi 直发 `ChangeProvisioningSession`（支持 `UIMSEL_AID` / `UIMSEL_ST` / `UIMSEL_DEACT`）。
  - `uimwatch.c`：订阅 UIM 事件（必须 `setbuf(stdout, NULL)` 防管道全缓冲）。
  - 就地编译：`gcc -o <bin> <src>.c $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)`（需 `gcc libc6-dev libqmi-glib-dev pkg-config`）。
- **离线回归测试**：`python3 scripts/test-modem-uim.py`。
- **诊断工具**（`workspace/`，不入库）：`uimrd.c`、`wdsup.c`（参考）、`nonhlos-tool.py`。
