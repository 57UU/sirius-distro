# USB Type-C：PM660 CC / PD 栈

> 对应 `kernel/linux-sirius` `feat/sirius-7.2` 分支的 `qcom_smb2_tcpm` 驱动（替代已删除的 `sirius-usb-bind` 用户态脚本，历史见 [USB-HOST-FIX.md](USB-HOST-FIX.md)）。

## 1. 架构与组成

```text
PM660 Type-C 硬件状态机 (0x1300) → qcom_smb2_tcpm → 主线 TCPM
  ├─ typec class      → /sys/class/typec/port0, port0-partner
  ├─ usb role switch  → dwc3 (host / device)
  ├─ VBUS boost       → SMB2 DCDC_CMD_OTG (0x1140 bit0)
  └─ PD               → qcom_pmic_typec_pdphy (0x1700)
```

| 位置 | 改动内容 |
|---|---|
| `drivers/usb/typec/tcpm/qcom_smb2_tcpm.c` | 将 SMB2 Type-C 寄存器翻译为 TCPC 回调，复用 PD PHY |
| `drivers/usb/typec/tcpm/qcom/qcom_pmic_typec_pdphy.c` | 导出 `qcom_pmic_typec_pdphy_probe` |
| `arch/arm64/boot/dts/qcom/pm660.dtsi` | 新增 `typec@1300`（`reg = <0x1300>, <0x1700>` + CC/PD 中断） |
| `arch/arm64/boot/dts/qcom/sdm710-xiaomi-sirius.dts` | `&usb_1_dwc3` 开 `usb-role-switch`、去 ID extcon；`&pm660_typec` 配 DRP 与 PDO |
| `drivers/power/supply/qcom_smbx.c` | 支持 `qcom,typec-managed-icl` / `qcom,typec-managed-vbus`、新增软件 JEITA |
| `defconfig` | `CONFIG_TYPEC_QCOM_SMB2=m`（依赖 `qcom_pmic_tcpm.ko` → `tcpm.ko`） |

## 2. 硬件寄存器（USBIN 基址 `0x1300`）

| 寄存器 | 偏移 | 含义 |
|---|---|---|
| `TYPE_C_STATUS_1` | `0x0B` | sink 视角：对端 Rp 档位（`RD3P0`/`RD1P5`/`RDSTD`） |
| `TYPE_C_STATUS_2` | `0x0C` | source 视角：对端 Rd/Ra 组合 |
| `TYPE_C_STATUS_4` | `0x0E` | 角色（bit7）、VBUS（bit6）、正反面（bit1）、已连接（bit0） |
| `TYPE_C_CFG` / `_2` / `_3` | `0x58`–`0x5A` | factory mode、VCONN softstart、TRY.SINK |
| `TYPE_C_INTRPT_ENB` | `0x67` | CC 状态变化中断（bit2） |
| `TYPE_C_SW_CTRL` | `0x68` | `UFP_EN`/`DFP_EN`/`DISABLE`（全 0 = 硬件 DRP 自动翻转）及 VCONN |
| `DCDC_CMD_OTG` | `0x1140` | 主机态 5V boost（`BIT(0)`） |

## 3. 场景行为

- **普通 C 线接电脑**：Attached.SNK → gadget（`usb0` 172.16.42.1）。
- **OTG 转接头 + 外设**：Attached.SRC → 开 5V boost → dwc3 切 host → xhci 枚举。
- **PD 充电器**：按 `sink-pdos`（5V/3A、9V/2A）协商，实测 9V/2A 合约（输入 13–15W，见 [CHARGING.md](CHARGING.md)）。
- **供电 + 外设 Type-C 分线器**：PD 协商后发 `DR_SWAP`（`power_role=sink` + `data_role=host`，boost 保持 0）；注意分线器**下游接了设备才发 `DR_SWAP`**，空载时仍为 device。
- **开机即插线**：`smb2_typec_probe_kick()` 在 probe 后 400ms 间隔采样 6 次。

