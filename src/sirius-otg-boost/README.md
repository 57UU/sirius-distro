# sirius-otg-boost（测试模块源码，转正待合入驱动）

给 PMI660（pm660-charger，驱动 `qcom_smbx`）手动打开 OTG 5V boost，
让手机在 host 模式下能直接给鼠标/U 盘供电。原理见 `docs/USB-HOST-FIX.md`。

## 交付方式：随 SIRIUS_KMOD 包，不进 overlay

- 二进制 `.ko` 不提交到仓库。编好后放进 kmod 包的 `extra/` 目录并重跑
  `depmod`（server2 已备好 `~/sirius-build/kmod-gcbbdbeb2ca53-otg.tgz`，
  即原包 + `extra/otg_boost_test.ko` + 更新后的索引）。
- 下次烘 rootfs 时 `SIRIUS_KMOD` 必须指向上述 `-otg` 包；
  `sirius-otg` 脚本用 `modprobe` 加载。
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

转正方案是把使能逻辑写进 `qcom_smbx` 驱动并重编 `Image.gz`，
本模块届时删除。
