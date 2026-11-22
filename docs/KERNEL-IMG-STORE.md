# system / userdata 分区解耦（kernel.img ↔ rootfs）

本项目将硬件侧与发行版侧拆为两个可独立升级的镜像（抽象模型见 [PARTITION-MODEL.md](PARTITION-MODEL.md)）：

| 分区 | 设备 / 挂载点 | 镜像 | 内容 |
|---|---|---|---|
| `system` | `/dev/mmcblk0p79`（`sirius_vendor`，`sysmod_part=`）→ `/mnt/sysmod`（`ro`） | `build/kernel.img`（ext4 384M，首启扩满） | 内核 `Image`/dtb/initrd、模块、固件、设备耦合 userspace（`glue/`） |
| `userdata` | `/dev/mmcblk0p81` → `/` | `build/debian-trixie-sirius-{server,gnome}-*.simg` | Debian trixie、GNOME/Orbital、flavor 策略、用户数据 |

## 1. 边界判据

| 放 `glue/`（随 `kernel.img`） | 留 `rootfs/overlay/` 或发行版包 |
|---|---|
| 与内核/驱动/固件/QRTR/FastRPC 耦合的 unit、脚本、二进制 | 发行版包、Orbital/GNOME、桌面与用户策略 |
| 设备 udev 规则、模块加载、tmpfiles、ALSA UCM、Sensor Core 配置 | **flavor 策略**（server/gnome 行为不同的配置，如 logind 电源键） |
| 设备层私有运行库（glibc 与 GLib 家族由 rootfs 提供，其余自带） | 用户可改的 `/etc`、CLI 工具（`sirius-screen` 等） |
| 设备相关、**flavor 中立**的运行期配置（经 `glue/run/` 链进 `/run`） | OS 底座服务与工具（见 §2 第 5 项） |

`system` 镜像为两 flavor 共用，因此 flavor 策略必须留 `userdata`。

## 2. 跨层接口（rootfs 侧）

镜像层面接口极窄（`manifest` 与生成器实现全在 `system` 内部）；运行期则通过稳定契约双向协作：

1. **唯一执行入口**：`/usr/lib/systemd/system-generators/sirius-kernel-glue`（4 行 stub，转发 `$@` 到 `/mnt/sysmod/glue/scripts/sirius-kernel-glue`）。
2. **挂载点**：initrd 将 `system` 分区 `ro` 挂到 `/mnt/sysmod`，并 bind `lib/modules/<uname -r>`、`lib/firmware` 进新根（缺失时回落 rootfs 空目录）。
3. **运行库 ABI 下限**：rootfs 提供 `glibc >= 2.38`（trixie 2.41 可用，bookworm 2.36 不可）及 `GLib 2.x` 家族（`libglib-2.0`/`libgio-2.0`/`libgobject-2.0`/`libgmodule-2.0`）。
4. **首启 preset**：`/etc/systemd/system-preset/50-sirius-glue.preset`（`disable adsprpcd-* / sirius-* / bt-addr.service / pd-mapper.service / wifi-shutdown.service`），防止 systemd 首启将 generator 单元固化进 `/etc`。
5. **运行时底座服务契约**（均在 `SIRIUS_BASE_PKGS` 中，rootfs 不可删除或替换）：

   | rootfs 底座 | glue 调用方式 |
   |---|---|
   | `systemd` / `udev` / `kmod` / `coreutils` / `util-linux` / `procps` | generator、rules/link/modules-load、设备脚本工具链 |
   | `qrtr-tools`（`qrtr-ns`） / `tqftpserv` / `rmtfs` | `adsprpcd-*`、`pd-mapper`、`sirius-sensors`、`sirius-modem-uim*` 依赖与 drop-in |
   | `BlueZ` / `NetworkManager` / `ModemManager`+`libqmi-utils` | `bt-addr`、`sirius-bt-*`、`sirius-wifi-auto`、`sirius-modem-uim`、`glue/run` 配置 |
   | `ALSA`（`alsaucm`） / `PipeWire`（`pw-cli`、wireplumber） | `sirius-audio-init`、`sirius-audio-refresh` |

## 3. `glue/` 布局与运行时配置

```text
glue/
  ABI                    # 当前 "1"（manifest schema 版本）
  manifest               # 构建时由 kernel/gen-glue-manifest.sh 生成
  bin/                   # adsprpcd、pd-mapper、uimsel/uimwatch、hexagonrpcd、ssccli、sirius-remodeset
  scripts/               # 设备脚本、生成器（sirius-kernel-glue）、sirius-glue-setup、CLI 工具
  lib/                   # 私有运行库闭包（~7.6M），来源见 glue/lib/README.md
  units/                 # 设备 systemd unit（含 rmtfs drop-in、tmp.mount mask）
  units.enable           # <unit> <target> 列表
  udev/rules.d/  modules-load.d/  modprobe.d/  tmpfiles.d/  network/  alsa/ucm2/SE/  sensors/
  run/                   # flavor 中立的运行期配置，开机由 sirius-glue-setup.service 链到 /run
```

`glue/run/` 在 udev、sysctl、tmpfiles 和 NM 之前链入 `/run`（`/etc` 同名覆盖优先级更高）：

