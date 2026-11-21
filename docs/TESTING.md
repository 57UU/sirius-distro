# 测试：一键硬件/迁移自检

`sudo /mnt/sysmod/glue/bin/sirius-test` 会跑完一整套即时检查并给出 PASS/FAIL/SKIP
汇总。脚本本身随 glue 层打进 **system 分区**，升级只刷 system。默认**快速模式**只包含：现在就能得到
结果、且不依赖外部条件的检查。

```sh
sudo /mnt/sysmod/glue/bin/sirius-test          # 快速模式（默认，约 30s）
sudo /mnt/sysmod/glue/bin/sirius-test --full   # 额外跑依赖外部条件的检查
sudo /mnt/sysmod/glue/bin/sirius-test --no-wait # 不等开机就绪（已有代码会用这个）
```

脚本开头会做一次 **preflight**：如果刚开机、systemd/glue 服务还没起来，会先等
系统状态和关键 unit 就绪（最多 90s）；刚开机 180s 内还会等 WiFi phy、wlan0、
QRTR modem 和 uim-watch 就绪（最多 120s）。已就绪时零等待，避免把启动过程误判成
硬件失败。

退出码：全部通过（含 SKIP）为 0，有 FAIL 为 1。

## 快速模式覆盖

- **system 分区/迁移**：cmdline、ro 挂载、modules/firmware bind、glue ABI/manifest、
  生成器 unit 数量、`/etc` 无影子软链、无 failed unit
- **glue 服务**：常驻 unit active、oneshot `Result=success`、timer active、
  主守护进程确实从 `/mnt/sysmod/glue/bin` 运行
- **运行时配置**：`sirius-glue-setup` 执行结果、udev/modules-load/tmpfiles/network 软链、工厂 WiFi MAC drop-in（没有工厂数据或存在用户主 `.link` 时 SKIP）、`/dev/qrtr0`、ALSA UCM
- **模块/固件**：WiFi/BT/rmtfs 模块，ath10k/qca/touch/tas2557/regdb 固件，ADSP 目录
- **传感器（SSC）**：`sirius-sensors`、runtime 树、加速度计（三轴合加速度≈9.8，不受摆放方向影响）、磁力计、指南针
- **音频/显示/输入/相机**：server 版 logind 的实际电源键短按策略为 ignore（交给 Orbital）、声卡、PipeWire sink、DSI connected、触摸/按键软链、video 节点
- **无线/蓝牙/Modem**：phy0/wlan0、WiFi 扫描（扫到 AP 为 PASS；扫描成功但 0 个 AP 为 SKIP；`iw scan` 本身失败为 FAIL）、hci0+蓝牙地址、QRTR modem 服务、SIM（没插卡则 SKIP）
- **电源/温度/zram**：电池电量、充电器节点、Type-C PD 控制器、thermal zone、zram swap
- **其他**：系统时间（RTC 未同步则 SKIP）、USB RNDIS（非 gadget 模式 SKIP）

已知不支持的项目只 SKIP 不 FAIL：光感/距感（SSC 未注册）、`adsprpcd-audiopd`
（已知 auto-restart 基线，音频实际正常）。

## --full 额外内容（都需要外部条件）

- PD 快充：只在**实际协商到 >5.5V** 时 PASS，否则 SKIP（`usb_type` 只是能力表，
  不代表插着 PD 充电器）
- 光感/距感的实际返回（预期 UNKNOWN）
- 音频播放/PD 功率/摄像头出图等交互类测试只 SKIP，不自动执行

## 部署

脚本源码/内容在 `glue/bin/sirius-test`，由 `./build.sh kernel` 打进 `kernel.img`
的 system 分区；rootfs 不建软链，直接运行上面的 system 路径。临时使用可：

```sh
scp glue/bin/sirius-test u57u@172.16.42.1:/tmp/
ssh u57u@172.16.42.1 'sudo chmod 755 /tmp/sirius-test && sudo /tmp/sirius-test'
```
