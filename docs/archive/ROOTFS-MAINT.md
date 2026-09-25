# sirius rootfs 维护手册（Debian trixie / 小米 8 SE）

> 适用：已进系统的 Debian rootfs（日常维护）＋全新刷入后的首次配置。
> 背景原理见 `HANDOFF-2026-09-19.md`（§12–§18），WiFi 专项步骤见 `WIFI-ROOTFS-SETUP.md`；
> 本文只写"现在是什么样、平时怎么管"，是管理员视角的操作手册。
> 内核：`7.2.3-sdm670`（分支 `feat/sirius-7.2`，远端 `57UU/linux-sirius` 同名分支，
> 配置见 `arch/arm64/configs/sdm710-xiaomi-sirius_defconfig`），启动镜像 `boot_sys-72-wifi-v2.img`。

## 1. 全新 rootfs 首次配置（按序，不可跳步）

```bash
ssh u57u@172.16.42.1   # RNDIS，sudo 免密
sudo date -s '2026-09-19 12:00:00 +0800'   # ①先扶正时间，否则 https 证书全未生效、apt 全灭
sudo resize2fs /dev/mmcblk0p81             # ②先扩根分区（镜像 6G/分区 51G，不扩很快 91% 满，关机会慢 10 分钟）
sudo journalctl --vacuum-size=120M; sudo apt clean
sudo apt update && sudo apt install -y rmtfs tqftpserv qrtr-tools wireless-tools systemd-timesyncd util-linux-extra
sudo timedatectl set-ntp true              # ③NTP 自启（唯一对时手段）
# ④摆固件（见 §4 表），⑤enable §2 的服务，⑥按 §7 验证
```

## 2. 常驻服务（当前 enabled 清单，勿动）

| 服务 | 作用 | 没它会怎样 |
|---|---|---|
| `rmtfs`（`-r -s -o /var/lib/rmtfs`） | EFS 代理（modem 读 modemst1/2/fsg/fsc） | 基带崩 |
| `tqftpserv` | RFS/TFTP（modem 取固件/mcfg） | 基带起不来 |
| `pd-mapper`（`/usr/local/bin/pd-mapper` 自编译） | servreg 位置库（含 wlan_pd 映射） | 无 WLFW、无 wlan0 |
| `systemd-timesyncd` | NTP，唯一对时手段 | 重启回到 1978 |
| `NetworkManager`（+dispatcher/wait-online） | WiFi/网络 | 无网 |
| `bluetooth`（+`hci_uart/btqca` 自启） | 蓝牙 | 无 BT |
| `wifi-shutdown.service` | 关机前 disconnect＋rmmod ath10k | 关机路过驱动残留 |
| `60-adsp-norecovery.rules`（udev） | 禁 ADSP recovery（避内核死锁） | D-state kworker 堆积 |
| `10-wlan0.link` | wlan0 命名/MAC 相关（MAC 持久化未闭环，见坑） | — |

检查：`systemctl is-active rmtfs tqftpserv pd-mapper systemd-timesyncd`；
基带三件套看 `qrtr-lookup | grep -E " 69 | 64 "`（69=WLAN 固件服务，64=servreg）。

另：`/usr/local/sbin/safe-reboot`（sysrq s+u+b）是可靠重启通道；`60-sysrq.conf` 已配。

## 3. 时间方案（只剩 NTP，别再加东西）

- 开机 RTC 恒为 1978（PMIC RTC 对 Linux 只读＋无 SDAM＋出厂安卓亦只读，HANDOFF §18 全卷结论），
  指望写 RTC 已彻底关闭。
- 当前链：开机 1978 → WiFi 连上后 timesyncd 几十秒扶正 → 之后自持。
  `fake-hwclock`、`modem-time-sync`（NITZ）已按用户决策拆除（源文件在 `scripts/modem-time/` 留档）。
- 已知代价：每次重启到 WiFi 连上前为 1978；无 WiFi 时一直 1978。这是接受过的 trade-off。

## 4. 固件与文件布局（手机路径 ↔ 料源）

