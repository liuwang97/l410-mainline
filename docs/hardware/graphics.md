# 显示与 GPU

L410 的内屏是一块 2160×1440 的 eDP 面板，信号路径是 Kirin 990 的显示子系统（DSS）→ MIPI DSI0 → TI SN65DSI86（DSI 转 eDP 桥）→ 面板。
GPU 是 Mali-G76 MC16，用主线的 Panfrost 内核驱动和 Mesa，不需要厂商的 DSS 驱动和闭源 libmali。

显示驱动 `kirin990-dss` 是新写的：开机时接管 UEFI 已经点亮的管线，关屏时按厂商的顺序把整条链断电，开屏时从复位重建。
DP/HDMI 输出没有做。

## 一览

| 部分 | 硬件 | 内核仓库里的位置 |
|---|---|---|
| 显示控制器 | DSS v510，扫描输出经叠加层 OV0 | `drivers/gpu/drm/hisilicon/kirin990/`（模块 `kirin990_drm`，DRM 驱动名 `kirin`） |
| DSI | DSI0，4 lane，每 lane 1248 Mbps | `kirin990_dsi.c` |
| eDP 桥 | SN65DSI86（I2C 控制器 fa04d000 上的 0x2c），eDP 4 lane RBR | `kirin990_edp.c` |
| 电源时序 | DSS 电源域和时钟、桥和面板供电 | `kirin990_power.c` |
| 背光 | SoC 的 BLPWM 输出（GPIO_161）+ 使能 GPIO_027 | `drivers/pwm/pwm-hisi-blpwm.c` + 主线 `pwm-backlight` |
| GPU | Mali-G76，16 核，GPU ID 0x7211 | `drivers/gpu/drm/panfrost/` |
| GPU 时钟 | `clk_g3d`，PMCTRL 硬件投票 | `drivers/clk/hisilicon/kirin990/clk-kirin-lpm3.c`、`drivers/soc/hisilicon/kirin-hw-vote.c` |
| 设备树修补 | | `l410/dt/fixups.d/60-graphics.dtsi`（显示、背光、GPU）、`90-perf.dtsi`（GPU 能耗模型和温控） |
| 内核配置 | | `l410/configs/60-graphics.config` |

## 显示

### 接管固件点亮的管线

UEFI 点亮整条内屏管线（DSS、DSI0、SN65DSI86、面板、背光），用读通道 RCH2（VG0）把 GOP 帧缓冲送进 OV0 的 0 层。
DSS 内部的 SMMU 全局旁路（SCR=0xf8001，SMR=0x1），帧缓冲在物理地址 0x62844000，stride 8640。
厂商的 `hisi,hisi-smmu-lpae` 软件 IOMMU 在主线没有驱动，设备树修补删掉了 dpe 节点的 `iommus`。

驱动 probe 时做这几件事：

1. 拿住 DSS 的 IP 电源域（media1、dsssubsys）和 7 个时钟，免得被当成没人用的资源关掉。
2. 从 DSI/LDI 寄存器读回模式：2160×1440，htotal 2320，vtotal 1480，标称像素时钟 206.016 MHz。
3. 实测一帧的周期，按实测值上报像素时钟（日志 `measured frame period`）。这块面板实际刷新率是 60.51 Hz。
   按标称的 60 Hz 上报时，KWin 用错误的周期排帧，空闲之后外推出错，会出现画面提前画完却晚一帧上屏。
4. 找出 UEFI 用的通道和层，移除 simpledrm，注册 DRM 和 fbdev（GEM DMA，缓冲区从 CMA 分配，限 32 位地址）。

DRM 驱动名取 `kirin`，Mesa 的 kmsro 靠这个名字把它和 Panfrost 配成一对：Panfrost 渲染，DSS 扫描输出。

UEFI 没有点亮屏幕时（冷启动路径），probe 用厂商的面板时序作为模式，第一次使能 CRTC 时从复位上电。

### 翻页、vblank 和提交

