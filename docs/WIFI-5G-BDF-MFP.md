# sirius 5GHz 故障排查：BDF 校准 × MFP 管理帧保护

日期：2026-10-02 ｜ 机型：小米 8 SE（sirius / sdm710 / WCN3990），hwversion 2.3.0 MP CN
路由器：NN6000 V2（ImmortalWRT SNAPSHOT，5G HE80，sae-mixed，ch auto）
手机系统：Debian trixie（mainline 7.2，ath10k_snoc），QMI 上报 board_id=0xff / chip_id=0x30214

## 0. 症状（修之前）

- 距路由器 3m，5G（ch157）信号 -67~-75dBm，协商 MCS0/1，ping 网关 92ms~3.3s，偶发秒级 stall；
- 2.4GHz 正常；同位置其它手机/电脑 5G 满格千兆；家里另一台锐捷路由同样连不上 5G；
- 初步排除路由器与距离因素，锁定手机侧 5G 接收链。

## 1. 结论总览：两个独立病因叠加

| # | 病因 | 修法 | 效果 |
|---|---|---|---|
| 1 | 原厂通版 BDF（`bdwlan.bin`）5G 接收增益与本机 FEM 对不上，高频段差 12~25dB | 换 `bdf_e2.bin`（同 modem 分区原厂工程版校准） | 信号 -62→-50，吞吐 6M→20M（MFP 开着时） |
| 2 | 路由器 MFP（802.11w 管理帧保护）与 2019 版 ath10k 固件犯冲，下行/上行被拖成 100/200ms 双峰抖动 | 路由器关 MFP（`ieee80211w 0`） | ping 77ms→1.2ms，iperf 下行 17M→358M |

单修任何一个都只能好一半；两个都修：ping 1.2~1.8ms，下行 270~358M，上行 415M。

## 2. 新旧固件性能对比（同 MFP 关、同 ch149、同位置）

| 指标 | 旧版 `bdwlan.bin`（原厂通版） | 新版 `bdf_e2.bin`（原厂工程版） |
|---|---|---|
| 信号（手机侧） | -62dBm | -50~-51dBm |
| 协商速率 | MCS1/2 | MCS5 80MHz（520M 档） |
| ping 网关 | 4.9ms（mdev 7.7，max 33ms） | 1.8ms（mdev 0.9，max 5ms） |
| iperf 上行 | 5.7M（10 重传） | 415M（0 重传） |
| iperf 下行 | 12.5M | 270~358M |

参考：笔记本 5G 同位置 261M/0~1ms；Redmi K80 Ultra 同位置 AP 侧 -57~-60dBm（手机 AP 侧 -66~-68dBm，稳定低约 10dB，
2x2 AX 新机 vs 2018 单流机的硬件代差，认了）。

其它候选（同 board-2.bin 容器，只换 sirius 条目 payload，逐个重启验证）：
`bdf_ipa.bin` / `bdf_f31`（19152 补零）：认证 3/3 超时，完全不可用；
`xiaomi_beryllium`（Poco F1 同芯片上游版）：与基线无差别；
`bdwlan.b3f`（高通 sdm845mtp 公版短格式）：-63dBm 且只到 40MHz，≈基线。

## 3. MFP 开关对比（e2，同 ch 高频，A/B/A 验证）

- MFP 开：1.9/77.5/203.7ms，mdev 89（抖回来了）；
- MFP 关：0.9/1.2/2.4ms，mdev 0.3；iperf 下行 358M；
- 开→关→开→关四轮一致，另有基线固件 + 无 MFP 对照（4.9ms/5.7M/12.5M），排除 reload 运气因素。

定位过程：双边时间戳（手机 ping `-D` × 路由器 tcpdump 同 seq 对齐）证明抖动在**上行发射方向**
（std 48ms），路由器转发仅 0.1ms；AP 侧该客户端 PS 缓冲/积压全 0、底噪 -106~-118、信道忙 3.6%、
蓝牙/CPU/省电逐项排除；最终关 MFP 即好。旧固件行为符合 802.11w 下管理帧/密钥路径异常
（ipa 版甚至认证都过不了）。

## 4. 2.4GHz 对照：一直没问题

同位置同路由 2.4G（ch6）：信号 -36dBm，ping 1.1/1.8/3.8ms（mdev 0.6），路由器测速 83M，
iperf 上行 76M / 下行 101M。驱动/协议栈/CPU 全栈无辜，病灶锁死 5GHz 射频路径。

## 5. e2 如何修复（原理）

