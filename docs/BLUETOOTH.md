# 蓝牙（WCN3990 over UART）bringup 与故障恢复

状态：**可用**。控制器为 WCN3990（QCA SOC 0x40010214），走 UART6 @3.2M，
固件 `crbtfw21.tlv` + `crnv21.bin`，2026-10-18 实测 HID 键盘连接正常。

---

## 1. 结论速览

| 环节 | 状态 | 说明 |
|---|---|---|
| 芯片上电 | ✅ | DT 四路供电（vph_pwr / L9A 1.8 / L6A 1.3 / L19A 3.3） |
| 固件加载 | ✅ | btqca 经 UART 下载 rampatch + NVM |
| BD 地址 | ✅ | NVM 自带出厂地址；开机由 `bt-addr.service` 校准/兜底 |
| 用户态 | ✅ | bluetoothd + bluetoothctl；server 版由 `sirius-bt-auto` 自动上电 |

一条命令检查当前是否活着：

```sh
btmgmt info | head -3     # 0 items = 控制器不可见，见 §4.2
```

---

## 2. 启动链路

```
DT: &uart6 (898000.serial, qup_uart6_4pin)
  └── bluetooth { compatible = "qcom,wcn3990-bt"; max-speed = <3200000>; }
        │  hci_uart_qca (serdev)  probe → 上电 → 115200 握手 → 3.2M
        │  btqca: crbtfw21.tlv (rampatch) → crnv21.bin (NVM)
        v
hci0（内核，管理接口 MGMT）
  ├── 上电后默认 HCI_UNCONFIGURED（DT 未提供 local-bd-address）
  ├── bt-addr.service: btmgmt --index 0 public-addr <persist 里的出厂地址>
  │     └── 控制器转为 configured，进入 Read Index List
  ├── udev 70-sirius-bt.rules: hci0 重新出现（re-probe）时自动拉起
  │     sirius-bt-reprobe.service 重跑 sirius-bt-addr（治 §4.2 隐形）
  └── bluetooth.service (bluetoothd)
        ├── sirius-bt-auto.service: btmgmt power on / bluetoothctl power on
        └── sirius-bt-watch.service: 监视内核日志，芯片卡死后自动
              unbind/bind 硬复位 + 重配地址 + 上电（§5/§7）
```

BD 地址来源（`/usr/local/sbin/sirius-bt-addr`）：

1. persist 分区（mmcblk0p68/69）`wlan_bt/bt.mac`（6 字节）——出厂地址；
2. 读不到则退回烙在脚本里的 LAA `02:57:55:08:5E:02`（无 persist 数据的共享镜像兜底）。

vendor NVM（crnv21.bin）本身已带出厂地址，所以正常情况下这只做**校验**；
只有控制器地址与期望不一致时才真正下发。

---

## 3. 固件与内核的几个事实

- 固件在 `/lib/firmware/qca/`：`crbtfw21.tlv`、`crnv21.bin`（WCN3990/3998 家族 21 系列）。
- 内核驱动：`drivers/bluetooth/hci_qca.c`（serdev + hci_uart 协议层）、`btqca.c`
  （QCA 私有命令）。设备树源码 `sdm710-xiaomi-sirius.dts` 的 `&uart6` 节点。
- 内核对一个 hci0 的生命周期：register 时置 `HCI_SETUP` + `HCI_AUTO_OFF`，
  首次 power_on 做 setup（下载固件）→ setup 结束后若控制器无有效地址（或
  UNCONFIGURED/RFKILLED）会**立刻自己关回去**，随后发 Unconfigured Index Added。
- 内核 `Read Index List` **只列 configured 控制器**。unconfigured 的只能通过
  Unconfigured Index Added 事件或 Read Unconfigured Index List 看到。
- 崩溃自恢复：芯片触发 hw_error 后驱动收集 memdump（devcoredump，
  `/sys/class/devcoredump/`），然后重跑 setup。**dump 收完后立刻重试，中间不重新断电**。