- 主平面更新：在 MCTL0 mutex 下改读通道的 DATA_ADDR0、STRIDE0、DMA 格式和 DFC 格式，置 RCH_FLUSH_EN，解锁后下一帧生效。只提供 32 bpp 格式。
- vblank 来自 DSI0 的 LDI 中断（设备树 interrupts 第 4 项，SPI 251，VSYNC 是 bit4）。
  驱动没有读硬件行计数，时间戳取自中断处理时刻，`kirin990_drm.vblank_filter`（默认开）把中断延迟的抖动滤掉。
- 非阻塞提交由 SCHED_FIFO 线程 `kirin-commit` 写寄存器（`kirin990_drm.rt_commit`，默认开）。
  原先 commit_tail 跑在普通优先级的 kworker 上：KWin 的实时线程按时提交了，真正写寄存器的线程在有负载时却可能错过 vblank。
- 提交顺序和 `drm_atomic_helper_commit_tail_rpm()` 相同：先使能 CRTC 再写平面，CRTC 关着时平面不碰硬件。
- 不接受其他驱动导出的 dma-buf（`kirin990_drm.foreign_import`，默认关）。DSS 只能经 32 位 DMA 窗口扫描物理连续的缓冲区，没有 IOMMU；
  Panfrost 等驱动的缓冲区既不连续也不在 4 GiB 以下，映射时先在 swiotlb 里反弹几毫秒，最后还是失败。
  Mesa kmsro 在 KWin 里会把每个客户端缓冲区都试着导入一次，每次在 KWin 主线程上卡 1-3.6 ms，开机日志里还有几十条 `swiotlb buffer is full`。
  直接拒绝之后这些停顿就没有了。
- LDI underflow 按厂商的办法恢复：屏蔽（粘滞的）中断、停 LDI、清 MCTL、等 D-PHY 进入 stop state、复位 DSI PWR_UP、重开 LDI。
  日志是 `LDI underflow #N, recovering`。正常使用中不应出现。

### 关屏断电

DPMS 关屏和系统睡眠都会关闭 CRTC。驱动按厂商的 bridge disable → encoder disable → bridge post_disable → crtc disable 顺序断电：
背光 → eDP 视频流 → LDI 和 D-PHY → 面板 VDD、桥 EN、桥 1.2 V/1.8 V → DSS 时钟和电源域。
开屏时反过来，从复位把整条链建起来，约 300 ms。

面板供电：固件设备树里 SN65DSI86 节点的 `product_type = 3`，对应厂商 `laptop_bridge.c` 里的 "laptop UA" 板型，桥和面板的供电都是 SoC GPIO：

| 信号 | GPIO |
|---|---|
| 桥 1.2 V | GPIO_105 |
| 桥 1.8 V | GPIO_047 |
| 桥 EN | GPIO_206 |
| 面板 VDD | GPIO_028 |
| 背光使能 BL_EN | GPIO_027 |

桥的参考时钟是 PMIC 的 clk_nfc（38.4 MHz）。EC 上的 `EC_1V2_EN`、`EC_DSI_VCCIO_ON` 属于另一种板型（"laptop U"，product_type 0），
这台机器的设备树里没有节点用它们，厂商内核也不碰，所以没有接进内核。
设备树修补在 dpe 节点上加了上面几个 GPIO、`hisilicon,edp-bridge`、`backlight` 和 `regulator_vivobus-supply`。

桥（照厂商的 `sn65dsix6.c`）：上电时 1.2 V、1.8 V 各等 20 ms，再开参考时钟、EN、面板 VDD；设参考时钟、关 HPD、等 100 ms，
经面板 DPCD 0x10A 打开 ASSR。DSI 起来之后配 4 lane DSI、EQ 0xFF、DSI 时钟档 0x7C、eDP 4 lane RBR、DP PLL，
做半自动链路训练（最多 3 次），训练后把 TX 摆幅写回 0x21（厂商注释说 WiFi 天线线离 eDP 线太近，不改会闪屏），
最后写视频时序、开视频流。面板断电后至少等 500 ms 才重新上电。

