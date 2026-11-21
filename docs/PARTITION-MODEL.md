# 分区模型：boot / system / userdata

核心原则：按**变化频率与所有权**分层——把高频变动、无状态的硬件侧抽成独立小分区，日常更新不动用户数据。

| 层 | 内容 | 变化频率 | 挂载 | 有状态 | 重建代价 |
|---|---|---|---|---|---|
| `boot` | bootloader、默认 cmdline | 极低 | loader 自读 | 否 | 高（刷坏需 fastboot 救） |
| `system`（store） | 内核 `Image`、dtb、initrd、模块、固件、设备耦合 userspace | 高 | `ro` | 否 | 低（`mkfs` 即恢复） |
| `userdata` | 发行版包、桌面、flavor 策略、`/etc`、`/home`、`/var` | 低 | `rw` | **是** | 极高（用户数据） |

**归属判据**：没内核也必须对 → `boot`；跟内核/硬件同生共死 → `system`；因发行版、flavor 或用户而异 → `userdata`。

## 1. 启动链

```text
ROM / XBL / ABL                    固定入口，只认 boot 分区
  └─ boot: loader + 默认 cmdline   换引导器或默认参数时才刷
       ├─ 读 store 的 /boot/{Image,initrd,dtb}
       └─ 启动内核 → initrd（住 store）
            ├─ 等设备 → 扩分区 → ro 挂 store
            ├─ bind /lib/modules/<uname -r>、/lib/firmware ← store
            └─ switch_root → userdata（systemd）
                 ├─ 反向指回 store：stub 调注入器，将 unit / 配置注入 /run（缺则降级）
                 └─ 运行期双向协同：rootfs 底座服务 ↔ store 模块 / 固件 / 设备服务（靠 ABI 与 CLI/D-Bus/unit 契约对接）
```

- **store 自包含**：内核与 initrd 同层打包，避免版本错配；模块/固件通过 bind 挂载提供，不在 userdata 留副本。
- **启动后反向回指**：`switch_root` 交给 `userdata` 后，依赖链并非单向结束——rootfs 需通过固定入口（stub + 挂载点）反向拉起 store 的设备层注入，且运行期 rootfs 底座服务与 store 设备服务互为依赖（仅靠稳定 ABI 与服务名契约对接）。
- **设备差异参数化**：分区设备名、cmdline 参数名、固件映射表。

## 2. 边界与约束

### 文件归属

| 放 `system`（store） | 放 `userdata` |
|---|---|
| 与内核/驱动/固件耦合的 unit、脚本、二进制 | 发行版包、桌面、用户脚本与 CLI 工具 |
| 设备 udev 规则、模块加载、tmpfiles、ALSA UCM、传感器配置 | **flavor 策略**（不同口味行为不同的配置，如电源键） |
| 设备层私有运行库（仅依赖 userdata 的 C 库与 GLib 家族） | 用户可改的 `/etc`、持久状态（`nmcli`、应用数据） |
| 设备相关、flavor 中立的运行期默认值（注入 `/run`） | 底座服务：systemd、udev/kmod、NM、MM、BlueZ、PipeWire 等 |

- **flavor 策略必须留 `userdata`**：`system` 为多 flavor 共用，放进去会导致策略串味。
- **底座服务留 `userdata` 且不可删**：store 只通过 unit / CLI / D-Bus 契约调用它们，不打包它们。
- **配置优先级**：`用户 /etc > store 注入 /run > 发行版默认`。镜像默认值禁止写入 `/etc`，否则旧副本会屏蔽后续 store 更新。

### 核心约束

1. **单一归属**：文件只在一层存在，跨层仅靠窄接口（注入入口路径、挂载点、ABI 下限、首启清理）与服务名契约交互。
2. **`boot` 不含 OS 内容**：内核、initrd、dtb、模块全部在 store；cmdline 从单一源文件渲染进 loader 默认环境与 store 启动配置，避免漂移。
3. **store 只读、无状态、可重建**：`ro` 挂载（无 `noexec`），最小尺寸构建 + 首启扩容。唯一例外是引导期一次性迁移写（如补写工厂 MAC），必须 `remount rw` → 写后恢复 `ro` → 幂等且失败不阻塞启动。
4. **降级不阻塞启动**：store 缺失、清单损坏或 ABI 不符时，记日志并跳过注入继续启动，保证 SSH / USB 网络救援通道可用。
5. **工厂分区只读**：`persist` / `modem` 等校准分区永久 `ro` 挂载，不作为更新目标。