---

## 4. 三个必须知道的坑

### 4.1 `QCA preshutdown_cmd failed (-56)` 是噪音，不是病因

控制器以 unconfigured 状态起来后，内核会立刻把它关回去（§2），关机路径里
`qca_hci_shutdown` 会发 pre-shutdown 私有命令；此时命令工作队列已在收尾，
发送失败返回 -56 并打印这条错误。开机日志里必有，无害，别顺着它排障。

### 4.2 重 probe 后控制器"隐形"——必须重跑 bt-addr

驱动 unbind/rebind（或任何让 hci0 消失再出现的操作）后，新控制器仍是
unconfigured，而 `bt-addr.service` 是开机一次性的 oneshot，不会再来。
后果：

- `btmgmt info` → `Index list with 0 items`
- `btmgmt --index hci0 info` → `Invalid Index`
- `bluetoothctl power on` → `No default controller available`

此时芯片、固件、地址全都是好的（btmon 里 Read BD ADDR 正常返回），
只差有人给它下发 public-addr。恢复见 §5。

### 4.3 芯片卡死时内核的自救是无效的，必须断电复位

WCN3990 崩溃后如果 UART 完全无响应，驱动内置的 `Retry BT power ON`
（关开 serdev + 重发命令，最多 3 次）救不回来——实测三次全 `-110` 超时。
唯一有效的恢复是让驱动走 unbind/rebind：unbind 触发
`qca_regulator_disable` 真正拉掉芯片供电，rebind 重新上电。

### 4.4 给重 probe 的控制器设地址：public-addr 会撞 Invalid Index 窗口

从 `hci0` 设备出现到内核发 "Unconfigured Index Added"（setup 需 ~3 秒固件
下载）之间，`btmgmt --index 0 <任何命令>` 都返回 Invalid Index (0x11)。
且 `btmgmt info` 对**空索引列表**也是退出码 0，不能当就绪探针。
所以重配地址必须**以 public-addr 本身作为探针**循环重试（成功输出含
"complete"）；另外设完地址后内核还要跑第二次 setup 才把控制器挂进
configured 列表，验证循环要给足 ~12 秒。`sirius-bt-addr` 已按此实现。

---

## 5. 故障恢复手册

**自动恢复已内置**（`sirius-bt-watch`，事件驱动，平时零开销）：

- 芯片卡死（内核打出 `Retry BT power ON` / `Opcode 0x0c03 failed`）→ watcher
  等驱动重试耗尽并确认无自恢复 → unbind/bind 硬复位 → 重配地址 → 上电，
  全程约 30 秒，日志在 `journalctl -t sirius-bt-watch`。
- hci0 re-probe 后的地址重配由 udev 规则自动完成（`sirius-bt-reprobe`）。
- 手工触发一次恢复：`sudo sirius-bt-watch recover`。

以下手册用于自动化失效时手工操作。先看内核日志定位属于哪种：

```sh
sudo dmesg | grep -iE 'bluetooth|qca'
```

**情形 A：有 memdump + 一串 -110 超时（芯片卡死）**

```sh
# 1) 真断电硬复位
echo serial0-0 | sudo tee /sys/bus/serial/drivers/hci_uart_qca/unbind
sleep 3
echo serial0-0 | sudo tee /sys/bus/serial/drivers/hci_uart_qca/bind

# 2) 等固件重载（约 3 秒，出现 "QCA setup on UART is completed"）
sudo dmesg | tail

# 3) 关键：重新下发地址（否则控制器隐形，见 §4.2）
sudo systemctl restart bt-addr.service

# 4) 上电验证
bluetoothctl power on && bluetoothctl show | grep Powered
```

崩溃的 memdump 会留在 `/sys/class/devcoredump/devcd*`，要留档就先拷走：

```sh
sudo cp /sys/class/devcoredump/devcd1/data /tmp/bt-memdump.bin
```