DSI：D-PHY PLL 和各 lane 时序按厂商 `get_dsi_dphy_ctrl()` 的公式，由 624 MHz 的 dsi_bit_clk 算出（每 lane 1248 Mbps，fbkdiv 130，posdiv 1）。
probe 时驱动把算出的主机寄存器和读回的 D-PHY test code 逐项和 UEFI 的设置比对，全部一致（日志 `computed setup matches firmware`）。
断电时停 LDI、关 D-PHY、复位 DSI（PERI_CRG PERRSTEN3 bit28）。

DSS：照厂商的 `dpe_on()`，先开 media1、vivobus、dsssubsys 电源域和时钟，再从复位写时钟门控、DBUF、DPP 旁路、pipe switch、中断、MIF、
SMMU（沿用 UEFI 的全局旁路）、MCTL、OV0 底层。重建之后主平面改走无缩放的通道 D1（MCTL 通道 1，DMA 0x53000），和光标一样整通道编程；
厂商的 V0 通道即使 1:1 输出也要配缩放器和锐化。LDI 在第一帧 flush 之后才打开，背光再晚 50 ms。

断电深度由 `kirin990_drm.power_off` 决定，运行时可写：

| 值 | 关掉的部分 | 说明 |
|---|---|---|
| 0 | 不断电，扫描源切回 UEFI 帧缓冲 | 旧行为，只在第一次断电之前有效 |
| 1 | 背光、面板、桥、DSI | DSS 保持供电和时钟，LDI 停 |
| 2 | 再加 DSS 时钟 | 和 1 一样省电：DSS 时钟另有持有者，引用计数不归零 |
| 3 | 再加 DSS 电源域 | 默认 |
| 4 | 再加 vivobus、media1 电源域 | 厂商的做法。**在 L410 上断电后约 1 s 整机硬挂死，不要用** |

4 级挂死时驱动这边已经没有任何寄存器访问，内核连 panic 都打不出来（看门狗半周期的 FIQ panic 也没有），只能等硬件看门狗复位。
vivobus/media1 后面还有别的部件依赖它们，是哪个没有查。

实测（电池供电，背光 50/100，整机功耗取 EC 的电压×电流）：

| 状态 | 整机功耗 |
|---|---|
| 亮屏 | 3.1-3.7 W |
| 关屏，1 级或 2 级 | 1.46-1.48 W |
| 关屏，3 级（默认） | 1.31-1.50 W |

`tests/display-power.sh` 跑 3 轮关屏/开屏，24 项全部通过，开屏 295-298 ms，链路训练每次一次成功。

### 系统睡眠

kirin990-dss 的睡眠回调是 `drm_mode_config_helper_suspend/resume`：挂起时关 CRTC，走的就是上面的断电路径（按 `power_off` 的级别，默认 3），
唤醒后从复位重建。`systemctl suspend` 唤醒后 252-337 ms 屏幕恢复。睡眠本身见 [sleep.md](sleep.md)。

### 面板 EDID

模式仍然来自接管的管线，物理尺寸和面板身份从 EDID 读：驱动经桥的 AUX 通道（I2C-over-AUX）读面板 EDID，
`drm_dp_aux` 只初始化不注册（面板断电时不能让别的代码用它），在 `get_modes()` 里调 `drm_edid_connector_update()`
设置连接器的 width_mm/height_mm 和 EDID 属性。读不到时尺寸保持 0×0。日志是 `panel EDID: <名字>, W x H cm image size`。
冷启动路径下 probe 时不读，第一次上电后再读。

有了物理尺寸之后，KWin 会据此重新算默认缩放，可能选 1.25。想要别的缩放比例在系统设置的显示设置里改。

### 硬件光标

`kirin990_drm.cursor_plane`（默认开）提供光标平面：读通道 RCH6/7，在 OV0 里叠在主平面上一层，按无缩放通道完整编程，预乘 src-over 混合，
最大 256×256（`cursor_width/height` 报 256）。
隐藏光标时不关层，而是换成一张 16×16 的全透明图，因为关 OV 层再写 OV0_FLUSH_EN 会让 LDI 永久 underflow。
Plasma 下移动光标、换形状、隐藏、拖窗口、反复最大化都没有 underflow。

