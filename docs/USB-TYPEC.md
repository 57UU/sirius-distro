# USB Type-C：PM660 CC / PD 栈

> 2026-10-18 实机 bring-up，对应 `kernel/linux-sirius` `feat/sirius-7.2` 分支的 `qcom_smb2_tcpm` 驱动。

## 1. 背景

旧方案：`gpio38` ID 针 + PMIC 的 Rd 判角色，`dr_mode=auto` 会抖，靠 `sirius-otg` + `sirius-usb-bind` 手动跟随（2026-10-19 删，见 `docs/USB-HOST-FIX.md`）；安卓侧 `qpnp-pdphy` + `dwc3-msm` 跟随角色、PD 走 `drivers/usb/pd`，绑死 4.9 电源框架。现方案 = 内核主线 TCPM 等价物：

```
PM660 Type-C 状态机（硬件）
        ↓ 状态寄存器
qcom_smb2_tcpm（TCPC 驱动，本仓库新增）
        ↓ struct tcpc_dev
TCPM（drivers/usb/typec/tcpm，主线）
        ├─ typec class  → /sys/class/typec/port0、port0-partner
        ├─ usb role switch → dwc3（host/device）
        ├─ VBUS boost → SMB2 DCDC_CMD_OTG（主机态供电）
        └─ PD → qcom_pmic_typec_pdphy（PM660 PD PHY，0x1700）
```

## 2. 组成

| 位置 | 内容 |
| --- | --- |
| `drivers/usb/typec/tcpm/qcom_smb2_tcpm.c` | 新驱动：把 SMB2 的 Type-C 状态寄存器翻译成 TCPC 回调，复用 `qcom_pmic_typec_pdphy.c` 的 PD PHY |
| `drivers/usb/typec/tcpm/qcom/qcom_pmic_typec_pdphy.c` | 只加了一行 `EXPORT_SYMBOL_GPL(qcom_pmic_typec_pdphy_probe)`，让新驱动能复用 PD PHY |
| `arch/arm64/boot/dts/qcom/pm660.dtsi` | 新增 `typec@1300`：`reg = <0x1300>, <0x1700>`，CC 变化 + PD PHY 七条中断 |
| `arch/arm64/boot/dts/qcom/sdm710-xiaomi-sirius.dts` | `&usb_1_dwc3` 打开 `usb-role-switch`、加 HS 端口；`&pm660_typec` 描述 `usb-c-connector`（DRP、sink/source PDO）；去掉 dwc3 的 ID extcon |
| `drivers/power/supply/qcom_smbx.c` | 配合改动：`qcom,typec-managed-icl` 时不再用 APSD 猜输入限流（交给 TCPM 的 `set_current_limit()`）；`qcom,typec-managed-vbus` 时 2 秒 OTG 轮询不再碰 boost 位；新增软件 JEITA（见 §8） |
| `defconfig` | `CONFIG_TYPEC_QCOM_SMB2=m`（`TYPEC_TCPM=m`、`TYPEC_QCOM_PMIC=m` 已有） |

模块依赖：`qcom_smb2_tcpm.ko` → `qcom_pmic_tcpm.ko` → `tcpm.ko`。

## 3. 硬件事实（从安卓 smb-reg.h 逆向确认）

Type-C 块在充电器 USBIN 窗口（基址 `0x1300`）：

