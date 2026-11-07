# 充电：双路硬件、PD/QC 协议与实测

> 2026-11-08 实机确认（kernel `7.3.0-sdm670+`，Wi-Fi SSH）。本文覆盖 PM660 SMB2 主充、SMB1355 并联从充、
> PD 与 QC3/HVDCP 的区别、电池 profile 现状，以及电池端/输入端的实测功率。
> Type-C/PD 栈本身见 [USB-TYPEC.md](USB-TYPEC.md)。

## 1. 硬件拓扑

板上有两路充电：

| 路 | 芯片 | 总线 | 作用 | 主线现状 |
| --- | --- | --- | --- | --- |
| 主充 | PM660 SMB2 | SPMI | USB 输入、Type-C/PD、OTG boost、电池主充电环路 | `qcom_smbx` 已支持 |
| 从充 | SMB1355 | i2c10（`a88000`），7-bit **0x0c** | 并联充电，与主充 50/50 分担 FCC | **无驱动、DT 注释掉、GPIO 未开** |

SMB1355 细节：

- 芯片 ID：寄存器 `0x01ff` 读回 `0xff`（SMB1355；`0x01` 是 SMB1354）。`0x08` 地址在板上是空的，
  安卓 DTS 里那两个 `smb1355@8` / `smb1355@c` 是参考设计抄下来的，实际只贴了 `0x0c` 这一颗。
- 使能：**PM660 物理 GPIO11，高有效**。主线当前没描述它，`/sys/kernel/debug/gpio` 显示 `gpio11: in low`，
  芯片处于 shutdown，i2c 不应答。
- 中断：TLMM GPIO54（低电平有效）。
- 测温：PM660 RRADC ch2/ch12（安卓 `xiaomi-sdm710-common.dtsi` 的接法；参考设计原本是 ch8/ch10）。
- 安卓的用法：`smb1355-charger.c` 注册名为 `"parallel"` 的 power_supply，`battery.c` 的 `get_fcc_split()`
  按 50/50 把总 FCC 分给主/从；总 FCC 由板级 `qcom,fcc-max-ua = 3000000` 封顶。

主线缺口：

- `sdm710-xiaomi-sirius.dts` 的 `&i2c10` 只有 `// smb1355@8` / `// smb1355@c` 两行注释；
- `drivers/power/supply/` 没有 smb1355 驱动；
- `qcom_smbx` 没有 parallel/从充分流逻辑；
- PM660 GPIO11、TLMM GPIO54、RRADC 测温都没描述。

### 1.1 实机确认方法

1. 找到 i2c10 的总线号：`ls -l /sys/bus/i2c/devices/ | grep a88000`（本机是 `/dev/i2c-2`；rootfs 默认没装
   `i2c-tools`，可用 i2c-dev ioctl 临时探测）。
2. PM660 GPIO11 是 **物理编号**，gpio chardev 的 **line 10**（PMIC debugfs 的 `gpioN` 是 1-based）。
   拉高前 `0x0c` NAK，拉高后 `0x0c` ACK。
3. 读 ID：16-bit 寄存器地址，`0x01ff` 返回 `0xff` 即 SMB1355。
4. 读状态：`0x1042`（CHGR_ENABLE）= `0x00`、`0x1061`（FCC）= `0x00`，说明芯片虽然上电但没有被配置充电。

## 2. 协议：PD 9V 是好的，QC3/HVDCP 没开

| 充电器 | 协议 | 主线行为 |
| --- | --- | --- |
| **PD 充电器**（支持 USB-PD） | USB-PD，CC 线，TCPM 谈 PDO | **9V/2A 合约**，实测输入 13–15W |
| **QC3 充电器**（HVDCP） | HVDCP/QC3，D+/D- 脉冲 | **停在 5V**：`qcom_smbx` 初始化把 `HVDCP_EN` 写 0；安卓是 `HVDCP_EN\|AUTH_ALG`，PD 不活跃时打开 |
| 普通 5V DCP/CDP | BC1.2 | ICL 由 APSD/硬件 override 决定；PC CDP 实测 850mA→1.075A。安卓对 DCP 额外投 2.7A，主线没有 |

注意：`pm660-charger/usb_type` 是 **APSD/BC1.2 的结果**，PD 充电器也可能显示 `DCP`。判断 PD 要看：

```sh
cat /sys/class/typec/port0-partner/supports_usb_power_delivery   # yes
cat /sys/class/power_supply/tcpm-source-psy-*/uevent             # USB_TYPE=PD, VOLTAGE_NOW=9000000
```

### 2.1 PD 实测（2026-11-08，屏幕最亮，Wi-Fi 待机）