只有主平面和光标两个平面，没有 overlay 平面。

### 背光

新写的 PWM 驱动 `pwm-hisi-blpwm`（匹配厂商的 `hisilicon,hisiblpwm` 节点）驱动 SoC 的 BLPWM 输出（GPIO_161，功能 1），
主线 `pwm-backlight` 管亮度，GPIO_027 是背光使能。

- 周期 497.8 µs（约 2 kHz），和厂商内核相同：90 MHz 时钟，DIV 0x37，800 个计数。UEFI 设的 26.7 µs 不沿用。
- 亮度 0-100 级（`brightness-levels`，单位是周期的 1/10000）。0 关背光；1 级是厂商的最低亮度，占空比 0.25%，脉宽 1.24 µs
  （厂商 `laptop_bridge.c` 里 bl_min = max/90，经 `level_map[]` 得 2/800）；1-100 级按 CIE 1931 明度升到 100%。默认 50 级，占空比 19%。
- 脉宽再短，面板可能完全不亮，所以 1 级就是下限。

### 为什么不用主线的桥和面板驱动

主线有 `ti-sn65dsi86`、`panel-edp`、`dw-mipi-dsi`，这里没有用：厂商的上电时序和几个板级修正（DSI EQ、训练后的 TX 摆幅）直接照搬更稳。

## GPU

### 驱动和上电

- 设备树修补把厂商给 kbase 写的节点（`arm,mali-midgard`、大写的中断名、gpu-supply、带电压的 v1 OPP 表）
  改成 `"hisilicon,kirin990-mali", "arm,mali-bifrost"`，中断名改成小写的 `job`、`mmu`、`gpu`。
- 供电：`mali-supply` 是 LPM3 管理的 IP 电源 "g3d"（ip-regulator-lpm，LPM3 IPC `{0x30004,0}`/`{0x30104,0}`）。
  LPM3 按频率自己配电压，所以 Kirin 990 的 compatible 数据设了 `supplies_are_switches`：OPP 表只写频率，调压器由 panfrost 直接 enable
  （`drm/panfrost: allow supplies that are only power switches`）。
- 每次上电做 PCTRL 胶合（`panfrost_gpu_hisi_kirin990_quirk()`）：`PERI_CTRL92`[16:0] 清零（关掉软件控制的 RAM 深睡），
  `PERI_CTRL93` bit1 置位（RAM 由硬件自动关断），`PERI_CTRL19`[11:9] 置位（256 字节条带哈希）。
- 厂商节点的 `system-coherency = <0x1f>` 是 kbase 的 COHERENCY_NONE，不表示 dma-coherent，修补里删掉了。
- 识别结果：`mali-g76 id 0x7211`，shader_present 0xffff（16 核），l2_present 0x1，渲染节点 `/dev/dri/renderD128`。

### 调频

- OPP 14 档，只有频率：166、185、208、230、253、277、304、332、375、418、461、509、557、600 MHz。调速器 simple_ondemand，采样周期 50 ms。
- LPM3 不理会设备树里写的 IPC 调频命令，回读一直是 166 MHz。厂商用的是 PMCTRL 硬件投票（`CONFIG_HISI_HW_VOTE_GPU_FREQ`），
  所以 xfreq 时钟加了可选属性 `hisilicon,hw-vote-channel`：`clk_g3d` 用 `"gpu-freq", "vote-src-1"`，经 kirin-hw-vote 投票，值以 MHz 为单位；
  投票模块没有 probe 时退回 IPC。`clk_g3d` 的频率读的是投票结果寄存器，也就是 LPM3 实际给的频率。
- 桌面合成只占 GPU 几个百分点，按占用率调频会一直停在 166 MHz；实测 332 MHz 起 KWin 才能保持 100% 双缓冲。
  所以 panfrost 里加了 msm 式的 boost，电源模式模块 l410-perf（`drivers/soc/hisilicon/l410-perf.c`）在出帧时还会给 GPU 设 332 MHz 下限
  （见 [../tuning/](../tuning/)）。

