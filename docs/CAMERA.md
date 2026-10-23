# 摄像头（Sony IMX363 / Qualcomm CAMSS）

后置主摄 Sony IMX363 的 mainline 适配记录：设备树、驱动修复、预览链路现状与已知问题。
前摄（S5K3T1）与后置副摄/景深（S5K3E8/S5K5E8）暂无 mainline 驱动，不在此文范围。

## 当前状态

| 项目 | 状态 | 说明 |
|---|---|---|
| 裸流采集（V4L2/CAMSS） | 可用 | 4032x3024 SRGGB10 packed（`pRAA`），约 30 fps |
| libcamera 直接预览（`libcamerasrc`） | 可用 | 640x480 约 29 fps |
| PipeWire/libcamera 预览（Snapshot 走的路） | 部分可用 | 新启动时 640x480 / 1280x720 / 1920x1080 都是 ~30 fps；累计开关十几次后整体卡死 |
| GNOME Snapshot | 不稳定 | 真正原因是下面的「会话累积退化」，不是 1080p；另外进程会刷 `gdk_subsurface_attach` 断言后退出 |
| 方向 | 待确认 | DT `rotation = <270>` 已部署；90 时实测上下颠倒，270 尚未得到用户确认 |
| 3A / 闪烁 | 未标定 | libcamera 软件 ISP 没有 imx363 sensor helper 和 `imx363.yaml`，AE/AWB 未校准 |

## 实测复现（2026-10-23）：连续出流 ~1 分钟后 CSI 停摆

> **本文早期结论已作废**：`1920x1080 为 0 帧` 是在已经退化的状态下测出来的，不是 1080p 本身的问题。
> 干净启动后 1080p 在 libcamerasrc 下 31.7 fps、PipeWire 下 30.9 fps，完全正常。

干净启动（`reboot` 之后、没开过任何相机应用）实测基线：

| 通路 | 640x480 | 1280x720 | 1920x1080 |
|---|---|---|---|
| `v4l2-ctl` 裸流 4032x3024 pRAA | 33 ms/帧（~30 fps） | — | — |
| `libcamerasrc` | 30~33 fps | 29~30 fps | 31.7 fps |
| `pipewiresrc path=67` | 29.8 fps | 29.6 fps | 27~30 fps |

### 关键事实：**一次长时间的裸流也会自己停**（与 libcamera 无关）

用 `v4l2-ctl` 只做裸流采集（不经过 libcamera/PipeWire），每次都能复现：

| 运行 | 出流时长 | 帧数 |
|---|---|---|
| 第 1 次 | 57.1 s（ts 80.35 → 137.46） | 1733 |
| 第 2 次（`min_queued_buffers=2` 版本） | 57.6 s | 1742 |
| 第 3 次（libcamerasrc 单会话 90 s） | 50.6 s | 1538 |
| 把 vblank 拉大到 ~8.7 fps | 14.8 s | 130 |

即：**不是会话数、不是分辨率、也不是固定时间/帧数**，而是出流一段时间后 CSI 侧彻底停摆，
此后任何通道（裸流 / libcamera / PipeWire）都是 0 帧，只有整机重启能恢复。

还有一次更"便宜"的复现路径：重启后先跑 5 s 基线（164 帧正常），**闲置约 10 分钟、中间完全没碰相机**，
再开会话时第一帧就是 0。所以这个故障既能出现在"连续出流 ~1 分钟后"，也能出现在
"空闲之后的下一次启动"，更像启动路径/PHY 锁定相关的状态问题，而不是单纯的数据量或时长。

### 停摆后的状态与已排除项

