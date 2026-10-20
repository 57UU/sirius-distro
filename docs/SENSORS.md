# 传感器（Snapdragon Sensor Core）

加速度计、陀螺仪、磁力计、指南针可用；光线 / 距离不可用。

## 部署

1. `systemctl disable --now adsprpcd-sensorspd` —— 不关它会抢 fastrpc 的 default listener。
2. 准备 `/usr/share/qcom/`：

   | 路径 | 来源 |
   |---|---|
   | `sensors/config/` | 原厂 `vendor.img` 的 `/etc/sensors/config`（26 个 json） |
   | `sensors/registry/` | `/persist/sensors/registry/registry` |
   | `sensors/sns_reg.conf` | `vendor.img` 的 `/etc/sensors/sns_reg_config`（改名） |
   | `socinfo/` | `mount --bind /sys/devices/soc0` |
   | `dsp` | 软链到 `/lib/firmware/qcom/sdm710/pyxis/adsp` |

3. 起 `hexagonrpcd.service`（`rootfs/overlay/etc/systemd/system/`）：
   `hexagonrpcd -f /dev/fastrpc-adsp-secure -s -R /usr/share/qcom`

4. 读数据：`ssccli --sensor=accelerometer|gyroscope|magnetometer|compass`

源码：hexagonrpc（`github.com/linux-msm/hexagonrpc`）、libssc（`codeberg.org/DylanVanAssche/libssc`，
网上流传的 gitlab 地址已 403）。依赖：`libglib2.0-dev libqrtr-glib-dev libqmi-glib-dev libprotobuf-c-dev
protobuf-c-compiler protobuf-compiler python3-dev meson ninja-build`。

## 光感 / 距感为什么不行

`ambient_light` 在 SSC 里没有注册。根因是 `adsp_default_listener` 全局唯一：

- 启动 sensor PD 要靠 `adsprpcd`（占住 listener，却不提供文件服务）
- 提供 config/registry 文件服务要靠 `hexagonrpcd`（抢不到 listener）

sdm845 有独立 SLPI（`/dev/fastrpc-sdsp`），两者不冲突；sdm670 没有 SLPI，sensor 直接在 ADSP 里，
天然二选一。试过所有配置层的组合（改名、owner、is_dri、三套并存、清 registry）均无效。

## 注意

- **不要 `systemctl restart hexagonrpcd`**：重启后它抢不到 listener，会变 inactive，
  只能整机重启恢复（开机时它比 adsprpcd 注册得早）。
- 磁力计会警告 mount matrix 全 0，回退单位矩阵，方向可能偏。
- `bmp285`（气压计）只是 config 残留，这台机器没有该硬件。
