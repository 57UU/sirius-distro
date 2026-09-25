# sirius 服务器模式（Orbital 默认 UI + 背光守护 + 电源键）

> 2026-09-25 定稿，手机实测通过。分工原则：**Orbital 只管画，
> 电源与息屏归守护进程**（Orbital 的电源处理故意禁用，见 orbital/README）。
> 内核零修改（`7.2.3-sdm670-gcbbdbeb2ca53`）；
> boot（`boot_sys-72-nodebug`，cmdline 去 `debug`）只管启动。

## 1. 显示实测结论（决定设计）

```text
- 无头启动后 fbcon 提交卡住（planes_changed 常 1，fb blank 写 EIO，
  fb paper-state 与 dpms 节点不可信）。有合成器（GNOME/Orbital）的
  启动则一切正常 —— 对照实测。
- sirius-remodeset（自研约 150 行 C，裸 ioctl 无 libdrm 依赖）可做
  完整 modeset 解卡，现保留为手动救援工具（平时不用）。
- 背光 WLED ae94000.dsi.0 双向可靠，是真正的开关。
  SoC/WiFi/BT/SSH 全程在线，不碰 suspend。
```

结论：守护进程只碰背光，不碰显示管线。

## 2. 行为

```text
开机：      orbital.service 自启（/opt/orbital，root 身份），
            自己 modeset 点亮面板。console/tty1 留在底下备用。
电源键：    triggerhappy（root 身份）抓 KEY_POWER →
            sirius-screen toggle：灭（存亮度→背光 0）/
            亮（恢复亮度）。只动背光。
音量±/触摸：直接点亮（sirius-screen pon，背光恢复，无其他动作）。
无操作120s：sirius-idle-watch（python3 无依赖，读 /dev/input/event*）
            调 sirius-screen auto-off。只关不開，不打架。
亮度记忆：  每次关屏存当前值，开屏恢复；Orbital 滑杆随便拖，
            灭亮一次也不丢。
网络：      NM 自连（`sirius-wifi-add` 烤首个网络，powersave=2）+
            RNDIS usb0 静态（`172.16.42.1`）+ BT 自启。
logind：    HandlePowerKey=ignore（按键归 triggerhappy，
            否则按电源会触发 suspend），IdleAction=ignore。
```## 3. 文件（本库 `rootfs/overlay/`，手机端位置镜像对应）

```text
overlay/usr/local/sbin/  sirius-screen sirius-remodeset（救援用）
                         sirius-idle-watch sirius-bt-auto sirius-wifi-add
overlay/etc/systemd/system/  sirius-idle-watch orbital triggerhappy
                         .service.d/sirius-root.conf（thd 必须 root）
overlay/etc/triggerhappy/triggers.d/sirius-power.conf
overlay/etc/systemd/logind.conf.d/sirius-server.conf
overlay/etc/NetworkManager/conf.d/sirius-server.conf
overlay/etc/sysctl.d/60-sirius-printk.conf
build-server.sh（另有 build-gnome.sh GNOME 桌面版，同息屏/电源键栈）
src/sirius-remodeset.c（救援工具源码）
```

手机包外单装：`triggerhappy evtest rfkill auditd kbd`
（`build-server.sh` 已含；`libdrm-tests kmscube` 为调试工具，手动装）。

## 4. 验证记录（手机，2026-09-24/25）

```text
OK  multi-user 无桌面；零 failed 单元；WiFi 开机自连；BT hci0 UP RUNNING
OK  背光双向；电源键 toggle；120s 无操作自动息屏；音量/触摸点亮
OK  亮度记忆（300→灭→亮回 300）；Orbital /opt 服务版运行正常
OK  kmscube freedreno OpenGL ES 3.2（GPU 驱动正常；fastfetch 软渲染是
    无合成器 + 缺 video/render 组（已加）+ vulkan 被 purge 的结果）
OK  audit 进文件（auditd）；大字体 console 备用；printk 限级
```

## 5. 已知限制（设计如此，不是 bug）

```text
- 真 suspend 没做：只关屏不断网（SSH/WiFi 存活优先）。
- btmgmt 在 WCN3990 上会卡住：已 timeout 化 + 服务 TimeoutStartSec=30；
  BT 实际靠 BlueZ AutoEnable 已 UP。
- fb paper-state / dpms 节点不可信；fb blank 写 EIO（设计已绕开，
  平时根本不碰显示管线）。
- thd 默认 nobody，必须 root drop-in，否则按键脚本无权限（踩过）。
- Orbital 长按电源退出（上游行为）目前被禁用（电源归守护进程），
  如需还给 Orbital，改 service 环境变量即可。
```

## 6. 排错速查

```text
按键没反应  evtest 看 KEY_POWER → ps 确认 thd --user root →
           /etc/triggerhappy/triggers.d/sirius-power.conf
屏灭亮度回不来  删 /run/sirius-screen/brightness.* 再 on
关机慢  老规矩：等 15 分钟；急用 safe-reboot（sysrq s+u+b）
apt 403/超时  先 date 看时间（1978 老坑）；IPv6 可用时 apt 优先走 v6
```