| 观测 | 结果 | 结论 |
|---|---|---|
| 传感器 0x0100（MODE_SELECT） | 流中 = 0x01 | 传感器**确实在出流** |
| MCLK0 / CSIPHY0 / CSID0 / IFE0 时钟 | 24 / 384 / 384 / 100 MHz，已使能 | 供电、时钟正常 |
| csiphy ctrl5/ctrl6/ctrl7 | 0xd5 / 0x01 / 0x02，4 lane + PLL 上电，长时间不变 | PHY 配置未丢失 |
| CSID `CSI2_RX_IRQ_STATUS` | 0x0（无 ECC/CRC/包错误） | 停摆前后**没有解码错误** |
| VFE0 / CSID0 中断 | 停摆后只剩 RESET_ACK，无 REG_UPDATE / frame-done | 数据没到 |
| `dmesg` | 无 CAMSS/VFE/CSID/IOMMU 报错、无 violation | 静默失败 |
| `dma_buf/bufinfo` / 时钟 enable 计数 / genpd | 无泄漏（idle 全 0/off） | 排除资源泄漏 |
| 冷却到 29.8 °C 静置 8 分钟 | 仍 0 帧 | **与温度无关**（不需要重启才能热恢复） |
| 卡死状态下读 CCI（/dev/i2c-3） | 永久阻塞 | 摄像头块整体不响应 |
| ISP 是否"没起来" | **不适用** | 这条链路是 `imx363 → csiphy0 → csid0 → vfe0_rdi0 → video0`，**RDI 直通**，拓扑里没有 ISP 实体；mainline camss 在这颗 SoC 上也没有硬件 ISP 驱动，debayer 是 libcamera 在 CPU 上做的软 ISP。裸流 `v4l2-ctl` 完全不经过软 ISP，照样停摆 → 停摆在数据进入 CSID 之前就发生了 |

在带插桩的内核里抓到过一次中间态：VFE 的 31 ms 帧节拍中断一直在，但 `bus0`（RDI buffer done）
只出现 1 次 —— 也就是「帧在进、写不进内存」，之后再演变成全静默。这条线索指向 VFE 写入路径/CSI 停摆，
但还需要更细的追踪才能定论。同一个中间态在**原始模块**上也复现过一次：VFE 中断累计 639 次后停住，
`dqbuf` 始终是 0（即"有中断、无成帧"），说明它不依赖我给内核加的插桩。

一条关键推理：每次新会话都会走完 `imx363_power_on()`（vana/vdig 断电重上 + XCLR 拉低/释放 + MCLK 开关）
和 `csiphy_set_power()`（PHY 软复位 + vdda-phy/vdda-pll），但**卡死状态依然存在** —— 所以它不是
"某个模块没被复位"，而是普通 power-cycle 清不掉的状态，只有整机（PMIC/SoC）复位能清。
供电实测：`bob`（vana 上级）use=5、`smps6`（vdig 上级）use=1，都是共享轨；csiphy 的 `s6`/`l1` 空闲时 use=0。

### 停摆瞬间的 PHY 状态轮询（2026-10-23 晚）

给 `csiphy` 加了一个 5 秒一次的 `delayed_work`，**只读** `COMMON_STATUS0..3`（进程上下文、不动控制寄存器），
两次长跑结果：

| 运行 | 出流时长 | 结果 |
|---|---|---|
| 第 1 次 | 75 s（跑到 timeout） | **没停**，2271 帧 |
| 第 2 次 | 94.7 s | 停了，2865 帧 |

两次的 PHY 状态寄存器**全程恒定**：`st0=0x4 st1=0x1 st2=0x80 st3=0x20`，
**停摆前后没有任何变化** → 这几个 STATUS 寄存器不反映这个故障。

同时也说明停摆时间**抖动极大**：已累计观测 14.8 s / 21.6 s / 48~57 s / 75 s+ / 94.7 s。

下一步可用的信号（还没试）：VFE 侧有 `MASK_1_CAMIF_ERROR (BIT 0)` 和 `VFE_CAMIF_CMD (0x478)`、
`VFE_BUS_IRQ_STATUS(0)`，可以在同一个 poller 里加读 `VFE_IRQ_STATUS_0/1` 与 CAMIF 状态，
看停摆瞬间 CAMIF 有没有报错/半停。这些是**读状态**，不会像上次那样扰动控制寄存器。

**已补测（2026-10-23 22:0x）**：把 VFE 侧的 `IRQ_STATUS_0(0x06c)`、`IRQ_STATUS_1(0x070)`、
`VIOLATION_STATUS(0x07c)`、`BUS_IRQ_STATUS(0)(0x205c)` 加进同一个 poller，再跑 135 s：

