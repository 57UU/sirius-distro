# 蜂窝 bringup（基带 + SIM + LTE 数据，2026-10-18 打通）

状态：**LTE 信令与数据均可用**。中国电信卡实测注册 CHN-CT、bearer 拿到 `10.150.136.161/30`，
`ping -I` 外网 17~48ms。

---

## 1. 结论速览

| 环节 | 状态 | 说明 |
|---|---|---|
| 基带固件 | ✅ | mpss 正常加载，IMEI 可读 |
| 射频 | ✅ | LTE RSRP -90 dBm / RSSI -60 dBm |
| SIM 卡识别 | ✅ | 需手工建 provisioning session，见 §4.2 |
| LTE 注册 | ✅ | `registered` / `PS attached` / operator 46011 CHN-CT |
| 数据连接 | ✅ | NetworkManager 按运营商自动选 APN，bearer 由 ModemManager 建 |

一条命令检查当前是否活着：

```sh
sudo mmcli -m any | grep -E 'state|access tech|operator|packet service'
```

---

## 2. 启动链路（基带视角）

```
modem 分区 mmcblk0p76（192M，FAT）
  └── image/{mba.mbn, modem.b00..b29, modem.mdt}   ← 整包 NON-HLOS 内容
        │ rmtfs 按需供给（EFS 读写在 modemst1/2、fsg）
        v
remoteproc2 (q6v5-mss, 4080000)  ← 固件实际取自 /lib/firmware/qcom/sdm710/pyxis/
  ├── MBA booted → loading mpss → "modem running event"（IPA 侧）
  ├── QRTR 服务齐（UIM 50 / DMS 21 / NAS / WDS / IPA 49 …）
  ├── rmtfs      ← modem 通过 /boot/modem_fs{1,2,c,g} 读写 EFS
  ├── tqftpserv  ← PD 文件传输
  └── pd-mapper  ← PD 域映射
        v
ModemManager（qcom-soc 插件）
  ├── 需要 /dev/qrtr0 存在，否则放弃 modem（§4.3）
  ├── 需要 UIM 已有 provisioning session，否则判 sim-missing（§4.2）
  └── simple-connect → Bearer → qmapmux0.0（QMAP mux over rmnet_ipa0）
        v
手动配 IP / 路由 → 公网可达
```

---

## 3. 固件与分区的几个事实

- **目录名 `pyxis` 只是沿用了同平台机型的路径**，`/lib/firmware/qcom/sdm710/pyxis/` 里的
  `mba.mbn`、`modem.b00..b29`、`modem.mbn` 与 sirius 原厂 `NON-HLOS.bin` 提取物 **md5 完全一致**。
  不要因为目录名不是 `sirius` 就以为用错了固件。
- `modem` 分区（p76）是 FAT，内容就是 NON-HLOS 固件包本体，**不是 EFS**。EFS 在
  `fsg`(p57) / `modemst1`(p59) / `modemst2`(p60)。
- rmtfs 的存储映射在 `/var/lib/rmtfs/`，只需四项软链：
  `modem_fs1→modemst1`、`modem_fs2→modemst2`、`modem_fsc→fsc`、`modem_fsg→fsg`。
- rmtfs 日志里的
  `request for unknown partition '/boot/modem_fsg_oem_1', rejecting`
  **是正常现象，不要去修**。rmtfs 的分区表是编译期硬编码的，只认 `modem_fs1/fs2/fsc/fsg`
  （以及 OnePlus 的几项），往里放文件无效；而且 stock Android 的 vendor 映射表同样只有这四项，
  安卓上也会收到同样的拒绝。
- 主线内核 sdm670 的 IPA 支持是本地补丁（`sdm670.dtsi` + `ipa_main.c` 复用 `ipa_data_v3_5_1`），
  但 `ipa_modem.c` **没有 mux 层**，只维护单个 `rmnet_ipa%d`。所以别指望手工
  `ip link add ... type rmnet mux_id N` 那套，多 mux 走不通；ModemManager 的 QMAP mux 才是活路。

---

## 4. 四个必须知道的坑

### 4.1 UIM 的 AID 必须用卡上真实值，不能套模板

通用 USIM AID 模板是

```
A0:00:00:00:87:10:02:FF:86:FF:FF:89:FF:FF:FF:FF
                          ^^
```

但本机电信卡上真实的是（第 12 字节是 `03`）：

```
A0:00:00:00:87:10:02:FF:86:FF:03:89:FF:FF:FF:FF
```

