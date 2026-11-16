# system / userdata 分区解耦（kernel.img ↔ rootfs）

本项目把系统切成两个**可独立升级**的镜像：

| 分区 | 手机设备 | 挂载点 | 镜像 | 内容 |
|---|---|---|---|---|
| system | `/dev/mmcblk0p79`（label `sirius_vendor`，cmdline `sysmod_part=`） | `/mnt/sysmod`（initrd 挂 **ro**） | `build/kernel.img`（ext4，384M，首刷由 initrd 扩到整分区） | 内核 `Image`/dtb/initrd、内核模块、设备固件、**内核/设备耦合 userspace（glue）** |
| userdata | `/dev/mmcblk0p81` | `/` | `build/debian-trixie-sirius-{server,gnome}-*.simg` | 发行版（Debian trixie）、GNOME/Orbital、用户数据 |

为什么要这样切：内核、驱动、固件和设备服务几乎总是一起变（换内核、调 WiFi/Modem/传感器、换固件），
但它们跟 rootfs 的发行版包几乎无关；而重刷 userdata 代价高（用户数据、所有 apt 包、桌面配置）。
把这一层抽出来放 system 分区后，**升级内核/驱动相关的东西只刷 system，不动 rootfs**。

## 0. 边界判据：什么进 glue，什么留 rootfs

这条判据决定所有文件的归属，改动前先对照：

| 放 `glue/`（随 kernel.img） | 留 `rootfs/overlay/` 或发行版包 |
|---|---|
| 与内核模块/驱动/固件/QRTR/FastRPC 耦合的 unit、脚本、二进制 | 发行版包、Orbital/GNOME、桌面与用户策略 |
| 设备相关的 udev 规则、模块加载、tmpfiles、ALSA UCM、Sensor Core 配置 | **flavor 策略**（server/gnome 行为不同的东西） |
| 设备层私有运行库（glibc 与 glib 家族由 rootfs 提供，其余自带） | 用户可改的 `/etc` 配置、CLI 用户脚本（`sirius-screen` 等） |
| 设备相关、**flavor 中立**、低 churn 的运行期配置（经 `glue/run/` 链进 `/run`） | 需要用户用 `nmcli`/编辑器随时改的配置文件 |
| —（glue 只是**调用**它们，不打包它们） | OS 底座服务与工具：systemd、udev/kmod、qrtr-tools、tqftpserv、rmtfs、BlueZ、NetworkManager、ModemManager、ALSA、PipeWire…（见 §1 第 5 项） |

**system 镜像是两个 flavor 共用的**，所以第 2 行是硬约束。反例：logind 的电源键策略
（server：按键归 Orbital；gnome：gsd 处理、logind 只做 backstop）**必须留 rootfs**，放进
`glue/run/` 会让共用镜像把 server 的策略串到 GNOME 上（systemd 按 drop-in 文件名字典序
合并，`sirius-server.conf` 排在 `sirius-gnome.conf` 之后就会覆盖它）。

## 1. 解耦接口：rootfs 侧只有 stub、preset 和 glibc/glib 家族 ABI

**镜像层面**的接口很少：rootfs 侧只有 stub、首启 preset 和 glibc/glib 家族 ABI；manifest、生成器实现、
unit 与配置内容全部属于 system 镜像内部，rootfs 不读、不解析、也不感知——协议两端
（`gen-glue-manifest.sh` 与 `sirius-kernel-glue`）同属一个 system.img，改 schema 只刷 system，
不存在跨镜像版本错配。

**但运行期不是单向的**：glue 的 unit/脚本要调用 rootfs 的底座服务与工具；rootfs 的
daemon 又依赖 system 提供的内核模块、固件和设备服务（见第 5 项）。这些是稳定的
CLI / D-Bus / unit 名字契约，不是包或 ABI 耦合，但它们划定了"只刷 system"的边界。