**情形 B：控制器在但 power on 失败（多半是重启过 bluetoothd/驱动后地址没设）**

```sh
sudo systemctl restart bt-addr.service
bluetoothctl power on
```

**情形 C：完全没反应**：确认 `sys-subsystem-bluetooth-devices-hci0.device`
是否存在、服务是否 enabled：`bt-addr`（Before=bluetooth.service）、
`bluetooth`、`sirius-bt-auto`（server 版）。

---

## 6. 崩溃事件记录（2026-10-18）

时间线（dmesg 单调时间）：

| 时刻 | 事件 |
|---|---|
| 开机 | 正常：固件加载、bt-addr 校验通过、上电 |
| 2563s | **崩溃 #1**，memdump 收齐（425984B），驱动自动重跑 setup，重载固件成功 |
| 2632s | BT5.0 HID 键盘连接成功 |
| 2636s | **崩溃 #2**（连接后 3 秒），memdump 收齐；此次重试 setup 全部 `-110` 超时，芯片卡死 |
| 2696s | 3 次重试耗尽，`Opcode 0x0c03 (Reset) failed`，蓝牙不可用 |

两次 dump 均完整收齐（`QCA memdump Done, received 425984`）。崩溃原因
见 dump 分析（§7，深挖记录）；按 §5 手册恢复后功能正常。

---

## 7. 深挖记录（2026-10-18 双崩溃的根因分析）

### 7.1 恢复流程代码走读（hci_qca.c / hci_core.c）

芯片崩溃后的完整链条：

```
芯片固件崩溃
  ├── 自发 vendor 事件（QCA_SSR_DUMP_HANDLE）分块送出 425984B RAM dump
  │     └── qca_controller_memdump: hci_devcd_init → 收包 → COLLECTED
  ├── 随后发标准 Hardware Error 事件
  │     └── hci_hardware_error_evt → error_reset 工作队列
  │           ├── qca_hw_error：dump 已 COLLECTED → 清 QCA_SSR_TRIGGERED/
  │           │     QCA_IBS_DISABLED、tx_ibs_state=AWAKE、msleep(100)
  │           └── hci_dev_do_close + hci_dev_do_open → 重跑 qca_setup
  │                 └── 重下固件 crbtfw21.tlv + crnv21.bin
  └── 芯片同时自己暖重启（无固件重载，靠 host 重新下载）
```

两次崩溃的分水岭在**芯片自己的暖重启是否走完**：

- 崩溃 #1：暖重启正常完成，host 重跑 setup 成功（dump 收完到 setup 只隔 40ms）。
- 崩溃 #2：dump 收完（2639s）后 Hardware Error 事件**迟到 14 秒**（2653s 才到），
  之后 setup 第一条命令就收到 WCN3990 固件特有的 opcode 0x0000 伪 Command Complete，
  随后全部 -110 超时——芯片暖重启没走完/挂死，对 UART 完全无响应。

### 7.2 为什么 host 的自救注定无效：bt_en 不可控

`sirius.dts` 的 bluetooth 节点**没有 `enable-gpios`（bt_en）**——小米把 bt_en 硬拉高，
主机无法控制。这命中了上游 2025-12 的补丁
`fce1a9244a0f ("Bluetooth: hci_qca: Fix SSR (SubSystem Restart) fail when BT_EN is
pulled up by hw")` 描述的场景：

- bt_en 拉高的平台上，固件崩溃后芯片只能**暖重启**（不重载固件），
  暖重启没走完时芯片对任何 HCI 命令都不响应；
- 内核的 "Retry BT power ON"（关开 serdev 重发命令）不碰供电，救不了挂死的芯片；
- **唯一有效的冷复位是断电**：unbind/rebind 走 `qca_regulator_disable` 拉掉
  L9A/L6A/L19A 三路供电（vddio 接 vph_pwr 常供电轨，断不掉但无碍），芯片彻底复位。