用模板去 `--uim-open-logical-channel` 会得到 `SimFileNotFound`，很自然会误判成"这张卡没有 USIM 应用"。
**正确做法：先 `qmicli --uim-get-card-status`，从输出里抄 `Application ID`。**

另外：单卡时卡状态有时只报出第一个应用（csim），插上双卡后才会把 `usim` 也列出来。
判定卡类型不要只看一眼就下结论。

### 4.2 provisioning session 必须手工建，MM 自己不会建

卡上电后 `Application state` 停在 `detected`、`Primary GW: session doesn't exist`，
此时 ModemManager 会报 `GW primary session index unknown` 并把 modem 判成 sim-missing。

qmicli 的 `--uim-change-provisioning-session` 在这台 modem 上走不通：它会先做一次
power-off SIM，而这一步固定返回 `QMI error 3 'Internal'`。
绕过办法是直接用 libqmi 发请求（不经过 power-off），工具见 §7 的 `uimsel`：

```sh
# 电信卡：用 card status 里抄出来的 usim AID
sudo env UIMSEL_AID=A0000000871002FF86FF0389FFFFFFFF UIMSEL_ST=0 uimsel 1
#   UIMSEL_ST=0  Primary GW provisioning（LTE/GSM 鉴权，必须）
#   UIMSEL_ST=1  Primary 1X provisioning（仅 CSIM 卡/老卡才用得上）
#   UIMSEL_DEACT=1  撤销
```

成功标志：

```
Primary GW:   slot '1', application '2'
Application state: 'ready'      PIN1 state: 'disabled'
```

随后十几秒内应出现 `Registration state: 'registered'` 与 `PS: 'attached'`。

### 4.3 ModemManager 需要 /dev/qrtr0 存在

MM 的 qcom-soc 插件在初始化时会去 `g_file_query_info("/dev/qrtr0")`，文件不存在就打

```
couldn't reset QMI port 'qrtr0' with data interface 'rmnet_ipa0':
Couldn't query file info: ... No such file or directory
```

然后**放弃 modem**（`enabled → disabling → disabled`，最终 `No modems were found`）。
QRTR 的 QMI 走 socket，本来就没有 /dev 节点，给个假节点即可：

```sh
sudo ln -sf /dev/null /dev/qrtr0
sudo systemctl restart ModemManager
```

之后 MM 立刻正常工作（见 §5）。

### 4.4 libqmi 1.36 缺 bind_subscription，纯 qmicli 路线到不了数据面

如果想绕开 MM 直接用 qmicli 建数据连接，会连续撞墙：

| 尝试 | 结果 |
|---|---|
| `--wds-bind-mux-data-port`（ep 0~8、mux 0/1/128） | `QMI error 3 'Internal'` |
| 跳过绑定直接 `--wds-start-network` | `QMI error 70 'InvalidOperation'` |
| `--wds-start-network="3gpp-profile=1"`（profile 1 = ctnet 已存在） | 同样 `InvalidOperation` |
| `--wds-set-autoconnect-settings=enabled` | 同样 `InvalidOperation` |
| `--wds-set-default-profile-number=3gpp,1` 后再 start | 仍 `InvalidOperation` |
| `--wds-reset` 后再 start | 仍 `InvalidOperation` |
| `--wds-bind-data-port=1` | `25 'DeviceUnsupported'`（USB 专用命令） |

根因是 WDS 客户端缺少 **BindSubscription**，而 libqmi 1.36 根本没实现这条消息
（`qmi-wds.h` 里搜不到），qmicli 自然发不出来。单卡、双卡都一样。

> 注意 qmicli 的另一个陷阱：`--client-cid=N` 不能跨进程复用（进程退出即失效，
> 报 `Unknown client N for service wds`），而一次调用又不允许两个 WDS 动作
> （`too many WDS actions requested`）——所以任何"先 bind 再 start"的脚本都写不出来，
> 只能自己写程序（`wdsup`）或走 ModemManager。

---

## 5. 操作步骤

### 5.1 手工拉起（排障用）

