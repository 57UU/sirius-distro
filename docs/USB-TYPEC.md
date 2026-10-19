# USB Type-C：PM660 CC / PD 栈

> 2026-10-18 实机 bring-up，对应 `kernel/linux-sirius` `feat/sirius-7.2`
> 分支上的 `qcom_smb2_tcpm` 驱动。本文只讲这条栈怎么用、怎么调、边界在哪。

## 1. 为什么要有它

以前的角色判断是「拼」出来的：

- `gpio38` 只看 Micro-USB 时代的 ID 针是否接地，翻面/悬空就丢信号；
- PMIC 只看 CC 上有没有 Rd，判断不出正反面和电流档位；
- 于是 `dr_mode` 写 `auto` 会在 host/device 之间来回抖，只能用
  `sirius-otg` 手动切，再靠 `sirius-usb-bind` 在用户态用 udev 事件模拟
  跟随（见 `docs/USB-HOST-FIX.md`）。

安卓侧的做法是：PM660 充电器的 Type-C 状态机 + `qpnp-pdphy` 上报
extcon + `dwc3-msm` 跟随角色，PD 由 `drivers/usb/pd` 的 policy engine 谈。
那套代码绑死在 4.9 的电源框架上，不能直接搬进 7.2。

现在的做法是**内核主线的等价物**：

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

关键点：**CC 状态机是硬件跑的**，驱动只读结果、写角色命令，不像 TCPCI
那样逐条 CC 采样。因此 `get_cc()` 返回的是「对端端接」的合成结果：

- 我们当 sink（硬件报 UFP）：返回对端 Rp 档位（`RP_DEF`/`RP_1_5`/`RP_3_0`）；
- 我们当 source（硬件报 DFP）：返回对端 Rd（`TYPEC_CC_RD`）。

正反面由 `STATUS_4` bit1 决定，VCONN 走另一根 CC。

## 4. 现在插上线会发生什么

| 场景 | 行为 |
| --- | --- |
| 插电脑（普通 C 线） | 硬件进 Attached.SNK → TCPM 认 sink + device → gadget 照常（RNDIS/usb0 172.16.42.1） |
| 插 OTG 头 + 鼠标/U 盘 | 硬件进 Attached.SRC → TCPM 认 source → 开 boost → dwc3 切 host → xhci 枚举 |
| 拔线 | CC 变化中断 → TCPM 回 DRP 翻转，角色跟着下一次插入走 |
| PD 充电器 | TCPM 用 `sink-pdos`（5V/3A、9V/2A）谈 PD；对端不支持的按 Type-C 默认电流充 |
| 支持 PD 的 PC | 先 PD 协商，必要时做 data/power role swap |
| 供电 + 外设的 Type-C 分线器 | 对端按 AMA 处理：PD 谈好电压后做 **DR_SWAP**，电源支路让手机当 sink、外设支路让手机当 DFP（`power_role=sink` + `data_role=host`，此时 `boost` 保持 0）。注意分线器**只有下游接了设备才发 DR_SWAP**，空载时 `data_role` 仍是 device |

开机时如果线已经插着，驱动会在 probe 后连打 6 次状态采样（间隔 400ms）
让 TCPM 追上已经存在的连接——这段逻辑见 `smb2_typec_probe_kick()`。

## 5. 旧脚本的去向

用户态伪 auto 在 2026-10-19 随这套栈上线一并删除（它和 TCPM 抢角色、抢
boost 位）：

| 已删除 | 说明 |
| --- | --- |
| `usr/local/sbin/sirius-usb-bind` | udev 事件驱动的角色跟随 |
| `etc/systemd/system/sirius-usb-bind.service` | 开机跑一次的那个 oneshot |
| `etc/udev/rules.d/99-sirius-usb.rules` | 喂给它事件的四条规则 |
| `sirius-otg` 的 `on` / `off` / `auto` 与 manual pin | 脚本只剩 `status` / `watch` 只读诊断 |

`rootfs/sirius-device.sh` 里的 enable 列表和 chmod 列表也同步去掉了。
现在角色只由 CC 线决定，不需要任何用户态守护进程；`sirius-otg` 只报状态，
传 `on/off/auto` 会直接提示已移除。

`qcom_smbx` 的 2 秒 OTG 轮询仍然保留：它只在「检测到 Rd 且没有 VBUS」时开
boost，和 TCPM 的 `set_vbus()` 写同一个寄存器位，两边都幂等，不冲突；万一
TCPM 没加载，它自己也能把 OTG 头供上电。

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

