# orbital-pkg：预编译 Orbital（烤进 rootfs /opt/orbital/）

`Orbital`（3MB，自研 QML 已编入；fork 57UU/Orbital `sirius/auto-screen-off` 构建，含内建自动息屏）+ 上游原样 `run.sh`。
构建脚本（`../build-server.sh`）把它拷到 `$R/opt/orbital/`，
service（`../overlay/etc/systemd/system/orbital.service`）用 sirius
环境变量启动（触摸 event3、音量 event1,event2、电源真实键交 Orbital；外挂息屏守护已删）。

刷新方式：按 `../orbital/README.md` 在手机或容器里重编（记得切到 `sirius/auto-screen-off` 分支），
把新 `Orbital` 拷回本目录即可。Qt 运行库由构建脚本 apt 装
（qt6-base qt6-declarative qml6 模块 libgl/egl，见 build-server.sh）。