```sh
# 0) 基础服务（应由 systemd 拉起，确认即可）
systemctl is-active qrtr-ns rmtfs tqftpserv pd-mapper

# 1) MM 的必需品
sudo ln -sf /dev/null /dev/qrtr0

# 2) 基带置 online（若停在 shutting-down，多半是 MM 上次失败后关的）
sudo qmicli -d qrtr://0 --dms-set-operating-mode=online

# 3) 建 provisioning session（AID 从 card status 抄）
sudo env UIMSEL_AID=<卡上的 usim AID> UIMSEL_ST=0 uimsel 1

# 4) 重启 MM，确认它认下 modem
sudo systemctl restart ModemManager
sudo mmcli -m any | grep -E 'state|access tech|operator|packet service'
#  期望：registered / lte / CHN-CT / attached

# 5) 建数据连接（必须 root，普通用户会被 polkit 拦）
sudo mmcli -m any --simple-connect=apn=ctnet,ip-type=ipv4
sudo mmcli -b 1        # 记下 address / prefix / gateway / dns / mtu

# 6) 配接口（MM 只建 bearer，不配 IP）
sudo ip addr add <address>/<prefix> dev qmapmux0.0
sudo ip link set qmapmux0.0 up mtu 1410
sudo ip route replace default via <gateway> dev qmapmux0.0 metric 700

# 7) 验证
ping -I qmapmux0.0 223.5.5.5
```

实测样例：

```
interface: qmapmux0.0   address: 10.150.136.161/30
gateway: 10.150.136.162   dns: 218.6.200.139, 61.139.2.69   mtu: 1410
ping 223.5.5.5 → 3/3, 17~48ms
TCP 114.114.114.114:53 → 通
```

判读注意：**运营商网关不响应 ping**（10.150.136.162 打不通是正常的）；
`223.5.5.5:80` 不提供 HTTP，也不要用它验 HTTP。

### 5.2 交给 NetworkManager（正式方案）

上面的手工流程只用于排障。日常由 NM 接管，overlay 里预置
`etc/NetworkManager/system-connections/cellular.nmconnection`：

```ini
[connection]
id=cellular
type=gsm
interface-name=qrtr0

[gsm]
auto-config=true          # 关键：不写死 APN

[ipv4]
method=auto
[ipv6]
method=auto
```

`auto-config=true` 让 NM 按卡上的 MCC/MNC 去 `mobile-broadband-provider-info`
查表取 APN，**换卡不用改配置**：

| 运营商 | MCC/MNC | 自动得到的 APN |
|---|---|---|
| 中国移动 | 46000/46002/46004/46007/46008 | CMNET |
| 中国电信 | 46003/46011/46012 | CTNET |
| 中国联通 | 46001/46006/46009 | 3GNET |

实测：插电信卡得 CTNET、换移动卡得 CMNET，都直接可用。

两个注意点：

1. **keyfile 必须 root:600**，否则 NM 静默忽略（连接“不存在”）。overlay 拷进去是 644，
   由 `sirius_overlay()` 统一 `chmod 600` 修正。
2. **别用电信卡的 APN 跑别的卡**。虽然实测移动网络对 `ctnet` 也放行（走默认承载），
   但那是运营商的宽容而非规范，自动查表更稳。

### 5.3 自动化：谁在什么时候动手

三个单元围绕同一个幂等脚本 `sirius-modem-uim`：

| 单元 | 触发时机 | 职责 |
|---|---|---|
| `sirius-modem-uim.service` | 开机（`Before=ModemManager`）、timer、事件 | 读卡 → 取 AID → 建 primary-gw 会话 → 必要时异步重启 MM |
| `sirius-modem-uim.timer` | 每 60 秒 | 兜底：事件丢失时仍能补上 |
| `sirius-modem-uim-watch` | 常驻（`Restart=always`） | 订阅 UIM 的 `card-status`/`slot-status`，有变化就触发上面那个 service |

几个必须知道的细节：

- **顺序**：`qrtr-ns`/`rmtfs` → `sirius-modem-uim` → `ModemManager` → `NetworkManager`。
  service 必须早于 MM，否则 MM 会因 `GW primary session index unknown` 判 sim-missing 并放弃 modem。
- **modem 起不来时**，等待上限是 40 秒（`qmicli` 轮询）。这段时间会拖住 MM 和 NM 的启动，
  是刻意换取"MM 一次启动成功"的代价——反过来让 MM 先失败再重启会更慢（它的停止要等 QMI 收尾）。
- **互斥**：脚本开头有 `flock`。因为它会被三条路径触发，其中 watch 是**直接 exec**（绕过 systemd），
  systemd 管不到这条路径；一次拔插会产生十几条事件，没有锁就会并发跑十几个实例同时发 QMI。
