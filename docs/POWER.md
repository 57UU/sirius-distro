# 电源键与息屏 (sirius，GNOME 版；server 版走 Orbital，见 SERVER-MODE.md)

2026-10-18：空闲/锁屏/灭屏/唤醒交回 GNOME 原生；2.0 的 `sirius-powerd`、`sirius-gnome-blank` 全删。仅留 `sirius-powerkey`（电源键→锁屏），不碰亮度/DPMS/grab 设备。

## 原生链路

1. `org.gnome.desktop.session idle-delay`（设置→电源→屏幕空白，默认 120s）到点 → gnome-shell 激活 ScreenSaver：先锁屏（`lock-enabled=true`），shield 接管输入。
2. mutter 随后 KMS disable CRTC → `drm_panel_unprepare`：`ams639rq08` 发 display off + sleep in，断 vsp/vsn/vdd 轨，拉 reset。`/sys/class/drm/card0-DSI-1/dpms` 读回 `Off`，背光 `bl_power=4`，`brightness` 仍是灭屏前的值（关键）。
3. 任意输入 → mutter unblank → `drm_panel_prepare` 重新上电 → `drm_panel_enable()` 里 `backlight_enable()` 用 `props.brightness` 重新下发 DCS 亮度；输入被 shield 吃掉。

面板命令模式 DSI，亮度 = DCS `0x51`，无背光芯片；灭屏只有 unprepare 一条路，写 `brightness=0` 只能假灭屏（2.0 就这么干的）。

## 电源键：为什么需要 sirius-powerkey

GNOME 电源键动作四选一（`org.gnome.settings-daemon.plugins.power power-button-action`）：`nothing`/`suspend`/`hibernate`/`interactive`。

- `suspend`/`hibernate` 死路：s2idle 太浅，按键边沿自唤醒；targets 已 mask；`supports_power_action()` 回落 interactive。
- `interactive` 非电源菜单：gsd-media-keys 直接 `gnome-session Shutdown`（源码 `do_config_power_action()`），弹关机确认框，60s 无人管即关机。实测 14:41:08 按下 → 14:42:10 关机。
- `nothing` = 无反应。
- 无 lock：logind `HandlePowerKey=lock` 轮不上 —— gsd-media-keys 持有 logind 的 `handle-power-key:handle-suspend-key:handle-hibernate-key` block 型 inhibitor（`ListInhibitors` 可见，与 `power-button-action` 无关），按键到不了 logind。

`sirius-powerkey`（`src/sirius-powerkey/`）：按下 = 锁屏。

- watch `pm8941_pwrkey`（按设备名找，event 号会漂），不 EVIOCGRAB；按键照旧到 mutter（灭屏时按一下 = 原生唤醒到锁屏）。
- 按下先读 `/sys/class/drm/card0-DSI-1/dpms`（任何 D-Bus 往返前），再查 `org.gnome.ScreenSaver.GetActive`，三状态分流：未锁 → `org.gnome.ScreenSaver.Lock`；已锁+亮屏 → 灭屏（`SetActive(false)` → 轮询 `GetActive` 变 false → `Lock()`）；已锁+灭屏 → 不做事（按键即唤醒）。
- 要点：① 采样序先 dpms 后 GetActive —— `GetActive` 一次 gdbus ~40ms，唤醒几十 ms 内翻 dpms=On 会误判成亮屏键，事件一到就读 ~1ms；② 循环须等 `GetActive` 变 false —— 过早 `Lock()` 撞 `_resetLockScreen` SHOWN 早退、`_completeDeactivate` 未翻 `_isActive`（挂死），轮询 ~40ms、收尾 ~250-400ms、toggle ~1s、再按被 2s 守卫吞；③ 已锁时不可调 `Lock()`/`SetActive(true)`（`_lockScreenState=SHOWN` 时 `_resetLockScreen()` 早退 → `Lock()` 25s 超时、`SetActive(true)` no-op）；④ 不可直写 mutter `PowerSaveMode=3`（native vfunc 只有 OFF 方向，恢复靠 gsd became-active watch，gsd 灭屏走 `idle_set_mode(BLANK)`，实测写 3 后按键唤不醒）。
- `power-button-action="nothing"`；跑 `systemd --user`（需 `input` 组读 `/dev/input/event*`），`WantedBy=graphical-session.target`。

## 设置（`rootfs/build-gnome.sh` 烤进镜像）

`/usr/share/glib-2.0/schemas/90-sirius-power.gschema.override`：