| 手机目标 | 本机源（`E:\Tools\Device\8se\linux\`） | 服务器镜像 | 说明 |
|---|---|---|---|
| `/lib/firmware/qcom/sdm710/pyxis/`（mba/modem.*b*/adsp/wlanmdsp/qdsp6m/modem_pr/5×jsn） | `firmware/jsn/`＋设备分区只读拷出（本机无存货） | `firmware/pyxis-dsp/`（**`mba.mbn` 必须用本机的，md5=`62520866…cfd395`**） | 缺 jsn 则无 WLFW |
| `/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin` | `firmware/ath10k/board-2.bin.sirius` | 同名 | 自制校准 variant=xiaomi_sirius |
| `/lib/firmware/qca/crbtfw21.tlv`（并删 `crnv21.bin`） | `firmware/qca/ubuntu25-crbtfw21.tlv` | `firmware/crbtfw21.tlv.ubuntu25` | 蓝牙（Debian 自带版会死在 0x204B） |
| `/usr/local/bin/pd-mapper` | `pd-mapper-arm64` | `pd-mapper-src/`（源码，可重编） | 自编译＋query 日志 |
| `/usr/local/bin/tqftpserv-dbg` | `tqftpserv-dbg-arm64` | `tqftpserv-src/` | 调试版（已去 `-d`，`zz-dbg.conf`） |

一键打包（在调通的手机上，不含内核）：见 `WIFI-ROOTFS-SETUP.md` §7 `sirius-wifi-pack.tgz`。
大备份：`.tmp\sirius-state-20260919.tgz`（114M，整机快照）。

## 5. 日常维护（每月或出问题时看一眼）

```bash
df -h / | tail -1                        # 根分区>80% 就处理（resize 已到顶，只能清）
journalctl --disk-usage                  # >200M 则 --vacuum-size=120M
sudo apt autoremove --purge; sudo apt clean
timedatectl | grep -E "synchronized|NTP" # 在线时应为 yes/active
qrtr-lookup | grep -c ATH10k; ip -br link | grep wlan0   # WiFi 存活
```

## 6. 红线（碰了会出大事，按严重排序）

1. **绝不写 `modem/NON-HLOS/modemst1/modemst2/fsg/fsc/persist`**；基带运行时不读 modem 原始分区（会硬挂，只能拔电池/硬重启）。
2. 关机/reboot 给 15 分钟耐心再判死刑；急用走 `safe-reboot`。屏幕冻结点不可信（fb 早死）；`ping 灭≠关机成`。
3. systemd drop-in 按文件名排序：自定义 ExecStart 用 `zz-*.conf`（`override-dbg.conf` 会被 `override.conf` 覆盖）。
4. FW 运行后 `ip link set wlan0 address` 会把固件弄僵（恢复靠 ath10k rmmod/modprobe）；真 MAC（persist 只读 `48:2c:a0:4b:c6:0d`）持久化未闭环，随机 MAC 可用。
5. `chan info: invalid frequency 0` benign；`ota_firewall/ruleset` 取不到正常；ADSP 40s crash-loop 与 WiFi 无关（音频无声卡，另立项）。
6. `scp -r` 别直接拷内核源码树（顺着 build 软链接拷全树，先 tar 排除）。
7. 中转文件放 E 盘，勿放 C 盘；PowerShell 远程命令避开 `$`、反引号（会被本地展开吃掉）。

## 7. 故障速查

| 现象 | 先查 | 多半是 |
|---|---|---|
| 无 wlan0 | `qrtr-lookup` 有无 69 | pd-mapper/jsn 缺（§4） |
| 时间 1978 | `timedatectl` NTP active? WiFi 通？ | 没网（NTP 够不着）；apt 前先 `date -s` |
| apt 全 Ign | `date` 年份 | 1978→证书未生效，先扶正 |
| 关机慢/疑似卡死 | `df -h` 根分区；等 15 分钟 | 磁盘满（已扩 50G，复发先查这个） |
| 蓝牙 DOWN | `crbtfw21.tlv` 版本/`crnv21.bin` 是否复活 | 包升级覆盖了固件，重摆 §4 |
| SSH 连不上 | ping→RNDIS 网卡在否→手机是否活着 | RNDIS 偶发掉线，重插/等自恢复 |

## 8. 地址速查

手机 `ssh u57u@172.16.42.1`（RNDIS，sudo 免密）｜服务器 `ssh -p 31739 u57u@server.57u.tech`
（`~/projects/mi8se-linux`）｜本机 `E:\Tools\Device\8se\linux\`｜内核远端 `57UU/linux-sirius`
（`feat/sirius-7.2`）｜fastboot ID `2df46452`（USB2 口，音量下＋电源手动进，只刷 boot 分区）。