| 项目 | 数值 |
| --- | --- |
| 合约 | 9V / 2A（`CURRENT_MAX=2000000`） |
| USBIN | 8.53–8.59V（线上压降约 0.4V），1.53–1.79A |
| 输入功率 | **13.1–15.3W** |
| 电池侧 | 4.397V × 2.53–2.83A = **11.1–12.5W** |
| 效率 | ~84% |
| 系统占用 | ~2–2.8W（屏幕最亮 + Wi-Fi） |
| 电池温度 | 38.5°C |

测试时 FG 报 73%，但电池端已经 4.4V、进入 CV，所以电流从 1.79A 往下掉。**这是 SOC 曲线问题（见 §3），
不是充电器功率不够**：9V×2A 的 18W 里，手机实际抽 15.3W、电池拿 12.5W，已经接近该合约的实际上限。

## 3. 电池 profile 与 SOC

主线 `qcom_fg` 现在会在 probe 后加载电池厂商的 224 字节 FG SRAM profile
（`qcom,fg-profile-data`），不再只用 OTP 默认曲线：

- DT 里放两套 profile：ATL（`qcom,batt-id-kohm = <68>`）和 Coslight（`<100>`），
  各 224 字节；FG 用 `<&pm660_rradc 0>` 读 batt-id（IIO 电阻通道）。
- probe 后 2s 加载：读 batt-id → 按 ±15% 选 profile → IMA word 24 写 224 字节
  → word 79/offset 3 置 `PROFILE_LOAD|HLOS_RESTART` → `BATT_SOC_RESTART(0x48).bit0`
  重启 FG → 等 SOC ready → `power_supply_changed`。
- 实测（2026-11-08）：batt-id ≈ 69 kΩ → 选中 ATL 68k profile 0；充满后
  `capacity=100%`。加载前充电中段的 73% 是当时确实没充满，不是坏读数；profile 的作用
  是让电量曲线和电池实际一致，不是把 73 硬改成 100。

顺带修了 RRADC 驱动的两个 batt-id 问题：batt_id 通道要声明
`IIO_CHAN_INFO_PROCESSED`，且 `rradc_read_raw()` 的 PROCESSED 分支原来把
`scale_fn` 的返回值（0）赋给 `*val`，会把算好的欧姆值冲掉（表现为
`iio_read_channel_processed()` 返回原始码或 0）。

安卓侧参考（数据和加载序列的来源）：

- `batterydata-e2-atl-3120mAh.dtsi`：ATL，`batt-id-kohm = 68`，3120mAh，4.4V，3A；
- `batterydata-e2-coslight-3120mAh.dtsi`：Coslight，`batt-id-kohm = 100`，其余相同；
- `qpnp-fg-gen3.c` 的 profile load 序列、`fg-memif.c` 的 IMA 读写。

风险：profile 选错会让 SOC 和充电终止判断异常，换电池/换批次时要确认 batt-id；
它修的是 SOC 曲线，不会让 2018 年的老电芯恢复 3120mAh。

## 4. 功耗实测（电池侧，无充电器）

| 场景 | 电池端功率 |
| --- | --- |
| 待机（亮屏 + Wi-Fi） | ~1.4–1.9W |
| CPU 8 核 + 8×vkcube | 3.5–3.9W |
| CPU 8 核 + glmark2 `refract` 离屏 1080p | 4.5–4.7W |
| 上述 + 屏幕最亮（1023/1023） | **5.1–5.3W** |
| PC USB-CDP 输入上限 | 4.25W（850mA）→ 5.4W（1075mA） |

- 电脑 CDP 口双烤 9 分钟：电量 100% 没掉；电池净电流 **-29mA（放）~ +4.4mA（充）**，基本为零。
  这个口的 ICL 会自己从 850mA 抬到 1075mA；换成 500mA 的口或更重的负载（相机/Modem）会开始掉。
- 带载时电池电压从空载 ~4.1V 掉到 3.8V 左右是内阻压降，功率按带载 V×I 算。

## 5. 待办（按收益排序）

1. **HVDCP/QC2/QC3**：让原装 QC3 头也能 9V（当前只 5V），小改动、收益直接。
2. **SMB1355 并联从充**：驱动 + DT + `qcom_smbx` 分流。总 FCC 3A 封顶，补它**不提高峰值**，
   主要降低单颗发热、维持长时间 3A；要突破 3A 才需要它。
3. 板级参数：DCP 2.7A、JEITA 表与安卓对齐。

## 6. 相关文档

- [USB-TYPEC.md](USB-TYPEC.md)：Type-C/PD 栈、角色切换、OTG、软件 JEITA
- [USB-HOST-FIX.md](USB-HOST-FIX.md)：OTG boost 与角色抖动历史
