# 传感器（Snapdragon Sensor Core）—— 已打通（2026-10-20）

加速度计、磁力计、指南针**实测出数**；光感/距感能进 registry 但读数报 UNKNOWN。

## 结论

**能做，而且不需要改 DT。** 之前判断"卡在 ADSP 固件"是错的。真正原因是
`adsprpcd sensorspd` 抢先占住了 fastrpc 的 default listener，hexagonrpcd 注册不上。

pmOS 的 sdm670 内核提交也写了：CVE-2024-41024 的修复破坏非安全域后，
**为了让 audiopd/rootpd/sensorspd 继续可用，ADSP 域被标记为 secure**。所以
`/dev/fastrpc-adsp-secure` 就是对的，不要加 `qcom,non-secure-domain`（加了反而报
`dsp information is incorrect`）。

## 关键步骤（按顺序）

1. **停掉并禁用 `adsprpcd-sensorspd`**（成败关键）：
   ```sh
   systemctl disable --now adsprpcd-sensorspd
   ```
   不关它，hexagonrpcd 必报 `Could not register ADSP default listener`。

2. **准备 HexagonFS 文件树**（`-R /usr/share/qcom`）：

   | 本地路径 | 来源（Android） | 我们怎么拿的 |
   |---|---|---|
   | `sensors/config/` | `/vendor/etc/sensors/config` | 原厂 `vendor.img`（sparse ext4）解出，26 个 json |
   | `sensors/registry/` | `/mnt/vendor/persist/sensors/registry/registry` | 设备 `/persist/sensors/registry/registry` |
   | `sensors/sns_reg.conf` | `/vendor/etc/sensors/sns_reg_config` | 同上 vendor.img，**要改名** |
   | `socinfo/` | `/sys/devices/soc0` | `mount --bind /sys/devices/soc0 /usr/share/qcom/socinfo` |
   | `dsp` | `/vendor/dsp` | 软链到 `/lib/firmware/qcom/sdm710/pyxis/adsp` |

   `sns_reg_config` 里写明 registry 是 DSP **运行时生成**的（读 socinfo + config 后写回
   `sensors/registry/`），所以该目录必须可写，socinfo 必须挂上，否则 registry 出不来。

3. **编译 hexagonrpcd + libssc**：
   - hexagonrpcd：`https://github.com/linux-msm/hexagonrpc`（meson，依赖 libqrtr-glib）
   - libssc：**`https://codeberg.org/DylanVanAssche/libssc`**（网上的 gitlab 地址已 403）
   - 依赖：`libglib2.0-dev libqrtr-glib-dev libqmi-glib-dev libprotobuf-c-dev
     protobuf-c-compiler protobuf-compiler python3-dev meson ninja-build`
   - 产物在设备 `/home/u57u/{hexagonrpc-build,libssc-build}`

4. **起服务**：`rootfs/overlay/etc/systemd/system/hexagonrpcd.service`
   （做 socinfo bind mount，以 `-f /dev/fastrpc-adsp-secure -s -R /usr/share/qcom` 启动）

5. **读数据**：
   ```sh
   LD_LIBRARY_PATH=/home/u57u/libssc-build/src \
     /home/u57u/libssc-build/src/ssccli --sensor=accelerometer --timeout=20
   ```

## 实测结果

| 传感器 | 结果 |
|---|---|
| Accelerometer | `X=-0.47 Y=0.48 Z=9.74 m/s²`（重力 9.8，正确） |
| Magnetometer | `X=-8.85 Y=62.4 Z=-152`（μT，量级合理） |
| Compass | `273.5°`，连续变化正常 |
| Ambient Light | `Unable to initialize light sensor: UNKNOWN` |
| Proximity | `Unable to initialize proximity sensor: UNKNOWN` |
| Gyroscope / Pressure | registry 里有 `bmi160.gyro`、`bmp285.pressure`，ssccli 不支持单独读 |

DSP 生成的 registry 里能看到这些条目：`bmi160`（加计+陀螺+温度）、`ak0991x`（磁力）、
`bmp285`（气压）、`tmd2725`（光感+距感）。注意 **这台机器实际没有气压计硬件**，
`bmp285` 只是 registry 里的配置残留（来自同平台其他机型的 config），别当成可用传感器。

光感/距感的 UNKNOWN 已经查到具体程度，但没解决：

- `ssccli -v` 显示 `Discovering sensor UID for data type 'ambient_light'` → `No 'ambient_light' sensor available`，
  即 SSC 里根本没注册这个 data type（不是 libssc 读不到）。
- 原厂 `vendor.img` 的 `/etc/sensors/config/` 里这颗芯片的配置叫 **`tmd2725.json` / `sdm670_tmd2725.json`**，
  `slave_config=57`（0x39），`is_dri=1`。
- 但在 `adsp.mbn` 里 `strings | grep` 出来的是 **`sns_tmd3702_sensor` / `sns_tcs3701_sensor_instance_island` /
  `TCS3701ALS` / `TCS3701PROX`**，**完全没有 tmd2725 字样**。
- 试过：① 补 `hw_platform=MTP`（原始 sysfs 里没有这个文件）② `is_dri` 改 0（轮询）
  ③ 把 `tmd2725.json` 整体改名成 `tmd3702.json` 并同步改 `config_list.txt` —— **三种都没让 ambient_light 出现**。

所以：固件只认 TMD3702/TCS3701，而原厂配置写 TMD2725，两者对不上。要往下走必须先确认这颗芯片到底是哪颗
（原厂 CONFIG 说是 tmd2725，固件驱动说只有 3702/3701），然后按固件支持的型号写配置。

另：`/usr/share/qcom/sensors/registry/` 清空后加计/陀螺/磁力照样能读，说明 DSP 在内存里维护 sensor 表，
磁盘上那份只是持久化副本，删了不影响运行。

## 已知副作用

- 磁力计警告 `Mount matrix provided by firmware is all 0, falling back to identity matrix`，
  校准矩阵没读到（registry 里有 `ak0991x_0_platform.orient/placement` 但值为 0）→ 方向可能偏。
- `adsprpcd-sensorspd` 必须保持 disabled。回退：`systemctl enable --now adsprpcd-sensorspd`
  并停掉 hexagonrpcd。
