# 音频 bringup（ADSP + 声卡 + 喇叭，2026-10-03 可出声）

状态：ADSP 稳定（无 DOG），声卡 card0 正常，TAS2557 经 PRI_MI2S_RX 出声，PipeWire 软音量。


## 2. 启动链路（全，音频视角）

```
fastboot [boot: Image.gz + sirius dtb + initrd] [vendor: vendormod.img] [userdata: rootfs]
  |  (换大版本内核才需 fastboot erase dtbo；见 boot/build_boot.sh)
  v
kernel (cmdline root=mmcblk0p81)
  +-- initrd：RNDIS 早联网（ssh 172.16.42.1）+ 挂 rootfs + switch_root
  +-- userdata rootfs：udev/systemd
  |     /usr/lib/modules/<ver>  <- bind /mnt/vendormod（mmcblk0p80，ro）
  |     /usr/lib/firmware       <- 同上（modules + firmware 全在 vendor 分区）
  +-- remoteproc 起 ADSP（/lib/firmware/qcom/sdm710/pyxis/adsp.mbn，一次读入后进 fw cache）
  +-- adsprpcd x3（After qrtr-ns/pd-mapper，ADSP_LIBRARY_PATH=pyxis/adsp）推送用户 PD 的 so
  +-- APR 音频服务齐（q6core/AFE/ASM/ADM）-> 声卡 probe 出 card0（ADSP 没好会 defer/重试）
        +-- tas2557 probe：拉 tas2557_uCDSP.bin（必需）+ ti/tas2557/tas2557_cal.bin（可选）
  +-- sirius-audio-init.service（After sound.target）：alsaucm 挂 Speaker 路由
  +-- 用户 session：pipewire + wireplumber（preset 自启），wpctl 控音量
```

注意：/tmp 重启清空（测试 wav、insmod 用的散模块放 /home/u57u 才 survives）；
vendor 是只读挂载，改文件先 remount rw，改完记得 ro 或重打镜像。
## 3. ADSP（Phase A，已完成）

现象（修之前）：no soundcards；q6core 报 Global_cal.acdb -2；每 40s USER-PD DOG 复位。

根因三条（独立问题）：
1. Global_cal.acdb 缺失：DT 点名 qcom/sdm710/pyxis/Global_cal.acdb，库里只有 sirius/Forte 版
   （两者 md5 相同），改名装机即解。
2. 缺 adsprpcd 三 daemon：本机 ADSP 用户态不走 TFTP（inotify 铁证：4 个启动周期零打开），
   用户 PD 的 so 靠 APPS 侧 adsprpcd 经 FastRPC 推送。自编译 qualcomm/fastrpc，
   三 unit（rootpd/audiopd/sensorspd），ADSP_LIBRARY_PATH 指向 pyxis/adsp。
3. 缺 stock rfsa 件：sensor PD 要 libSuperSensor_skel 等 23 个，dsp 分区里没有，
   从 AndroidBlobs sirius-user-9-9.8.22 取回。

验证：干净 reboot 后 140s+ 零 DOG，APR 音频服务齐（q6core/AFE/ASM/ADM/voice）。

## 4. 声卡与喇叭（Phase B，已完成）

- 机器驱动：移植 sdm670-mainline 的 sdm660-internal.c（只改 7.x API 名 + remove 改 void），
  compatible qcom,sdm660-internal-sndcard。DT 修三处：sound 去 cdc_pdm_default（gpio18-20 被相机
  CCI 占，pinctrl 静默失败是之前卡不出最大坑）、删第 6 条 DMIC 路由（widget 不存在）、
  spk_amp 改 ti,tas2557 + 真供电。
- 功放 = TI TAS2557（I2C 0x4C，reset gpio95，irq gpio96，I2S 16bit）：出厂 dtbo 的 sirius
  overlay fragment@65 原样；出厂 vendor 有 tas2557_uCDSP_aac/goer.bin（md5 相同，即本库文件）。
