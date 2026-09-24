# sirius-remodeset：无头启动显示解卡工具（自研）

无头启动后 fbcon 提交卡住，一次完整 DRM modeset 即可解卡并刷出控制台。
本工具对 DSI-1 做 1080x2244 modeset（fb=-1 沿用当前 fb），退出时
drm_lastclose 触发 fbdev restore。裸 ioctl 实现，无 libdrm 依赖。

```bash
aarch64-linux-gnu-gcc -O2 -Wall -o sirius-remodeset sirius-remodeset.c
```

调试血泪（修过，备忘）：GETRESOURCES/GETCONNECTOR 第二遍必须把
不需要的 list 的 count 置零，否则 NULL 指针进内核报 EFAULT；
SETCRTC 带 mode 时 fb_id 不能为 0（ENOENT），用 -1 沿用当前 fb。