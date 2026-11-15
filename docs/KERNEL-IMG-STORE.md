# system 分区仓库（kernel.img）：内核模块 + 固件 + 内核耦合 glue

`userdata` 的 rootfs 只装系统；内核模块、设备固件以及**与内核 ABI/驱动/固件耦合的 userspace 层（glue）**住 `system` 分区（`mmcblk0p79`），开机由 initrd 把仓库挂进新根。内核/模块/固件/glue 同版本一起走，因此升级这些内容只需要刷 `system` 分区，不用重刷 rootfs。

> 历史：曾在 system（mmcblk0p79，sysmod）↔ vendor（mmcblk0p80，vendormod）间搬迁；2026-10-14 为 U-Boot sysboot mmc 0:4f 搬回 system；2026-10-18 名改回 sysmod（cmdline `sysmod_part=`、挂载点 `/mnt/sysmod`），旧名 `vendor_part=` 在 initrd 里仍兼容。刷机 `fastboot flash system kernel.img`。

## 布局（system 分区内）

```text
lib/modules/<uname -r>/   内核模块 + depmod 数据库（构建机 modules_install 产物）
lib/firmware/...          设备固件（映射见 rootfs/sirius-device.sh 头注释：
                          a615_zap/a630_sqe/a630_gmu、
                          st_fts_v521.ftb、pyxis-phone 整包、ath10k WCN3990 三件套、
                          qca 蓝牙两件套、无线管制数据库 regulatory.db(+p7s)；
                          adsprpcd/pd-mapper/uimsel/uimwatch 已随 glue 进 system，
                          rootfs 只留 adsprpcd 的 FastRPC 支持库）
boot/                     Image、dtb、initrd.cpio.gz、extlinux.conf（U-Boot payload）
glue/                     内核耦合 userspace 层（见下），rootfs 只通过一个 4 行 stub 接入
```

## glue 层（system 分区内 `/glue/`）

glue 是 system.img 里的一块自包含目录，由仓库根目录的 `glue/` 打包而来：

```text
glue/
  ABI                    # 契约版本，当前 "1"
  manifest               # 构建时由 kernel/gen-glue-manifest.sh 生成，不手写
  bin/                   # 生成器实现、设备脚本、设备守护二进制（adsprpcd、pd-mapper、
                         # uimsel/uimwatch、hexagonrpcd/ssccli）及其私有 .so
  lib/                   # 设备层私有库（FastRPC：libadsp_default_listener/libadsprpc/libyaml；
                         # 直接以运行时文件名存放，无软链，见 glue/lib/README.md）
  units/                 # 与内核/驱动耦合的 systemd unit（含 rmtfs 的 drop-in）
  units.enable           # <unit> <target> 列表，构建时转成 manifest 的 wants 行
  udev/rules.d/          # 设备命名/自动恢复规则
  modules-load.d/        # 开机要加载的模块
  modprobe.d/            # modprobe 配置（当前为空/按需）
  tmpfiles.d/            # 运行时文件/软链（如 UCM 的 /usr/share 软链）
  network/               # udev .link（wlan0 MAC 等驱动相关固定项）
  alsa/ucm2/SE/          # 驱动耦合的 ALSA UCM profile
  sensors/               # 厂商 Sensor Core 配置（config/ + sns_reg.conf），
                         # 由 sirius-sensors.service 组装到 /run/sirius-qcom
```

**rootfs 侧只有一个接入点**：`/usr/lib/systemd/system-generators/sirius-kernel-glue`，内容 4 行，只做转发：

```sh
#!/bin/sh
G=/mnt/sysmod/glue/bin/sirius-kernel-glue
[ -x "$G" ] || exit 0
exec "$G" "$@"
```

真正的解析器 `glue/bin/sirius-kernel-glue` 和 manifest **同属 system.img**，一起构建、一起升级，所以不存在跨镜像的协议版本错配。它把 manifest 翻译成：

- `/run/systemd/generator/`：unit 软链、`<target>.wants/`、`<unit>.d/` drop-in；
- `/run/udev/rules.d/`、`/run/modules-load.d/`、`/run/modprobe.d/`、`/run/tmpfiles.d/`、`/run/systemd/network/`：运行时配置软链。

manifest schema v1（一行一条，未知类型会被记录并忽略）：

