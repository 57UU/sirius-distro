# 图形栈版本与性能实测（Mesa 25.0.7 → 26.1.6，sirius / Adreno 616）

2026-10-19。设备从 Debian trixie 自带的 Mesa **25.0.7** 升到 trixie-backports 的
**26.1.6**，用 glmark2 / vkmark 做了受温度门控的对比。本文记录方法、数据、归因和回滚方式。

## 结论

- **OpenGL（freedreno）客户端快了约 10%**：同一合成器下 861 → 952（+10.6%），
  refract/shadow/build/shading 提升最大。
- **Vulkan（Turnip）客户端没有变化**：593 → 594（+0.2%），四个场景全部持平。
- **合成器（gnome-shell）在 26.1 上呈现更贵**：同一个旧 Turnip 客户端，
  旧合成器 666 → 新合成器 593（−11%）。所以整栈跑分里 vkmark 掉了 10.4%，
  但这不是驱动吞吐下降，而是每帧合成/呈现的开销。
- 整栈 glmark2 953 → 942（−1.2%，在噪声内），正好是「客户端 +10%」被「合成器 −10%」抵消。
- **KMS 直出复核**：停掉合成器直出原生分辨率，vkmark 分数回到旧合成器的量级（597 → 598，
  与旧合成器 666 按像素折算吻合），证实那 10% 只出在合成路径上。
- **同场景微基准**：同一网格/着色器下，重片元负载 GL≈VK（49.2 vs 49.0 fps）；
  540k 顶点单 draw VK 快 42%，512 draws VK 快 52~61%（每次 draw 开销 GL≈2.1µs、VK≈1.1µs）。
  即「像素吞吐相同，顶点/draw 提交 Turnip 更好」，与上面两条基于不同场景工具的结论并不矛盾。

## 版本对照

| 组件 | 升级前（trixie） | 升级后（本机现状） | 上游可及 |
|---|---|---|---|
| Mesa（freedreno + turnip） | 25.0.7-2+deb13u1 | **26.1.6-1~bpo13+1** | sid 26.2.5 |
| libdrm | 2.4.124-2 | 2.4.124-2 | sid 2.4.134 |
| 内核 | 7.2.3-sdm670+ | 7.2.3-sdm670+ | stable 7.2.11 / 7.3（10-18 发布） |
| linux-firmware（qcom/atheros） | 20250410-2 | 20250410-2 | backports 20260916-1 |

固件没有升：`a630_gmu.bin`、`a630_sqe.fw`、WCN3990 `firmware-5.bin` / `wlanmdsp.mbn`
在新版包里的 md5 与现有完全相同；linux-firmware 至今没有 `sdm710/pyxis` 目录，
`a615_zap.mbn` 继续用本仓库自备的一份。

## 测试方法

### 环境

- 设备：sirius，Debian 13.7，内核 7.2.3-sdm670+，GNOME **Wayland** 会话（autologin）。
- 画面：窗口模式 1280x720，经合成器呈现（与日常桌面路径一致，不是直扫）。
- 工具：glmark2 2023.01（`glmark2-wayland`，GL 4.6）、vkmark 2025.01（`--winsys wayland`）。

### 温度门控

每一轮开跑前都要满足：**电池（thermal_zone23）≤ 33°C、cpu0（thermal_zone1）≤ 36°C**，
且连续 4 个 15s 采样都在这条线以下（约 60s），才开跑；跑完立刻回到门控等待。

同时把 `pm660-charger` 的输入限流写 0（停充），避免充电发热把电池顶在 35–36°C。
每组用独立进程每 2s 采样电池/CPU/GPU 温度和 GPU 频率，落在 `.temps` 文件里。
实测每次跑峰值 cpu0 41–43°C，没有触发降频。

### 定频

不定频时 glmark2 只有 606–690（GPU 在 180–430MHz 之间跳），组内散度 12.6%，
没有可比性。所以测试期间：