- BDF 是固件的射频参数表：按频段/速率/温度分档的 LNA 增益、PA 功率、天线增益
（同时决定 RSSI 上报和 EIRP 反推发射功率）、DPD、FEM 开关、CCA 门限。
- 原厂 `cnss-daemon` 选型（线刷包 vendor.img 内二进制字符串实锤）：按 board_id 拼
`bdwlan.<id>`（如 `.102`=0x102、`.b04`=0x04），拼不上回落 `bdwlan.bin`；读 `ro.boot.hwversion`
决定工程机用 `bdf_e2.bin`。本机 board_id=0xff 无对应文件＋量产版 → **原厂自己用的也是
`bdwlan.bin`**，35 个文件里没有藏着"正确"的，基线即原厂行为。
- `bdf_e2` 是工程验证版硅片/前端用的那套表（与基线全文差约 3440 字节，整套重调），
其 5G（尤其 5.8G 高频）增益恰好对上本机 FEM：接收 +10~20dB，MCS0→MCS5，stall 消失。
TX 功率同量级（fw_stats 40 vs 38），无超标发射迹象；e2 下驱动上报双链（NSS2）属显示层面，不影响使用。
- per-unit（每台唯一）RF 校准不存在，原厂唯一 per-unit 的是 persist 分区的 MAC。

## 6. 当前状态与待办

- 手机 vendor 分区（`/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin`）已手改为 e2 版
（md5 `63bb8000fe1f…`，基线备份 `/home/u57u/board-2-baseline.bin`，md5 `4002bddb…`）：
重启保持，重刷丢失。**固化进仓库（board-2.bin.sirius 重打包＋重打 vendormod＋重刷）待批准。**
- 路由器最终配置：HE80（VHT80 测试无效已还原）、sae-mixed、MFP 关、txpower 23。
路由器侧只读＋批准过的抓包，未改配置；`tcpdump`（apk 装的）、/tmp 抓包、手机 /home 测试文件、
`workspace/` 测试 BDF 与 vendor-raw.img（3.2G）待收尾清理。
- 曾试：路由器加 monitor 接口会导致 AP down（已 revert，不再用）；手机驱动不支持 monitor＋managed
并发；`iw set bitrates/txpower` 手机侧旋钮对抖动无效（已还原）。

## 7. ath10k 固件（wlanmdsp）版本调查：不建议升级

- 在跑：`WLAN.HL.2.0.1.c13-00149`（2019-12-16，FW API 5）＝ modem 分区自带 ＝ V12.5.1 线刷包
NON-HLOS（2021，最后一个 sirius 版本）——modem 上电自加载，host 侧 `/lib/firmware` 的
wlanmdsp.mbn（上游通版 `HL.2.0-01387`，比在跑的还老）与 60 字节的 `firmware-5.bin`
描述符都不参与加载（dmesg 无 host 加载日志佐证）。
- 全网最新同硅片固件：linux-firmware `qcm2290` 变体 `WLAN.HL.3.3.7.c2-00931`（2024，
Debian trixie `firmware-atheros 20250410` 自带，已取到，主流 mainline 机型如 ginkgo 用 HL.3.0.2）。
- 上新固件的代价：必须动 modem 分区（fastboot 刷改过的 NON-HLOS/modem，有变砖需 EDL 救的风险），
且是跨 SoC 固件（qcm2290 给 sirius 的 WCN3990 用，BDF/QMI 兼容性未知，社区有混用告警先例）。
- 结论：当前 358M/1.2ms 已满血，无升级收益；唯一假想收益是"新固件可能修好 MFP 互操作"
（无证据）。除非将来必须开回 MFP，否则不动。

## 8. e2 固化记录（2026-10-02，用户已批准，未 commit）

- 改动（3 改 + 本文档）：`firmware/ath10k/board-2.bin.sirius` 28 条目中仅
`variant=xiaomi_sirius` 的 payload 由 `bdwlan.bin` 换成 `bdf_e2.bin`
（md5 `4002bddb…`→`63bb8000fe1f…`，与手机实测 358M 的版本逐字节一致，容器其余 27 条＋头部未动）；
`firmware/MANIFEST.sha256` 同步新 sha256（`3f1c7301…`，全量 `sha256sum -c` 通过）；
`kernel/build-vendormod.sh:63` 门禁 md5 同步更新。
- 生效方式：下次在构建机跑 `bash kernel/build-vendormod.sh`（需 kernel submodule kernel/linux-sirius 已构建，
本机没有）重打 vendormod.img 并 `fastboot flash vendor`，手机即永久 e2。
手机当前 vendor 分区手改版与仓库一致，重启保持。

## 9. vendormod 重打记录（2026-10-02，手机原生构建）

- 旧产物归档：`build/` 下 v11/v12/v13 simg＋sha＋zst 移入 `build/prev/`。
- 新镜像 `build/vendormod-e2.img`（256M ext4，label sirius_vendor，sha256 见同名 `.sha256`），
在手机上原生打包（`vbuild.sh`，`build-vendormod.sh` 的手机版：模块取自运行内核
`7.2.3-sdm670-g4fe70fc14282-dirty` 的 `/lib/modules` 1:1 拷贝＋depmod，不需 kernel tree；
其余固件拷贝＋chmod＋md5 门禁与原脚本一致，全部通过；e2fsck clean；已验镜像内 board-2.bin=e2）。
- boot 不用打：BDF 只进 vendor，内核/dtb/ramdisk 无变化，且 kernel tree 只在构建机有。
rootfs 不用打：固件住 vendor 分区，rootfs 本轮零改动（overlay 未动）。
- 刷入：`fastboot flash vendor build/vendormod-e2.img`（手机现已手改 e2 运行中，不急着刷）。