| 观测 | 结果 |
|---|---|
| 出流 | 2835 帧 / 93.6 s 后停 |
| `s1`（含 CAMIF_ERROR / VIOLATION） | **全程 0x0** |
| `vio` | **全程 0x0** |
| `bus0`（写通路 pending） | **全程 0x0** |
| `s0` | 只有最开始一次 0x08000000，之后 0x0 |
| PHY status | 全程恒定，同前 |

也就是说：**CAMIF 没报错、没有 violation、没有 pending 写**，硬件侧"安静地"不再来数据。
到这里，SoC 侧能读的状态寄存器全部看过了，都没有异常 —— 软件可见的线索基本用尽。


### ftrace 观察（内核 tracing 现状与停摆瞬间）


- 本内核 `CONFIG_KPROBES` **未开启**，所以 `kprobe_events`/kprobe 事件不可用；
  但 `CONFIG_FUNCTION_TRACER` + `CONFIG_DYNAMIC_FTRACE` 已开启，`function_graph` 可用。
- 对 `vfe_isr / csid_isr / vb2_buffer_done` 做 function_graph（buffer 8 MB/CPU），
  一次 51.5 s、1564 帧的长跑里，trace 末尾（停摆时刻）是**一次正常的
  `vfe_isr → vb2_buffer_done`**，之后到结束的 40 多秒里**再没有任何中断/回调**：
  ISR 外层约 12 µs、其中 `vb2_buffer_done` 约 1.5–2.5 ms。
  也就是说硬件是"干完一帧就彻底不吭声"了，软件侧没有任何异常、没有超时、没有错误码。
- `modprobe -r qcom_camss` 在卡死状态下返回 `Module qcom_camss is in use`（refcount 手持着），
  所以"重载 camss 模块"不能作为恢复手段。

### 新增：2016×1512 2×2 binning 模式（`imx363.c`）

在 `supported_modes[]` 里加了第二档 **2016×1512**，实现方式是极小的改动：

- `mode_4032x3024_regs` 里 `0x0900 (BINNING_MODE)=0`、`0x0901 (BINNING_TYPE_V)=0x11` 本来就在表里；
- `imx363_start_streaming()` 里当 `cur_mode->width == 2016` 时补写三条：
  `0x0900=1`、`0x034C (X_OUT_SIZE)=2016`、`0x034E (Y_OUT_SIZE)=1512`；
- PPL(8832) / VTS(3136) / link freq 全部不变 → **帧率保持 30fps，每帧数据量正好 1/4**。

实测（`v4l2-ctl` 裸流）：格式协商成 2016×1512 SRGGB10，每帧 3 822 336 字节，30.29 fps，
原始数据 min/max/mean = 14/784/75.8，非零字节 93% —— 是**正常的图像**，不是黑帧/垃圾。

**但这并没有修好停摆**：binning 模式下 120 s 长跑仍然中断，而且更快 ——
657 帧 / 21.6 s（全分辨率是 1500~1750 帧 / 48~57 s）。数据量降到 1/4 反而更早停，
说明停摆**不是数据率/带宽相关**，而是时间相关且抖动很大（已观测 14.8 s / 21.6 s / 48~57 s）。

### 试过但无效的方向（已回退）

> **踩过的坑（重要）**：模块目录里同时存在 `qcom-camss.ko` 和旧的 `qcom-camss.ko.zst` 时，
> 系统会加载**旧的 .zst**，新编的 .ko 根本没生效。早期"min_queued_buffers=2 无效"和
> "camnoc_axi 400 MHz 导致 EBUSY"这两条结论都因此作废（后者其实是 wireplumber 占着
> `/dev/media0` 造成的）。换模块必须先 `rm -f .../qcom-camss.ko.zst`（见 `install_mod4.sh`）。

- `q->min_queued_buffers = 2`：**未真正验证过**（被上述坑挡住），已回退为 1。
- 给 `vfe_res_670` 的 `camnoc_axi` / `vfe0_axi` 补 400 MHz：**未真正验证过**，已回退。
- **VFE 时钟 100 MHz → 404 MHz（真正测过）**：注意 CSID 的 `csid_res_670` 也会把共享的
  `ife_0_clk` 设成 100 MHz 并覆盖 VFE 的设置，两处都改后 `ife_0_clk` 确实变成 404 MHz，
  但结果是**一帧都出不来（0 帧）**，比原来更差，说明 VFE 时钟不是瓶颈。已回退。

