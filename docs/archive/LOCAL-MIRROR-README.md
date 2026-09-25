# mi8se-linux 本机镜像（小米 8 SE / sirius 移植）

本目录是服务器工程在 Windows 本机的落盘：构建产物、二进制、备份的“本地一份”，
内核源码本身只在服务器上有（本机不存源码树）。

## 地址速查

| 端 | 地址 / 位置 | 说明 |
|---|---|---|
| 服务器 SSH | `ssh -p 31739 u57u@server.57u.tech` | 传文件一律 `scp -P 31739`（大写 P） |
| 服务器工程 | `/home/u57u/projects/mi8se-linux`（`~/projects/mi8se-linux`） | 内核源码 `linux-on-stable/`、构建脚本 `boot/`、规范固件库 `firmware/`、Debian 系统 `systems/` 全在这里 |
| 本机工程 | `E:\Tools\Device\8se\linux\`（本目录） | 只存产物和文档，不存源码 |
| 手机 SSH | `ssh u57u@172.16.42.1`（密码 `1234`，sudo 免密） | RNDIS 网卡，宿主侧是 `172.16.42.2`；服务器直连不到手机，链路永远是 服务器→本机→手机 |
| 基带备份 | `E:\Tools\Device\8se\backup\` | modem/modemst1/modemst2/fsg/fsc/persist，见里面 `README-baseband.md` |
| 手机 fastboot | ID `2df46452`，必须 USB2 口/线 | 全面屏无按键，进 fastboot 靠音量下 + 电源手动 |

## 目录对照（本机 ↔ 服务器）

| 本机（`E:\Tools\Device\8se\linux\`） | 服务器（`~/projects/mi8se-linux/`） | 说明 |
|---|---|---|
| `boot-images\` | `boot\`（`boot.img` / `boot_sys.img` / `Image.gz` / `kernel-dtb`） | 启动镜像归档；当前在用 `boot_sys-72-wifi-v2.img`，兜底 `KNOWN-GOOD-72-cbbdbe.img` |
| `boot-img\` | — | 旧批次启动镜像，按 `boot-images\` 为准 |
| `firmware\` | `firmware\`（`README.md` + `MANIFEST.sha256` 在这一层） | 固件部分镜像，以服务器 `MANIFEST.sha256` 为准 |
| `modules\` | 内核构建机 `out/` / `/tmp/modstage` | 内核模块包（`.tgz`）+ `diag-20260919\` 诊断归档 |
| `systems\` | `systems\` | Debian/Ubuntu 系统镜像（`.simg` / `.tar.zst`）+ 抓固件脚本残留 |
| `scripts\` | `boot\`、`systems\*.sh` | 调试脚本（telnet 等） |
| `rootfs\` | `systems\debian-trixie-sirius\` | rootfs 相关 |
| `HANDOFF-2026-09-*.md` | `HANDOFF.md` / `HANDOFF-2026-09-15.md` | 交接文档；最新看日期最大的那份 |
| `PANEL-FIX-2026-09-15.md` | — | EA8074 面板 1080x2244 修复记录 |
| `README.md` | `README.md`（构建流程总览） | 本文件只管地址和位置，构建流程看服务器那份 |

## 注意事项

- 中转文件放 E 盘（如本目录下 `.tmp`），**不要放 C 盘**（`C:\Temp` 保持清空）。
- `scp -r` 会顺着内核源码 `build` 软链接拷整个源码树，打包先 tar 排除 build。
- 本机是 PowerShell：远程命令避开 `$`、反引号、子命令括号。
- 内核分支 `feat/sirius-7.2`（只有服务器有），改内核先上服务器，产物再拷回本机归档。

## 手机固定 MAC（自编 LAA，2026-09-25）

主线驱动读不到出厂 MAC（WiFi 每次重启 choosing random，蓝牙恒为 00:00:00:00:5A:AD），故在 OS 层钉死一对自编本地管理地址（02 开头，LAA 单播，不会和真机 OUI 撞；出厂 MAC 仍在 backup/persist.img 备份里，本次未采用）：

| 设备 | 固定 MAC | 手机侧落点 |
|---|---|---|
| wlan0（WiFi） | 02:57:55:08:5E:01 | /etc/systemd/network/10-wlan0.link（udev 层，Match OriginalName=wlan0） |
| hci0（蓝牙） | 02:57:55:08:5E:02 | /etc/systemd/system/bt-addr.service（After=bluetooth，stop 蓝牙→改地址→start 蓝牙） |

地址取 57U/8SE 谐音好记。验证：重启后 ip link show wlan0 与 bluetoothctl show 应显示上表地址。注意两点：一是 WiFi 换 MAC 后路由器 DHCP 会重分 IP（192.168.110.x 可能变化），要固定 IP 请在路由器按新 MAC 重做 reservation；二是分享 rootfs 镜像给别的机器前须换掉这两个地址，否则撞车。

踩坑记录（bt-addr，根因都是 btmgmt 的 stdin）：
- btmgmt 在 stdin 为 /dev/null 时会 hang 死等（实测 6 秒零输出、必须 SIGKILL；无视 SIGTERM）。systemd unit 默认 stdin=/dev/null，所以 unit 里裸调 btmgmt 必卡，进而靠 Before= 排序连带卡住 bluetooth 启动。修复：所有 btmgmt 调用都经 sleep 管道喂一个常开无数据的 stdin（形如 sleep 4 | timeout -s KILL 3 btmgmt ... info），并统一用 timeout -s KILL 兜底。
- 定稿流程：After=bluetooth，确认 daemon 存活→stop 蓝牙→轮询确认控制器落定 DOWN→改地址→start 蓝牙→轮询校验地址+powered。失败不挡开机（蓝牙回落缺省地址，看 journal）。
- 血泪教训：不要在 daemon 运行时用 btmgmt power off/on 拨弄控制器（wcn3990 上曾观察到改完地址被重置回缺省）；启停一律走 systemctl stop/start bluetooth。另外 PowerShell 下写远程 heredoc 时，单引号、dollar、反引号都会被层层转义，unit 里只用双引号+字面数字列表才一次写对。
