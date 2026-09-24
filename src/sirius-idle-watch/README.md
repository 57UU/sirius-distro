# sirius-idle-watch：输入空闲灭背光（C 版）

`idle-watch.c` 自包含（仅 libc，无第三方依赖），`select()` 睡眠等事件，
空闲超时才 fork 一次 `sirius-screen auto-off`。常驻 ~100KB，idle 时 0% CPU。
对比：旧 python 版常驻约 10MB。

```bash
aarch64-linux-gnu-gcc -O2 -Wall -o sirius-idle-watch idle-watch.c
```

成品直接拷到 rootfs `overlay/usr/local/sbin/sirius-idle-watch`
（同名替换，原 python 版退役），service 文件不用动。
新接入的输入设备下次超时时自动拾取；拔掉的自动剔除。