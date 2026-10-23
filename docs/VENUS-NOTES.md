# Venus 视频编解码 bringup 笔记（2026-10-16 初验，2026-10-23 复验+排障）

sdm710 venus（`aa00000.video-codec`），固件 + 驱动 + 硬件三层已通。IPA/CDSP 见 `firmware/README.md`，本篇只记 venus。

## 1. 固件（`firmware/venus-sirius/`，已入库）

| 文件 | 说明 |
|---|---|
| `venus.mbn` | 由 modem 分区 `image/venus.mdt` 改名（内容相同，md5 `9ca486b4`，手机端实测一致） |
| `venus.b00-b04` | 同上 modem 分区原样 |
| `mba.mbn` | 沿用 `pyxis-phone` 包里的（238304B），venus 先于 video fw 加载成功，无需动 |

原理：驱动 `venus_load_fw` 调 `qcom_mdt_load(dev, mdt, fwname, ...)`，`fwname` 按 DT 的 `firmware-name`（`qcom/sdm710/pyxis/venus.mbn`）取头文件，再推导 `.bXX` 分段；上游 Debian 包 `.mdt`/`.mbn` 即同一文件两名，改名与上游一致。

目标路径 `/lib/firmware/qcom/sdm710/pyxis/venus.{mbn,b00-b04}`，安装行在 `kernel/build-kernel-img.sh`。

## 2. 验证结论

- 解码：H.264 干净、`HEVC` 90 帧全出、`H.264 2560x1440` 实时解完。硬件实际支持 H.264 / VP8 / VP9 / HEVC / MPEG-2（以解码器节点的 `--list-formats-out` 为准；ffmpeg 编译期列表多出的 H.263/MPEG-1/MPEG-4/VC-1 设备不支持）。
- 编码（2026-10-23 复验）：H.264 经 `v4l2-ctl` 直调多次出有效流（640x480、1280x720），`ffprobe` + 软解回放通过；实录 720p60（481 帧）Venus 硬编画面正确（缩略图见测试记录）；高度会被驱动对齐到 32（720→736），见坑 4。
- 节点（7.2.3 #4 实测，以 `-D` 的 card 名和队列方向为准）：`/dev/video12` encoder（OUT 进 raw，CAP 出编码）、`/dev/video13` decoder（OUT 进编码，CAP 出 raw）；video0-11 是相机 ISP。旧版内核节点号可能相反，不要硬编码。
- `fw_level`（`/sys/kernel/debug/venus/fw_level`，需 root）可读即固件会话层正常。

## 3. 坑

1. **ffmpeg 打不开编码器先看 pix_fmt**：必须 `-pix_fmt nv12`，默认的 yuv420p 会在 open 直接 EINVAL（源码 `libavcodec/v4l2_m2m_enc.c` 的 `v4l2_encode_init()`：拿驱动 `S_FMT` 回来的 NV12 去比对 `avctx->pix_fmt`，yuv420p 对不上就拒）。
2. **ffmpeg v4l2m2m drain 段错误（未解）**：trixie ffmpeg 7.1.5、`-pix_fmt nv12`、lavfi 干净时间戳输入照样 `SIGSEGV`（`rc=139`）、输出 0 字节；旧记录里 master（N-127564）同样。查退出码不要接 `| head`（`$?` 会变成 head 的）。修需啃 ffmpeg 源码或等上游。
3. **失败会话会拖死 Venus，后续全 EIO**：特征是 `dmesg` 报 `session error: event id:100e (2002)` + `1004 (0)`，之后任何新会话（连 v4l2-ctl）`DQBUF: Input/output error`。恢复：残留 ffmpeg 进程还在就 `pkill -x -9 ffmpeg`（短名用 `-x` 安全，不会误杀 ssh）；段错误死掉的进程只能重启（`safe-reboot`）。
4. **高度 32 对齐**：720p 实际按 736 编（`S_FMT`/`G_FMT` 回 1280x736）。直接喂 720 行 raw 会逐帧错位、花绿屏。喂之前 `pad=1280:736:0:0`，或接受输出就是 736。
5. **时间戳一烂即静默 wedging（解码侧）**：ShadowPlay 1440p 文件（DTS 大量重复）直接硬解卡死（0 CPU、无报错、`poll` 等到天荒地老，只能 kill）；`ffmpeg -c copy` remux 后实时解完。喂包前先保证时间戳干净。
6. **装包**：trixie 源（含清华镜像）可直接 `apt install -y v4l-utils ffmpeg`（带 v4l2m2m）。旧的 WSL 搬 `.deb` / BtbN 静态包方式已过时（2026-10-23 起设备即用源里版本）。
7. **改名规则通用**：`ipa_fws`/`cdsp` 同为 modem 分区 `.mdt` → `.mbn` + 分段，见 firmware 表。
