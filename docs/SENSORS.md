# 传感器（Snapdragon Sensor Core）

加速度计、磁力计、指南针已实测可用；陀螺仪走同一 SSC 通道（libssc 的 gyroscope
接口，本轮未单独测）；光线 / 距离不可用（SSC 里没有注册 `ambient_light`）。

## 架构

```
sensor PD (ADSP 内, /dev/fastrpc-adsp-secure)
        │  FastRPC reverse tunnel: apps_std 文件请求
        ▼
hexagonrpcd (glue/bin, -s -R /run/sirius-qcom)
        │  HexagonFS: config / registry / sns_reg.conf / socinfo / dsp
        ▼
libssc (glue/lib/libssc.so.2)  ← QRTR QMI service "ssc" → SSC service (node 400)
        ▼
ssccli（或任何调用 libssc 的程序）
```

sdm670 没有独立 SLPI，sensor PD 直接在 ADSP 里，而 ADSP 的 default listener
**全局唯一**：谁先 attach 谁得到服务。`adsprpcd-sensorspd` 与 `hexagonrpcd`
不能并存，所以现在不再启用 `adsprpcd-sensorspd`，改由 `hexagonrpcd` 先注册
（`sirius-sensors.service` 的 `Before=adsprpcd-*`），再由 `adsprpcd` 启动
audio/root PD。

## 部署（已自动化，随 system 分区走）

组件全部在 `glue/`，由 `./build.sh kernel` 打进 `kernel.img`：

| 内容 | 位置 | 来源 |
|---|---|---|
| `hexagonrpcd` | `glue/bin/hexagonrpcd` | [linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) 自编译（glibc，私有库同目录） |
| 私有库 | `glue/lib/libhexagonrpc.so.0.5`、`libssc.so.2`、`libprotobuf-c.so.1`（另有 qmi/qrtr 闭包；glib 家族用 rootfs 的，见 `glue/lib/README.md`） | hexagonrpc / libssc / Debian trixie |
| `ssccli` | `glue/bin/ssccli` | [libssc](https://codeberg.org/DylanVanAssche/libssc) 示例 CLI |
| 厂商 sensor 配置 | `glue/sensors/config/`（27 个 json，含 `config_list.txt`） | 原厂 `vendor.img` 的 `/etc/sensors/config` |
| `sns_reg.conf` | `glue/sensors/sns_reg.conf` | 原厂 `vendor.img` 的 `/etc/sensors/sns_reg_config`（改名） |
| 校准 registry | **运行时**从 persist 分区只读复制 | `/persist/sensors/registry/registry` |

`glue/scripts/sirius-sensors-setup`（unit 的 `ExecStartPre`）负责组装运行时根：

1. `/run/sirius-qcom/sensors/config` ← glue 里的厂商配置；
2. `/run/sirius-qcom/sensors/sns_reg.conf` ← glue；
3. `/run/sirius-qcom/sensors/registry` ← **persist 只读挂载后复制**（DSP 会回写
   registry，写的是 tmpfs；**persist 分区永远不写**）；
4. `/run/sirius-qcom/socinfo` ← `mount --bind /sys/devices/soc0`；
5. `/run/sirius-qcom/dsp` ← 软链到 `/lib/firmware/qcom/sdm710/pyxis/adsp`。

unit：`glue/units/sirius-sensors.service`（无 `[Install]`，启用关系在
`units.enable`）。旧的 `hexagonrpcd.service` 已从 rootfs overlay 删除。

## 读数据

```sh
sudo ssccli --sensor=accelerometer --timeout=10
sudo ssccli --sensor=magnetometer  --timeout=10
sudo ssccli --sensor=compass       --timeout=10
# rootfs 不需要建软链，glue 里的依赖库由镜像构建时写入的 RPATH 自动找到；
# 也可以直接跑 /mnt/sysmod/glue/bin/ssccli。
```

`ssccli` 需要访问 `AF_QIPCRTR`（root 下跑最简单）。光感/距感会报 `UNKNOWN`，
因为 SSC 没有注册这两个 sensor。

## 排障

```sh
systemctl status sirius-sensors
journalctl -b -u sirius-sensors
ls -la /run/sirius-qcom /run/sirius-qcom/sensors
qrtr-lookup | grep -i "Sensor Core"      # 期望有 node 400 的服务
sudo dmesg | grep fastrpc                # listener/DSP 侧报错
```

- **不要手动 `systemctl restart sirius-sensors`**：重启后 hexagonrpcd 抢不到
  已经注册的 default listener，只能整机重启恢复（`Restart=on-failure` 只用于
  启动失败重试）。
- 注册流程依赖顺序：`sirius-sensors` 必须先于 `adsprpcd-*`。如果看到
  `adsprpcd-sensorspd` 在跑，说明镜像还是旧的（旧 unit 已删除，旧 rootfs 上
  可 `systemctl mask hexagonrpcd` 并重刷 rootfs）。
- persist 读不到时 unit 仍会启动，只是没有校准数据（日志 `continuing without
  calibration`）。
- 磁力计会警告 mount matrix 全 0，回退单位矩阵，方向可能偏。
- `bmp285`（气压计）只是 config 残留，这台机器没有该硬件。