- **重启 MM 要冷却**：脚本记了 `/run/sirius-modem-uim.stamp`，60 秒内不重复重启，
  防止"重启 → 新事件 → 再重启"的循环。
- **判断"无卡"和"卡还没读完"是两件事**：卡 present 但应用列表为空时会重试最多 10 秒
  （实测插卡后 2~6 秒应用才出现）；卡真的 absent 则立即退出，不空等。

---

## 6. 会让整机冻死的操作（务必避让）

| 操作 | 后果 |
|---|---|
| `systemctl restart rmtfs`（modem 运行中） | 系统冻死，只能长按电源 |
| `echo stop > /sys/class/remoteproc/remoteproc2/state` | 系统冻死 |
| 基带运行时挂载/遍历 `modem` 分区 | AP 与基带同时访问存储，硬挂死 |

要重启基带就整机重启。若系统还活着（SSH 可用），自己 `sync && reboot -f` 即可——
`-f` 跳过服务停止，绕开 rmtfs 那个已知的 stop hang。

---

## 7. 工具

### 生产组件（随镜像发布）

源码在 `src/modem/`，编译产物放在 `rootfs/modem-pkg/`，由 `rootfs/sirius-device.sh` 的
`sirius_overlay()` 装进 `/usr/local/bin/`（做法同 `rootfs/powerd-pkg`）。

| 文件 | 用途 |
|---|---|
| `uimsel.c` | 直接用 libqmi 发 ChangeProvisioningSession，跳过 qmicli 内部会失败的 power-off。支持 `UIMSEL_AID` / `UIMSEL_ST` / `UIMSEL_DEACT` |
| `uimwatch.c` | 常驻订阅 UIM 的 `card-status` / `slot-status` 事件；**必须自己 `setbuf(stdout, NULL)`**，否则 qmicli 那套走管道会全缓冲、事件读不出来 |

在 arm64 设备上就地编译：

```sh
gcc -o uimsel uimsel.c     $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
gcc -o uimwatch uimwatch.c $(pkg-config --cflags --libs qmi-glib qrtr-glib glib-2.0 gio-2.0)
```

依赖：`gcc libc6-dev libqmi-glib-dev pkg-config`。

**运行时依赖**（`rootfs/sirius-device.sh` 的 `SIRIUS_BASE_PKGS` 已包含）：

- `modemmanager` —— 提供 ModemManager 以及 libqmi-glib / libqrtr-glib / libmbim-glib
- `libqmi-utils` —— 脚本里调用的 `qmicli`，缺了它整个流程跑不起来
- `rmtfs`、`tqftpserv`、`qrtr-tools` —— 基带 EFS 与 QRTR 基础服务

对应 systemd 单元也在 `SIRIUS_BASE_UNITS` 里 enable：`ModemManager`、`sirius-modem-uim`、
`sirius-modem-uim.timer`、`sirius-modem-uim-watch`。

### 诊断工具（`workspace/`，不入库）

| 文件 | 用途 |
|---|---|
| `uimrd.c` | 直接读 SIM 透明文件（指定 session 类型），用于验证卡内文件 |
| `wdsup.c` | 尝试 bind mux + start network + 读 IP 的完整 WDS 程序。**当前路线上失败**，保留作为 libqmi 补齐后的参考 |
| `nonhlos-tool.py` | 纯 Python 解析 `NON-HLOS.bin`（FAT 镜像），`list` / `ls IMAGE` / `extract <outdir> <prefix> IMAGE` |

---

## 8. 排查路径留档（避免重走）

被排除的假设，按时间顺序：

1. ~~基带挂了~~ —— mpss 正常、IMEI 可读、QMI 服务齐全。
2. ~~固件版本不对~~ —— 与 stock `NON-HLOS.bin` 逐文件 md5 一致。
3. ~~卡是坏的 / 老卡只有 CSIM~~ —— 双卡插入后 card status 明确列出 `usim` 应用。
4. ~~rmtfs 映射缺失~~ —— `fsg_oem` 的拒绝在安卓上同样发生。
5. ~~ModemManager 干扰~~ —— 停掉它基带仍不建会话，但**它是 shutting-down 的制造者**。
6. ~~双卡需要 bind_subscription~~ —— 拔掉第二张卡后 `start_network` 依然 `InvalidOperation`。
7. ✅ 真因：session 未建（§4.2）+ MM 缺 `/dev/qrtr0`（§4.3）+ libqmi 缺 `bind_subscription`（§4.4）。