boost 参数在 `/sys/module/panfrost/parameters/`，倍数为 0 或 1 表示关。boost 由 SCHED_FIFO 线程 `panfrost-boost` 经 PM QoS 下发，
持续一个采样周期后自动撤销：

| 参数 | 默认 | 作用 |
|---|---|---|
| `idle_boost` | 2 | 空闲超过一个采样周期后的第一个 job，按当前频率 ×2 请求 |
| `deadline_boost` | 2 | fence 截止前 `deadline_margin_us` 还没完成，×2 |
| `deadline_margin_us` | 3000 | 截止前多久检查 |
| `wait_boost` | 2 | CPU 阻塞等忙着的缓冲区时 ×2 |
| `highpri_submit` | Y | job 提交走高优先级工作队列（只读） |
| `compositor_priority` | Y | 有 CAP_SYS_NICE 的打开者（KWin）走高优先级运行队列，和 Linux 6.19 的 JM 上下文优先级权限模型一致 |

另外，MMU 状态轮询间隔从 10 µs 改成 1 µs（`drm/panfrost: poll the MMU status every microsecond`）。
LOCK、FLUSH_PT 几微秒就完成，每次映射或解除映射缓冲区要等两次；按 10 µs 轮询，应用启动时建几百个缓冲区要在忙等里花几十毫秒。

温控：GPU 是冷却设备（`devfreq-fe140000.mali`），GPU 温区 90 °C 被动降频，用 IPA（power_allocator）。
能耗模型用厂商 kbase 的 `dynamic-power-coefficient` 8538 和厂商 OPP 表里的电压（`90-perf.dtsi`），电压只用于能耗模型，Linux 这边没有 GPU 调压器。

### Mesa 和桌面

- Debian forky 的 Mesa 26.1：OpenGL ES 3.1，桌面 OpenGL 3.1，渲染器名 `Mali-G76 MC16 (Panfrost)`。Debian 13 自带的 Mesa 25.0.7 也能用，渲染器名不带 MC16。
- KWin 用 GLES 合成：[system/perf/systemd/plasma-kwin_wayland.service.d-l410-gles.conf](../../system/perf/systemd/plasma-kwin_wayland.service.d-l410-gles.conf)
  设 `KWIN_COMPOSE=O2ES`。KWin 6.7.4 用桌面 GL 3.1 时，weston-presentation-shm 低延迟模式 10 s 掉 8 帧、67 帧；改 GLES 后 0、1、5 帧，
  KWin 渲染中位 2.1 ms，p99 4.3-6.1 ms，100% 双缓冲。
- Chromium 经 ANGLE 用 Panfrost，`chrome://gpu` 里 Canvas、合成、光栅化、WebGL、WebGPU 都是硬件加速，没有黑名单项。
- 没有 Vulkan：Mesa 的 PanVK 不接受 G76 所在的 v7 架构。
- 没有硬件视频解码：Chromium 的 VA-API 初始化失败，实际是软解。
- [system/mesa/](../../system/mesa/) 给 Mesa 的 panfrost 打了一个补丁（`0001-panfrost-convert-private-AFBC-resources-on-CPU-write.patch`）。
  panfrost 把大于 16×16 的纹理都建成 AFBC，CPU 每写一次都要建临时缓冲区、GPU blit、立即 flush，而 Qt Quick 的每个图标、每个字形都是一次上传。
  补丁让私有的 AFBC 资源第一次被 CPU 写时转成 u-interleaved 格式。系统设置启动时的 GPU 提交从 2626 次降到 64 次，
  开始菜单第二次起打开从约 300 ms 降到 43-48 ms。补过的 libgallium 装在 `/usr/local/lib/l410-mesa/`，Debian 的包不动；
  Mesa 升级后覆盖会自动失效（库名带包版本），apt 钩子会提示重编。设 `PAN_AFBC_CPU_WRITE=staging` 可退回上游行为。

### 实测

