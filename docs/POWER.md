# 电源键与息屏 (sirius，GNOME 版；server 版走 Orbital，见 SERVER-MODE.md)

2026-10-18 重做：**空闲/锁屏/灭屏/唤醒全部交回 GNOME 原生**，
2.0 的 `sirius-powerd` 与 `sirius-gnome-blank` 全部删除。
唯一保留的小件是 `sirius-powerkey`（电源键→锁屏，见下），它不碰亮度、
不碰 DPMS、不 grab 设备。

## 原生链路长什么样

1. `org.gnome.desktop.session idle-delay`（设置 → 电源 → 屏幕空白，默认 120s）
   到点 → gnome-shell 激活 ScreenSaver：**先锁屏**（`lock-enabled=true`），
   shield 接管输入。
2. mutter 随后 KMS disable CRTC → `drm_panel_unprepare`：
   `ams639rq08` 发 display off + sleep in，断 vsp/vsn/vdd 轨，拉 reset。
   此时 `/sys/class/drm/card0-DSI-1/dpms` 读回 `Off`，背光 `bl_power=4`，
   但 **`brightness` 仍是灭屏前的值**（没人写它，这是关键）。
3. 任意输入（触摸、按键）→ mutter unblank → `drm_panel_prepare`
   重新上电初始化 → `drm_panel_enable()` 里 `backlight_enable()` 用
   `props.brightness` 重新下发 DCS 亮度。锁屏界面正常亮度出现，
   输入被 shield 吃掉，不会点到下层应用。

面板是命令模式 DSI，亮度就是 DCS `0x51`，没有独立背光芯片；
「灭屏」在驱动层只有 unprepare 一条路。绕开它去写 `brightness=0`
只会得到一个「UI 以为还亮着」的假灭屏 —— 2.0 就是这么干的。

## 电源键：为什么还需要一个小件

GNOME 给电源键的动作只有四个（`org.gnome.settings-daemon.plugins.power
power-button-action`）：`nothing` / `suspend` / `hibernate` / `interactive`。

- `suspend`/`hibernate` 在这台机器上是死路（s2idle 太浅，按键边沿自己就唤醒；
  targets 已 mask），gsd 的 `supports_power_action()` 也会回落到 interactive。
- `interactive` **不是电源菜单**：gsd-media-keys 直接
  `gnome-session Shutdown`（源码 `do_config_power_action()`），gnome-shell 弹的
  是关机确认框，**60 秒没人管就真的关机**。实测 14:41:08 按下 → 14:42:10 关机。
- `nothing` = 按下没反应。
- **没有 lock**。而 logind 的 `HandlePowerKey=lock` 永远轮不上：gsd-media-keys
  一启动就持有 logind 的
  `handle-power-key:handle-suspend-key:handle-hibernate-key` **block** 型
  inhibitor（`ListInhibitors` 可见，和 `power-button-action` 取值无关），
  按键根本到不了 logind。

所以 `sirius-powerkey`（`src/sirius-powerkey/`）只做一件事：**按下 = 锁屏**。

- 只读 watch `pm8941_pwrkey`（按设备名找，event 号会漂），**不 EVIOCGRAB**，
  所以按键照旧到 mutter —— 灭屏时按一下就是原生唤醒到锁屏界面。
- 每次按下先（在任何 D-Bus 往返之前）读
  `/sys/class/drm/card0-DSI-1/dpms` 记下面板状态，再查
  `org.gnome.ScreenSaver.GetActive`，按三种状态分流：
  - 未锁：调 `org.gnome.ScreenSaver.Lock`（锁屏）。
  - 已锁 + 按下时亮屏：**立即灭屏**。做法是把 ScreenSaver 走一个循环：
    `SetActive(false)` → 轮询 `GetActive` 等它真的变 false → 再 `Lock()`。
    gsd 在 `ActiveChanged false→true` 这条边上灭屏
    （`idle_set_mode(BLANK)` → mutter `PowerSaveMode=3`），所以灭屏者
    还是 gsd 自己，之后的唤醒路径和原生一字不差。不能直接写 mutter 的
    `PowerSaveMode=3`：mutter 的 native vfunc 只实现了 OFF 方向，
    恢复全靠 gsd 的 became-active watch，绕过 gsd 写会把唤醒搞坏
    （实测过：自己写 3 之后按键唤不醒）。
  - 已锁 + 按下时灭屏：什么都不做，这次按键本身就是唤醒。
- 为什么 dpms 要在读 GetActive **之前**采样：对灭屏状态按键时，原生唤醒
  （按键 → gsd → `PowerSaveMode=0` → KMS commit）几十毫秒内就会把 dpms
  翻成 On，而 `GetActive` 一次 gdbus 就 ~40ms —— 在它之后读 dpms 会把
  唤醒键误判成亮屏键、立刻又灭回去。事件一到就读（~1ms）必然还是按键前
  的值。