1. **唯一执行入口（rootfs 提供，systemd generator 约定）**：
   `/usr/lib/systemd/system-generators/sirius-kernel-glue`，固定把 systemd 传给 generator 的
   参数原样转发给 system 分区里的生成器。接口就是 systemd 的 generator CLI（`$1` = normal
   generator 目录），**不传任何自定义数据**；挂载点 `/mnt/sysmod` 写死在这几行里。
   [rootfs/overlay/usr/lib/systemd/system-generators/sirius-kernel-glue](../rootfs/overlay/usr/lib/systemd/system-generators/sirius-kernel-glue)：

   ```sh
   #!/bin/sh
   G=/mnt/sysmod/glue/bin/sirius-kernel-glue
   [ -x "$G" ] || exit 0
   exec "$G" "$@"
   ```

2. **挂载点（由 system 镜像自己的 initrd 建立）**：initrd 打在 system 镜像的 `boot/` 里，
   开机把分区 ro 挂到新根 `/mnt/sysmod`，并把 `lib/modules/<uname -r>`、`lib/firmware`
   bind 进新根（版本不匹配时回落 rootfs 里的空目录）。rootfs 侧只依赖这个路径存在。

3. **glibc + glib 家族 ABI（rootfs 提供给 system）**：glue 里的 ELF 在**链接层面**依赖 rootfs 的
   glibc 与 loader（当前要求 **`GLIBC_2.38`**，trixie 2.41 可以，bookworm 2.36 不行，原因见 §4），
   以及 glib 家族 `libglib-2.0`/`libgio-2.0`/`libgobject-2.0`/`libgmodule-2.0`（GLib 2.x ABI 稳定，
   trixie 2.84.x）。system 不链接 rootfs 的其它库；但运行期会**执行** rootfs 的命令、`systemctl`
   控制其 unit，见第 5 项。

4. **首启 preset（rootfs 侧配合 systemd，不是数据接口）**：
   `/etc/systemd/system-preset/50-sirius-glue.preset`（`disable adsprpcd-* / sirius-* /
   bt-addr.service / pd-mapper.service / wifi-shutdown.service`）。它在 systemd 首启的
   "populated /etc with preset unit settings" 阶段阻止把 generator 里的 unit link 进
   userdata 的 `/etc`，否则之后改 `units.enable` 就不生效了（见 §5）。它不参与运行时数据流。

5. **运行时服务/工具依赖（system 调用 rootfs，运行期契约）**：glue 不打包这些 daemon，
   但它的 unit 排序、脚本命令和 D-Bus 客户端都指向 rootfs：

   | rootfs 侧必须存在 | glue 的使用方式 |
   |---|---|
   | systemd（PID1、generator、tmpfiles/modules-load、user manager） | 整个 glue 靠它激活：stub 是 systemd generator；`sirius-audio-refresh` 还会 `systemctl --user restart wireplumber` |
   | udev + kmod | `udev/rules.d`、`network/*.link`、`modules-load.d`；`dev-snd-controlC0.device` / `hci0` device 单元；脚本里的 `modprobe`/`rmmod` |
   | sh + coreutils + util-linux + procps | 生成器（`ln`/`mkdir`）与设备脚本（`mount`/`umount`/`flock`/`timeout`/`logger`/`zramctl`/`swapon`/`pkill` 等） |
   | qrtr-tools（`qrtr-ns.service`；调试 `qrtr-lookup`） | `adsprpcd-*`、`pd-mapper`、`sirius-sensors`、`sirius-modem-uim*` 的 `Wants/After=qrtr-ns` |
   | tqftpserv（`tqftpserv.service`） | rmtfs 的 `Requires/After=tqftpserv`，adsprpcd 的 `After` |
   | rmtfs（`/usr/bin/rmtfs`、`rmtfs.service`） | glue 只给 drop-in（`ExecStart` 覆盖）和 `/var/lib/rmtfs` backing 软链，daemon 本体在 rootfs |
   | BlueZ（`bluetooth.service`、`bluetoothctl`/`btmgmt`） | `bt-addr.service`（`Before=bluetooth.service`）、`sirius-bt-{auto,watch}` |
   | NetworkManager（`NetworkManager.service`、`nmcli`，+ wpa_supplicant/iw） | `sirius-wifi-auto.timer`、`wifi-shutdown`、`glue/run` 的 WiFi/蜂窝配置 |
   | ModemManager + libqmi-utils（`mmcli`/`qmicli`） | `sirius-modem-uim(.timer/-watch)`；glue **不**自带 MM 或 qmi-proxy |
   | ALSA userspace（`alsaucm`、`sound.target`） | `sirius-audio-init` 的 `/usr/bin/alsaucm`（UCM 数据由 glue 提供） |
   | PipeWire/WirePlumber（`pw-cli`、wireplumber 用户服务） | `sirius-audio-refresh` 让声卡重新探测 |

   这些包都在 `SIRIUS_BASE_PKGS` 里（两个 flavor 共用）。rootfs 删包或换实现（例如
   NM→systemd-networkd、BlueZ 整体替换）会让对应设备功能静默降级，而且**刷 system 救不回来**。
   反方向：rootfs 的 NM/MM/BlueZ/PipeWire 又依赖 system 的模块、固件、rmtfs/tqftpserv 设备服务，
   所以运行期是两边协作；升级时只要求这些 CLI/D-Bus/unit 名字契约不变（见 §8）。

