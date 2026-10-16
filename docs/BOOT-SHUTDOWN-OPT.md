# 开关机优化 (sirius)

2026-10 实测 + 落地记录。结论先行：

- 开机 `multi-user.target`：7.50s → 5.88s（warm reboot，kernel-monotonic）。
- 关机 `multi-user stop → Shutting down`：25~28s → 4.6s。
- 手段：6 个 unit 只改排序不动逻辑 ＋ wifi-shutdown 改 ExecStop ＋ fastrpc release 等待 10s→2s ＋ 关 LOCALVERSION_AUTO。

## 0. 测量方法

- `systemd-analyze` 在手机上 hang（原因未深究，`systemctl` 正常），所以全部用 `systemctl show -p InactiveExitTimestampMonotonic,ActiveEnterTimestampMonotonic,ExecMainExitTimestampMonotonic` 直接量时间戳，前后对比。
- 关机用 `journalctl -b -1 -o short-monotonic` 看上一次的关机窗口。

## 1. 开机：关键路径实测

基线（server，warm reboot）：userspace 共 7.05s，其中 BT 链占 3.8s：

- `bt-addr` 21.23→23.80（2.57s，hci0 固件等待 ＋ btmgmt 轮询）
- `bluetooth.service` 23.80→23.89（0.09s）
- `sirius-bt-auto` start 23.90 exit 25.04（1.13s，hci 轮询 ＋ btmgmt ＋ bluetoothctl）
- `multi-user` 25.05（bt-auto 跑完 14ms 后才到，它就是尾巴）
- `sirius-audio-init` 21.64→21.69（这次声卡来得早；注释记载声卡经常 ~30s 才来，那时会拖住 multi-user）
- `orbital` 25.06（被 After=multi-user 钉在最后）

改动（`rootfs/overlay/etc/systemd/system/`，只改排序）：

- `sirius-bt-auto`：`After += multi-user.target`。power-on 只是 belt-and-braces（BlueZ AutoEnable 兜底），worst-case ~29s，不配挡 boot。
- `sirius-audio-init`：`After += multi-user.target`。`Requires=声卡` 和 `Restart=on-failure` 保留，卡晚到也不拖 boot，路由照样补上。
- `bt-addr`：`WantedBy: multi-user.target → bluetooth.service`。地址必须在 bluetoothd 之前设好（`Before=` 保留），但没人等它；hci0 固件等待移出关键路径。附带修了无 BT 时 boot 卡 90s（JobTimeout）的坑。
- `sirius-zram`：删 `After=systemd-modules-load`（脚本自己 modprobe，无依赖）。
- `orbital`：删 `After/Wants=multi-user`。DSI/input 在 kernel 里远早于 userspace 就绪；缺节点就 crash，`Restart=always` 兜着，UI 早几秒出来。
- `sirius-powerd`（gnome 才 enable）：`After: multi-user → dev-input-event0.device`。pwrkey 18.94s 就绪（journal 实测），按真实依赖排序；只做了 verify，没活测（gnome 没刷）。

注意：`bt-addr` 换 `[Install]` 后要 `reenable` 一次（旧 symlink 还在）；**重 bake 会自动生成对的**（`SIRIUS_BASE_UNITS` 本来就 enable 它），构建脚本不用改。

改后（同条件 warm reboot）：`multi-user @ 5.88s`，`bt-auto/audio-init` 全在之后并行，`orbital` 提前 1s 多起来。省 1.6s；固件来得慢的那种启动省得更多（bt-auto ≤29s、声卡 ≤30s 不再 gate）。

## 2. 关机：25s 的拆解

三次关机日志互相印证，总账 `multi-user stop → Shutting down` 25~28s：

- `adsprpcd-audiopd` 停服 10.3~10.4s，`adsprpcd-rootpd` 停服 10.2s，两者串行（audiopd `After=rootpd`，关机反转）→ 20.6s。
- `wifi-shutdown` 跑 4.2~4.3s，且跑在最后（rmtfs 死后 10s 才启动，见下）。
- `orbital` 有一次也 10.3s，但后两次 0.17s，没复现，不管了。`rmtfs` 传说中的 22s hang 这次反而 0.4s，也没复现。

