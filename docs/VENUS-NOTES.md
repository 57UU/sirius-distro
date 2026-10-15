# Venus 视频编解码 bringup 笔记（2026-10-16 验证）

sdm710 venus（`aa00000.video-codec`），固件 + 驱动 + 硬件三层已通。
IPA/CDSP 见 `firmware/README.md` 对应行，本篇只记 venus。

## 1. 固件（`firmware/venus-sirius/`，已入库）

| 文件 | 说明 |
|---|---|
| `venus.mbn` | 由 modem 分区 `image/venus.mdt` 改名（内容相同，md5 `9ca486b4`） |
| `venus.b00-b04` | 同上 modem 分区原样 |
| `mba.mbn` | 沿用 `pyxis-phone` 包里的（238304B），venus 先于 video fw 加载成功，无需动 |

原理：驱动 `venus_load_fw` 调 `qcom_mdt_load(dev, mdt, fwname, ...)`，
`fwname` 按 DT 里 `firmware-name`（`qcom/sdm710/pyxis/venus.mbn`）请求头文件，
再按同名推导 `.bXX` 分段。上游 Debian 包里 `.mdt`/`.mbn` 就是同一文件两个名字，
改名做法与上游一致。

手机目标路径：`/lib/firmware/qcom/sdm710/pyxis/venus.{mbn,b00-b04}`，
安装行在 `kernel/build-kernel-img.sh`（`workspace/vbuild.sh` 为同逻辑手机端镜像）。

## 2. 验证结论

- 解码：H.264 干净、`HEVC` 90 帧全出；`H.264 2560x1440` 实时解完。
  硬件实际支持解码：H.264 / VP8 / VP9 / HEVC / MPEG-2（`v4l2-ctl -d /dev/video12 --list-formats-out` 为准，
  ffmpeg 编译期列表里多出来的 H.263/MPEG-1/MPEG-4/VC-1 设备并不支持）。
- 编码：H.264 / HEVC 经 `v4l2-ctl` 直调 V4L2 均可出有效流且硬解回放通过。
  注意 venus 会把画面对齐（如 320x240 → 384x256），属正常行为。
- 设备节点：`/dev/video12` decoder，`/dev/video13` encoder（video0-11 是相机 ISP，别搞混）。
  `fw_level`（`/sys/kernel/debug/venus/fw_level`）可读即固件会话正常。

## 3. 坑

1. **ffmpeg 的 v4l2m2m 编码器段错误**：7.1.5 和 master（N-127564）都在 drain 阶段 SIGSEGV（`rc=139`），
   输出 0 字节。之前因为命令接了 `| head`，`$?` 取到的是 head 的返回值，崩溃被掩盖了——查退出码务必直接取。
   驱动侧无辜（v4l2-ctl 同条件一次过）。修它要啃 ffmpeg 源码或等上游。
2. **时间戳一烂就静默 wedging**：ShadowPlay 录的 1440p 文件（DTS 大量重复）直接硬解会卡死
   （0 CPU、无报错、`poll` 里等到天荒地老，只能 kill）。`ffmpeg -c copy` remux 后实时解完。
   lavfi 生成流的 `Non-monotonic DTS` 属同类幽灵。结论：喂包前先保证时间戳干净。
3. **手机上 kill ffmpeg 别用 `pkill -f`**：pattern 会匹配到 ssh 会话自身的命令行，把自己杀掉。
   用精确名：`pkill -x` 太长会被截断，推荐 `pkill -f "ffmpeg-arm64-lates[t]"` 这类写法。
4. **手机没网时装包**：WSL 下好 `.deb` 再 `scp` 过去 `dpkg -i`（v4l2-ctl 就是这么装的：v4l-utils + libv4l 三件套）。
   系统 ffmpeg 7.1.5 已卸载，现用 BtbN 静态 master（`/home/u57u/ffmpeg-arm64-latest`，
   `/usr/local/bin/ffmpeg` 软链；7.1.5 的 `.deb` 备份在 `workspace/`）。
5. **固件改名规则通用**：`ipa_fws`/`cdsp` 同样是 modem 分区 `.mdt` 改名 `.mbn` + 分段，见 firmware 表。