TCPM 状态机日志在 `/sys/kernel/debug/usb/tcpm-<dev>/log`（`<dev>` 是
`c440000.spmi:pmic@0:typec@1300`）。注意它是 seq 文件，**读一次就清空**，
要留档先 `cat > /tmp/tlog` 再分析；`head` 过之后再读会得到 0 字节。

## 7. 源端（OTG host）为什么会抖，以及怎么压住的

这是接鼠标/键盘时才暴露的坑，现象是每 1 秒左右 `role` 在 host/device 之间翻，
`xhci-hcd.1.auto` 反复 init/teardown，外设一直枚举不上。

根因链（全部在主线 `tcpm.c` 的行为里，不是本驱动的私货）：

1. 主线 `run_state_machine()` 的 `SRC_ATTACHED` 分支本身就是
   `tcpm_set_state(SRC_UNATTACHED, PD_T_PS_SOURCE_ON /*480ms*/)`；
2. 能取消这个 480ms 定时回落的，只有 VBUS 上升沿：`_tcpm_pd_vbus_on()`
   在 `SRC_ATTACHED` 状态下会把状态推到 `SRC_STARTUP`（`delay 0` 会清掉
   `delayed_state`）；
3. PM660 的 Type-C FSM 每次在 DFP 锁定 / boost 上电那一下，会把
   `TYPE_C_STATUS_4` 的 VBUS 位连同 `CC_ATTACHED` 位一起清掉几百毫秒。
   `get_vbus()` 照实返回 0，TCPM 在 480ms 窗口里看不到 VBUS 上升沿 → 准点
   回落 → `SRC_UNATTACHED` → toggling → 又检测到 sink → 重新 attach → 循环。

驱动里用四条互相兜底的措施压住：

| 措施 | 作用 |
| --- | --- |
| `get_vbus()` 里 boost 开着就报 VBUS=1（`chip->vbus_on`） | 不信 FSM 的瞬时清零，边沿成立 |
| `set_vbus()` 真正改位后 50ms 主动补 `tcpm_vbus_change()+tcpm_cc_change()`（`vbus_kick` work） | 保证 480ms 窗口内 TCPM 一定被叫醒 |
| `set_cc()`：已按目标角色锁存就不重写命令寄存器 | 避免重写重启 FSM、又制造一次瞬断 |
| `set_vbus()` 幂等：同值不写寄存器 | 每次重连不再触发 boost 写 → FSM 重启 |

另外 `get_cc()` 对 attach 做了 800ms 保持（`detach_check` work 到期再采样），
盖住 FSM 的瞬断；代价是真拔线最多晚 0.8s 才被识别。

接非 PD 设备（鼠标、U 盘、普通 hub）时，日志会出现
`PD TX complete, status: 2`——这是 PHY 报「没收到 GoodCRC」，
TCPM 会重发 4 次 Source Caps 然后进 `SRC_READY`，属于正常流程，不会重连。

### 7.1 boost 位会被充电器自己清掉（2026-10-19 补）

第二个独立原因，症状更迷惑：TCPM 侧一切正常（`power_role=[source]`、
`data_role=[host]`），但 **VBUS 实测 0 V**，鼠标只走到
`usb 1-1: new full-speed USB device number 2` 就没了下文，10 秒后
`xHCI host not responding to stop endpoint command` → `HC died`，
之后插什么都不会再认，必须重建控制器。

根因：boost 一打开，5 V 就出现在 SMB2 的 USBIN 上，充电器把它当成
「插进来一个充电器」，自己的状态机重新初始化 DCDC 块，把
`DCDC_CMD_OTG.bit0` 清掉——软件侧**没有**任何一次写 0（加日志确认过，
全程只有 `set_vbus(1)` 一次调用）。TCPM 于是看到 VBUS 掉、480 ms 到点、
detach → toggling → 再 attach → 再被清，xhci 就在这串抖动里卡死。

两个措施：

| 措施 | 作用 |
| --- | --- |
| `vbus_kick` 兼作 20 × 500 ms 的保持窗口，每轮读回 `DCDC_CMD_OTG`，被清就重新置位 | 熬过充电器重启 DCDC 的那几秒；只在真被清时打一条 `dev_dbg` |
| `qcom_smbx` 新增 DT 开关 `qcom,typec-managed-vbus`（板级已加） | 置位后 2 秒一次的 OTG 轮询不再碰 boost 位——它看不到 Type-C 适配器的 Rd，会把 TCPM 刚打开的供电又关掉 |