### 测试环境注意

- `pipewire` / `wireplumber` 会一直占着 `/dev/video0` 和 `/dev/media0`，做内核级裸流测试前必须
  `systemctl --user stop wireplumber pipewire`，否则 `video_prepare_streaming()` 返回 `-EBUSY`。
- 每轮测试前要重启（停摆状态跨会话、跨进程保持）。
- 换 `qcom-camss.ko` 时必须同时删掉模块目录里的 `qcom-camss.ko.zst`，否则加载的还是旧的压缩模块。

### 原厂固件（sirius_images_V12.5.1.0.QEBCNXM）里有什么

- `images/vendor.img` 是 **Android sparse** 格式（`simg2img` 可展开成 3.2 GB ext4，可 `sudo mount -o loop,ro`）。
- **相机 sensor 数据在 `/lib/camera/`（32 位库目录，不是 `/lib64/camera`，后者不存在）**：
  - `com.qti.sensor.imx363.so`（24 KB，ELF32，sensor 模块外壳）
  - **`com.qti.sensormodule.imx363.bin`（131 KB，QTI Chromatix `ParameterParser V1.1.0` 容器）**
  - `com.qti.tuned.ofilm_imx363.bin`（3.7 MB，tuning）
  - 另有 `imx363_ii` 变体（第二个模组厂）以及 s5k2l7 / s5k2t7sp / s5k5e8yx 的对应文件
- `.bin` 容器里的 section 名（可直接 `strings`）：
  `sensorDriverData`、`PDConfigData`、`cameraModuleData`、`actuatorDriver`、`EEPROMDriverData`、
  `flashDriverData`、`sensorName`、**`powerSetting`（上电/下电两组）**、`integrationInfo`、
  **`resolutionInfo`／`resolutionData`／`streamConfiguration`／`regSetting`**，以及成对的
  `slaveAddr` / `registerData` / `delayUs` —— 也就是说**寄存器序列按分辨率都在这一个文件里**。
- 常量扫描确认它含多档分辨率：**4032×3024、1920×1080、1280×720、1008×756、1512…**
  （`4032/3024` 相邻出现在 104120/104124，`1920/1080` 相邻出现在 113447/113451，符合 `{u16 w; u16 h;}`）。
- 已抽出到 `workspace/build/camtest/vendor/`（含 `analysis.txt`、`layout.txt`、`scan_res.py`）。
- `/etc/camera/` 只有 MIUI 人脸/水印资源和 `camxoverridesettings.txt`；`/etc/sensors/` 是运动传感器 HAL。
- 真正的厂商相机 DT：`~/rocky-sdm710-linux/arch/arm64/boot/dts/qcom/sirius-sdm670-camera-sensor.dtsi`。
- **`system.img` 里没有相机配置**：展开后 `/etc`、`/lib64`、`/vendor`（symlink）都没有 camera/imx 相关，
  相机配置全在 `vendor.img`。

#### 容器解包进度（2026-10-23 22:4x）

已经确定的部分：

- 条目表：`0xb8` 起 1619 条 × 64 字节，字段为 `[flag][offset][size][id][name[32]]` + 16 字节填充。
  `offset` 是**在所属数据区内的相对偏移**，`size` 是字节数（已验证连续性：0→384→464→484→586→1182→1240…）。
- 根数据区基址 **≈ 0x1F9AA (129450)**：在这里 `sensorName` 解出 **`imx363_ofilm`**，
  `flashDriverData` 区里还有 `sirius_bu64748gwz`、`imx363_pdaf`、`com.qti.stats.pdlib` 等字符串。
- 但 `streamConfiguration`（offset 1419, size 672）与 `regSetting` 组（offset 2155+）已经超出该区
  → **数据被拆成多个区，每个根 section 有自己基址**，这个基址目前还不知道从哪读。
- 寄存器数值**不是**明文 `{addr, val}`：3/4/6 字节多种布局、u16/u32 数组、以及特征序列
  （`0x0900=0 / 0x0901=0x11`、`0x0381..0x0387=1`）在 `.bin` 和 `sensor.so` 里**全部搜不到**
  → 寄存器数组是编码/压缩存储的，需要 ParameterParser 的格式规范才能解。