## 2. system 镜像布局

```text
lib/modules/<uname -r>/   内核模块 + depmod 数据库（modules_install 产物）
lib/firmware/...          设备固件（gpu/ipa/cdsp/venus/adsp/acdb/touch/ath10k/qca/regdb，
                          映射关系在 rootfs/sirius-device.sh 头部注释与打包脚本里）
boot/                     Image、dtb、initrd.cpio.gz、efi/BOOTAA64.EFI、extlinux.conf
glue/                     内核/设备耦合 userspace 层（见 §3）
```

## 3. glue 层（system 分区内 `/glue/`）

```text
glue/
  ABI                    # 契约版本，当前 "1"（manifest schema 版本）
  manifest               # 构建时生成，不手写
  bin/                   # 设备守护二进制（adsprpcd、pd-mapper、uimsel/uimwatch、
                         # hexagonrpcd、ssccli）、设备脚本、生成器实现；
                         # 运行库不在本目录，RPATH 指向 ../lib
  lib/                   # 设备层私有运行库闭包（glibc 与 glib 家族由 rootfs 提供），见 glue/lib/README.md
  units/                 # 与内核/驱动耦合的 systemd unit（含 rmtfs 的 drop-in）
  units.enable           # <unit> <target> 列表，构建时转成 manifest 的 wants 行
  udev/rules.d/          # 设备命名/自动恢复规则
  modules-load.d/        # 开机要加载的模块
  modprobe.d/            # modprobe 配置（当前为空/按需）
  tmpfiles.d/            # 运行时文件/软链（UCM 软链、qrtr0、rmtfs partlabel 软链）
  network/               # udev .link（wlan0 MAC 等驱动相关固定项）
  alsa/ucm2/SE/          # 驱动耦合的 ALSA UCM profile
  run/                   # flavor 中立的设备运行期配置，开机链到 /run（见下）
  sensors/               # 厂商 Sensor Core 配置（config/ + sns_reg.conf），
                         # 由 sirius-sensors.service 组装到 /run/sirius-qcom
```

**`glue/run/` 的语义**：system 分区是 ro，不能往 `/etc` 写东西；而 systemd/NM 等
都支持 `/run` 下的运行时配置目录，所以这类文件在镜像里放在 `glue/run/<相对 /run 的路径>`，
开机由 `sirius-glue-setup.service` 链到 `/run/<同一路径>`，生成器只负责 unit。
初始化服务在 udev、模块加载、sysctl、tmpfiles 和 NetworkManager 之前执行。当前只有 flavor 中立项：

