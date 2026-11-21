# 蓝牙（WCN3990 over UART）bringup 与故障恢复

状态：**可用**。控制器 WCN3990（QCA SoC `0x40010214`），走 UART6 @3.2M，固件 `crbtfw21.tlv` + `crnv21.bin`（`/lib/firmware/qca/`）。检查：`btmgmt info | head -3`（`0 items` 说明控制器未设地址而隐形）。

## 1. 启动链路

```text
DT &uart6 (898000.serial) → qcom,wcn3990-bt (3.2M)
  └─ hci_uart_qca / btqca：115200 握手 → 3.2M → 下发 crbtfw21.tlv + crnv21.bin
       └─ hci0（默认 HCI_UNCONFIGURED）
            ├─ bt-addr.service（glue/bin/sirius-bt-addr）：从 persist wlan_bt/bt.mac 校验/下发地址
            │    （读不到退回 02:57:55:08:5E:02；NVM 正常自带出厂地址，不一致才下发）
            ├─ udev 70-sirius-bt.rules：hci0 re-probe 时拉起 sirius-bt-reprobe 重设地址
            └─ bluetooth.service → sirius-bt-auto（上电）+ sirius-bt-watch（崩溃硬复位）
```

## 2. 已知特性与坑

- **`QCA preshutdown_cmd failed (-56)`**：`hci0` 以 unconfigured 起来后内核立刻关回时，pre-shutdown 私有命令发送失败的开机噪音，无害。
- **`unexpected event for opcode 0x0000`**：WCN3990 固件伪 Command Complete 伴生现象，内核已有 `QCA_DROP_VENDOR_EVENT` 处理。
- **重 probe 后控制器隐形**：`unbind/rebind` 后新控制器回到 `HCI_UNCONFIGURED`，`Read Index List` 不显示；必须重跑 `bt-addr`。
- **设地址窗口期**：从 `hci0` 出现到 setup 完成（~3s）期间 `btmgmt --index 0` 报 `Invalid Index (0x11)`，且 `btmgmt info` 对空列表也返回 0。`sirius-bt-addr` 以 `public-addr` 本身循环重试作为探针，设完后再等 ~12s 完成二次 setup。
- **内核 SSR 自救会失败（硬件边界）**：`sirius.dts` 无 `enable-gpios`（小米硬件拉高 `bt_en`），芯片崩溃后只能暖重启；若暖重启挂死，驱动的 `Retry BT power ON`（不碰电源）三次 `-110` 超时救不回来，**唯一冷复位手段是 `unbind/bind` 断掉 L9A/L6A/L19A 供电**（`vddio` 接常供电轨 `vph_pwr`，不影响复位）。安卓 4.9 内核同样无 `bt_en` GPIO，靠用户态 HAL 掉 regulator 实现冷复位。

## 3. 故障恢复

**自动恢复已内置**（`sirius-bt-watch`）：监测到 `Retry BT power ON` / `Opcode 0x0c03 failed` → 等重试耗尽 → `unbind/bind` 硬复位 → 重配地址 → 上电（约 30s，日志 `journalctl -t sirius-bt-watch`，手动触发 `sudo sirius-bt-watch recover`）。

自动化失效时手工处理（先看 `sudo dmesg | grep -iE 'bluetooth|qca'`）：

```sh
# 情形 A：有 memdump（/sys/class/devcoredump/devcd*）+ 一串 -110 超时 → 断电硬复位
echo serial0-0 | sudo tee /sys/bus/serial/drivers/hci_uart_qca/unbind
sleep 3
echo serial0-0 | sudo tee /sys/bus/serial/drivers/hci_uart_qca/bind
# 等 ~3s dmesg 出现 "QCA setup on UART is completed"，再重设地址并上电：
sudo systemctl restart bt-addr.service
bluetoothctl power on && bluetoothctl show | grep Powered

# 情形 B：控制器在但 power on 失败（地址未设）
sudo systemctl restart bt-addr.service && bluetoothctl power on
```

> 留档取证：`sudo cp /sys/class/devcoredump/devcd1/data /tmp/bt-memdump.bin` 或抓包 `sudo btmon -w /tmp/bt.log &`。