- 弯路归档（勿重走）：SEC_TDM_RX_0 + DSP_A/B 全死寂——总线就没接喇叭，驱动全绿零报错是常态。
  根因：出厂两处一致 SND_DEVICE_OUT_SPEAKER -> PRI_MI2S_RX（MIUI stock + crDroid 设备树）；
  另 FW 内 PLL 按 BCLK 1.536M 调、ti,i2s-bits=16 互证。修法：DT 加 pri-mi2s-rx-link +
  q6afedai dai@16（qcom,sd-lines=<0>，否则 AFE 报 no line is assigned）；机器驱动照抄上游
  sdm845 PRIMARY_MI2S_RX（MCLK_1 9.6M + PRI IBIT 1.536M，cpu BP_FP，codec BC_FC|NB_NF）。
- S16 硬约束（PipeWire 静音案）：机器驱动 startup 约束 S16_LE。本机 LPASS 总线 16bit，
  FE 通告 S24，PipeWire 开 S24，ASM->AFE 不转换=跑着无声；aplay 默认 S16 所以一直是好的。
  失败偏方存档：asound.conf 包 plug + WP 改 api.alsa.path（ACP 只要 hw 路径，sink 直接消失）。

## 5. 固件现状（firmware/）

- dsp-adsp/：36 文件 + adsp_avs_config.acdb。组成：DSP 点名的 31 音频/语音模块 + 6 系统 skel +
  CHRE/sensor 全套 + aptX + fastrpc_shell_0 + cellinfo（定位以后用）。已剔除：map_*.txt×4
  （工厂打包清单，跑起来没人读）、相机/计算/lowi/testapp 8 个。注意手机 vendor 里还是完整 72 件，
  下次重打 vendor 自动精简。
- rfsa-adsp/：23 件，sensor PD 必需（缺则 DOG），不动。
- acdb/：Forte 全套 + Global_cal（改名装机 pyxis/Global_cal.acdb）。
- tas2557/：uCDSP.bin（PPC SmartAmp，3 programs/6 configs，48k 固定 PRG0 Tuning Mode + CFG0，
  解析见 workspace/fwscan.py）+ 本机出厂校准 tas2557_cal.bin.sirius（persist/audio 原样，
  AAC 喇叭 Re=6.69，换机器要换自己的；装机 ti/tas2557/tas2557_cal.bin，缺省也能响）+ 报告 txt。

## 6. 用户态：UCM + PipeWire（pipewire-only）

- UCM：overlay/usr/share/alsa/ucm2/SE/{SE.conf,HiFi.conf}，单个 Speaker（hw:SE,0，cset 开
  PRI_MI2S_RX MM1，需 cdev 声明；目录名与 conf 文件名必须一致；${CardId} 本机未定义，写死）。
- 开机路由：overlay/etc/systemd/system/sirius-audio-init.service（alsaucm 挂 Speaker）。两 flavor 构建均 enable（server 镜像 2026-10-03 前漏了，已补）。
- PipeWire：两 flavor 均装 pipewire + wireplumber（gnome 无 pulse 层，wpctl 原生调音量）。alsa-utils 两 flavor 均装（server 镜像 2026-10-03 前只有 alsa-ucm-conf，无 aplay/amixer/alsaucm，已补）。
  功放 DSP 固定增益，系统音量=软音量（和原厂一致）；Digital RX1/2/3 只属于耳机通路，别动。
  已知：WirePlumber/ACP 目前不吃这份 UCM（sink 名 stereo-fallback），路由靠上面服务保证。

## 7. 排查手法备忘

