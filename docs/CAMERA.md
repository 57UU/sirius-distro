# 摄像头（Sony IMX363 / Qualcomm CAMSS）

后置主摄 Sony IMX363 的 mainline 适配记录（前摄 S5K3T1、副摄 S5K3E8/S5K5E8 暂无 mainline 驱动）。

## 1. 当前状态

| 项目 | 状态 | 说明 |
|---|---|---|
| 裸流采集（V4L2/CAMSS） | 部分可用 | 4032×3024 SRGGB10 packed（`pRAA`）~30 fps；连续出流 ~15–95s 或空闲后 CSI 停摆 |
| libcamera / PipeWire 预览 | 部分可用 | 干净启动下 640×480 / 720p / 1080p 均 ~30 fps；受上述 CSI 停摆影响 |
| 方向 | 待确认 | DT 已设为 `rotation = <270>`（90 时实测上下颠倒，270 待预览确认） |
| 3A / 闪烁 | 未标定 | libcamera 软 ISP 缺 `imx363` sensor helper 与 `imx363.yaml`，室内灯光易轻微闪烁 |
| GNOME Snapshot | 不稳定 | 受 CSI 停摆影响，且存在 GTK4 `gdk_subsurface_attach` 断言退出问题 |

## 2. 核心未解故障：CSI 静默停摆

**现象**：干净启动后各通路（`v4l2-ctl` 裸流、`libcamerasrc`、`pipewiresrc`）在 480p/720p/1080p 下均能稳定 ~30 fps；但**连续出流 14.8–94.7 s 后，或跑完一次短流并空闲 ~10 分钟后**，CSI 侧彻底停摆，此后所有通路均 0 帧，仅整机（PMIC/SoC）重启可恢复。

- **与 libcamera/PipeWire 无关**：`v4l2-ctl` 裸流单独可复现。
- **与分辨率/数据率无关**：`2016×1512` 2×2 binning（1/4 数据量，30.29 fps）同样停摆且更快（21.6 s / 657 帧）；拉大 vblank 到 8.7 fps 也会停（14.8 s / 130 帧）。
- **与模块热重载无关**：`modprobe -r qcom_camss` 在卡死态报 `in use`，无法靠重载恢复。

### 已观测事实与排除项

| 观测项 | 结果 | 结论 |
|---|---|---|
| 传感器 `0x0100`（MODE_SELECT） | 流中 = `0x01` | 传感器仍在出流 |
| MCLK0 / CSIPHY0 / CSID0 / IFE0 时钟 | 24 / 384 / 384 / 100 MHz，已使能 | 时钟与供电正常（`bob`、`smps6`、`s6`/`l1` 无异常） |
| `csiphy` ctrl5/6/7 与 `COMMON_STATUS0..3` | `0xd5/0x01/0x02`，`st0..3 = 0x4/0x1/0x80/0x20` 全程恒定 | PHY 配置未丢失，状态寄存器无变化 |
| CSID `CSI2_RX_IRQ_STATUS` | `0x0` | 无 ECC/CRC/包解码错误 |
| VFE `IRQ_STATUS_0/1`、`VIOLATION_STATUS`、`BUS_IRQ_STATUS(0)` | 全程 `0x0`（偶见中间态：有 VFE 帧节拍中断但 `bus0` 无成帧） | 无 CAMIF 错误、无 violation、无 pending 写 |
| `ftrace`（`function_graph`） | 最后一次正常 `vfe_isr → vb2_buffer_done` 后彻底无中断 | 硬件安静停流，无超时/报错 |
| `dma_buf` / 时钟 enable 计数 / genpd / 温度 | idle 全 0/off；冷却到 29.8 °C 仍 0 帧 | 排除资源泄漏与过热 |
| 卡死后读 CCI（`/dev/i2c-3`） | 永久阻塞 | 摄像头块整体不响应 |
| 每次会话 `imx363_power_on` / `csiphy_set_power` | 走完仍无法恢复 | 非普通模块复位能清的状态 |

### 试过但无效的改动（已回退）

- **VFE 时钟 100 → 404 MHz**（同时改 `vfe_res_670` 与 `csid_res_670` 的 `ife_0_clk`）：直接 0 帧，已回退。
- **`q->min_queued_buffers = 2` / `camnoc_axi` 400 MHz**：早期被旧 `.ko.zst` 覆盖坑挡住未真正测通，已回退。

> **模块测试踩坑**：模块目录同时存在 `qcom-camss.ko` 和 `qcom-camss.ko.zst` 时系统优先加载 `.zst`。替换测试前必须先删 `.ko.zst`；且须 `systemctl --user stop wireplumber pipewire` 释放 `/dev/video0` 和 `/dev/media0`。