```text
abi 1
unit    units/<name>.service
dropin  <unit>   units/<unit>.d/<file>.conf
wants   <target> <unit>
run     <dest>   <src>
```

**失败策略**：glue 缺失、manifest 缺失/损坏、ABI 不匹配、stub 目标不可执行时，生成器只写 kmsg 并 `exit 0`，开机继续（设备服务降级，但 SSH 可用）。`/mnt/sysmod` 是 **ro** 挂载，glue 只读、不存状态；运行态写 `/var` 或 `/run`。

**enablement 与 `[Install]`**：glue 里的 unit **故意不写 `[Install]` 段**，开机启用关系只由 `units.enable` → manifest `wants` → `/run/systemd/generator/<target>.wants/` 表达。原因是 systemd 257 首次启动会执行 “Populated /etc with preset unit settings”（首启 preset），带 `[Install]` 的 unit 会被它在 userdata 的 `/etc/systemd/system` 里落成影子软链；这样后续改 `units.enable` 就不生效了。没有 `[Install]` 的 unit 不会被首启 preset 处理成 wants，glue 的启用关系始终只来自 system.img。

**rootfs 侧的第二个固定件**：`/etc/systemd/system-preset/50-sirius-glue.preset`（`disable adsprpcd-*`、`sirius-*`、`bt-addr.service`、`pd-mapper.service`、`wifi-shutdown.service`）。systemd 257 的首启 preset 在 generator 跑完后还会把 generator 目录里的 unit **link 进 `/etc`**（即使没有 `[Install]`），这份 preset 让首启后 `/etc` 保持干净。新增 glue unit 时若名字不匹配这些 pattern，首启最多在 `/etc` 留一个指向 system 分区的良性软链，不影响升级语义；规范命名（`sirius-*` 或 `adsprpcd-*`）即可避免。

## 启动流程（boot/initrd/initramfs/init + systemd）

1. `find_sysmod_dev`：用 `/dev/mmcblk0p79`（system 分区），cmdline `sysmod_part=` 可覆盖（旧名 `vendor_part=` 兼容）。
2. `mount --move` 仓库进新根 `/mnt/sysmod`；再把 `lib/modules/<uname -r>`、`lib/firmware` bind 进新根。
3. `switch_root` 后 systemd 发现 rootfs 的 4 行 stub → 执行 `/mnt/sysmod/glue/bin/sirius-kernel-glue` → 生成 `/run` 下的软链。
4. 每步写 kmsg：`dmesg | grep -E "sysmod|sirius-glue"` 查命中分支。

## 版本号 `+` 后缀说明

`uname -r` 形如 `7.3.4-sdm670-gcbbdbeb2ca53+`，末尾 `+` 是 kbuild 给**脏树**（有未提交改动）打的标记，模块目录名必须带 `+`。内核与模块必须同一次构建一起发布；`qcom-battery`、`ath10k`、`qcom_smbx` 全是模块，目录错一位就全灭（WiFi 消失、无电池、otg 报错）且静默无日志——排错先看 `ls /lib/modules/$(uname -r)`。

## 构建与刷机

```bash
# 远程构建机（内核树已编过）：
./build.sh kernel
# 产物默认 build/kernel.img（384M，gitignored；首刷开机由 initrd 自动扩到整个 system 分区），附 md5。
# 打包时会拷贝 glue/ 并由 kernel/gen-glue-manifest.sh 生成 manifest（含一致性校验，坏 glue 构建即失败）。
# 本地自检（不碰设备，覆盖 happy path / 未知行 / ABI 不符 / manifest 缺失）：
bash scripts/test-glue.sh

# init/extlinux 改过则重打 system 镜像（initrd 是中间产物，先就位）：
./build.sh initrd && ./build.sh kernel   # initrd -> workspace/build/initrd.cpio.gz

# 刷机（fastboot）：
fastboot flash system kernel.img && fastboot reboot
```

注意：刷 system 会清空该分区原厂数据（Android 侧已无用）

## 升级范围（刷 system 就够了）

| 改动内容 | 需要刷 |
|---|---|
| 内核 Image / dtb / initrd / modules / firmware | system |
| `glue/` 里的 unit、脚本、设备私有库、udev 规则、模块加载、UCM、生成器实现、manifest | system |
| rootfs 的发行版包、GNOME/Orbital、用户自建 unit | rootfs（userdata） |