| 寄存器 | 偏移 | 含义 |
| --- | --- | --- |
| `TYPE_C_STATUS_1` | `0x0B` | sink 视角：对端 Rp 档位（`RD3P0`/`RD1P5`/`RDSTD`） |
| `TYPE_C_STATUS_2` | `0x0C` | source 视角：对端 Rd/Ra 组合（`RD_OPEN`/`RD_RD`/`RD_RA_VCONN`/`RA_RA`） |
| `TYPE_C_STATUS_4` | `0x0E` | 角色位（bit7）、VBUS（bit6）、正反面（bit1）、已连接（bit0） |
| `TYPE_C_CFG` / `_2` / `_3` | `0x58`–`0x5A` | factory mode、VCONN softstart、TRY.SINK 等配置 |
| `TYPE_C_INTRPT_ENB` | `0x67` | 只开 CC 状态变化（bit2） |
| `TYPE_C_SW_CTRL` | `0x68` | 角色命令：`UFP_EN`/`DFP_EN`/`DISABLE`，全 0 = 硬件 DRP 自动翻转；VCONN 位也在这里 |
| `DCDC_CMD_OTG` | `0x1140` | 主机态 5V boost（`BIT(0)`） |

CC 状态机由硬件跑，驱动只读结果、写角色命令。`get_cc()`：sink（UFP）→ `RP_DEF`/`RP_1_5`/`RP_3_0`，source（DFP）→ `TYPEC_CC_RD`；正反面 = `STATUS_4` bit1，VCONN 走另一根 CC。

## 4. 插上线后的行为

| 场景 | 行为 |
| --- | --- |
| 插电脑（普通 C 线） | 硬件进 Attached.SNK → TCPM 认 sink + device → gadget 照常（RNDIS/usb0 172.16.42.1） |
| 插 OTG 头 + 鼠标/U 盘 | 硬件进 Attached.SRC → TCPM 认 source → 开 boost → dwc3 切 host → xhci 枚举 |
| 拔线 | CC 变化中断 → TCPM 回 DRP 翻转，角色跟着下一次插入走 |
| PD 充电器 | TCPM 用 `sink-pdos`（5V/3A、9V/2A）谈 PD；对端不支持的按 Type-C 默认电流充 |
| 支持 PD 的 PC | 先 PD 协商，必要时做 data/power role swap |
| 供电 + 外设的 Type-C 分线器 | 对端按 AMA 处理：PD 谈好电压后做 **DR_SWAP**，电源支路让手机当 sink、外设支路让手机当 DFP（`power_role=sink` + `data_role=host`，此时 `boost` 保持 0）。注意分线器**只有下游接了设备才发 DR_SWAP**，空载时 `data_role` 仍是 device |

开机即插线：probe 后 6 次采样（间隔 400ms），见 `smb2_typec_probe_kick()`。

## 5. 旧脚本的去向

用户态伪 auto 于 2026-10-19 随本栈删除（与 TCPM 抢角色、抢 boost 位）：

| 已删除 | 说明 |
| --- | --- |
| `usr/local/sbin/sirius-usb-bind` | udev 事件驱动的角色跟随 |
| `etc/systemd/system/sirius-usb-bind.service` | 开机跑一次的那个 oneshot |
| `etc/udev/rules.d/99-sirius-usb.rules` | 喂给它事件的四条规则 |
| `sirius-otg` 的 `on` / `off` / `auto` 与 manual pin | 脚本只剩 `status` / `watch` 只读诊断 |

`rootfs/sirius-device.sh` 的 enable / chmod 列表同步去掉。`qcom_smbx` 的 2 秒 OTG 轮询保留（有 Rd 无 VBUS 时开 boost，与 `set_vbus()` 写同一位、幂等）。

## 6. 调试

```bash
ls /sys/class/typec/                       # port0 / port0-partner
cat /sys/class/typec/port0/power_role      # [sink] / [source]
cat /sys/class/typec/port0/data_role
cat /sys/class/typec/port0-partner/supports_usb_power_delivery
cat /sys/class/power_supply/tcpm-*/uevent  # ONLINE / USB_TYPE
cat /sys/class/usb_role/a600000.usb-role-switch/role
grep -i typec /proc/interrupts             # SPMI 中断计数（插拔会涨）
sudo sirius-otg status
```

强制角色（调试）：

```bash
echo host   | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
echo device | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
```