| 文件 | 链接目标 | 作用 |
|---|---|---|
| `glue/run/NetworkManager/conf.d/sirius-server.conf` | `/run/NetworkManager/conf.d/` | WiFi `powersave=2`、扫描不随机改 MAC |
| `glue/run/NetworkManager/system-connections/cellular.nmconnection` | `/run/NetworkManager/system-connections/` | 蜂窝自动连接（必须 `root:0600`） |
| `glue/run/sysctl.d/60-sysrq.conf` | `/run/sysctl.d/` | `kernel.sysrq=1` |

## 4. 运行库与打包策略

- **RPATH 代替 `LD_LIBRARY_PATH`**：`kernel/build-kernel-img.sh` 打包时用 `patchelf` 给 staging 树 ELF 写 RPATH（`bin` → `$ORIGIN/../lib`，`lib` → `$ORIGIN`），不污染 unit 内 `exec` 的 rootfs 程序（`iw`/`bluetoothctl` 等）。新增库需放实名 SONAME `.so` 进 `glue/lib`，刷机后用 `ldd /mnt/sysmod/glue/bin/* | grep 'not found'` 自检。
- **manifest schema v1**：支持 `abi`、`unit`、`dropin`、`wants`、`run` 五类指令（未知行记日志忽略）；生成器只写 `/run/systemd/generator/`，`sirius-glue-setup.service` 负责 `/run/` 配置（重跑时依 `/run/sirius-glue/links` 清理旧链接）。
- **永不阻塞启动**：glue/manifest 缺失、ABI 不符或 stub 不可执行时，写 `/dev/kmsg` 后 `exit 0`（设备服务降级，SSH 仍可用）。
- **特殊规则**：
  - **WiFi 工厂 MAC**：基础规则在 `glue/network/10-wlan0.link`；`sirius-glue-setup` 只读挂载 `persist`，生成 `/run/systemd/network/10-wlan0.link.d/50-factory-mac.conf`（仅覆盖 `MACAddressPolicy=none` 与 `MACAddress`），并按内容一致原则清理旧 initrd 遗留的 `/etc/systemd/network/10-wlan0.link`。
  - **enablement**：glue unit 不写 `[Install]`，统一由 `units.enable` → manifest `wants` 启用；新增 unit 需按 `sirius-*` / `adsprpcd-*` 命名以匹配首启 preset。
  - **磁盘 `/tmp`**：`glue/units/tmp.mount` 指向 `/dev/null` mask 掉发行版 tmpfs，改用 userdata 磁盘 `/tmp`（`/run` 仍为 tmpfs；用户可在 `/etc/systemd/system/tmp.mount` 覆盖）。
  - **权限**：`glue/` 打包时全 `root:root`，`cellular.nmconnection` 为 `0600`（因此 `kernel` 构建需要 `sudo`）。

## 5. 启动链

1. initrd `find_sysmod_dev` 定位 `/dev/mmcblk0p79`（`sysmod_part=` 可覆盖）→ `expand-part` → `mount -o ro` → `mount --move` 至 `/mnt/sysmod`。
2. bind `lib/modules/<uname -r>`、`lib/firmware` 至新根；initrd 仅处理蓝牙 NVM，不再写 `/etc` WiFi `.link`。
3. `switch_root` 后 systemd 调 stub → 生成器生成 unit → `sirius-glue-setup.service` 准备 `/run` 配置与工厂 MAC drop-in。
4. 排查日志：`dmesg | grep -E "sysmod|sirius-glue"`、`journalctl -b -u sirius-glue-setup`。

## 6. 构建、升级与刷机

```bash
./build.sh initrd
./build.sh kernel            # 需要 root（NOPASSWD sudo 或 sudo ./build.sh kernel）
bash scripts/test-glue.sh    # 离线回归测试
fastboot flash system kernel.img && fastboot reboot
```

- 产物 `build/kernel.img`（384M）归还给调用者所有；rootfs 树与 `workspace/build/base` 属 root。
- **升级兼容**：`旧 rootfs + 新 system` 通常安全（旧 `/etc` 同名覆盖优先）；`新 rootfs + 旧 system` **会坏**（缺 `glue/run`、tmpfiles 等）。首次引入 glue 的版本（2026-11-15 起）须两边同批刷写。

## 7. 验收清单

```bash
# 构建侧：bash scripts/test-glue.sh；挂载 kernel.img 确认 root:root、0600、RUNPATH=$ORIGIN/../lib
# 设备侧：
uname -r; ls /lib/modules/$(uname -r) | head
cat /proc/mounts | grep sysmod              # 期望 ro 且无 noexec
dmesg | grep -E "sysmod|sirius-glue"        # 期望 "linked N units from /mnt/sysmod/glue (ABI 1)"
systemctl --failed
systemctl is-active qrtr-ns tqftpserv rmtfs bluetooth NetworkManager ModemManager
command -v nmcli mmcli qmicli btmgmt alsaucm
systemctl cat sirius-sensors | head         # FragmentPath 在 /run/systemd/generator/
ls -l /var/lib/rmtfs                        # 4 项 partlabel 软链在位
nmcli con show | grep -i cellular           # 从 /run 读到蜂窝 profile
ldd /mnt/sysmod/glue/bin/* 2>/dev/null | grep 'not found'   # 期望为空
sudo /mnt/sysmod/glue/scripts/sirius-test   # 一键硬件自检（--full 加外设项）
```