### 2.1 adsprpcd 的 10.3s：fastrpc release 等 DSP

证据链：

- 两次关机、三个 daemon（audiopd×2、rootpd×2），SIGTERM 到 dead 全是 10.2~10.4s；`TimeoutStopSec` 默认 90s 且无 Killing 日志，不是 SIGKILL，是自愿退出慢。
- 健康系统手动 `SIGTERM` 同样 ~11s 才死——和关机状态无关，daemon 退出就这么贵。
- 手动 `SIGKILL`：变僵尸卡数秒——等待在内核释放路径，userspace 手段（换信号、调 timeout）够不着。
- 活体采样抓到 adsprpcd 线程卡在 `fastrpc_internal_invoke`。
- 读驱动对上号：进程退出关 `/dev/fastrpc-adsp*` → `fastrpc_device_release()` → `fastrpc_release_current_dsp_process()` 发 `INIT_RELEASE` RPC → kernel 上下文 `wait_for_completion_timeout(&ctx->work, 10 * HZ)`。DSP 从不及时回，次次跑满 10 秒（`drivers/misc/fastrpc.c`）。

修法（`linux-sirius/drivers/misc/fastrpc.c`）：只给 RELEASE 这一路 10s→2s，别处不动。敢砍是因为 release 的返回值调用方直接丢弃，本来就是 best-effort。
验证：audiopd 10.3→2.04s，rootpd 10.2→2.06s。

### 2.2 wifi-shutdown 跑错位置

旧设计：`DefaultDependencies=no` ＋ start-job ＋ `Before=NM/MM/rmtfs` ＋ `WantedBy=shutdown.target`，本意 modem 停之前先拆 WiFi（HANDOFF 结论：modem 先停会 wedge wifi 栈）。
日志实锤：`Before=` 管不住别人的 stop——它在 rmtfs 死后 10 秒才启动，4.3 秒全落在关机尾巴上，初衷落空。
改法：`ExecStop` 模式（开机 `/bin/true` 占位，`WantedBy=multi-user`），排序用 `After=NM/MM/rmtfs/...`。stop-job 的顺序本来就是反的，`After=` 在这里恰好表示“你们停之前我先跑”。
验证：这次 `Stopping wifi-shutdown @61.47`，MM/rootpd/NM/rmtfs 全在 71.6s+ 才停，顺序对了；还和 audiopd 的 2 秒完全并行。
（注：它的 10.2s 里 `modprobe -r ath10k` 两次撞上自带的 5s timeout，说明 ath10k 卸载同样在等 DSP，和 fastrpc 同一家族的问题；timeout 有界，先不动。换 `[Install]` 后要 `reenable` 一次才能生效，重 bake 则自动对。)

改后关机总账：`[wifi-shutdown 2.0s ∥ audiopd 2.0s] → rootpd 2.1s`，`multi-user stop → Shutting down` **4.6s**。

## 3. 版本号坑（`setlocalversion`）

fastrpc 是 `=m`，patch 一打 tree 变脏，模块目录多了 `-dirty` 后缀，而 Image 没重编还是干净版——两边对不上，一个模块都加载不了（连 `insmod` 都救不了，vermagic 写死了）。教训：

- `CONFIG_LOCALVERSION_AUTO=y` 时版本 `7.2.3-sdm670-gHASH[-dirty]`，跟着 git 走；
- 关掉它还不够：无 tag 的树恒多个 `+`（`7.2.3-sdm670+`），要彻底干净得再 export 空的 `LOCALVERSION=`；
- 现在的 `7.2.3-sdm670+` 虽然丑，但脏净恒定不变，够稳定。initramfs 按 `uname -r` 动态绑模块目录，不用改 fstab。
- 全量重编后 Image 和模块已对齐。`LOCALVERSION_AUTO=n` 写进 `sdm710-xiaomi-sirius_defconfig` 即可，以后每次构建都生效。