TCPM 日志 `/sys/kernel/debug/usb/tcpm-<dev>/log`（`<dev>` = `c440000.spmi:pmic@0:typec@1300`），seq 文件**读一次就清空**：先 `cat > /tmp/tlog` 留档，`head` 过之后再读会得到 0 字节。

## 7. 源端（OTG host）抖动与压制

现象：接鼠标/键盘，`role` 每秒左右在 host/device 间翻，`xhci-hcd.1.auto` 反复 init/teardown，枚举不上。

根因（主线 `tcpm.c` 的 `run_state_machine()`）：`SRC_ATTACHED` 到点回落 `SRC_UNATTACHED`（`tcpm_set_state(SRC_UNATTACHED, PD_T_PS_SOURCE_ON /*480ms*/)`），可取消它的只有 VBUS 上升沿（`_tcpm_pd_vbus_on()` → `SRC_STARTUP`，`delay 0` 清 `delayed_state`）；PM660 FSM 在 DFP 锁定/boost 上电时把 `TYPE_C_STATUS_4` 的 VBUS 位连同 `CC_ATTACHED` 清掉几百毫秒，`get_vbus()` 返回 0 → 回落 → toggling → 重连。

| 措施 | 作用 |
| --- | --- |
| `get_vbus()` 里 boost 开着就报 VBUS=1（`chip->vbus_on`） | 不信 FSM 的瞬时清零，边沿成立 |
| `set_vbus()` 真正改位后 50ms 主动补 `tcpm_vbus_change()+tcpm_cc_change()`（`vbus_kick` work） | 保证 480ms 窗口内 TCPM 一定被叫醒 |
| `set_cc()`：已按目标角色锁存就不重写命令寄存器 | 避免重写重启 FSM、又制造一次瞬断 |
| `set_vbus()` 幂等：同值不写寄存器 | 每次重连不再触发 boost 写 → FSM 重启 |

`get_cc()` attach 保持 800ms（`detach_check`），真拔线最多晚 0.8s 识别。接非 PD 设备日志有 `PD TX complete, status: 2`（PHY 无 GoodCRC，重发 4 次 Source Caps 后进 `SRC_READY`），正常。

### 7.1 boost 位被充电器自己清掉（2026-10-19 补）

TCPM 侧正常（`power_role=[source]`、`data_role=[host]`）但 **VBUS 实测 0 V**；鼠标停在 `usb 1-1: new full-speed USB device number 2`，10 秒后 `xHCI host not responding to stop endpoint command` → `HC died`，须重建控制器。

根因：boost 一开 5 V 出现在 SMB2 USBIN，充电器当成插入充电器，重新初始化 DCDC 块并清掉 `DCDC_CMD_OTG.bit0`（软件侧没写过 0，只有 `set_vbus(1)` 一次调用）→ VBUS 掉 → 480 ms 到点 → detach → toggling → 再 attach → 再被清。

| 措施 | 作用 |
| --- | --- |
| `vbus_kick` 兼作 20 × 500 ms 保持窗口，每轮读回 `DCDC_CMD_OTG`，被清就重新置位 | 熬过充电器重启 DCDC 的那几秒；真被清时打 `dev_dbg` |
| `qcom_smbx` 新增 DT 开关 `qcom,typec-managed-vbus`（板级已加） | 置位后 2 秒一次的 OTG 轮询不再碰 boost 位（它看不到适配器的 Rd，会关掉 TCPM 刚开的供电） |

实测（OTG 头 + 鼠标，冷启动）：`boost=1`、VBUS 5.04 V、`event4: Gaming Mouse` / `event5: Gaming Mouse Keyboard`，日志只有一次 `OTG boost was cleared, re-asserted`。

控制器死后插拔不恢复，重建（不用重启）：

```bash
echo device | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
sleep 1
echo host   | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
```

## 8. 充电电流与电池温度（软件 JEITA）