| 测试 | 结果 |
|---|---|
| kmscube 600 帧 | 60.5 fps，无 LDI underflow |
| modetest `-v` 翻页 | 60.51 Hz，跟 vsync |
| glmark2-es2-drm | 1545-1556 |
| weston（DRM 后端 + GL 渲染）+ glmark2-es2-wayland | 863-875 |
| GPU 调频 | devfreq 钉在 166 和 600 MHz，`clk_g3d` 读回一致 |
| 1 小时混合烤机 | GPU 负载连续 3600 s 正常 |

前四项是 Debian 13（Mesa 25.0.7）时测的。

## 怎么检查

### 快速检查

```bash
# 显示：实测刷新率、DSI 参数比对、EDID、underflow
sudo dmesg | grep -E "measured frame period|computed setup|panel EDID|LDI underflow"
modetest -M kirin -c | head -20      # eDP-1 connected，2160x1440，尺寸不是 0x0
modetest -M kirin -p                 # 两个平面：主平面和光标

# DSS 状态（debugfs 只有 root 能读）
D=$(sudo sh -c 'grep -l "^kirin " /sys/kernel/debug/dri/*/name' | head -1); D=${D%/name}
sudo head -2 $D/kirin_state          # power on, power-ups N, eDP link failures N；underflows 0
sudo cat $D/kirin_frames
cat /sys/module/kirin990_drm/parameters/power_off     # 3

# 背光：max 100，bl_power 0
cat /sys/class/backlight/backlight/{max_brightness,brightness,bl_power}

# GPU
sudo dmesg | grep -i "mali-g76 id"
F=/sys/class/devfreq/fe140000.mali
cat $F/available_frequencies $F/governor $F/cur_freq
sudo cat /sys/kernel/debug/clk/clk_g3d/clk_rate      # LPM3 实际给的频率
eglinfo -B -p gbm | grep -E "renderer|version"
```

自检套件也有显示和 GPU 两组，桌面开着也能跑，不抢 DRM master：`sudo bash tests/quick.sh --only display,gpu`。

### tests/graphics.sh

完整的显示和 GPU 功能测试，以 root 运行。它会停掉 sddm 和 tty1 的 getty 来独占屏幕，结束时恢复 getty，sddm 要自己 `systemctl start sddm`。
需要的软件包：kmscube、libdrm-tests（modetest）、glmark2-es2-drm、glmark2-es2-wayland、mesa-utils-bin（eglinfo）、weston。

检查项：panfrost 渲染节点和 GPU ID；kirin 的 KMS 节点；eDP 连接器；modetest 列出连接器；背光（调到 30% 三秒再恢复）；
eglinfo（GBM，渲染器必须是 Panfrost）；kmscube 600 帧不得 underflow；modetest `-v` 翻页频率在 50-70 Hz；
GPU 调频（devfreq 钉在最低和最高档，`clk_g3d` 读回必须等于请求值）；glmark2-es2-drm（≥ 100 分、Panfrost、无 underflow）；
weston（DRM 后端 + GL，tty7）+ weston-simple-egl + glmark2-es2-wayland；全程无 LDI underflow。

每项输出 `PASS`/`FAIL`/`SKIP`，最后一行 `RESULT:`。`MARK` 行写明这时屏幕上应该看到什么，有人看着屏幕时可以对照。

### tests/display-power.sh

关屏断电和开屏重建的测试。在 Plasma 会话里以桌面用户运行（需要免密 sudo）：

```bash
# 从 ssh 登录时先指向桌面会话
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
bash tests/display-power.sh 3 60     # 3 轮关屏/开屏，每次测功耗 60 s
```

- `LEVEL=0..3` 先设 `power_off` 再测。不要设 4。
- 脚本自己补 Wayland 环境（ssh 里没有 `WAYLAND_DISPLAY` 时 `kscreen-doctor` 会崩溃退出），在 `kde-inhibit` 下运行，免得 PowerDevil 中途调暗或锁屏。
- 每轮关屏/开屏期间把看门狗设成 240 s（`DEADMAN=` 可改）：挂死会自动复位，pstore 里的 `display off/on` 日志能看出停在哪一步。
  看门狗和 pstore 的用法见 [dev/README.md](../../dev/README.md)。