- strings adsp.mbn 找 statichashes：拿 DSP 侧期望 so 清单，反推缺件。
- journalctl 看 apps_std_fopen_with_env failed：第一个报的就是缺的件。
- ADSP 重启不用整机：recovery 先 enabled，再 stop/start（crashed 直接 start 无效是正常的）。
- inotify 在 ro 的 vendor 分区上收不到事件（tmpfs 对照正常），别在这上面浪费时间。
- DAPM：/sys/kernel/debug/asoc/.../tas2557.1-004c/dapm/ 看 ASI1/DAC/ClassD/OUT 是否全 On，
  注意单次抓五个 widget（分开抓会有时序假象）。
- regmap：先 mount debugfs，/sys/kernel/debug/regmap/1-004c/registers 是 live 读数（REGCACHE_NONE），
  但只反映当前 book/page（enable 后停在 book100，小心误读）。
- 用户态无声先看组：`aplay -l` 报 no soundcards found，但 `sudo aplay -l` 能看到 SE，
  `/dev/snd/*` 属主 root:audio 660 → 用户不在 audio 组。2026-10-03 server 实测
  `getent group audio` 为空。修法：`sudo usermod -aG audio u57u` 后重连 ssh（新会话才生效）；
  构建侧两 flavor 的 usermod 已加 audio。
- 新服务等硬件一律写 device 单元，别写 target：`After=sound.target` 这类里程碑不保证卡在位（实测它只排在 alsa-state/alsa-restore 后面），要写 `After= + Requires=dev-snd-controlC0.device`（磁盘挂载同款写法）+ `Restart=on-failure` 兜底。
- server 镜像重启后路由回到 [off]：2026-10-03 前 server 没 enable sirius-audio-init，
  dmesg 会刷 `no backend DAIs enabled for MultiMedia1`。构建已补 enable；
  存量机器手动 `alsaucm -c SE set _verb HiFi set _enadev Speaker`。
- pkill -f 会杀自己：`pkill -f "aplay.*camp-test"` 的 pattern 含在自己 ssh 那行 bash 命令里，
  连自己一起杀，表现为 ssh 空输出 exit 1。改用 `pkill -x aplay` 或 bracket 写法
  `pkill -f "[a]play"`。（btmgmt 那条同理，见 STABLE-MAC §5。）
- wpctl 连不上先看 socket：`Could not connect to PipeWire` 时查 `/run/user/1000/pipewire-0`
  是否存在（只剩 pipewire-0.lock 说明 daemon 掉过）。aplay 直播不依赖 PipeWire，
  可先用它验证硬件链。
- 手机播 mp3 先转码：本机无解码器，PC 侧 `ffmpeg -ac 2 -ar 48000 -sample_fmt s16` 转 wav
  再 scp 到 /home/u57u（/tmp 重启清空，别放那），遵守 S16/48k 硬约束。
- 出厂对照：stock vendor.img（sparse，用 simg2img 解）+ dtbo.img（52 overlay 逐个拆，sirius 是
  含 tas2557 的那两个）+ mixer/platform_info（speaker 后端以 intcodec 的 backend 表为准）。

## 8. 固化与待办

- 内核 SIRIUS-DBG 打印已清（531015c36）。server 树与手机 Image 的关系：打印是编进 Image 的，
  下次重编 Image 才彻底消失，功能不受影响。
- 2026-10-03 补：两 flavor 默认用户进 audio 组；server 加 alsa-utils + enable sirius-audio-init（此前三处都缺，实测表现为用户态 no soundcards / 路由 [off]）。组与音频包收敛在 sirius-device.sh（SIRIUS_GROUPS / SIRIUS_AUDIO_PKGS），各 build-*.sh 引用变量；sirius-audio-init 的 enable 留在各 flavor 的 enable 列表（flavor-specific）。运行中 Image（#5）里 SIRIUS-DBG 还在，佐证打印是编进 Image 的。
- 待：耳机通路（INT0）未验证；单声道只响一边是否符合预期（出厂 mono_speaker=right）；
  UCM 让 ACP 认出来后删 audio-init 服务；README 状态表用户自己改。