主线 `qcom_smbx` 无温度降额（PMIC JEITA 停复位值，`qcom-smb-charger` 未挂热区，`qcom-battery` 是无 trip 的虚拟热区）。驱动补 30 秒一轮 `smb_jeita_work`：读电池热区温度按表改 `FAST_CHARGE_CURRENT_CFG (0x61)`，越界用 `CHARGING_ENABLE_CMD (0x42)` 停充。

| 电池温度 | 充电电流 | 说明 |
| --- | --- | --- |
| < 0 °C | 停充 | 低温保护 |
| 0 – 10 °C | 1.0 A | 低温慢充 |
| 10 – 40 °C | 3.0 A | 满速（≈1C） |
| 40 – 43 °C | 2.0 A | 温控 1 档 |
| 43 – 46 °C | 1.5 A | 温控 2 档 |
| 46 – 48 °C | 1.0 A | 温控 3 档 |
| 48 – 55 °C | 0.5 A | 温控 4 档 |
| ≥ 55 °C | 停充 | 过温保护，降回 55 °C 以下自动恢复 |

- 边界带 **1 °C 迟滞**（升温立刻降档，降温要低于边界 1 °C 才升档）；
- 插拔线缆时 `smb_status_change_work` 立刻补跑，不等 30 秒；
- 只影响 CC 阶段电流（CV 末尾只剩 200 mA）；
- 表在 `drivers/power/supply/qcom_smbx.c` 的 `smb_jeita_table[]`。

热区支持注入假温度，不用真加热：

```bash
Z=/sys/class/thermal/thermal_zone$(for z in /sys/class/thermal/thermal_zone*; do       [ "$(cat $z/type)" = "qcom-battery" ] && echo ${z##*thermal_zone}; done)
echo 45000 | sudo tee $Z/emul_temp    # 伪造 45 °C → 应降到 1.5 A
sudo journalctl -b -k | grep JEITA
echo 0     | sudo tee $Z/emul_temp    # 取消伪造，恢复真实温度
```

## 9. 边界与已知限制

- **只有 USB2**：板子没走 SS 差分对，sdm670-usb.dtsi 里 `ssusb@a800000` 是删掉的，与 Type-C 栈无关。
- **没有 DP alt mode**：PM660 侧没有 SBU/DP 通路，USB-C 转 HDMI 不工作。
- **source 电流档位**：硬件广告的 Rp 电流由 PM660 内部配置决定，驱动只按角色切换，不按 PDO 调档；`source-pdos` 只用于 PD 报文。
- **sink 电流**：TCPM 把合约（Rp 档位或 PD PDO）经 `tcpc->set_current_limit()` 写入 `USBIN_CURRENT_LIMIT_CFG`；board DT 的 `qcom,typec-managed-icl` 让 qcom_smbx 不再用 APSD 的值覆盖。SMB2 的 AICL 在 VBUS 压降时仍会收小限流（读数低于合约值），属硬件保护。
- **模拟音频附件**（Type-C 转 3.5mm）能识别成 audio accessory，但本机 3.5mm 走模拟耳机孔，没有 SBU 开关，不路由。
- **PD 需要 PD 电源**：普通 5V 充电器只走 Type-C 默认电流。
- PD PHY 的 `sig-tx` 中断在本机是空事件（主线驱动只打一行 dev_err），驱动没申请它，避免刷屏。

## 10. 回退

```sh
sudo rmmod qcom_smb2_tcpm        # 立刻退回 dr_mode 默认（peripheral）
```

彻底回退：`&pm660_typec` 的 `status` 改回 `disabled`、`&usb_1_dwc3` 去掉 `usb-role-switch;` 与 `ports` 节点、加回 `extcon = <&extcon_usb>;`，重建 `kernel.img` 刷入。用户态跟随脚本已删，需先按 `git log -- rootfs/overlay/usr/local/sbin/sirius-usb-bind` 找回那三个文件（脚本、service、udev 规则），否则只能手动写 dwc3 角色（`usb_role/.../role` 或 debugfs `mode`）+ `otg_boost`。