上游 2026-05 的 100ms 等待补丁（等芯片重载 rampatch/NVM）也已在树里——
即这棵内核已带最新 SSR 修复，但修复只覆盖"暖重启走完"的场景，
覆盖不了"暖重启本身挂死"（crash #2 的情形）。

### 7.3 已排除/澄清的方向

- `unexpected event for opcode 0x0000`：WCN3990 固件从 2019 年就有的怪癖
  （伪 Command Complete），内核的 drop-event 机制（QCA_DROP_VENDOR_EVENT）已在，
  这里只是崩溃的伴生现象，不是原因。
- `QCA preshutdown_cmd failed (-56)`：unconfigured 关闭路径噪音（§4.1）。
- 崩溃与固件加载无关：两次 dump 都完整收齐，且崩溃前固件已稳定运行 40+ 分钟。

### 7.4 崩溃诱因（未定论）

- 崩溃 #1 发生在蓝牙**空闲**约 44 分钟后；崩溃 #2 在 HID 键盘连接后 **3 秒**
  （活跃 IBS 睡眠/唤醒切换 + ACL 流量期间）。无共同的用户态触发点。
- WCN3990 是 WiFi/BT combo，WiFi（ath10k snoc）当时在跑，存在 coex 干扰的可能，
  无法进一步验证。
- RAM dump（425984B）需要 Qualcomm 内部工具解析，只能留档：
  `workspace/bt-memdump2.bin`（头部：`BTFM.HW_CHE.2.1-00043-QCACHROM-1`，SoC 0x40010214）。
- **下次再崩时先抓 btmon**（`sudo btmon -w /tmp/bt.log &`），能看到崩溃前的最后
  一条 HCI 交互，比 dmesg 信息多得多；dump 头也会带当时的连接上下文。

### 7.5 与安卓原厂内核（4.9，rocky-sdm710）的对比

| | 安卓原厂（4.9.337） | 主线（我们，6.1 基） |
|---|---|---|
| hci_qca.c | 992 行，纯 ROME 驱动（"ROME setup"），只有 IBS | 完整 wcn3990：serdev、固件下载、memdump、SSR |
| BT 供电/复位 | `bluetooth-power.c`（匹配 `qca,wcn3990` 节点，regulator + rfkill plane），**由用户态 vendor HAL（libbt-vendor.so）调度** | 内核内（qca_regulator_enable/disable + bt_en），假设 bt_en 可控 |
| 固件下载 | 用户态（4.9 btqca.c 只有 ROME 代码，下不了 crbtfw21.tlv） | 内核 btqca.c |
| 崩溃恢复 | **用户态全冷复位**：HAL 掉 regulator → 上电 → 从零 bring-up | 内核 SSR：依赖芯片暖重启 + host 重下固件 |

结论：

- **安卓内核里没有任何可移植的 BT 恢复逻辑**——它压根没有内核内恢复这套东西。
  芯片崩了安卓就是用户态断电重来，每次都是全冷复位，所以"暖重启挂死"这个
  坑在安卓路线下不存在。
- 我们手工的 unbind/rebind + bt-addr 恢复，在语义上就是复刻安卓 HAL 的
  冷复位动作；这是高通为该硬件设计的唯一可靠恢复路径。
- 安卓 DTS（`bt_wcn3990`）只配了三路 regulator（pm660_l9 1.8V / l6 1.3V /
  l19 3.3V，与主线 vddxo/vddrf/vddch0 一一对应），**同样没有 bt_en GPIO**——
  印证 sirius 硬件上 bt_en 没接主机 GPIO，§7.2 的结论成立。
- `btfm_slim_wcn3990.c` 是 slimbus 音频侧（FM/sco codec），与 HCI 无关，勿混淆。

### 7.6 已知边界

固件级别的随机崩溃无法在主机侧根治（bt_en 不可控，打不了冷复位补丁），
能做的是：恢复手册自动化（§5）、崩溃后自动重配地址（防 §4.2 隐形）、
以及每次崩溃都留下 dump + btmon 取证。
