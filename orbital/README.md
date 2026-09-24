# Orbital（上游仪表盘占位，不 vendor 源码）

上游：https://github.com/AthBe1337/Orbital
手机上没有源码时（需联网，IPv6 可用）：

```bash
sudo apt-get install -y cmake g++ git qt6-base-dev qt6-declarative-dev \
  libgl-dev libegl-dev pkg-config libdrm-dev
git clone https://github.com/AthBe1337/Orbital
cd Orbital && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j8
```

sirius 实测映射（`orbital.service` 已按此配好，见 rootfs/overlay）：

```text
触摸   /dev/input/event3（fts），inhibit 同目录 inhibited 节点
电源   故意配错（/dev/input/sirius-nopower）—— 电源归我们的 triggerhappy，
       不让 Orbital 碰 DPMS；音量 /dev/input/event1（下）,/dev/input/event2（上）
缩放   QT_SCALE_FACTOR=2.2；以 root 跑（input/backlight/DRM master 都要权）
```

注意：Orbital 自己没有自动息屏，息屏仍靠我们的 `sirius-idle-watch`；
两者分工见 docs/SERVER-MODE.md。