- 关屏后检查：`kirin_state` 为 power off；桥和面板 GPIO 全低；背光 `bl_power`；各时钟引用计数。
- 开屏后检查：LDI 在扫描；面板 DPCD `lanes 77 77 align 01 sink 01`；桥寄存器 `96=01`（主链路正常模式）；没有新的 underflow；背光开着。
- 拔掉电源时还测亮屏和关屏的整机功耗（EC 的电压×电流，10 s 更新一次）。
- 只读时钟引用计数，不读 `clk_summary`：它会重算分频，去读可能已经断电的 media CRG。

### debugfs

都在 `/sys/kernel/debug/dri/<n>/` 下：

| 文件 | 内容 |
|---|---|
| `kirin_state` | 第一行电源状态、上电次数、eDP 链路失败次数；第二行通道、层、underflow 数、vblank 数；上电时还有扫描相关寄存器快照 |
| `kirin_frames` | vblank 和翻页计数、翻页间隔分布、在消隐期内 flush 的次数、拒绝的外来导入数、underflow 数、帧周期 |
| `kirin_edp` | 把桥的寄存器和面板 DPCD 0x200-0x207 打进内核日志（正常时 lane 状态 `77 77`、对齐 `01`、同步 `01`） |
| `kirin_dump` | 重新转储 probe 时那几段 DSS 寄存器 |
| `devfreq_boost`（panfrost 的 DRM 设备） | GPU boost 统计 |

## 已知问题

- 自动测试只能看链路状态（面板 lane 锁定和同步、LDI 在扫描、没有 underflow），读不出画面内容：DSS 的输出 CRC 寄存器（GLB、DBG、DISP_CH、DSI）
  读出来是 0 或常数。断电重建后主平面换到了 D1 通道，画面是否正确要人眼确认。
- `power_off=4` 会挂死整机，原因没查。
- DSS 时钟断电后引用计数仍是 1，另一个持有者没有找出来，所以 2 级和 1 级一样省电。电源域关掉后时钟门控省不了多少，没再追。
- 背光最低档是否看得见、2 kHz PWM 有没有啸叫或闪烁，还没有人工确认；自动测试只核对了周期和亮度的读写。
- 重新登录（重启 sddm）后，PowerDevil 有时把亮度恢复成 0。0 级是关背光，屏幕看起来全黑。看一下 `/sys/class/backlight/backlight/brightness`，调亮即可。
- 空闲睡眠唤醒后亮度停在 11：这是 PowerDevil 空闲调暗留下的值，驱动从不改亮度。

## 没有做

- DP/HDMI：厂商的 DP 控制器驱动（hidpc，约 6000 行）、USB-C combo PHY 的 DP 部分（`hisi_usb_dp_ctrl`）、PS176（I2C4 的 0x48）都没有移植，DP 音频也没有。
- overlay 平面。
- Vulkan、硬件视频编解码。

## 试过但没用

- 隐藏 OV 层再写 OV0_FLUSH_EN（早期 kmscube 切模式、隐藏光标都这么做）：LDI 永久 underflow，黑屏。现在不切层，光标用透明图隐藏。
- 经 LPM3 IPC 给 GPU 调频：LPM3 不理，频率一直是 166 MHz。改用 PMCTRL 硬件投票。
- 用 DSS 的输出 CRC 判断画面内容：寄存器读出 0 或常数。
- 背光沿用 UEFI 的 26.7 µs 周期和 pwm-backlight 默认的 0-1777 级 CIE 表：亮度拉到最低（值 1）时脉宽只有几 ns，屏幕全黑。
- `power_off=4`（照厂商连 vivobus/media1 一起关）：整机挂死。
- 用全局 `PAN_MESA_DEBUG=noafbc` 代替 AFBC 补丁：Chromium 和 QQ 变慢，它们的渲染目标靠 AFBC 省带宽。
