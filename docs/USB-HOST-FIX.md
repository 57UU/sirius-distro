# sirius USB host / 自供电修复手册

> 2026-09-26 定稿，手机实测通过；上游 `57UU/linux-sirius` `feat/sirius-7.2 @ 3606aa01`，boot 镜像 `boot_sys-72-otg-20260926.img`（`E:\Tools\Device\8se\linux\boot-images\`）。
>
> **2026-10-19 更新**：角色判断已由内核 Type-C 栈接管，「用户态角色跟随」（`sirius-usb-bind` + `99-sirius-usb.rules` + `sirius-otg` 的 manual pin）已删除，现行方案见 [`USB-TYPEC.md`](USB-TYPEC.md)；仍有效 §2（`dr_mode="otg"`）、§3、§9 与 §7 的热替换教训，§5/§6/§8 为历史。

## 1. 背景：之前为什么只能当网卡

`initramfs` 写死 `configfs g1 + rndis.usb0`（`rootfs` 静态 `usb0 172.16.42.1`）；`usb_1_dwc3` 的 `dr_mode = "peripheral"` 锁死角色——`echo host > /sys/kernel/debug/usb/a600000.usb/mode` 返回成功但读回仍 `device`（`extcon` 已报 `USB-HOST=1`，是控制器拒绝切换）。pmOS 对同类硬件同样适用：`auto` 会抖只能手动切，PMIC 缺供电逻辑，只测 USB2 速率。

## 2. 修复一：解锁角色（已合入主线）

`arch/arm64/boot/dts/qcom/sdm710-xiaomi-sirius.dts`：

```diff
 &usb_1_dwc3 {
-	dr_mode = "peripheral";
+	dr_mode = "otg";
```

已合入上游 `feat/sirius-7.2 @ 3606aa01`（`kernel/linux-sirius` submodule）。当时用 dtb 热补丁流程（server2 的 `dtc/mkbootimg/unpack_bootimg`）：从 `boot_sys-72-nodebug-20260924.img` 解出 `Image.gz + dtb`，只改 dtb 后原样回编，`Image.gz`/`initramfs`/`cmdline` 保持不变。改后跟 extcon 走（基本是 host，gadget 需手动绑回）；`mode` 读写、`UDC` 解绑/重绑正常。

## 3. 修复二：自供电（驱动已转正）

- 根因：`qcom_smbx`（pm660-charger）把 OTG 配成软件控制后从不打开 boost（唯一 OTG 写在 init 表里）；smb5 的等效操作 `smblib_vbus_regulator_enable`：`DCDC_CMD_OTG_REG(0x1140) |= BIT(0)`。
- 交付：`qcom_smbx` 上游已合入，供电走 `otg_boost` 属性，由 TCPM 的 `set_vbus()` 切到 source 时自动打开；`src/sirius-otg-boost/` 测试模块退役（kmod 包旧二进制下次刷新时删掉）。
- 验证（历史）：`sirius-otg on`（dmesg `before=0x0 after=0x1`）→ 鼠标枚举为 `USB OPTICAL MOUSE`（`hid-generic`，`REL_X/REL_Y + 左中右键`）；`rmmod` → 灯灭掉线。
- 模块 vermagic 必须与手机内核严格一致（`7.2.3-sdm670-gcbbdbeb2ca53`，`LOCALVERSION` 留空否则多一个 `+` 后缀导致 `insmod` 拒绝），用 `~/kbuild/linux-sirius` 按本库 defconfig `modules_prepare` 后编译，见模块目录 README。
- 鼠标可直插使用（PMI660 boost 带得动）；U 盘待测。

## 4. 查看状态（WiFi SSH 下执行）

`sirius-otg` 只剩只读诊断（`on/off/auto` 已删除，会提示角色由线缆决定）：

```bash
sudo sirius-otg status   # 角色归属、power/data role、partner、boost、usb0
sudo sirius-otg watch 1  # 每秒刷新
```

调试角色直接写 dwc3 的角色开关，TCPM 下一次插拔时重新接管：

```bash
echo host   | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
echo device | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role
```

没有 Type-C 栈时旧路径是 `echo host > /sys/kernel/debug/usb/a600000.usb/mode` + `otg_boost`（现只作应急）；不要往内核 `mode` 写 `auto`。这些裸命令只在 `qcom_smb2_tcpm` 没加载时才有意义。

## 5. 角色跟随（已删除，2026-10-19）

用户态伪 auto（`sirius-usb-bind` 按 pm660-charger / usb_device / qcom_smbx 三路 udev 事件摆角色，回 device 前关 boost 防 backpower 再绑回 UDC；`sirius-otg on/off` 用 `/run/sirius-usb-manual` 钉住状态）与 TCPM 抢角色、抢 boost 位，已删除：`usr/local/sbin/sirius-usb-bind`、`etc/systemd/system/sirius-usb-bind.service`、`etc/udev/rules.d/99-sirius-usb.rules`、`sirius-otg` 的 manual pin / `on` / `off` / `auto`。角色要强制就写 `usb_role/.../role`（纯内核调试）。历史：extcon 真实拔插不发 uevent（gpio38 中断没动静），旧 extcon 规则一直是死的。

## 6. 局限（历史）

ID 是 Micro-USB 时代遗留的 OTG 识别针（接地 host / 悬空 device），CC 才是 Type-C 的完整协商输入；旧方案只有两个单边信号，故有「部分线要翻面」「ID 接地的线钉死 host」「切了角色还要手动开供电」这些毛病，已被内核 CC 栈取代。物理限制仍在：本机只有 USB2（无 SS 差分对）、没有 SBU/DP 通路。

## 7. 代办 / 注意事项

- ~~CC 完整栈~~：2026-10-18 落地（`docs/USB-TYPEC.md`），2026-10-19 删掉用户态跟随；`extcon` 节点保留但不再参与角色判断。
- **别热替换 charger 驱动**：rmmod qcom_smbx 会在注销电源供应时吃 WARN（fg 还拿着引用）并在通知链里留坏表项，之后每次电源状态变化都 oops 掉一个 kworker，第二次 rmmod 直接 D 住卸不掉只能重启；测驱动改动请走重启（新模块已进 lib/modules，重启即生效）。

## 8. 状态机（已删除）

旧用户态角色状态机（`NO_CABLE` / `DEVICE` / `HOST_IDLE` / `HOST_POWERED`，mermaid 图）随 §5 删除。

## 9. Windows 认不到 RNDIS：gadget VID:PID 被 Google 驱动劫持（2026-10-13）

现象：手机侧 gadget 正常（单 RNDIS、UDC 已绑、usb0 UP 有 IP），Windows 上只有一个 OK 的 Android ADB Interface，没有 RNDIS 网卡，`172.16.42.1` 不通；重绑 UDC/换线无效。

根因：gadget 沿用 pmOS initrd 默认 `18D1:D001`，本机 Google USB 驱动（oem31.inf v9.0.0.0）有 `USB\VID_18D1&PID_D001` 精确匹配，Windows 排序里它优先于 inbox RNDIS 的 compatible-ID，设备被绑成 ADB 口（`MatchingDeviceId` 实测即此条）。

修复：gadget 改用经典 Linux RNDIS ID `0525:A4A2`（`boot/initrd/initramfs/init_functions.sh` 里 `setup_usb_network` 的默认值）。fastboot（`18D1:D00D`）不受影响，udev/脚本无一处依赖旧 VID:PID。改后 Windows 上 inbox Remote NDIS 驱动，DHCP 拿到 `172.16.42.2`，USB ssh 恢复。