- 为什么循环灭屏要等 `GetActive` 变 false：shell 只在 `_completeDeactivate`
  才翻 `_isActive`，过早 `Lock()` 会撞上 `_resetLockScreen` 的 SHOWN 状态
  早退（调用挂死、会话停在解锁态）。每次轮询 ~40ms，shell 收尾 ~250-400ms。
  toggle 全程 ~1s，期间再按会被 2s 守卫吞掉。
- 为什么不能图省事在已锁时调 `Lock()`/`SetActive(true)`：已锁（shield up）
  时 `_lockScreenState` 是 SHOWN，`_resetLockScreen()` 直接早退 ——
  `Lock()` 等 `lock-screen-shown` 等到 25s 超时，`SetActive(true)` 静默
  no-op，都不会灭屏。
- `power-button-action="nothing"`，gsd 不再把关机框拉起来。
- 跑在 `systemd --user`（需要 `input` 组读 `/dev/input/event*`），
  `WantedBy=graphical-session.target`。

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

`/etc/systemd/logind.conf.d/sirius-gnome.conf`：`HandlePowerKey=lock` 只是
backstop（gsd 挂了才轮到它），`HandlePowerKeyLongPress=poweroff`
（长按最终是 PMIC 硬件关机），`IdleAction=ignore`。

`systemctl mask suspend.target hibernate.target hybrid-sleep.target
suspend-then-hibernate.target` 保留。

## 2.0 为什么错（三条实测）

1. **powerd 的灭屏是假的**：EVIOCGRAB 掉 event0 后只写 `brightness=0`。
   gnome-shell 不知道屏灭了，ScreenSaver 不激活、shield 不接管输入，
   触摸事件照旧进 UI —— 「息屏后触摸屏还在工作」说的就是这个：
   不是触摸没关，是没人告诉系统屏黑了。
2. **两个进程抢同一个 sysfs**：sirius-gnome-blank 在 `ActiveChanged(true)`
   时写 `brightness=0` + `bl_power=1`，而 GNOME 原生灭屏是 KMS disable
   把面板 unprepare。面板一 unprepare，DSI 命令发不出去，
   powerd / gnome-blank 的写入立刻 `EINVAL`
   （journal 里的 `write brightness: Invalid argument`）。
3. **锁屏唤醒是黑的**：gnome-blank 只在 `ActiveChanged(false)`（解锁）恢复
   亮度。灭屏 → 唤醒时 saver 仍 Active，亮度停在 0：
   实测 `actual_brightness` 读回 **0**，锁屏界面黑的，得盲输密码。
   停掉 gnome-blank 后同样流程读回 **500**。

## 验证（2026-10-18，真机）

停掉两个自制件、只留 GNOME 后：

| 时刻 | dpms | brightness | actual | bl_power | saver | locked |
|------|------|-----------|--------|----------|-------|--------|
| 亮屏 | On | 500 | 500 | 0 | false | no |
| idle 20s 到点 | Off | **500** | EINVAL（面板已断电） | 4 | true | yes |
| 按键唤醒 | On | 500 | 500 | 0 | true | yes |
| 解锁 | On | 500 | 500 | 0 | false | no |

电源键用 `mock-press.py` 造同名 uinput 设备、`sirius-powerkey sirius-mock`
单独跑一份来测（第二个参数就是设备名，方便不碰真键）：

- 未锁 → 按下：`saver=true locked=yes dpms=Off`，日志一行 `lock`。
- 已锁+灭屏 → 按下：屏幕亮（`dpms=On`），日志**没有**新的 `lock`/`blank`。
- **已锁+亮屏 → 按下：立刻灭屏**（`dpms=Off`），日志一行 `blank`，
  saver/locked 保持 true —— 2026-10-18 新增的 toggle 分支。
- 立刻解锁再按下：马上又是 `lock`，没有 25 秒死区。
- 灭屏下 0.4s 双击：唤醒 → 再灭（每次按键按按下时的面板状态翻转）。

上表是 2026-10-18 复测的（含新分支）；`brightness` 全程 500。

5 次 0.15s 间隔 SetActive 快速翻转后仍能正常恢复，没有再出现
`Cursor update failed: drmModeAtomicCommit`。

## 注意 / 已知

- **唤醒延迟**：unblank 要走完整 prepare（reset + 上电 + on 序列 + 67ms），
  量级几百 ms。能接受就先不动；嫌慢的解法是给面板驱动加 soft-off
  （unprepare 只发 display off + sleep in 保住轨压，延迟几十秒再真断电，
  prepare 走 sleep-out 快路径）——目前没做。
- **关掉锁屏（`lock-enabled=false`）也成立**：saver 仍会在 idle 时激活，
  powerkey 靠 GetActive 判断，行为不变，只是醒来不用密码。
- **不做 dim**：`idle-dim=false`，灭屏是硬切。
- **没有 suspend**：真要挂起只能手动。
- **server 版不受影响**：Orbital 自己抓 KEY_POWER、自己算 idle，走
  `sirius-screen` 切背光（那个脚本还在，别一起删）。

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