| 文件 | 开机链接到 | 作用 |
|---|---|---|
| `glue/run/NetworkManager/conf.d/sirius-server.conf` | `/run/NetworkManager/conf.d/` | WiFi powersave=2、扫描不改 MAC（两个 flavor 都需要） |
| `glue/run/NetworkManager/system-connections/cellular.nmconnection` | `/run/NetworkManager/system-connections/` | 蜂窝自动连接（NM 从 `/run` 读 keyfile，要求 root:0600） |
| `glue/run/sysctl.d/60-sysrq.conf` | `/run/sysctl.d/` | `kernel.sysrq=1` |

**不要**把 flavor 策略、或用户需要长期编辑的配置放这里：`/run` 是 tmpfs，重启即从 system
镜像恢复；`/etc` 里的同名文件优先级更高，是给用户覆盖用的。真要加，先回到 §0 的判据。

## 4. 运行库策略

`glue/lib` 自带除 glibc 和 glib 家族以外的全部依赖；glib 家族
（`libglib-2.0`/`libgio-2.0`/`libgobject-2.0`/`libgmodule-2.0` 及其
`pcre2-8`/`ffi`/`mount`/`blkid`/`selinux`/`z`/`atomic` 依赖）直接用 rootfs 的 Debian
trixie 包（GLib 2.x ABI 稳定，trixie 2.84.x）。因此 system 分区在链接/ABI 层面对 rootfs 的
依赖是 glibc（≥2.38）+ glib 家族，unit 里不需要 `LD_LIBRARY_PATH`。

- 库按 SONAME 实名存放、不建软链，来源见 [glue/lib/README.md](../glue/lib/README.md)。
- 打包时 `kernel/build-kernel-img.sh` 用 `patchelf` 给 staging 树里的每个 ELF 写 RPATH
  （bin → `$ORIGIN/../lib`，lib → `$ORIGIN`），仓库里的文件本身没有被改过。
- 用 RPATH 而不是 `LD_LIBRARY_PATH`：后者会继承给 unit 里 exec 的 rootfs 程序
  （`iw`/`bluetoothctl`/`amixer`…），把 qmi/qrtr 顶到不该用的版本；RPATH 只作用于自身，
  且在 `ld.so.cache` 之前查找。`dlopen` 也认调用者的 RPATH（FastRPC listener 靠它）。
- 新增依赖：除 glib 家族外的 NEEDED 必须把 `.so` 放进 `glue/lib`；构建不校验，刷机后
  `ldd /mnt/sysmod/glue/bin/* | grep 'not found'` 自检。
- 代价：`glue/lib` ≈ 7.6M（打包后 glue ≈ 10M）；这些库不随 apt 升级，qmi/qrtr 等的
  安全更新要重取并重刷 system 镜像。

## 5. 生成器与 manifest

manifest 是 **system 镜像内部协议**：构建时 `kernel/gen-glue-manifest.sh` 从 glue 树生成，
开机由同一镜像里的 `/glue/bin/sirius-kernel-glue` 解析。rootfs 侧只有一个转发 stub（§1），
所以 schema 改动只影响 system.img。manifest 由两部分消费：

- 生成器只写 `/run/systemd/generator/`：`unit` 软链、`<target>.wants/`、`<unit>.d/` drop-in；
- `sirius-glue-setup.service` 负责 `/run/` 下的运行时配置：`udev/rules.d`、`modules-load.d`、`modprobe.d`、`tmpfiles.d`、
  `systemd/network`，以及 §3 里 `glue/run/**` 的任意树。

manifest schema v1（一行一条，未知类型记录后忽略，便于前向兼容）：

```text
abi     1
unit    units/<name>.service
dropin  <unit>   units/<unit>.d/<file>.conf
wants   <target> <unit>
run     <dest>   <src>          # 链到 /run/<dest>/<basename(src)>
```

