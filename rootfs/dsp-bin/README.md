# dsp-bin：自编译底层二进制（烤进 rootfs）

- `pd-mapper`：Qualcomm PD 映射服务，`/usr/local/bin/pd-mapper`。
  源码见 `../../src/pd-mapper/README.md`（上游 + 本地构建说明）；
  没有编译环境时直接用本目录成品（手机现行验证版）。
- `adsprpcd` + `libadsp_default_listener.so.1.0.0` + `libadsprpc.so.1.0.0` + `libyaml-0.so.2.0.9`：
  Qualcomm FastRPC ADSP 用户态装载服务（一式三份：`adsprpcd`/`audiopd`/`sensorspd`），
  装机 `/usr/local/bin/adsprpcd` + `/usr/local/lib/`（建 `.so.1`/`.so` 软链后 `ldconfig`）。
  源码 https://github.com/qualcomm/fastrpc，自编译：`./gitcompile --host=aarch64-linux-gnu`
  （构建机需 `libyaml-dev:arm64 libbsd-dev:arm64 libmd-dev:arm64` + `PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig`）。
  没有编译环境时直接用本目录成品（手机现行验证版，main@2026-10-02）。
  对应 unit：`overlay/etc/systemd/system/adsprpcd-{rootpd,audiopd,sensorspd}.service`，
  环境变量 `ADSP_LIBRARY_PATH=/usr/lib/firmware/qcom/sdm710/pyxis/adsp`。
- 运行时依赖：libbsd0（已显式钉死在 build-gnome.sh / build-server.sh 的 apt 列表，勿删）；
  libyaml-0.so.2 用本目录自带（dpkg 不管，装机建软链 + ldconfig，见对应 unit/装机记录）。