```sh
echo 504000000 | sudo tee /sys/class/devfreq/5000000.gpu/min_freq   # GPU 钉最高档
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

测完恢复 `min_freq=180000000` 和 `schedutil`。定频后 glmark2 组内散度降到 5.7%。

### 负载

- OpenGL：8 个场景 × 5s —— `build (use-vbo)`、`texture (mipmap)`、`shading (phong)`、
  `bump (high-poly)`、`jellyfish`、`terrain`、`shadow`、`refract`
- Vulkan：4 个场景 × 5s —— `vertex`、`texture`、`shading`、`effect2d`

### 两组对照

1. **整栈**：旧系统（Mesa 25 + 旧合成器）vs 新系统（Mesa 26 + 新合成器），各 5 次。
2. **仅客户端 A/B**：都在**同一个 26.1 合成器**下，用 `/opt/mesa25` 覆盖层把旧
   EGL/GL/Vulkan 库塞给进程，交替跑旧/新客户端（GL 3 次、VK 5 次）。
   这样能把「客户端驱动」和「合成器」两个变量拆开。

覆盖层的写法（关键点都踩过）：

```sh
sudo dpkg-deb -x libgbm1_25.0.7-2+deb13u1_arm64.deb /opt/mesa25
sudo dpkg-deb -x libgl1-mesa-dri_25.0.7-2+deb13u1_arm64.deb /opt/mesa25
sudo dpkg-deb -x mesa-libgallium_25.0.7-2+deb13u1_arm64.deb /opt/mesa25
sudo dpkg-deb -x mesa-vulkan-drivers_25.0.7-2+deb13u1_arm64.deb /opt/mesa25
# GL 还必须补下面两个，否则 glvnd 仍旧加载系统的 26.1（表现为版本不生效或 eglGetDisplay 0x3000）
sudo dpkg-deb -x libegl-mesa0_25.0.7-2+deb13u1_arm64.deb /opt/mesa25
sudo dpkg-deb -x libglx-mesa0_25.0.7-2+deb13u1_arm64.deb /opt/mesa25
```

- GL：`LD_LIBRARY_PATH=/opt/mesa25/usr/lib/aarch64-linux-gnu`
  `LIBGL_DRIVERS_PATH=.../dri`
  `__EGL_VENDOR_LIBRARY_FILENAMES=/opt/mesa25/usr/share/glvnd/egl_vendor.d/50_mesa.json`
- VK：`VK_ICD_FILENAMES=/opt/mesa25/usr/share/vulkan/icd.d/freedreno_icd.json`
  （文件名是 `freedreno_icd.json`，不是 `.aarch64.json`）+ 同样的 `LD_LIBRARY_PATH`

## 结果

### 整栈升级（各 5 次，中位数）

| 项目 | 25.0.7 | 26.1.6 | 变化 |
|---|---|---|---|
| glmark2 总分 | 953（918–972） | 942（922–1016） | −1.2%（噪声内） |
| vkmark 总分 | 666（665–667） | 597（595–598） | **−10.4%** |

### 仅客户端 A/B（同一 26.1 合成器）

| 项目 | 旧客户端 25.0.7 | 新客户端 26.1.6 | 变化 |
|---|---|---|---|
| glmark2 总分 | 861（778–873） | **952（944–976）** | **+10.6%** |
| vkmark 总分 | 593（592–595） | 594（593–596） | +0.2% |

GL 分场景（中位 FPS）：

| 场景 | 25.0.7 | 26.1.6 | 变化 |
|---|---|---|---|
| refract | 84 | 158 | +88% |
| shadow | 521 | 714 | +37% |
| build (vbo) | 1619 | 1938 | +20% |
| shading (phong) | 1194 | 1370 | +15% |
| jellyfish | 753 | 799 | +6% |
| bump (high-poly) | 938 | 975 | +4% |
| terrain | 61 | 63 | +3% |
| texture (mipmap) | 1721 | 1710 | −0.6% |

VK 分场景（中位 FPS）：

| 场景 | 25.0.7 | 26.1.6 | 变化 |
|---|---|---|---|
| vertex | 668 | 668 | 0 |
| texture | 642 | 640 | −0.3% |
| shading | 602 | 603 | +0.2% |
| effect2d | 465 | 470 | +1.1% |

## 无合成器复核（KMS 直出，原生 1080x2244）

用 `systemctl stop gdm3` 把合成器整个停掉，让 benchmark 直接拿 DRM master 出图，
排除「窗口被合成器接管」这个变量：GL 用 `glmark2-drm`，VK 用
`sudo vkmark --winsys kms --winsys-options kms-drm-device=/dev/dri/card0:kms-tty=/dev/tty1`
（kms 后端要 root + 一个 VT，普通用户会报 `Failed to open VT`）。
GPU 仍钉 504MHz，测两次，结果几乎完全重复：

| GL 场景（glmark2-drm） | FPS | | VK 场景（vkmark kms） | FPS |
|---|---|---|---|---|
| build (vbo) | 683 | | clear | 1378 |
| texture (mipmap) | 601 | | cube | 1254 |
| bump (high-poly) | 469 | | desktop | 694 |
| shading (phong) | 445 | | vertex | 245 |
| shadow | 244 | | texture | 230 |
| jellyfish | 225 | | shading | 207 |
| refract | 50 | | effect2d | 184 |
| terrain | 41 | | | |

总分：glmark2-drm **343**（两次都是 343），vkmark kms **598**（两次都是 598）。

两个用处：

1. **验证合成器结论**。把 720p 的数据按像素数（1080x2244 是 720p 的 2.63 倍）折算，
   vkmark 四个重场景预测 254/244/230/179，实测 245/230/207/184，落在 ±10% 内，
   且整体量级对应「旧合成器 666」而不是「26.1 合成器 597」——说明那 10% 确实只发生在
   经合成器呈现的路径上，直出时不存在。
2. **GL 和 VK 在同一分辨率、同一呈现路径下的数字**。两套 benchmark 场景不同，总分不能直接比，
   跨工具「配对」也只能当参照：`texture` 601 vs 230、`shading`(phong) 445 vs 207 看着 GL 高，
   但那是两份不同的工作。严格的同场景对比见下一节。

坑：`glmark2 --off-screen`（pbuffer）虽然不是窗口，但在 Xwayland 下只有窗口模式的
约 1/4（320x240 build：731 vs 3044），走的是 pbuffer 拷贝路径，**不能代表 GPU 吞吐**，
别拿它做跨 API 对比；要排除合成器请用上面的 DRM/KMS 直出。

## 同场景 GL vs VK（自写微基准）

glmark2 和 vkmark 的场景不一样，光看总分说明不了「同一份工作谁快」。现成的双后端程序也走不通：

- SuperTuxKart 1.4（Debian 仓库版）`--render-driver` 只有 `gl` / `directx9`，Vulkan 后端 1.5 才有；
- Blender 4.3 的 `--gpu-backend opengl` 正常（720p/32 samples 约 104s），
  `--gpu-backend vulkan` 在 Turnip 上直接段错误。

所以写了个微基准 `workspace/bench/gfx/`：同一份网格、同一份 GLSL（std140 UBO）、同一个
1280x720 离屏目标，GL 走 EGL surfaceless + FBO，VK 走离屏 image + renderpass，
**不呈现、不过合成器**；GPU 钉 504MHz、温度门控，各跑 3 次。三种负载：

- `fill`：全屏三角形 + 48 次迭代的极重片元着色器（纯像素/着色器吞吐）
- `geom`：540k 顶点 / 180k 三角形，**1 次 draw**（顶点 + 光栅）
- `draw`：同一网格拆成 **512 次 draw**（每 draw 的提交开销）

结果（FPS，3 次几乎完全一致）：

| 负载 | GL (freedreno) | VK (Turnip) | 差异 |
|---|---|---|---|
| fill（重着色器） | 49.2（20.3 ms） | 49.0（20.4 ms） | −0.4%（持平） |
| geom（540k 顶点，1 draw） | 268.3（3.73 ms） | 380.4（2.63 ms） | **VK +42%** |
| draw（512 draws，VK 仅 GPU） | 205.4（4.87 ms） | 330.3（3.03 ms） | **VK +61%** |
| draw（512 draws，VK 含命令录制） | 207.5（4.82 ms） | 315.2（3.17 ms） | **VK +52%** |

由此推每次 draw 的额外开销：GL ≈ **2.1 µs**，VK 含录制 ≈ **1.1 µs**（仅提交 ≈0.8 µs）。

结论：

- **像素/着色器吞吐两边一样**（同一份重片元着色器，49.2 vs 49.0 fps），说明 ir3 编译出来的
  代码质量在同一水平，API 层没有额外损耗。
- **顶点与 draw 提交是 Turnip 更快**：540k 顶点单次 draw 快 42%，512 次 draw 快 52~61%。
  这和 vkmark/glmark2 的分数方向相反，因为那两个工具的场景不同、还叠了合成器。
- 局限：GL 侧用的是桌面 GL 4.6 core（不是 GLES 3.2），负载是单一着色器 + 单一网格，
  只能说明这份 workload 下的差别，不能外推成"Vulkan 一定更快"。

复现：设备上 `~/bench/gfx/`，`bash build.sh` 编出 `gfxbench`（需要 build-essential、
libegl-dev、libgles-dev、libvulkan-dev、glslang-tools），然后
`./gfxbench --api gl|vk --mode fill|geom|draw --draws 512 --width 1280 --height 720 --frames 60 [--timing full]`。

## 归因

- **合成器是 vkmark 掉分的唯一原因**。变量控制：同一个旧 Turnip 客户端，
  配旧合成器是 666，配 26.1 合成器是 593；而新合成器下新旧客户端都是 594。
  所以 26.1 的 gnome-shell 在呈现每帧时多吃约 10% 的时间。
  这与「Turnip 变慢」是两件事，纯 Vulkan 吞吐没有退化；KMS 直出复核也支持这一点。
- **GL 的提升在客户端侧**。refract（折射/多 pass）、shadow（阴影贴图）、
  build、shading 这几个 GPU 重的场景涨得最多，texture/terrain 这类填充率/几何
  固定的场景不动，符合 Mesa 26.x 的 ir3/NIR 与 tiling 改动方向（没有逐 commit 定位）。
- **整栈 glmark2 打平**是上面两者叠加的结果，不代表 GL 没进步。
- **跨 API 的绝对高低**：不能拿 glmark2 / vkmark 的分数或「语义相近」的场景配对下结论，
  它们不是同一份工作；严格同场景的结果是「像素吞吐持平，顶点/draw 提交 VK 更快」（见上一节）。

## 复现

设备上（`~/bench/`）：

```sh
# 整栈对比（5 次，GL+VK）
bash run_series.sh <label> both 5
# 客户端 A/B
bash ab_gl.sh <label> 3
bash ab_vk.sh <label> 5
# 无合成器（会停 gdm，脚本退出自动恢复）
sudo bash kms_series.sh 2
```

要点：

- 用 `systemd-run --user` 起长任务前先 `loginctl enable-linger u57u`，否则 SSH 断开即被杀。
- `glmark2 --off-screen` 在 Wayland 下会挂住（不出帧、5 分钟 0 输出）；换 X11 能跑，
  但走 pbuffer 拷贝，只有窗口模式的 1/4，别用它做对比。要无合成器就用 KMS 直出。
- KMS 直出期间 gdm 是停的（桌面会消失），脚本里务必用 trap 保证退出时 `systemctl start gdm3`。
- `glmark2 :quick` 全套要 333s，太长会累积热量，用上面的 8 场景自定义集。
- 温度门控的判据必须按 `millidegree / 1000` 换算（`32000` 是 32°C，不是 320）。
- 在 Windows 侧编辑过的 `.sh` 会带 CRLF，scp 前转 LF，否则远端报 `$'\r'` 语法错误。

汇总：

```sh
python3 parse_results.py results     # 整栈：总分 + 分场景
python3 analyze_ab.py  results       # A/B：old vs new
```

原始数据在 `workspace/bench/results/`：`<label>-<gl|vk>-r<n>.txt` 是程序输出，
同名 `.temps` 是 2s 间隔的温度/频率采样。

## 回滚

旧版 4 个 deb 备份在设备 `/home/u57u/bench/debs-old/`：

```sh
cd /home/u57u/bench/debs-old && sudo apt install ./*.deb && sudo systemctl reboot
```

backports 源在 `/etc/apt/sources.list.d/trixie-backports.list`（清华镜像），
不想要 26.x 就删掉它再 `apt update`。

设备当前保留 26.1.6；测试期间的熄屏（idle-delay）、充电限流、GPU min_freq、
CPU governor 均已恢复原值。