## 4. 源端（OTG host）抖动与 boost 掉电修复

- **角色抖动根因**：PM660 FSM 在 DFP 锁定/boost 上电瞬间会把 `STATUS_4` 的 VBUS 与 `CC_ATTACHED` 清零几百毫秒，导致 TCPM `SRC_ATTACHED` 480ms 超时回落 `SRC_UNATTACHED` 反复重连。
- **boost 自清根因**：boost 开启后 5V 出现在 USBIN，充电器误判插入外部电源并重启 DCDC 块，清掉 `DCDC_CMD_OTG.bit0`。

| 修复措施 | 作用 |
|---|---|
| `get_vbus()` 在 `chip->vbus_on` 为真时直接报 1 | 屏蔽 FSM 瞬时清零 |
| `vbus_kick`（50ms 触发 + 20×500ms 保持窗口） | 唤醒 TCPM 状态机并轮询回读 `DCDC_CMD_OTG`，被清即重新置位 |
| `set_cc()` / `set_vbus()` 幂等检查 | 已锁存/同值不重写寄存器，避免重启 FSM |
| `get_cc()` attach 保持 800ms（`detach_check`） | 过滤瞬断（真拔线最多晚 0.8s 识别） |
| `qcom_smbx` 加 `qcom,typec-managed-vbus` | 禁止 2s OTG 轮询干扰 TCPM 刚开的 boost |

> 接非 PD 设备时日志出现 `PD TX complete, status: 2`（无 GoodCRC）属正常。若 xHCI 死掉（`HC died`），可写 `device` → 等 1s → 写 `host` 至 `/sys/class/usb_role/a600000.usb-role-switch/role` 重建控制器。

## 5. 软件 JEITA 温控（`qcom_smbx.c`）

`smb_jeita_work` 每 30s（及插拔线缆时）读 `qcom-battery` 热区改写 `FAST_CHARGE_CURRENT_CFG (0x61)` 与 `CHARGING_ENABLE_CMD (0x42)`，边界带 **1 °C 迟滞**：

| 电池温度 | `< 0°C` | `0–10°C` | `10–40°C` | `40–43°C` | `43–46°C` | `46–48°C` | `48–55°C` | `≥ 55°C` |
|---|---|---|---|---|---|---|---|---|
| 充电电流 | 停充 | 1.0 A | 3.0 A | 2.0 A | 1.5 A | 1.0 A | 0.5 A | 停充 |

## 6. 边界与限制

- **仅 USB2 / 无 DP alt mode / 无 Type-C 音频路由**：板级无 SS 差分对与 SBU/DP 通路（3.5mm 走独立耳机孔）。
- **QC3 / 5V DCP**：主线 `qcom_smbx` 禁用了 `HVDCP_EN`，QC3 头停在 5V；判断真 PD 看 `port0-partner/supports_usb_power_delivery` 与 `tcpm-source-psy`（`pm660-charger/usb_type` 仅反映 APSD）。
- **`sig-tx` 中断**：本机为空事件，驱动未申请以防刷屏。

## 7. 调试与回退

```bash
ls /sys/class/typec/
cat /sys/class/typec/port0/{power_role,data_role}
cat /sys/class/usb_role/a600000.usb-role-switch/role
grep -i typec /proc/interrupts
sudo sirius-otg status
# TCPM seq 日志读一次即清空，先转存：
sudo cat /sys/kernel/debug/usb/tcpm-c440000.spmi:pmic@0:typec@1300/log > /tmp/tlog
# 伪造电池温度测 JEITA（找到 qcom-battery 对应 thermal_zoneN）：
echo 45000 | sudo tee /sys/class/thermal/thermal_zoneN/emul_temp
echo 0     | sudo tee /sys/class/thermal/thermal_zoneN/emul_temp
```

回退：`sudo rmmod qcom_smb2_tcpm` 立即退回 peripheral；彻底回退需在 DT 禁用 `&pm660_typec`、恢复 `&usb_1_dwc3` 的 `extcon` 并重编 `kernel.img`。
