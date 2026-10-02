# sirius-otg-boost（已退役测试模块源码，仅留档）

给 PMI660（pm660-charger，驱动 `qcom_smbx`）手动打开 OTG 5V boost，
让手机在 host 模式下能直接给鼠标/U 盘供电。原理见 `docs/USB-HOST-FIX.md`。

## 历史交付方式（已退役）：曾随 SIRIUS_KMOD 包，不进 overlay

- 二进制 `.ko` 不提交到仓库。编好后放进 kmod 包的 `extra/` 目录并重跑
  `depmod`（server2 已备好 `~/sirius-build/kmod-gcbbdbeb2ca53-otg.tgz`，
  即原包 + `extra/otg_boost_test.ko` + 更新后的索引）。
- 下次烘 rootfs 时 `SIRIUS_KMOD` 必须指向上述 `-otg` 包；
  旧版 `sirius-otg` 脚本曾用 `modprobe` 加载；现版本直接写驱动 `otg_boost` 属性，不再加载本模块。
- kmod 包更新步骤（server2，有新 `.ko` 时重做）：
  `tar xzf kmod-*.tgz -C stg` → 拷 `.ko` 到 `stg/<ver>/extra/` →
  `/sbin/depmod -b stg <ver>` → 重新打包（保持顶层即 `<ver>/` 的结构）。

## 编译（server2）

`~/kbuild/linux-sirius` 按本库 defconfig `modules_prepare` 后：

```bash
make KDIR=/home/u57u/kbuild/linux-sirius
```

vermagic 必须与手机内核严格一致（`LOCALVERSION` 环境变量留空，
否则多 `+` 后缀导致拒绝加载）。

已转正：使能逻辑已合入上游 `qcom_smbx` 驱动（`otg_boost` 属性），`sirius-otg` 直接写驱动属性，不再 `modprobe` 本模块。本目录仅留档，kmod 包里的旧二进制下次刷新时删掉。