首次引入 glue 的版本需要**同时**刷 rootfs + system（rootfs 装 4 行 stub、删除旧位置的服务文件）；之后内核/驱动相关的升级都只刷 system。

## 验证（进系统后，WiFi 或 USB 任一 shell）

```bash
uname -r; ls /lib/modules/$(uname -r) | head
cat /proc/mounts | grep sysmod              # 期望 ro，且没有 noexec
dmesg | grep -E "sysmod|sirius-glue"        # 期望 "linked N units from /mnt/sysmod/glue (ABI 1)"
systemctl cat sirius-audio-init             # SourcePath 应在 /run/systemd/generator/
ls /run/systemd/generator /run/udev/rules.d /run/modules-load.d /run/tmpfiles.d /run/systemd/network
systemctl --failed
cat /sys/class/power_supply/qcom-battery/charge_full_design  # 期望 3120000
lsmod | grep -E "ath10k_snoc|qcom_fg|qcom_smbx"
sudo sirius-otg status
```

## rootfs 侧配合

- rootfs **不再打包内核模块和设备固件**，system 分区是唯一来源；initrd 在 sysmod 缺失时虽然会回落到 rootfs 的文件，但新镜像里这些目录是空的（发行版固件 `wireless-regdb`/`alsa-topology-conf`/`firmware-atheros`/`firmware-qcom-soc` 会在 rootfs 构建末尾 purge）。
- rootfs 只保留 4 行 generator stub 和 `/etc/systemd/system-preset/50-sirius-glue.preset`（防首启 preset 在 /etc 落影子软链），**不创建任何指向 system 分区的软链**；glue 里的命令直接运行 `/mnt/sysmod/glue/bin/<cmd>`（如 `sirius-test`、`ssccli`、`sirius-bt-watch`）。
- 用户自己的 `/etc/systemd/system/*.service` 优先级高于 generator 输出，可正常覆盖/`systemctl mask` glue unit。
- 仓库挂载点开机后在 `/mnt/sysmod`；改 glue 内容：重跑 `./build.sh kernel` 并 fastboot 重刷 system。
- 开发时可在设备上临时 `mount -o remount,rw /mnt/sysmod` 改 glue，再 `systemctl daemon-reload` 让生成器重跑（重启后恢复只读）。

## 本次迁移说明（2026-11-15）

把原本烤在 rootfs 里的内核耦合层（glue）迁到 system 分区，目标是内核/驱动相关升级不再需要重刷 userdata。

**迁移范围**（原 `rootfs/overlay` → 仓库根 `glue/`，打包进 `kernel.img` 的 `/glue/`）：

- 16 个 unit：`adsprpcd-{rootpd,audiopd,sensorspd}`、`pd-mapper`、`bt-addr`、`sirius-bt-{auto,watch,reprobe}`、`sirius-modem-uim(.service/.timer)/-watch`、`sirius-wifi-auto(.service/.timer)`、`wifi-shutdown`、`sirius-zram`、`sirius-audio-init`；
- 8 个脚本：`sirius-audio-refresh`、`sirius-bt-addr/-auto/-watch`、`sirius-wifi-auto`、`sirius-zram`、`wifi-shutdown`、`sirius-modem-uim`；
- `rmtfs` 的 3 个 drop-in、`70-sirius-{bt,input}.rules`、`modules-load.d/sirius.conf`、`tmpfiles.d`（qrtr0 + UCM 软链）、`10-wlan0.link`、ALSA UCM `SE/`；
- 生成器实现本身（原计划放 rootfs 的 shim 逻辑）也在 system 分区：`/glue/bin/sirius-kernel-glue`。

**rootfs 侧只留固定件**：4 行 generator stub、`/etc/systemd/system-preset/50-sirius-glue.preset`；设备层可执行文件和 FastRPC 私有库都在 system 分区（`glue/bin`、`glue/lib`，见下节“设备层二进制”），发行版包、Orbital/GNOME 仍留 rootfs。

**机制**：`build-kernel-img.sh` 打包 glue，并用 `gen-glue-manifest.sh` 生成 manifest（`abi/unit/dropin/wants/run`，构建期校验）；开机 initrd 挂好 `/mnt/sysmod` 后，stub exec 生成器，生成器把 unit/wants 链到 `/run/systemd/generator/`、把 udev/modules-load/tmpfiles/network 配置链到对应 `/run` 目录。glue/manifest 缺失或 ABI 不符时只打 kmsg 并继续启动（设备服务降级，SSH 可用）。

