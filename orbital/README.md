# Orbital（fork submodule，不 vendor 源码进主库）

源码：`orbital/orbital-src`（submodule，fork https://github.com/57UU/Orbital，跟踪分支 `sirius/auto-screen-off`；上游基线 AthBe1337/Orbital commit `77a95d9`）。
主库只记 submodule 指针（gitlink），源码改动去 submodule 里提交再回主库 `git add orbital/orbital-src` 记新指针。
获取与更新：

```bash
git clone --recurse-submodules https://github.com/57UU/sirius-distro
# 已有 checkout：git submodule update --init --recursive
cd orbital/orbital-src && git pull   # 跟 sirius/auto-screen-off 最新
```

手机编译，在 submodule 目录里：
```bash
sudo apt-get install -y cmake g++ git qt6-base-dev qt6-declarative-dev \
  libgl-dev libegl-dev pkg-config libdrm-dev
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j4
# 产物 build/Orbital → 烤进 rootfs 见 ../rootfs/orbital-pkg/README.md
```

sirius 实测映射（`orbital.service` 已按此配好，见 rootfs/overlay）：

```text
触摸   /dev/input/event3（fts），inhibit 同目录 inhibited 节点
电源   真实键 event0（pmic pon pwrkey，已核对；ORBITAL_POWER_KEY_PATH）
       —— 短按 toggle，长按 1.5s 退出重启；音量 /dev/input/event1（下）,/dev/input/event2（上）
缩放   QT_SCALE_FACTOR=2.2；以 root 跑（input/backlight/DRM master 都要权）
```

注意：设置持久化走固定文件 /etc/orbital/Orbital.conf（显式 IniFormat 路径，不依赖 $HOME——systemd 服务默认没有 HOME，用 QSettings 用户域会静默回默认值，踩过）。
自动息屏已内建（DisplayBackend idle 计时 + 设置→Screen Off Time，
0.5~30min 可调或从不；QSettings 持久化到 /etc/orbital/Orbital.conf）。分工见 docs/SERVER-MODE.md。