结论：这条路（从原厂固件还原厂商寄存器表）**需要完整的 ParameterParser 逆向**，
是个小时级甚至更长的工程，且不保证有收益。


复现脚本：`workspace/build/camtest/`（`probe28_rawl.on` 裸流长跑、`probe19.sh` 压力复现、
`probe15.sh` 基线、`i2cread.py` CCI 直读、`install_mod3.sh` / `restore_mod.sh` 模块替换与回滚）。

## 设备树配置（`sdm710-xiaomi-sirius.dts`）

- 传感器：`cci_i2c0` 下 `camera@10`，`sony,imx363`，4 lane，MCLK0（GPIO 13），
  `CAM_RESET0`（GPIO 30，低有效）。
- 供电（参考 `~/rocky-sdm710-linux/arch/arm64/boot/dts/qcom/sirius-sdm670-camera-sensor.dtsi`）：
  - `vana`：GPIO 8 使能，PM660L BOB 2.8 V
  - `vdig`：GPIO 29 使能，输入 PM660 S6（实测 S6 约 1.224 V）
  - `vif`：PM660 LDO14 1.8 V
- CAMSS：`vdda-phy = L1A`、`vdda-pll = S6A`（沿用 sdm670-google-common 的接法）
- CSI：CSI0 / CSID0 / VFE0 RDI0，4 lane，link-frequency 636 MHz（4 lane）
- 方向属性（本次新增）：

```dts
rotation = <270>;
orientation = <1>; /* back */
```

`rotation` 语义见 `Documentation/devicetree/bindings/media/video-interface-devices.yaml`，
驱动通过 `v4l2_ctrl_new_fwnode_properties()` 暴露为 `V4L2_CID_CAMERA_SENSOR_ROTATION`，
libcamera/PipeWire 读取后作为相机属性（`api.libcamera.rotation`）交给应用做显示旋转。

> 历史：`rotation = <90>` 时画面上下颠倒；仅凭下游 `sensor-position-roll = <90>` 不能直接
> 映射到 libcamera 的旋转方向。270 是否最终正确仍需实际预览确认；若出现镜像而不是颠倒，
> 需要再处理 `V4L2_CID_HFLIP/VFLIP`（imx363 驱动已支持，但会改变 Bayer 顺序）。

## 已定位并修复的问题

### 1. 预览“用一段时间后卡死”：CAMSS 允许零缓冲启动

根因在 `drivers/media/platform/qcom/camss/camss-video.c` 的 vb2 队列：
`min_queued_buffers` 默认为 0，允许用户态在**还没入队任何 buffer 时先 `STREAMON`**。
libcamera 的 simple pipeline 存在先 `STREAMON` 再入队 buffer 的时序，于是：

1. 传感器、CSIPHY、CSID、VFE 全部正常启动（`s_stream` 均返回 0）；
2. 但 VFE 没有任何目标 buffer，写完一帧也不产生 frame-done 中断；
3. 之后 `QBUF` 入队的 buffer 不会再次触发 `start_streaming`，因为已经调用过；
4. 预览永远停在最后一帧/黑屏，直到重启；期间电源、时钟都正常，内核无报错。

修复：设置 `q->min_queued_buffers = 1`，让 vb2 等第一个 buffer 入队后再真正调用
`video_start_streaming()`。这样无论用户态是“先入队再 STREAMON”还是反过来，硬件都能拿到
目标 buffer。

验证（修复后，同一套 PipeWire/libcamera 通路）：

- `libcamerasrc` 8 s 出 157 帧；VFE 中断 0 → 420；
- 连续 3 轮 libcamera 启停：29 / 76 / 71 帧，每轮之后 `v4l2-ctl` 裸流仍能出图；
- PipeWire 640x480 15 s 出 453 帧（29.9 fps）。

### 2. 预览静默后连裸流也取不到帧

修复前，一旦进入“零缓冲启动”状态，后续 `v4l2-ctl` 也取不到帧（`STREAMON` 成功但无 dqbuf），
只有重启能恢复。修复后多轮启停下未再复现。`v4l2-ctl` 裸流本身只需先由 libcamera 或
`media-ctl` 把各 subdev 格式配置好（否则 `media_pipeline_start` 会因格式不一致返回 `-EPIPE`）。