```ini
[org.gnome.settings-daemon.plugins.power]
power-button-action="nothing"         # 按键交给 sirius-powerkey
sleep-inactive-ac-type="nothing"      # 永不 suspend
sleep-inactive-battery-type="nothing"
idle-dim=false                        # 不做渐变；想要可在设置里开
[org.gnome.desktop.session]
idle-delay=uint32 120
[org.gnome.desktop.screensaver]
lock-enabled=true                     # 灭屏 = 锁屏，唤醒要密码
idle-activation-enabled=true
```

`/etc/systemd/logind.conf.d/sirius-gnome.conf`：`HandlePowerKey=lock` 仅 backstop（gsd 挂了才轮到），`HandlePowerKeyLongPress=poweroff`（长按 = PMIC 硬件关机），`IdleAction=ignore`。

`systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target` 保留。

## 2.0 为什么错（三条实测）

1. 灭屏假：powerd EVIOCGRAB event0 后只写 `brightness=0`；gnome-shell 不知屏灭，ScreenSaver 不激活、shield 不接管，触摸照旧进 UI。
2. 两进程抢同一 sysfs：sirius-gnome-blank 在 `ActiveChanged(true)` 写 `brightness=0`+`bl_power=1`；原生灭屏是 KMS disable 把面板 unprepare —— unprepare 后 DSI 命令发不出，写入 `EINVAL`（journal `write brightness: Invalid argument`）。
3. 锁屏唤醒黑：gnome-blank 只在 `ActiveChanged(false)` 恢复亮度；灭屏→唤醒 saver 仍 Active、亮度停 0：`actual_brightness` 实测 0（黑屏盲输密码）；停掉 gnome-blank 后读回 500。

## 验证（2026-10-18，真机）

停两个自制件、只留 GNOME 后：

| 时刻 | dpms | brightness | actual | bl_power | saver | locked |
|------|------|-----------|--------|----------|-------|--------|
| 亮屏 | On | 500 | 500 | 0 | false | no |
| idle 20s 到点 | Off | **500** | EINVAL（面板已断电） | 4 | true | yes |
| 按键唤醒 | On | 500 | 500 | 0 | true | yes |
| 解锁 | On | 500 | 500 | 0 | false | no |

`mock-press.py` 造同名 uinput 设备、`sirius-powerkey sirius-mock` 单独跑测（第 2 参数 = 设备名，不碰真键）：

- 未锁按下：`saver=true locked=yes dpms=Off`，日志一行 `lock`。
- 已锁+灭屏按下：亮屏（`dpms=On`），日志无新 `lock`/`blank`。
- 已锁+亮屏按下：立刻灭屏（`dpms=Off`），日志一行 `blank`，saver/locked 保持 true（2026-10-18 新增 toggle 分支）。
- 立刻解锁再按下：马上 `lock`，无 25s 死区。
- 灭屏下 0.4s 双击：唤醒 → 再灭（按按下时的面板状态翻转）。

上表 2026-10-18 复测（含新分支）；`brightness` 全程 500。

5 次 0.15s 间隔 SetActive 快速翻转后仍正常恢复，未再出现 `Cursor update failed: drmModeAtomicCommit`。

## 注意 / 已知

- 唤醒延迟：unblank 走完整 prepare（reset + 上电 + on 序列 + 67ms），几百 ms。懒解法：面板驱动加 soft-off（unprepare 只发 display off + sleep in 保轨压，延迟几十秒再断电，prepare 走 sleep-out 快路径）—— 没做。
- `lock-enabled=false` 也成立（saver 仍 idle 激活，powerkey 靠 GetActive 判断，只免密码）；不做 dim（`idle-dim=false`，硬切）；没有 suspend（要挂起手动）。
- server 版不受影响：Orbital 自己抓 KEY_POWER、算 idle，走 `sirius-screen` 切背光（脚本还在，别删）。

## 排错

```sh
# 面板到底灭没灭（Off + bl_power 4 才对；bl_power=1 说明还有人写 bl_power）
cat /sys/class/drm/card0-DSI-1/dpms /sys/class/backlight/ae94000.dsi.0/bl_power
# 电源键有没有被接住（未锁按下打 lock，已锁亮屏按下打 blank，已锁灭屏不打）
journalctl --user -u sirius-powerkey -n 20
# 谁在挡 logind 的电源键（应该只有 gsd 一条 handle-power-key）
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager ListInhibitors
```