## 3. 设备树与原厂固件信息

### 设备树（`sdm710-xiaomi-sirius.dts`）

- **传感器**：`cci_i2c0` 下 `camera@10`（`sony,imx363`），4 lane，MCLK0（GPIO 13），`CAM_RESET0`（GPIO 30，低有效）。
- **供电**：`vana`（GPIO 8 → PM660L BOB 2.8V）、`vdig`（GPIO 29 → PM660 S6 ~1.224V）、`vif`（PM660 LDO14 1.8V）。
- **CAMSS / CSI**：`vdda-phy = L1A`、`vdda-pll = S6A`；CSI0 / CSID0 / VFE0 RDI0，4 lane，link-freq 636 MHz。
- **方向**：`rotation = <270>;`、`orientation = <1>;`（经 `v4l2_ctrl_new_fwnode_properties()` 暴露给 libcamera）。若后续预览发现镜像而非倒置，再考虑 `V4L2_CID_HFLIP/VFLIP`（会改变 Bayer 顺序）。

### 原厂固件（`sirius_images_V12.5.1.0.QEBCNXM` `vendor.img`）

- 传感器配置全在 `vendor.img` 的 `/lib/camera/`（`system.img` 无相关配置）：`com.qti.sensormodule.imx363.bin`（131 KB，QTI `ParameterParser V1.1.0` 容器）与 `com.qti.tuned.ofilm_imx363.bin`（3.7 MB）。
- 容器内含多档分辨率寄存器序列（4032×3024、1920×1080、1280×720 等），但寄存器数组经编码拆分存储，**直接还原原厂寄存器表需要完整逆向 ParameterParser**，成本高且不保证解决停摆。
- 参考厂商 DT：`~/rocky-sdm710-linux/arch/arm64/boot/dts/qcom/sirius-sdm670-camera-sensor.dtsi`。

## 4. 已修复问题

- **CAMSS 零缓冲启动导致用后卡死**：`drivers/media/platform/qcom/camss/camss-video.c` 原 `min_queued_buffers = 0`，libcamera 先 `STREAMON` 再 `QBUF` 时 VFE 无目标 buffer、不产生中断，导致死锁。改为 `q->min_queued_buffers = 1` 后，多轮启停（`libcamerasrc` / `pipewiresrc` / `v4l2-ctl`）恢复正常。
- **2016×1512 2×2 binning 模式**（`imx363.c`）：在 `supported_modes[]` 新增 2016×1512（`0x0900=1`, `0x034C=2016`, `0x034E=1512`），实测 30.29 fps 图像正常（未解决停摆，仅降低后级 debayer 负载）。

## 5. 其他已知限制

- **硬件 ISP（VFE PIX）未打通**：`msm_csid0` pad4 → `msm_vfe0_pix` → `/dev/video3` 尚缺格式对齐（`-EPIPE`），且主线缺 3A 统计与 libcamera Qualcomm ISP pipeline handler；即便打通也只能省 CPU debayer，修不了前端 CSI 停摆。
- **3A / 闪烁**：libcamera `IPASoft` 缺 `imx363` `CameraSensorHelper` 与 `imx363.yaml`，回退到 `uncalibrated.yaml`，需在用户态 libcamera 补充。
- **GNOME Snapshot 退出**：卡住时日志报 `gdk_subsurface_attach: assertion 'sibling != subsurface' failed`，属 GTK4 Wayland subsurface 问题。

## 6. 验证命令与部署状态

```sh
# 1. 裸流 30 fps（未配置格式时需先跑一次 libcamera 或 media-ctl）
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=10 --stream-to=/dev/null --verbose

# 2. 传感器控制与属性
v4l2-ctl -d /dev/v4l-subdev18 --get-ctrl exposure,analogue_gain,digital_gain,vertical_blanking
wpctl inspect 67 | grep -iE 'rotation|location'

# 3. 日志排查
sudo dmesg | grep -iE 'camss|imx363|vfe|csid|csi'
journalctl --user -b | grep -iE 'libcamera|camera|snapshot|pipewire'
```

- **已部署到测试机**：`/boot/dtb/sdm710-xiaomi-sirius.dtb`（rotation=270）、`imx363.ko.zst`、`qcom-camss.ko.zst`（`min_queued_buffers=1`）；旧文件备份在手机 `/home/u57u/cam-debug-backup/`；复现/压测脚本在 `workspace/build/camtest/`。
- **待做**：确认 `rotation = <270>` 预览方向；补充 libcamera `imx363` sensor helper 与调校文件；继续定位 CSI 静默停摆。
