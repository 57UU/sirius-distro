# 小米 8SE（sirius / sdm710）WiFi 手动修复手册

> 适用起点：刚刷好 Debian trixie，已是 `7.2.3-sdm670` + wifi-v2 DT 的内核，`ath10k_snoc` 能绑定但 `ip link` 里没有 `wlan0`。
> 风格说明：每一步只讲“在干什么、东西哪来的、做完应该看到什么”，原理为主，不堆长脚本、不展开分支排查。
> 配套（蓝牙 / NTP / bake 进镜像 / 重启挂起）不在本文范围。

## 0. 总览：先理解卡点在哪

**在干什么：** 把思路从“缺驱动”扭到“缺基带服务”。

WCN3990 在这代 SoC 上不是 AP 直接加载固件的，真固件 `wlanmdsp.mbn`（约 3MB）是由基带（MPSS）里的 `wlan_pd` 拉起来的。主线内核不管喂固件，只做一件事：`ath10k_snoc` 在 probe 末尾 `qmi_add_lookup(WLFW)` 干等。所以整条链是：

```
mba.mbn -> modem.mbn（.b00..b29 分片）由 qcom_q6v5_mss 加载
-> 基带起来 -> wlan_pd 拉起 wlanmdsp.mbn
-> QRTR 出现 WLFW（service 0x45 = 十进制 69）
-> ath10k 收到 FW_READY -> 上电 -> 出现 wlan0
```

**东西哪来的：** 结论来自实测 + 源码核对，详细取证在 `HANDOFF-2026-09-19.md §12–§16`，操作配方在 `WIFI-ROOTFS-SETUP.md`。本文只提炼主链。

**做完应该看到什么：** 认同“驱动/DT/供电都不用动，要补的是 AP 侧三个服务 + 两批固件”，再往下做。

内核前提（不满足就不用往下试）：`boot-images\boot_sys-72-wifi-v2.img` 对应版本，即 DT 里有 `wifi-firmware` 节点、`calibration-variant=xiaomi_sirius`。全程只动 AP 侧，基带运行时顺手一提：别去读 modem 原始分区，会硬挂。

## 1. 准备：连上、扶正时间、腾出空间、装包

**在干什么：** WiFi 修复全在手机上执行，所以先保证能连上、能 apt、有空间。时间不对会导致 https 证书全判无效、apt 全是 `Ign`；根分区不扩会很快写满。

**东西哪来的：** 手机经 RNDIS 在 `172.16.42.1`，PC 侧 `ssh u57u@172.16.42.1` 即可，sudo 免密。

关键命令要点：

```bash
sudo date -s '2026-09-19 12:00:00 +0800'
sudo resize2fs /dev/mmcblk0p81
sudo apt update && sudo apt install -y rmtfs tqftpserv qrtr-tools wireless-tools
```

**做完应该看到什么：** `date` 正常、`df /` 有空余、`rmtfs/tqftpserv` 已可安装。装包失败先回头查时间和 apt 源，别怀疑 WiFi 本身。

## 2. 固件摆位：把基带和校准要吃的文件放对地方

**在干什么：** 基带和 ath10k 都是“只认固定路径”，文件不在位就静默等待，不报错。一次把三类摆齐：校准、基带+WLAN 固件、服务注册表。

**东西哪来的（只给主来源）：**

| 手机目标 | 主来源 | 在干什么 |
|---|---|---|
| `/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin` | 本机 `firmware/ath10k/board-2.bin.sirius` | 自制校准，ath10k 做 BDF 时要用 `xiaomi_sirius` variant，原文件先备份再覆盖 |
| `/lib/firmware/qcom/sdm710/pyxis/` 下 `mba.mbn`、`modem.mbn`、`modem.b00..b29`、`wlanmdsp.mbn`、`qdsp6m.qdb`、`modem_pr/`、`adsp.mbn` | 手机自带 modem 分区，只读挂载拷出 | 基带本体 + WLAN 真固件 + 配置，主线 mdt_loader 原生认 `modem.mbn 头 + bXX 分片` 布局 |
| `/lib/firmware/qcom/sdm710/pyxis/*.jsn`（共 5 份：`adspr.jsn`、`adspua.jsn`、`cdsp_root_pd.jsn`、`modem_root_pd.jsn`、`wlan_pd.jsn`） | 本机 `firmware/jsn/` | servreg 位置库，告诉 pd-mapper 有哪些 PD、它们提供什么服务，缺了 `wlan_pd` 永远不被创建 |

