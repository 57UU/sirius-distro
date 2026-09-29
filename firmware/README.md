# firmware canonical store (2026-09-15整理)

旧目录 firmware-out/ 保留不动(兼容历史路径),以后新文件放这里。

| 目录 | 内容 | 手机目标路径 | 来源 |
|---|---|---|---|
| touch/st_fts_v521.ftb | 触屏固件 97K | initramfs /lib/firmware/st_fts_v521.ftb (调试用);rootfs同名亦可 | vendor 4.9树 firmware/转制,见HANDOFF第2节 |
| gpu/a615_zap.mbn | GPU zap 14K, sha256 207b07c4... | /lib/firmware/qcom/sdm710/pyxis/a615_zap.mbn (rootfs,已装机验证GPU init成功) | ellyq/firmware-mainline-pyxis f2e4f88 dsp_fw/a615_zap.mbn |
| gpu/a630_sqe.fw | GPU SQE 34K, md5 9f2540d7... | /lib/firmware/qcom/a630_sqe.fw (Adreno 616 必需,server/gnome通用) | Debian trixie firmware-qcom-soc 20250410-2 (gnome树实测GPU正常) |
| gpu/a630_gmu.bin | GPU GMU 32K, md5 ab20135f... | /lib/firmware/qcom/a630_gmu.bin (Adreno 616 必需,server/gnome通用) | 同上 |
| pyxis-dsp/ | adsp/cdsp/venus/ipa/mba/modem/qdsp6m/wlanmdsp | 待定,先别装(仅GPU已验证) | 同上pyxis包,供音频/视频/modem立项用 |
| ath10k/board-2.bin.pyxis | pyxis校准BDF 26K | 暂不装!上游注释说装了WiFi崩 | 同上pyxis包calib_data,仅参考 |

校验: MANIFEST.sha256 (本目录)。
注意: modem.mbn 58M为完整基带,仅存档,不要乱刷。
| ath10k/board-2.bin.sirius | sirius自制board-2.bin 704K(28条目) | /lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin (已装机,原文件备份为board-2.bin.debian-orig) | ath10k-bdencoder(qca-swiss-army-knife)用modem分区原厂bdwlan生成,含variant=xiaomi_sirius,2026-09-18 |
| ath10k/firmware-5.bin.WCN3990 | WCN3990主固件索引 60B, md5 d16e3444... | /lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin (缺它则ath10k_snoc bind后无wlan0) | Debian trixie firmware-atheros 20250410-2 |
| ath10k/wlanmdsp.mbn.WCN3990 | WCN3990主固件 3.7M, md5 259b4f9e... | /lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn | 同上 |
| qca/crnv21.bin.sirius | QCA BT NVM 4587B，tag2烤BD 02:57:55:08:5E:02，md5 3947c734... | /lib/firmware/qca/crnv21.bin（此前rm掉，缺省地址5A:AD且mgmt写不上；此NVM开机即带地址） | linux-firmware原版crnv21改tag2字节 |
| ath10k/sirius-bdwlan/ | 原厂WLAN校准35个(bdwlan.*/bdf_*.bin) | 同上生成用料,不直接装机 | 手机modem分区image/原样拷出,2026-09-18 |
| acdb/Forte_Global_cal.acdb | 音频ACDB 26K, sha256 0db18192... | /lib/firmware/qcom/sdm710/sirius/Forte_Global_cal.acdb (q6core拓扑必需, 无则声卡不出) | AndroidBlobs/vendor_xiaomi_sirius V11.0.1.0 stock vendor |
| dsp-adsp/ | ADSP用户态48文件+avs配置 15M | /lib/firmware/qcom/sdm710/pyxis/ (tqftpserv就地供给, 缺则ADSP看门狗崩溃) | 手机dsp分区原样拷出+stock vendor adsp_avs_config.acdb |
| pyxis-phone/adsp.mbn+adsp.b00-b29 | 原厂ADSP分段(头8476B+30段, loader按phdr索引取bNN, RELOC布局) | /lib/firmware/qcom/sdm710/pyxis/ (单文件合并版会EINVAL, 必须分段) | 手机modem分区image/原样拷出 |
| pyxis-phone/adsp/ | 同上48+1文件再放一份带adsp/子目录 (tqftp请求形如adsp/xxx, 平铺命中不了) | /lib/firmware/qcom/sdm710/pyxis/adsp/ | 同上 |