**失败策略：永不阻塞启动。** glue 缺失、manifest 缺失/损坏、ABI 不匹配、stub 目标不可执行时，
只写 `/dev/kmsg` 后 `exit 0`（设备服务降级，SSH 仍可用）。`/mnt/sysmod` 是 ro，生成器只建软链、
不存状态。

**运行时配置生命周期**：`daemon-reload` 只重新生成 unit，不修改其他服务的配置。
显式重跑 `systemctl restart sirius-glue-setup` 会根据 `/run/sirius-glue/links` 清理之前创建的
软链，再应用当前 manifest；已被消费者替换的文件或链接会保留。配置消费者是否需要
reload/restart 由各服务决定；正常的 system 升级仍以刷机后重启为准。

**WiFi 工厂 MAC**：基础规则在 `glue/network/10-wlan0.link`，初始化服务只读挂载
persist（`ro`，允许 ext4 在需要时回放日志恢复一致性），读取有效工厂地址后写入
`/run/systemd/network/10-wlan0.link.d/50-factory-mac.conf`。drop-in 仅设置
`MACAddressPolicy=none` 和 `MACAddress=`，不会覆盖基础规则的匹配、命名等属性。
读不到有效地址时不生成该 drop-in，保留基础规则的备用 MAC。

迁移时只删除与旧 initrd 按当前工厂地址生成的内容**逐字一致**的
`/etc/systemd/network/10-wlan0.link`。有额外设置、不同地址、空文件或软链的用户覆盖会保留；
存在用户主 `.link` 时不生成工厂 drop-in，避免反过来覆盖用户设置。
用户也可以在 `/etc/systemd/network/10-wlan0.link.d/90-user.conf` 中覆盖工厂属性。

**enablement 与 `[Install]`**：glue unit **故意不写 `[Install]`**，启用关系只由
`units.enable` → manifest `wants` → generator 表达；首启 preset（§1）负责让 `/etc` 保持干净。
新增 glue unit 时按 `sirius-*` / `adsprpcd-*` 规范命名即可被 preset 覆盖。

**权限**：镜像内 glue 全部 `root:root`（打包时 `chown -R`）；`cellular.nmconnection` 额外
置 0600——NetworkManager 只加载 root 所有且非 group/other 可读的 keyfile。因此 `kernel`
目标需要 root（`sudo`）完成 chown 和 mkfs，见 §7。

## 6. 启动链

1. initrd `find_sysmod_dev`：默认 `/dev/mmcblk0p79`，cmdline `sysmod_part=` 可覆盖；先
   `expand-part` 扩分区，再 `mount -o ro`、`mount --move` 进新根 `/mnt/sysmod`。
2. bind `lib/modules/<uname -r>`、`lib/firmware` 进新根（缺失时回落 rootfs，但新 rootfs 里
   这些目录是空的——发行版固件包已在 rootfs 构建末尾 purge）。
3. initrd 只处理蓝牙 NVM，不再往 rootfs 的 `/etc` 生成 WiFi `.link`。
4. `switch_root` 后 systemd 执行 rootfs 的 stub → 生成器生成 unit →
   `sirius-glue-setup.service` 在 udev 等消费者前准备 `/run` 配置、迁移旧 WiFi 文件并生成工厂 MAC drop-in。
5. 启动日志：`dmesg | grep -E "sysmod|sirius-glue"`；初始化服务日志见
   `journalctl -b -u sirius-glue-setup`。

## 7. 构建与刷机

```bash
# 构建 system 镜像（需要先有 initrd；主机需 patchelf、file，最终步骤需要 root）
./build.sh initrd
./build.sh kernel            # 已配置 NOPASSWD sudo 时；否则 sudo ./build.sh kernel

# 本地自检（不碰设备，覆盖 happy path / 未知行 / ABI 不符 / manifest 缺失）
bash scripts/test-glue.sh

# 刷机
fastboot flash system kernel.img && fastboot reboot
```

