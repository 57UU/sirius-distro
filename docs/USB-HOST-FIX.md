# sirius USB host / 自供电修复手册

> 2026-09-26 定稿，手机实测通过。对应上游 `57UU/linux-sirius`
> `feat/sirius-7.2 @ 3606aa01`，boot 镜像
> `boot_sys-72-otg-20260926.img`（`E:\Tools\Device\8se\linux\boot-images\`）。

## 1. 背景：之前为什么只能当网卡

- `initramfs` 写死 `configfs g1 + rndis.usb0`，`rootfs` 静态 `usb0 172.16.42.1`。
- 更深一层：`usb_1_dwc3` 的 `dr_mode = "peripheral"` 把角色锁死，
  `echo host > /sys/kernel/debug/usb/a600000.usb/mode` 返回成功但读回
  仍是 `device`，dmesg 无任何动静。此时 `extcon` 已报 `USB-HOST=1`，
  说明线缆检测到了，是控制器拒绝切换。
- pmOS 对同类硬件的描述同样适用：`auto` 会来回抖动，只能手动切；
  PMIC 缺供电逻辑，直插无源设备无电；只测 USB2 速率。

## 2. 修复一：解锁角色（已合入主线）

`arch/arm64/boot/dts/qcom/sdm710-xiaomi-sirius.dts`：

```diff
 &usb_1_dwc3 {
-	dr_mode = "peripheral";
+	dr_mode = "otg";
```

补丁已合入上游 `feat/sirius-7.2 @ 3606aa01`（见 `kernel/` submodule）。
当时为避免重编整个内核，用的是 dtb 热补丁流程（server2 有
`dtc/mkbootimg/unpack_bootimg`）：由在用的
`boot_sys-72-nodebug-20260924.img` 解出 `Image.gz + dtb`，
只改 dtb 后原样回编，`Image.gz`/`initramfs`/`cmdline` 保持不变。

改后行为：开机会跟 extcon 走（目前基本是 host，gadget 需手动绑回）；
`mode` 文件读写正常，`UDC` 解绑/重绑正常。

## 3. 修复二：自供电（驱动已转正，见上游 commit）

- 根因：`qcom_smbx`（pm660-charger）把 OTG 配成软件控制后，
  运行时从不真正打开 boost（全文件唯一的 OTG 写操作在 init 表里）。
  下游 smb5 的等效操作是 `smblib_vbus_regulator_enable`：
  `DCDC_CMD_OTG_REG(0x1140) |= BIT(0)`。
- 交付（已转正）：`qcom_smbx` 驱动上游已合入，供电走 `otg_boost` 属性，`sirius-otg` 脚本直接调驱动；`src/sirius-otg-boost/` 测试模块退役（kmod 包里的旧二进制下次刷新时删掉）。
- 验证：`sirius-otg on`（dmesg 显示 `before=0x0 after=0x1`）→ 鼠标灯亮并枚举为
  `USB OPTICAL MOUSE`（`hid-generic`，`REL_X/REL_Y + 左中右键`）；
  `rmmod` → 灯灭掉线。开关系双向验证通过。
- 编译要求模块 vermagic 与手机内核严格一致
  （`7.2.3-sdm670-gcbbdbeb2ca53`，注意 `LOCALVERSION` 环境变量留空
  否则多一个 `+` 后缀导致 `insmod` 拒绝），用 `~/kbuild/linux-sirius`
  按本库 defconfig `modules_prepare` 后编译，见模块目录 README。
- 鼠标可直插使用（PMI660 boost 带得动）；U 盘待测。

## 4. 手动切换命令（WiFi SSH 下执行）

```bash
sudo sirius-otg on      # host + 自供电（OTG 头+外设）
sudo sirius-otg off     # 关供电，尽力回 gadget（RNDIS 用普通线）
sudo sirius-otg status  # 看角色/供电/usb0

# 以下裸命令仅备用（脚本已包好上面三件事）：
# 切 host（先解绑 gadget）
echo "" | sudo tee /sys/kernel/config/usb_gadget/g1/UDC
echo host | sudo tee /sys/kernel/debug/usb/a600000.usb/mode
echo 1 | sudo tee /sys/bus/platform/devices/c440000.spmi:pmic@0:charger@1000/otg_boost   # 开自供电（驱动属性）

# 切回 gadget（RNDIS）
echo 0 | sudo tee /sys/bus/platform/devices/c440000.spmi:pmic@0:charger@1000/otg_boost   # 先关供电
echo device | sudo tee /sys/kernel/debug/usb/a600000.usb/mode
echo a600000.usb | sudo tee /sys/kernel/config/usb_gadget/g1/UDC
# 注：启动后手动重绑的 gadget，PC 侧需配静态 172.16.42.2/16
#（initramfs 的 udhcpd 只在开机时跑一次）
```

不要往 `mode` 里写 `auto`。

## 5. gadget 自动重绑
- `sirius-usb-bind`（只绑不解）：role 为 device 且 UDC 空就绑回，`usb0` 拉起。
- `99-sirius-usb.rules`（udev，extcon change 触发）+ `sirius-usb-bind.timer`（每 15 秒兜底），两个口味构建脚本都已 enable timer。
- 实测：extcon 在真实拔插时不发 uevent（monitor 全空），udev 规则留作摆设，timer 是真正干活的。
- UDC 解绑是软件状态：单纯拔线不会掉绑，只有角色翻转才踢掉；掉绑不影响已绑定的，开机/initramfs 绑一次就行。

## 6. 已知限制与待办

- ID 接地的线（OTG 转接头、9008 工程线、部分 A-to-C 线两面都接地）会把 `gpio38` 拉低，手机秒切 host，RNDIS 起不来；RNDIS 必须用普通直连线，A-to-C 先翻面，不行就换 C-to-C。被钉住时可手动 `echo device` + 绑 UDC抢回，只要不拔线就不会掉。
- `extcon-usb-gpio`（ID gpio38）在本机上连 PC 线也报 `USB-HOST=1`，
  线对的情况下 extcon 自动跟随是准的（普通线进 device，ID 接地的 OTG 线进 host）；但往 mode 里写 auto 仍别碰，拿不准就手动 echo。
- 同一 OTG 头在安卓机上能直接用，是因为安卓走 Type-C CC 检测；本机主线缺 tcpm/pdphy 那套栈，只剩 ID 脚 extcon。头没问题，是驱动栈的代差；完整修法是把 CC 检测接到角色切换+boost，工作量大，与驱动转正一起排期。注意部分廉价 OTG 头根本没接 ID 脚（gpio38 常高），这时角色不会自动切，必须手动 echo host；供电走驱动自动（认 Rd 那面）或手动 otg_boost。
- 朝向矩阵（实测）：A 面出 Rd（30E≈0x53/0x93，ID 悬空）→ 供电自动、角色手动；B 面接地 ID（gpio 低，30E≈0x91 无 Rd）→ 角色自动 host、供电手动。两面都能用，各需一步手动。B 面用完拔线后必须手动关供电（echo 0 > otg_boost），因为检测位从未置位、自动关不会触发。
- 开机默认会被带到 host：`initramfs` 需加一行先 `echo device`
  再绑 `UDC`，否则开机插线就没有 RNDIS（待改，
  `boot/initrd/initramfs/init_functions.sh:setup_usb_network`）。
- 转正（已完成）：boost 已写进 `qcom_smbx` 随模块走，未动 `Image.gz`；测试模块退役，`sirius-otg` 改调驱动属性。待办：kmod 包去掉旧二进制、`initramfs` 开机默认 gadget、CC 完整栈。
- 回滚：`fastboot flash boot` 刷回 `boot_sys-72-nodebug-20260924.img`。
