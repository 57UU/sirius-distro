# Venus 视频编解码 bringup 笔记（2026-10-16 验证）

sdm710 venus（`aa00000.video-codec`），固件 + 驱动 + 硬件三层已通。IPA/CDSP 见 `firmware/README.md`，本篇只记 venus。

## 1. 固件（`firmware/venus-sirius/`，已入库）

| 文件 | 说明 |
|---|---|
| `venus.mbn` | 由 modem 分区 `image/venus.mdt` 改名（内容相同，md5 `9ca486b4`） |
| `venus.b00-b04` | 同上 modem 分区原样 |
| `mba.mbn` | 沿用 `pyxis-phone` 包里的（238304B），venus 先于 video fw 加载成功，无需动 |

原理：驱动 `venus_load_fw` 调 `qcom_mdt_load(dev, mdt, fwname, ...)`，`fwname` 按 DT 的 `firmware-name`（`qcom/sdm710/pyxis/venus.mbn`）取头文件，再推导 `.bXX` 分段；上游 Debian 包 `.mdt`/`.mbn` 即同一文件两名，改名与上游一致。

目标路径 `/lib/firmware/qcom/sdm710/pyxis/venus.{mbn,b00-b04}`，安装行在 `kernel/build-kernel-img.sh`（`workspace/vbuild.sh` 为同逻辑手机端镜像）。

## 2. 验证结论

- 解码：H.264 干净、`HEVC` 90 帧全出、`H.264 2560x1440` 实时解完。硬件实际支持 H.264 / VP8 / VP9 / HEVC / MPEG-2（以 `v4l2-ctl -d /dev/video12 --list-formats-out` 为准；ffmpeg 编译期列表多出的 H.263/MPEG-1/MPEG-4/VC-1 设备不支持）。
- 编码：H.264 / HEVC 经 `v4l2-ctl` 直调 V4L2 均可出有效流、硬解回放通过；画面对齐（如 320x240 → 384x256）属正常。
- 节点：`/dev/video12` decoder、`/dev/video13` encoder（video0-11 是相机 ISP）；`fw_level`（`/sys/kernel/debug/venus/fw_level`）可读即固件会话正常。

## 3. 坑

1. **v4l2m2m 编码段错误**：ffmpeg 7.1.5 和 master（N-127564）均在 drain 阶段 SIGSEGV（`rc=139`），输出 0 字节。此前命令接 `| head` 使 `$?` 取到 head 返回值、崩溃被掩盖——查退出码务必直接取。驱动侧无辜（v4l2-ctl 同条件一次过）；修需啃 ffmpeg 源码或等上游。
2. **时间戳一烂即静默 wedging**：ShadowPlay 1440p 文件（DTS 大量重复）直接硬解卡死（0 CPU、无报错、`poll` 等到天荒地老，只能 kill）；`ffmpeg -c copy` remux 后实时解完。lavfi 流的 `Non-monotonic DTS` 同类。喂包前先保证时间戳干净。
3. **kill ffmpeg 别用 `pkill -f`**：会匹配到 ssh 会话自身命令行把自己杀掉；用 `pkill -f "ffmpeg-arm64-lates[t]"`（`pkill -x` 太长会截断）。
4. **手机没网时装包**：WSL 下好 `.deb` 再 `scp` + `dpkg -i`（v4l2-ctl 即如此装：v4l-utils + libv4l 三件套）。系统 ffmpeg 7.1.5 已卸载，现用 BtbN 静态 master（`/home/u57u/ffmpeg-arm64-latest`，`/usr/local/bin/ffmpeg` 软链；7.1.5 的 `.deb` 备份在 `workspace/`）。
5. **改名规则通用**：`ipa_fws`/`cdsp` 同为 modem 分区 `.mdt` → `.mbn` + 分段，见 firmware 表。