**已知坑（已处理）**：glue unit 不写 `[Install]`，enablement 只来自 `units.enable` → manifest；并用 preset 文件阻止 systemd 257 首启 preset 把 generator 里的 unit link 进 userdata 的 `/etc`（否则后续改 `units.enable` 不生效）。

**升级语义**：内核/模块/固件/glue 变更 → `./build.sh kernel` + `fastboot flash system`；本次首次迁移需同时重刷 rootfs + system；旧 rootfs + 新 system 可过渡（旧 unit 继续工作，glue 不被调用）。

**验证记录（2026-11-15，Mi 8 SE / server flavor）**：首启 `/etc` 影子软链 0；`dmesg` 出现 `sirius-glue: linked 16 units ... (ABI 1)`；`systemctl --failed` 为空；unit 的 `FragmentPath` 在 `/run/systemd/generator/`；音频 sink、蓝牙、WiFi 扫描、Modem 检测、zram、输入节点、rmtfs drop-in 正常；关机顺序不变；只刷 system 的升级以及 ABI 不符/未知 manifest 行/缺生成器等故障模式均实测通过。

### 设备层二进制（2026-11-15 第二批）

第一批只搬了 unit/脚本/规则；第二批把随内核/固件走的设备可执行文件也收进 system：

| 文件 | 原位置 | 现在 | 说明 |
|---|---|---|---|
| `adsprpcd` | `/usr/local/bin` | `glue/bin` | FastRPC ADSP listener 守护（unit 的 `ExecStart` 改为 `/mnt/sysmod/glue/bin/adsprpcd`） |
| `pd-mapper` | `/usr/local/bin` | `glue/bin` | PD 映射服务，读 firmware 里的 `servreg` `.jsn` |
| `uimsel` / `uimwatch` | `/usr/local/bin` | `glue/bin` | 蜂窝 UIM 工具；`uimwatch` 触发脚本路径改为编译期宏 `SIRIUS_MODEM_UIM`（默认 `/mnt/sysmod/glue/bin/sirius-modem-uim`） |

**运行库策略（A：不携带）**：这些二进制继续复用 rootfs 的 Debian 运行库
（glibc + `libqmi-glib`/`libqrtr-glib`/glib/gio + `libqrtr`/`liblzma`）。
glibc ABI 向下兼容（实测最高只要求 `GLIBC_2.34`，trixie 2.41 / bookworm 2.36 均满足），
第三方库由 `ModemManager`/`libqmi-utils` 包带进 rootfs（在 `SIRIUS_BASE_PKGS` 里，勿删）。

这样 system 分区额外体积约 0.3 MiB（四个二进制），代价是这些库必须留在 rootfs；
若以后要彻底解耦，可把第三方库闭包（≈13.6 MiB）或含 libc 的全闭包（≈16.3 MiB）
拷进 `glue/lib`，unit 加 `LD_LIBRARY_PATH=/mnt/sysmod/glue/lib` 即可。
musl 版本（静态 `pd-mapper`/`uim*` + musl 动态 `adsprpcd`）实测也能工作，
但需要额外维护 musl 工具链与 loader，本次未采用。

**其余 rootfs 侧改动**：`rootfs/sirius-device.sh` 不再往 `/usr/local/bin` 拷这四个
可执行文件，只保留 FastRPC 支持库；新的 rootfs 镜像里 `/usr/local/bin` 不再有它们，
旧 rootfs（已刷机的）里残留副本无人引用，可继续用。

**验证（2026-11-15，Mi 8 SE / server flavor，仅刷 system、rootfs 未动）**：
`adsprpcd-rootpd`/`adsprpcd-sensorspd`/`pd-mapper`/`sirius-modem-uim-watch` 的
`/proc/<pid>/exe` 均为 `/mnt/sysmod/glue/bin/*`；`uimwatch` 正常注册 UIM 事件
（`events registered (mask=0x15)`）；`systemctl --failed` 为空；`/etc` 影子软链 0；
音频 sink `Built-in Audio Stereo` 正常；Modem 仍按无卡基线进入 `sim-missing`；
`adsprpcd-audiopd` 仍是基线已知的 auto-restart（与本迁移无关）。