## 尚未解决的问题

### 1080p 预览为 0 帧（结论已作废，见上文「实测复现」）

> 2026-10-23 复测：干净启动下 1080p 各通路都有 ~30 fps。本节记录的 0 帧现象，实际是设备已经进入
> 「会话累积退化」后的状态，与 1080p 分辨率无关。以下内容仅作为历史记录保留。

实测 PipeWire 通路（SPA libcamera source，节点 `Built-in Back Camera`）：

| 请求分辨率 | 帧率 |
|---|---|
| 640x480 | 约 29 fps |
| 1280x720 | 约 26 fps |
| 1920x1080 | **0 帧** |

GNOME Snapshot 打开时固定 `configuring streams: (0) 1920x1080-ABGR8888`，因此用户看到的就是
“摄像头又死了”。libcamera 内部 debayer 日志仍显示 `Processed 30 frames ... 19 ms/frame`，
说明 raw 采集和 debayer 在跑，问题在 1080p 的输出/缩放/交付环节。

已验证/已排除：

- 1080p 失败后重新请求 640x480 仍可出帧（最近一次 6 s 185 帧）；
- 之前有两次在 1080p 长跑后整条管线静默（裸流也 0 帧），只能重启恢复；与上文的
  `min_queued_buffers` 修复是否完全无关尚未确认；
- 内核 `dmesg` 无 CAMSS/VFE/IOMMU 报错；VFE 中断不增长。

可能方向（按优先级）：

1. libcamera 软件 ISP 在大尺寸输出时的缩放/交付路径，查 libcamera 0.4 的
   `soft_simple` / `debayer_cpu` 在 1080p 下的行为与错误返回；
2. SPA libcamera 插件协商 1080p 时的 buffer 分配：`/dev/dma_heap/*` 为 `0600 root`，
   libcamera 回退到 `/dev/udmabuf`，需要确认 1080p 路径是否因此异常；
3. 若短期无法修好 1080p，可让应用侧改用 ≤720p（1280x720 已验证可用），
   或在 PipeWire 层限制该相机节点的最大格式；
4. ~~给 imx363 增加 2x2 binning 模式（约 2016x1512），libcamera 会优先选它，
   同时降低 debayer/缩放开销~~ —— **已实现并实测**，见上文「新增：2016×1512 2×2 binning 模式」。

### 硬件 ISP（VFE PIX）现状

- 媒体图里**存在** ISP 通路：实体 `msm_vfe0_pix`（`/dev/v4l-subdev9`）→ `msm_vfe0_video3`（`/dev/video3`），
  `/dev/video3` 声明支持 `UYVY / YUYV / VYUY / YVYU` 等 YUV 输出格式；
  pix 的 sink pad 由 **`msm_csid0` pad4** 喂入（不是 pad1）。
- **未验证通过**：手工用 media-ctl 打开该链路 + 对齐格式没成功（`STREAMON` 返回 `-EPIPE`），
  只试过两次，还差"csid pad4 格式 vs pix sink/source 格式对齐"这一步。
- **它修不了停摆**：停摆发生在数据进入 CSID 之前（裸流 RDI 都收不到任何包），
  换 PIX 只是换下游处理方式，输入还是同一条 CSI。
- 就算通了，也只是性能收益（省掉 12MP 的 CPU debayer、硬件缩放），
  代价是 mainline 的 PIX 缺 3A/统计实现、且没有 libcamera 的 Qualcomm ISP pipeline handler，需要自己写。



libcamera 软件 ISP 没有 imx363 的 `CameraSensorHelper`，也没有 `imx363.yaml` 调校文件，
启动日志可见：

```
IPASoft: Failed to create camera sensor helper for imx363
IPASoft: Minimum gain is zero, that can't be linear
IPAProxy: Configuration file 'imx363.yaml' not found ... falling back to 'uncalibrated.yaml'
```

