# 电源键与灭屏 (sirius，GNOME 版专属，server 版不启用)

sirius-powerd 独占 pmic 电源键，按一下翻转 OLED panel，只写 brightness，
永不碰 `bl_power`；监听全部 input 做无操作自动灭屏（时长跟随 Screen Blank 设置）。
GNOME 彻底退出灭屏链（不 KMS blank、不 dim）。
长按硬关机是 PMIC 硬件，不受影响。

## 为什么绕开 GNOME

- suspend 路是死路：`power-button-action=suspend` 时，一次按压产生十几次
  内核事件（logind 全记录），但 ~4.5 秒才放行一次 suspend，且 s2idle 太浅，
  0.5 秒内就被按键自己的边沿唤醒。151 次上报只换来 6 次空转，
  ScreenSaver 状态机一次没动。
- mutter 路是死路：saver activate 会 KMS disable CRTC，panel 驱动约 1 秒后
  自行 powerdown（`bl_power` 读回 4，此后 sysfs 写 `bl_power` 直接 EINVAL，
  brightness 写了也不亮）。快速灭/亮会把 atomic commit 干成
  `Cursor update failed: drmModeAtomicCommit: Invalid argument`，
  第三下之后点不亮。
- 改键路是死路：`pm8941_pwrkey` 不支持 EVIOCSKEYCODE（直接 EINVAL），
  hwdb 重启也没用；XKB layout 能生效但 `* = +inet(evdev)` 全模型追加，
  inet 在后面把 POWR 盖回 XF86PowerOff，layout 层永远赢不了；
  做成 option 能赢，但 shell 自定义快捷键没人接（xev 能看到 F24，
  却没有任何 grab 持有它）。

结论参考 OLED 本质：brightness 0 = 发光单元全灭，恢复只是写回数值，
不需要背光/powerdown 那套，单写 brightness 就够快够稳。

## 文件与设置

- `rootfs/overlay/usr/local/sbin/sirius-powerd`（C，源码见 `src/sirius-powerd`，裸 libc）：抓 event0（EVIOCGRAB），
  按键翻 panel（brightness 0 / 恢复），监听全部 event* 做 idle，
  saver Active 时（手动锁屏）按=经 saver 唤醒并强制 panel on。
- `rootfs/overlay/etc/systemd/system/sirius-powerd.service`：
  root system 服务，直写 backlight sysfs（无 sudo），
  multi-user 下自启（build-gnome 里 systemctl enable）。
- `90-sirius-power.gschema.override`：`power-button-action=nothing`，
  睡眠全 nothing，`idle-dim=false`，`idle-activation-enabled=false`。
- `sirius-gnome-blank` 保留但无事可做（saver 永不翻转）；logind 的
  HandlePowerKey* 留作 backstop（按键到不了 logind）。

## 验证

- mock 按键：新版 uinput `UI_SET_*` 传的是寄存器值不是指针
  （传指针地址一定大于 EV_MAX，直接 EINVAL；`struct uinput_setup`
  走不通时用老式 `write(uinput_user_dev)` + CREATE，一次写对 1116 字节）。
  见 workspace/mock-press.py（任意 keycode，libc ioctl 传值，见注释）。
- 按压矩阵：灭→亮→灭→亮，每下即时；托盘锁屏→按电源唤醒；
  60 秒无操作自动灭，触摸/音量/电源任意活动唤醒。
- 排错看：`journalctl --user -u sirius-powerd`（每次按压都有 log），
  `/sys/class/backlight/ae94000.dsi.0/{brightness,bl_power}`（正常态
  bl_power 恒 0，出现 4 说明 mutter 又 KMS-blank 了）。

## 已知问题

- 灭屏时长跟随 Settings → Screen Blank（idle-delay），改完一分钟内生效；设 Never 则只手动灭屏。
- suspend-on-power 已死（by design）；真要 suspend 只能手动。
- 从 mutter KMS-blank 态恢复只在 settle 后可靠，锁屏后立刻秒按可能撞上
  blank commit 在途，多按一次即可。