实测（OTG 头 + 鼠标，冷启动）：`boost=1`、VBUS 5.04 V、
`event4: Gaming Mouse` / `event5: Gaming Mouse Keyboard`，
日志里只有一次 `OTG boost was cleared, re-asserted`。

排错提醒：一旦看到 `xHCI host not responding to stop endpoint command`，
控制器已经死了，插拔不会恢复，用下面的命令重建即可（不用重启）：

```bash
echo device | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
sleep 1
echo host   | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
```

## 8. 充电电流与电池温度（软件 JEITA）

主线的 `qcom_smbx` 原本没有任何温度降额：PMIC 自带的 JEITA 块停在复位值，
`qcom-smb-charger` 这个 cooling device 也没挂到热区（`qcom-battery` 是
power_supply 自动建的虚拟热区，没有 trip、挂不上 cooling-maps）。所以驱动里
补了一个 30 秒一轮的 `smb_jeita_work`：读电池热区温度，按表改
`FAST_CHARGE_CURRENT_CFG (0x61)`，越界时用 `CHARGING_ENABLE_CMD (0x42)`
直接停充。

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

细节：

- 每档边界带 **1 °C 迟滞**（升温立刻降档保安全，降温要低于边界 1 °C 才升档，
  避免在边界上反复横跳）；
- 插拔线缆时 `smb_status_change_work` 会立刻补跑一次，不用等 30 秒；
- 只影响 CC 阶段电流，CV 末尾本来就只剩 200 mA，不受影响；
- 表在 `drivers/power/supply/qcom_smbx.c` 的 `smb_jeita_table[]`，改档位改这一处。

测试不用真加热，热区支持注入假温度：

```bash
Z=/sys/class/thermal/thermal_zone$(for z in /sys/class/thermal/thermal_zone*; do       [ "$(cat $z/type)" = "qcom-battery" ] && echo ${z##*thermal_zone}; done)
echo 45000 | sudo tee $Z/emul_temp    # 伪造 45 °C → 应降到 1.5 A
sudo journalctl -b -k | grep JEITA
echo 0     | sudo tee $Z/emul_temp    # 取消伪造，恢复真实温度
```

## 9. 边界与已知限制

- **只有 USB2**：板子没走 SS 差分对，sdm670-usb.dtsi 里 `ssusb@a800000`
  是删掉的，跟 Type-C 栈无关。
- **没有 DP alt mode**：PM660 侧没有 SBU/DP 通路，USB-C 转 HDMI 不工作。
- **source 电流档位**：硬件广告的 Rp 电流由 PM660 内部配置决定，驱动只按
  角色切换，不按 PDO 调档；`source-pdos` 只用于 PD 报文。
- **sink 电流**：TCPM 把合约（Rp 档位或 PD PDO）通过
  `tcpc->set_current_limit()` 写进充电器的 `USBIN_CURRENT_LIMIT_CFG`，
  board DT 里 `qcom,typec-managed-icl` 让 qcom_smbx 不再用 APSD 猜的值覆盖
  它。注意 SMB2 的 AICL 仍会在 VBUS 压降时把限流往下收（寄存器读数会比
  合约值低），这是硬件保护，不是 bug。
- **模拟音频附件**（Type-C 转 3.5mm）能识别成 audio accessory，但本机
  3.5mm 走的是模拟耳机孔，没有 SBU 开关，不路由。
- **PD 需要 PD 电源**：普通 5V 充电器只会走 Type-C 默认电流。
- PD PHY 的 `sig-tx` 中断在本机是空事件（主线驱动里只打一行 dev_err），
  驱动没申请它，避免每秒刷屏。

## 10. 回退

不想要 Type-C 栈时：

```sh
sudo rmmod qcom_smb2_tcpm        # 立刻退回 dr_mode 默认（peripheral）
```

彻底回退：把 `&pm660_typec` 的 `status` 改回 `disabled`、`&usb_1_dwc3`
去掉 `usb-role-switch;` 与 `ports` 节点、把 `extcon = <&extcon_usb>;` 加回，
重新构建 `kernel.img` 刷入。注意用户态跟随脚本已经从仓库删除，彻底回退要先
按 `git log -- rootfs/overlay/usr/local/sbin/sirius-usb-bind` 找回那三个文件
（脚本、service、udev 规则），否则没有 Type-C 栈时只能手动写 dwc3 角色
（`usb_role/.../role` 或 debugfs `mode`）+ `otg_boost`。
