# 开关机优化 (sirius)

2026-10 实测 + 落地记录。结论先行：

- 开机 `multi-user.target`：7.50s → 5.88s（warm reboot，kernel-monotonic）。
- 关机 `multi-user stop → Shutting down`：25~28s → 4.6s。
- 手段：6 个 unit 只改排序不动逻辑 ＋ wifi-shutdown 改 ExecStop ＋ fastrpc release 等待 10s→2s ＋ 关 LOCALVERSION_AUTO。

## 0. 测量方法

- `systemctl show -p InactiveExitTimestampMonotonic,ActiveEnterTimestampMonotonic,ExecMainExitTimestampMonotonic` 量时间戳前后对比（`systemd-analyze` 在手机上 hang，`systemctl` 正常）。
- 关机用 `journalctl -b -1 -o short-monotonic` 看上一次关机窗口。

## 1. 开机：关键路径实测

基线（server，warm reboot）：userspace 共 7.05s，BT 链占 3.8s：

- `bt-addr` 21.23→23.80（2.57s，hci0 固件等待 ＋ btmgmt 轮询）
- `bluetooth.service` 23.80→23.89（0.09s）
- `sirius-bt-auto` start 23.90 exit 25.04（1.13s，hci 轮询 ＋ btmgmt ＋ bluetoothctl）
- `multi-user` 25.05（bt-auto 跑完 14ms 后才到）
- `sirius-audio-init` 21.64→21.69（声卡经常 ~30s 才来，那时会拖住 multi-user）
- `orbital` 25.06（被 After=multi-user 钉在最后）

改动（`rootfs/overlay/etc/systemd/system/`，只改排序）：

- `sirius-bt-auto`：`After += multi-user.target`（power-on 是 belt-and-braces／BlueZ AutoEnable 兜底，worst-case ~29s，不挡 boot）。
- `sirius-audio-init`：`After += multi-user.target`（`Requires=声卡`、`Restart=on-failure` 保留）。
- `bt-addr`：`WantedBy: multi-user.target → bluetooth.service`（`Before=` 保留，须在 bluetoothd 前设好；hci0 固件等待移出关键路径；修了无 BT 时 boot 卡 90s/JobTimeout 的坑）。
- `sirius-zram`：删 `After=systemd-modules-load`（脚本自己 modprobe）。
- `orbital`：删 `After/Wants=multi-user`（DSI/input 在 kernel 里早于 userspace 就绪；缺节点就 crash，`Restart=always` 兜着）。
- `sirius-powerd`（gnome 才 enable）：`After: multi-user → dev-input-event0.device`（pwrkey 18.94s 就绪）；只 verify 没活测（gnome 没刷）。（2.1 起已删除，gnome 版电源键/息屏回 GNOME 原生，见 docs/POWER.md。）

注意：`bt-addr` 换 `[Install]` 后要 `reenable` 一次（旧 symlink 还在）；重 bake 自动生成对的（`SIRIUS_BASE_UNITS` 本就 enable 它），构建脚本不用改。

改后（同条件 warm reboot）：`multi-user @ 5.88s`，`bt-auto/audio-init` 全在之后并行，`orbital` 提前 1s 多起来。省 1.6s（固件慢的启动省更多：bt-auto ≤29s、声卡 ≤30s 不再 gate）。

## 2. 关机：25s 的拆解

总账 `multi-user stop → Shutting down` 25~28s：

- `adsprpcd-audiopd` 停服 10.3~10.4s，`adsprpcd-rootpd` 停服 10.2s，串行（audiopd `After=rootpd`，关机反转）→ 20.6s。
- `wifi-shutdown` 跑 4.2~4.3s，跑在最后（rmtfs 死后 10s 才启动）。
- `orbital` 一次 10.3s、后两次 0.17s（未复现）；`rmtfs` 22s hang 这次 0.4s（未复现）。

### 2.1 adsprpcd 的 10.3s：fastrpc release 等 DSP

根因（`drivers/misc/fastrpc.c`）：进程退出关 `/dev/fastrpc-adsp*` → `fastrpc_device_release()` → `fastrpc_release_current_dsp_process()` 发 `INIT_RELEASE` RPC → kernel `wait_for_completion_timeout(&ctx->work, 10 * HZ)`；DSP 从不及时回，跑满 10 秒。

证据：两次关机三个 daemon（audiopd×2、rootpd×2）SIGTERM→dead 均 10.2~10.4s，`TimeoutStopSec` 默认 90s 无 Killing 日志（自愿退出，非 SIGKILL）；手动 `SIGTERM` ~11s；手动 `SIGKILL` 变僵尸卡数秒；活体采样抓到线程卡在 `fastrpc_internal_invoke`。

修法（`linux-sirius/drivers/misc/fastrpc.c`）：只给 RELEASE 一路 10s→2s（返回值调用方丢弃、本就 best-effort）。验证：audiopd 10.3→2.04s，rootpd 10.2→2.06s。

### 2.2 wifi-shutdown 跑错位置

旧设计：`DefaultDependencies=no` ＋ start-job ＋ `Before=NM/MM/rmtfs` ＋ `WantedBy=shutdown.target`（本意 modem 停前先拆 WiFi，modem 先停会 wedge wifi 栈）；实测 `Before=` 管不住别人的 stop，rmtfs 死后 10 秒才启动、4.3 秒全在关机尾巴。

改法：`ExecStop` 模式（开机 `/bin/true` 占位，`WantedBy=multi-user`），排序 `After=NM/MM/rmtfs/...`（stop-job 顺序反，`After=` 即"你们停之前我先跑"）。验证：`Stopping wifi-shutdown @61.47`，MM/rootpd/NM/rmtfs 全在 71.6s+ 才停；与 audiopd 2 秒并行。

注：其 10.2s 里 `modprobe -r ath10k` 两次撞自带 5s timeout（ath10k 卸载同样等 DSP，timeout 有界，先不动）。换 `[Install]` 后要 `reenable` 一次，重 bake 自动对。

改后关机总账：`[wifi-shutdown 2.0s ∥ audiopd 2.0s] → rootpd 2.1s`，`multi-user stop → Shutting down` **4.6s**。

## 3. 版本号坑（`setlocalversion`）

fastrpc 是 `=m`，patch 一打 tree 变脏，模块目录多 `-dirty`，Image 没重编还是干净版——两边对不上，模块全加载不了（`insmod` 也救不了，vermagic 写死）。

- `CONFIG_LOCALVERSION_AUTO=y` → `7.2.3-sdm670-gHASH[-dirty]`（跟 git 走）；
- 关掉还不够：无 tag 树恒多个 `+`（`7.2.3-sdm670+`），彻底干净需再 export 空 `LOCALVERSION=`；
- 现版本 `7.2.3-sdm670+` 脏净恒定；initramfs 按 `uname -r` 动态绑模块目录，不用改 fstab；
- 全量重编后 Image 与模块已对齐；`LOCALVERSION_AUTO=n` 写进 `sdm710-xiaomi-sirius_defconfig` 即可。