**做完应该看到什么：** 上述路径都有文件、`wlanmdsp.mbn` 约 3MB。此时还不会有 wlan0，这是正常的——服务还没起。（顺带一提：拷分区时只读，别写任何基带分区。）

## 3. rmtfs：先让基带稳定活着

**在干什么：** 基带启动后会向 AP 要 EFS（掉电不丢的配置区），没人应答就约 40 秒看门狗打死、crash/recover 循环， 后面一切免谈。`rmtfs` 就是应答这个的人。

**东西哪来的：** Debian 自带包 `rmtfs`，但默认启动参数找的分区名不对，要改成找本机的 `modemst1/modemst2/fsc/fsg`。

关键要点：drop-in 改为 `ExecStart=/usr/bin/rmtfs -r -s -o /var/lib/rmtfs`，再在 `/var/lib/rmtfs/` 建四个软链 `modem_fs1->modemst1`、`modem_fs2->modemst2`、`modem_fsc->fsc`、`modem_fsg->fsg`，然后 `enable`。

**做完应该看到什么：** `systemctl status rmtfs` 为 active，基带不再循环崩，`qrtr-lookup` 能看到 node 0 的 EFS/WDS/NAS 等一整套基带服务，但依然没有 `69`——说明 EFS 这关过了，卡在下一步喂文件。

## 4. tqftpserv：给基带喂 wlanmdsp 的文件服务

**在干什么：** 基带里的 `wlan_pd` 要读 `/readonly/firmware/image/wlanmdsp.mbn`，这个路径是 RFS 虚路径，背后是 AP 侧的 TFTP 文件服务。安卓上叫 `tftp_server`，主线内核没有，Debian 的开源对应物就是 `tqftpserv`。没有它，文件摆对了也没人递过去。

**东西哪来的：** Debian 自带包 `tqftpserv`，默认配置即可，`systemctl enable tqftpserv`。它的翻译规则是 `/readonly/firmware/image/` -> `/lib/firmware/` + `firmware-name` 目录，正好对应第 2 步摆好的 `qcom/sdm710/pyxis/wlanmdsp.mbn`。

**做完应该看到什么：** `systemctl status tqftpserv` 为 active，`qrtr-lookup` 能看到 RFS/TFTP 服务，但 WLFW(69) 依然不来、modem 也没来取 `wlanmdsp`——说明缺的不是文件通道，而是“谁来创建 wlan_pd”。

## 5. pd-mapper + jsn：创建 wlan_pd 的最后一卡

**在干什么：** 高通的 PD（protection domain）要先向 servreg 登记，`pd-mapper` 读第 2 步那 5 份 jsn，把 `msm/modem/wlan_pd` 需要的 `kernel/elf_loader + tms/servreg + wlan/fw` 关系建起来，基带才会在启动时把 `wlan_pd` 解析出来。没有这一步，`wlanmdsp` 永远没人要。

**东西哪来的：** 二进制用本机 `pd-mapper-arm64`，装到 `/usr/local/bin/pd-mapper`；服务手写一个 `pd-mapper.service`（`After=qrtr-ns.service`），`daemon-reload` 后 `enable --now`。注意 jsn 是启动时一次性加载的，补完 jsn 必须 `restart pd-mapper` 才生效。

**做完应该看到什么：** `journalctl -u pd-mapper` 能看到 `tms/pdr_enabled`、`kernel/elf_loader` 查询，重启基带（或重启整机）后 `qrtr-lookup` 终于出现 `69 ... ATH10k WLAN firmware service`。这就是打通的标志。

## 6. 验收：四级信号

**在干什么：** 按顺序确认每一级，跳级看会误判。

1. `qrtr-lookup | grep -E " 69 "` 看到 `ATH10k WLAN firmware service`——wlan_pd 活了。
2. `ip -br link` 看到 `wlan0`——ath10k 走完 FW_READY + 上电了，没出现就等一分钟再查，`wlan_pd` 只在 modem 启动时解析。
3. `sudo nmcli dev wifi list --rescan yes` 扫出 AP——射频 + BDF 校准都对了，`invalid frequency 0` 这类零星报错不影响可忽略。
4. `sudo nmcli dev wifi connect "SCUNET"`（开放网示例）拿到 IP 并能 `curl`——全链路通。WPA 另给密码，不在本文范围。

四级全过即修复完成；若卡在第 1 级，回头看第 5 步的 pd-mapper 日志和 jsn 是否在位，若卡在第 3 级，回头看第 2 步的 board-2.bin 是否覆盖对。