## 3. 升级与兼容

| 改动内容 | 刷写目标 | `userdata` 影响 |
|---|---|---|
| bootloader、默认 cmdline | `boot` | 不动（确认 `root=` 未变） |
| 内核 / dtb / initrd / 模块 / 固件 / 设备服务 | `system` | 不动 |
| 发行版包、桌面、flavor 策略 | `userdata` | 重刷用户层 |

- **兼容方向单一**：**仅保证 新 `system` + 旧 `userdata`**（最坏停留在旧 `/etc` 覆盖，删掉即生效）；不承诺 新 `userdata` + 旧 `system`；首次引入分层须两边同批刷写。
- **保数据边界**：本模型不提供 A/B 或 `userdata` 增量刷（需要 A/B 时可在 `boot`/`system` 正交扩展）；日常更新无需动 `userdata`。

## 4. 移植到新设备

### 设备参数

| 参数 | 说明 | sirius 示例 |
|---|---|---|
| store 分区 | 可牺牲的大分区（原厂 system/vendor 常见 1–4 GB） | `mmcblk0p79` |
| rootfs 分区 | 剩余容量最大的分区 | `mmcblk0p81` |
| cmdline | `root=`、`sysmod_part=` 等参数单一来源 | `boot/bootargs` |
| 工厂只读分区 | 校准/MAC/射频分区，永久 `ro` | `persist` (`p68`) |

### 移植步骤

1. **盘点分区表**：确认 fastboot 名称与物理分区映射，锁定只读工厂分区，选定 store 与 rootfs 分区。
2. **定 loader 策略**：loader 能读 store 文件系统（U-Boot / EFI）→ 内核/initrd/dtb 全放 store；仅原厂 ABL → 内核/initrd 留 `boot`，其余放 store。
3. **单源 cmdline**：一份源文件同时渲染 loader 环境与 store 启动配置。
4. **构建 store 与 initrd**：store 固定包含 `/boot`、`/lib/modules/<ver>`、`/lib/firmware` 与设备 userspace（最小镜像 + 首启扩容）；initrd 负责等待设备、扩容、ro 挂载 store、bind 模块/固件并 `switch_root`，失败降级不 panic。
5. **收窄 `userdata` 接口**：固定注入入口、挂载点、运行库 ABI 下限与首启清理规则，同批首刷 `boot` → `system` → `userdata`。

### 验收标准

- 只刷 `system` 重启后，`/home` 不变、SSH 可用、设备服务正常。
- store 挂载为 `ro` 且无 `noexec`；内部二进制无 `not found` 缺失依赖。
- store 缺失、清单损坏或 ABI 不符时可降级启动，不 panic。
- 升级后 `userdata` 的 `/etc` 不产生镜像默认值副本；改默认值只刷 `system` 生效。

## 5. sirius 实现对照

| 抽象概念 | sirius 实现 |
|---|---|
| `boot` | `build/boot.img`（U-Boot）刷 `boot` 分区；需 `fastboot erase dtbo` |
| `system`（store） | `mmcblk0p79`，label `sirius_vendor`，`build/kernel.img`（ext4 384M） |
| store 布局 | `/boot`、`/lib/modules/<ver>`、`/lib/firmware`、`/glue` |
| `userdata` | `mmcblk0p81`，f2fs label `rootfs`，`*.simg`（5G，首启扩满） |
| cmdline 单一来源 | `boot/bootargs` → U-Boot `efi_args` + `/boot/extlinux/extlinux.conf` |
| 注入入口与清单 | `/usr/lib/systemd/system-generators/sirius-kernel-glue` → `glue/manifest`（schema v1） |
| 只读默认值与首启清理 | `glue/run/**` → `/run/**`；`/etc/systemd/system-preset/50-sirius-glue.preset` |
| 运行库 ABI 下限 | glibc ≥ 2.38 + GLib 2.x 家族 |
| 工厂只读 | `persist`（`p68`，`ro` 挂载取 WiFi 出厂 MAC） |
| 构建入口 | `./build.sh initrd` / `boot` / `kernel` / `rootfs-{server,gnome}` |
| 详细实现 | [KERNEL-IMG-STORE.md](KERNEL-IMG-STORE.md)、[U-BOOT.md](U-BOOT.md) |
