# sirius-powerd：电源键 + panel 常驻服务（自研）

独占 pmic 电源键（EVIOCGRAB event0），按一下翻转 OLED（只写 brightness，
永不碰 bl_power），监听全部 input 做 60 秒无操作自动灭屏。
GNOME 彻底退出灭屏链。裸 libc 实现，无第三方依赖。

```bash
aarch64-linux-gnu-gcc -O2 -Wall -o sirius-powerd sirius-powerd.c
```

以 root system 服务运行，直写 backlight sysfs；saver D-Bus 调用只用于
手动锁屏唤醒。长按硬关机是 PMIC 硬件，不受 grab 影响。详见 docs/POWER.md。