产物默认 `build/kernel.img`（384M，gitignored），脚本末尾打印 md5。注意：刷 system 会清空
该分区原有内容（原厂 Android 数据已无用）。`rootfs/` 侧的 rootfs 镜像由
`./build.sh rootfs-{server,gnome}` 产出。

**产物所有权**：`kernel` 目标最后要 chown/mkfs，所以需要 root；但 `build/` 里的最终产物
（`*.img`/`*.simg`）会交还给调用者——`sudo ./build.sh ...` 跑完仍是当前用户所有，不会留下
root 文件挡住后续非 root 构建、`./build.sh clean` 或 fastboot。只有 `workspace/build/` 里的
rootfs 工作树/`base` 是有意 root 所有的（chroot 需要）。

## 8. 升级范围与过渡语义

| 改动内容 | 需要刷 |
|---|---|
| 内核 Image / dtb / initrd / modules / firmware | system |
| `glue/` 里的 unit、脚本、设备二进制、私有库、udev、模块加载、UCM、运行期配置、生成器、manifest | system |
| rootfs 的发行版包、GNOME/Orbital、用户自建 unit、**flavor 策略**（logind 等） | rootfs（userdata） |

三种组合：

- **旧 rootfs + 新 system**：通常安全。glue 二进制自带闭包，rootfs 里残留的旧
  `/etc` 配置（同名）优先于 `/run`，最坏是行为停在旧配置；删掉它们即生效。
- **新 rootfs + 旧 system**：**会坏**。新 rootfs 不再带 NM conf、蜂窝 profile、sysrq 配置
  和 rmtfs 的 partlabel 软链（它们现在由 system 分区的 `glue/run` 和 tmpfiles 提供），
  旧 system 没有这些——所以新 rootfs 必须配同一批的 system 镜像。
- **新 rootfs + 新 system**：目标状态；首次引入 glue 的版本（2026-11-15 起）都是这个要求。

无论刷哪边，都要求 rootfs 保留 §1 第 5 项列出的底座服务/工具（它们在 `SIRIUS_BASE_PKGS` 里）。
如果 rootfs 换发行版基座或替换其中某项（例如不用 NetworkManager、不用 BlueZ），glue 的
对应 unit 会启动失败或降级，这不是刷 system 能修的。

## 9. 验收清单

构建侧（不碰设备）：

```bash
bash scripts/test-glue.sh                     # unit/运行时分离、配置清理、MAC 与迁移回归测试
# 挂 build/kernel.img 检查：/glue 全 root:root、cellular.nmconnection 0600、
# 二进制 RUNPATH 为 $ORIGIN/../lib、manifest 的 run 行与 §3 一致
```

设备侧（进系统后，WiFi 或 USB shell 均可）：

```bash
uname -r; ls /lib/modules/$(uname -r) | head
cat /proc/mounts | grep sysmod              # 期望 ro，且没有 noexec
dmesg | grep -E "sysmod|sirius-glue"        # 期望 "linked N units from /mnt/sysmod/glue (ABI 1)"
systemctl --failed
# rootfs 底座服务在位（§1 第 5 项；缺一个对应设备功能就会降级）
systemctl is-active qrtr-ns tqftpserv rmtfs bluetooth NetworkManager ModemManager
command -v nmcli mmcli qmicli btmgmt alsaucm
systemctl cat sirius-sensors | head         # FragmentPath 在 /run/systemd/generator/
ls -l /run/NetworkManager/conf.d /run/NetworkManager/system-connections \
      /run/sysctl.d /run/tmpfiles.d /run/udev/rules.d /run/systemd/network
ls -l /var/lib/rmtfs                        # 四项 partlabel 软链在位（tmpfiles）
nmcli con show | grep -i cellular           # 蜂窝 profile 从 /run 读到
ldd /mnt/sysmod/glue/bin/* 2>/dev/null | grep 'not found'   # 期望为空
sudo /mnt/sysmod/glue/bin/sirius-test       # 一键硬件自检（--full 加外设项）
```
