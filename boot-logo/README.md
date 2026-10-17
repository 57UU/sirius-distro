# boot-logo

自定义启动 logo，**可选**——纯属外观改动，不刷也不影响系统任何功能。

开机时由 ABL 从 `logo` 分区读出显示。当前生效的改动：

- 开机 logo：Tux + GNU/Linux（黑底，1080x2244）
- fastboot splash：已清空，进 fastboot 显示文本界面
- 充电画面、"system destroyed" 画面：保持原厂

## 文件

- `logo-new.7z` — 新制作的Linux Logo启动图片（解压得 logo-new.img，32 MiB）
- `tux_big.png` — 合成用的 Tux 素材

## 刷入

```sh
fastboot flash logo logo-new.img && fastboot reboot
```

## 恢复出厂

刷原厂固件包里的 `logo.img`。

## 想改图

格式与槽位说明见 `docs/BOOT-LOGO.md`：BMP 必须 1080x2244 24bpp，五个槽位原位替换，头部与未改的槽位需逐字节保持不变。