AE 的增益换算与 AWB 都处于未标定状态，普通室内灯光下容易出现亮度/颜色缓慢摆动。
修复需要在 libcamera 用户态补充 imx363 的 sensor helper（增益/曝光换算）和调校文件，
不是内核改动。此前“帧率极低、AE 反复修正”也会放大闪烁观感；`min_queued_buffers` 修复后
帧率稳定在 30 fps，AE 值不再来回跳（实测 preview 期间 `exposure=3126, gain=480` 稳定）。

### GNOME Snapshot 自身退出

用户侧日志在预览卡住后出现大量：

```
snapshot[...]: gdk_subsurface_attach: assertion 'sibling != subsurface' failed
```

随后应用 scope 结束（`Consumed 5.440s CPU time, 141.9M memory peak`），没有内核错误。
属于 GTK4/GDK Wayland subsurface 渲染问题，和摄像头采集无直接关系；但 1080p 预览无帧
会使用户优先感知为“相机死了”。

## 验证与调试命令

格式未配置时裸流会 `-EPIPE`，先跑一次 libcamera（或 media-ctl）配置链路，再：

```sh
# 裸流 30 fps
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=10 \
          --stream-to=/dev/null --verbose

# 传感器控制
v4l2-ctl -d /dev/v4l-subdev18 --get-ctrl \
          exposure,analogue_gain,digital_gain,vertical_blanking

# 相机属性（rotation/location）
wpctl inspect 67 | grep -iE 'rotation|location'

# 预览通路压测（PipeWire + libcamera，与 Snapshot 相同）
XDG_RUNTIME_DIR=/run/user/1000 python3 - <<'EOF'
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib
Gst.init(None)
p = Gst.parse_launch("pipewiresrc path=67 ! "
                     "video/x-raw,format=RGBA,width=640,height=480 ! "
                     "fakesink sync=false")
n = [0]
s = p.get_by_name("pipewiresrc0")
s.get_static_pad("src").add_probe(
    Gst.PadProbeType.BUFFER,
    lambda pad, info: (n.__setitem__(0, n[0] + 1), Gst.PadProbeReturn.OK)[1])
loop = GLib.MainLoop()
p.set_state(Gst.State.PLAYING)
GLib.timeout_add_seconds(10, lambda: (p.set_state(Gst.State.NULL), loop.quit())[1])
loop.run()
print("frames", n[0])
EOF

# 相机相关内核日志 / 用户态日志
sudo dmesg | grep -iE 'camss|imx363|vfe|csid|csi'
journalctl --user -b | grep -iE 'libcamera|camera|snapshot|pipewire'
```

## 部署状态

- 手机上已安装：
  - `/boot/dtb/sdm710-xiaomi-sirius.dtb`（rotation = 270）
  - `lib/modules/7.3.0-sdm670+/kernel/drivers/media/i2c/imx363.ko.zst`
  - `lib/modules/7.3.0-sdm670+/kernel/drivers/media/platform/qcom/camss/qcom-camss.ko.zst`
    （含 `min_queued_buffers = 1` 修复）
- 系统分区为 `mmcblk0p79`（`/mnt/sysmod`）；修改时需
  `mount -o remount,rw /mnt/sysmod`，完成后改回 `ro`。
- 旧文件备份在手机 `/home/u57u/cam-debug-backup/`
  （`imx363.ko.zst`、`qcom-camss.ko.zst`、`dtb.pre-rotation`）。
- 仓库内 `build/kernel.img` 仍是修复前的，下一次 `./build.sh kernel` 会带上新模块和 DTB。
- 源码改动未提交：`arch/arm64/boot/dts/qcom/sdm710-xiaomi-sirius.dts`（方向属性）、
  `drivers/media/platform/qcom/camss/camss-video.c`（min_queued_buffers），以及此前已有的
  imx363 电源时序、DTS 摄像头/音频改动。

## 下一步建议

1. 先确认 `rotation = 270` 的显示方向是否正确（必要时再调 hflip/vflip）；
2. 集中解决 1080p 0 帧（Snapshot 默认路径），优先查 libcamera 软件 ISP 的 1080p 输出；
3. 短期可用 ≤720p 预览作为可接受方案；
4. 补 libcamera 的 imx363 sensor helper / 调校文件，解决 AE/AWB 与闪烁；
5. 如需降低负载和提升预览体验，再考虑 imx363 2x2 binning 模式。
