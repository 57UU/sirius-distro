# pyxis-phone：modem 大包（已入库，基本不变）

为啥叫 pyxis（小米 9 SE）而不是 sirius：这是 SDM710 在 mainline
里的固件路径规范，内核/rmtfs/pd-mapper 认死
`qcom/sdm710/pyxis/` 这个位置。内容全是 sirius 本机提取的，
名字只是门牌号，不要改，改了装机脚本处处要加映射。

2026-09-25 从调通的设备上原样入库（含 `modem_pr/` 约 200 个运营商配置文件）。
`mba.mbn` 为本机版（md5 `62520866a13dc47bd0460f7594cfd395`）。
完整性用上层 `MANIFEST.sha256` 校验。

注意：`a615_zap.mbn` 与 5 个 `*.jsn` 和 `../gpu`、`../jsn`
是同一文件（构建脚本两边都会拷，内容一致）。
基带运行时需要的就是这一套；`modem` 原始分区永远别写（见 docs）。