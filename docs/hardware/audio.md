# 音频

L410 的声卡由四部分组成：外置 codec 海思 Hi6405，把 codec 接到 SoC 的 SLIMbus，在内存和 SLIMbus 端口之间搬 PCM 的 ASP DMA，以及两颗 TI TAS2562 扬声器功放。驱动在内核仓库的 `sound/soc/hisilicon/hi6405/`（`CONFIG_SND_SOC_HI6405_L410`，内建），功放用主线的 `sound/soc/codecs/tas2562.c`。

现在能用的：扬声器放音（48 kHz）、耳机通路、4 个内置数字麦录音，PipeWire 里显示为 Speaker / Internal Microphone。耳机插拔、线控按键、耳麦录音的代码都在，还没有人插耳机验证过。DP/HDMI 音频没做。

## 硬件

| 部件 | 说明 |
|---|---|
| Hi6405（DA_combine_v5） | 寄存器走 SoC 的 "codec SSI" 窗口 `0xfe104000`（`fe104000.codec_controller`）：一个 32 位字对应一个 codec 字节，256 字节一页，页号写 0x1FD/0x1FE/0x1FF；读之前要先假读一次。8 位寄存器在 0x20007000-0x20007fff，版本寄存器 0x20007000 = 0x11（CS 版）。DIG 页等要 codec PLL 开着才能读写（resmgr 的 pll_for_reg_access） |
| 复位/中断 | 复位 GPIO198（gpio24@fa8ac000 第 6 脚），拉低 1 ms 再拉高；中断 GPIO200（gpio25 第 0 脚），低电平有效，复位期间须保持低 |
| 时钟 | `clk_codecssi`（crgctrl 门控，SSI 接口）；`clk_pmuaudioclk`（PMIC 0x42 bit0，19.2 MHz，给 codec 当 MCLK）；`clk_asp_subsys`（sctrl 门控，ASP 子系统） |
| 电源 | ASP 子系统是 IP 调压器 `ip@14 "asp"`（经 ATF SMC），SLIMbus 用 `slimbus-reg-supply`，ASP DMA 用 `asp-dmac-supply` |
| SLIMbus | Cadence SLIMbus manager（CSMI），在 ASP 里 `0xfa550000`，codec 是唯一的从设备（枚举到 5 个设备）。放音时时钟场景 CG_8/SM_4，平时 CG_10/SM_2 |
| ASP DMA | `0xfa54b000`，GIC SPI 248。PL08x 风格的通道，每个 SLIMbus 端口一条单声道 32 位（24 位左对齐）通道，LLI 乒乓。缓冲必须在 HiFi 数据保留区 `0x26780000`（ASP 总线能访问的地方） |
| 功放 | 两颗 TAS2562，I2C3 地址 0x4c（左）/0x4e（右），I2S 接 Hi6405 的 S4（I2S4）口，32 位槽宽，关断 GPIO241（gpio30@fa8b2000 第 1 脚）两颗共用 |
| 麦克风 | 4 个数字麦（DMIC）进 Hi6405；耳机麦走 HSMIC |
| 耳机座 | Hi6405 自带 MBHC（插拔和按键），另有 hs-type 选择 GPIO（gpio@fe004000 第 6 脚、gpio@fe005000 第 0 脚） |

不需要 HiFi DSP。L410 的厂商配置是 `codec_without_hifi`：放音、录音由 AP 直接编程 ASP DMA，把 PCM 搬到 SLIMbus 端口；HiFi 只在手机的低功耗、算法场景用。6.18 这边完全不碰 HiFi，不加载 DSP 固件，也不走 IPC。

## 驱动结构

一个组合驱动 `snd-soc-hi6405`（编进内核），内部按顺序注册 6 个平台驱动：

| 驱动 | 匹配 | 来源 | 作用 |
|---|---|---|---|
| `hisi_slimbus_driver` | `candance,slimbus`（`/slimbusmisc`） | 厂商 slimbus/ 目录，基本原样移植 | SLIMbus manager、时钟场景、track（AUDIO_PLAY D1/D2 对应 dport 0/1，录音 U1..U4 对应 dport 2/3/12/13）、runtime PM（2 s autosuspend，停时钟并关 pmu/asp 时钟） |
| `hi6405_ctrl_driver` | `hisilicon,codec-controller` | 新写，替换 hi_cdc_ctrl + hi_cdc_ssi | SSI 读写（页切换、假读、32 位 RAM2AXI）、复位脉冲、中断 GPIO；打印 `Hi6405 version 0x11, chip id ...`，读到的不是 0x11 就 defer（MCLK 还没开时读到 00/ff），然后 populate 子节点 |
| `hi64xx_irq_driver` | `hisilicon,hi64xx-irq` | 厂商，改用主线 irq_domain/wakeup_source | codec 中断复用 |
| `hi6405_codec_driver` | `hisilicon,hi6405-codec` | 厂商 codec/ 目录（DA_combine_v5，单 kcontrol "PC" 模式） | ASoC component 和 DAI `DA_combine_v5-audio-dai`，新增 DAI `DA_combine_v5-s4-dai`（I2S4 到功放）；MBHC 耳机检测接到 ASoC jack |
| `asp_pcm_driver` | `hisilicon,hi64xx-asp-dma` | 新写，替换 asp_dma + pcm_codec + slimbus_dai | ASoC component `asp-pcm` 和 CPU DAI `slimbus-dai`：放音 2 声道，录音 1-4 声道，48 kHz，S16_LE/S32_LE（软件转换成 24-in-32 单声道流）；period 固定 960 帧（20 ms），3-32 个 |
| `hi6405_card_driver` | `hisilicon,hi3xxx-hi6405`（`/sound_hi6405`） | 新写，替换 da_combine_machine | 声卡 "hi6405"：link 0 是 asp-pcm 到 Hi6405；link 1 是 Hi6405 S4 到两颗 TAS2562（codec-to-codec，48 kHz/16 位/2 声道，I2S，codec 出时钟） |

card 的 link init 按厂商功放配置（`tas2562_tas2562_configs.xml`）设 TDM 槽（左/右）、放大等级 0x1c、5 个初始化寄存器，以及空闲静音阈值（见下文）。

去掉的厂商代码：HiFi DSP/OM/VAD、dsm/rdr 黑匣子、powerkey 联动、多 kcontrol 模式、rear jack 和 USB 模拟耳机、看门狗、IV 反馈路由、hi6403 等其他 codec 的分支。

构建输入：

- `l410/configs/80-audio.config`：SOUND/SND/SND_SOC、TAS2562、REGMAP_I2C、HWSPINLOCK、SND_SOC_HI6405_L410，全部内建。
- `l410/dt/fixups.d/80-audio.dtsi`：reserved-memory `hifi-data@26780000`（0x580000，no-map）给 ASP DMA 缓冲；codec_controller 补 `clocks`（codecssi、pmuaudioclk）、`reset-gpios`、pinctrl（default/idle）；hi6405_codec 补 `hs-type-gpios`；禁用旧的独立 SSI 节点 `/codecssi`（寄存器已归 codec_controller）；slimbusmisc 补 `clocks`（pmuaudioclk、asp_subsys）；ASP DMA 节点补 `memory-region`、`clocks`、`#sound-dai-cells`；smartpa@4C/4E 改成 `ti,tas2562`，加 `sound-name-prefix` Left/Right 和 `shutdown-gpios`，删掉厂商子节点；`/sound_hi6405` 补 `model = "HUAWEI L410"` 和 asp-pcm、codec、功放的 phandle。

## 控件和 UCM

- 选路开关（厂商单 kcontrol 模式）：`Speaker Playback Switch`、`Headset Playback Switch`、`Mic Capture Switch`（4 个 DMIC）、`Headset Mic Capture Switch`，另有几个蓝牙相关的。card 另有 pin switch `Speaker Switch`、`Internal Mic Switch`。
- 功放：`Left/Right ASI1 Sel`、`Left/Right Digital Volume Control`、`Left/Right Amp Gain Volume`。
- jack：`Headphone Jack`、`Headset Mic Jack`（MBHC 报 SND_JACK_HEADSET 加 4 个按键）。
- DAPM：AIF widget 绑到 DAI 流名，D1_D2_INPUT 对 "Playback"，U1..U4_OUTPUT 对 "Capture"，S4_TX_OUTPUT 对 "S4 TX"。HSMICBIAS 从 DAPM_MIC 改成 DAPM_SUPPLY（主线 DAPM 不让 MIC widget 当中间节点）。

UCM 配置在 `system/hardware/ucm2/conf.d/hi6405/`，`system/hardware/install.sh` 把它装到 `/usr/share/alsa/ucm2/conf.d/hi6405/`。只有一个 verb `HiFi`，设备有 Speaker、Headphones、Mic、Headset。扬声器和耳机共用 PCM 0，所以互斥；耳机、耳麦按 `Headphone Jack`、`Headset Mic Jack` 的状态切换。BootSequence 先关掉所有选路开关，把 `Left/Right ASI1 Sel` 设成 Left/Right。codec 只在有流时给通路上电，开关只负责选路。

## 移植中修掉的问题

### 声卡绑定时卡死：io_mutex 自锁

6.18 的 `snd_soc_component_read/write/update_bits()` 持着 `component->io_mutex` 调 codec 的 `.read/.write`；厂商代码在回调里又做寄存器访问（访问 DIG 页会让资源管理器开 codec PLL，开 PLL 又要写寄存器），同一线程二次加锁，声卡绑定卡死，内核进不了 init。4.19 的这些 helper 不加锁。改法：厂商代码的寄存器 helper 直接调回调（`hi6405_compat.h`），由 SSI 控制器自己的锁串行化总线访问；厂商代码以外（card、TAS2562）仍用 ASoC helper（`ASoC: hisilicon: hi6405: vendor register IO bypasses the ASoC io_mutex`）。

### codec 读回 0

`clk_pmuaudioclk` 在 PMIC 驱动起来之前就被 prepare 了，MCLK 实际没开，codec 读回 00/ff。时钟和 PMIC 驱动补了 regmap 移交和对已 prepare 门控的补写；codec 控制器读到的版本不对时 defer，等 PMIC 起来后重试（`ASoC: hisilicon: hi6405: defer the controller while the codec does not answer`）。正常启动日志：`Hi6405 version 0x11, chip id 64 05 01 00`。

### 没有输出通路时放音卡死

放音的 SLIMbus track 由 codec 的 `AUDIO_PLAY_DRV` widget 事件启动，而 DAPM 只在有完整输出通路时才给它上电。耳机开关开着、没插耳机（jack pin 关）时 ASP DMA 收不到请求，aplay 10 s 后 EIO。card 加了一个由 `AUDIO_PLAY_DRV` 供电的 `ASP Playback Sink`，放音流运行时 track 总会起来（`ASoC: hisilicon: hi6405: keep the playback track up without an output`）。

### 扬声器爆音、声音结尾有回音

现象：KDE + PipeWire 下扬声器有爆音，声音结尾像有回音；1 kHz 测试音听起来正常。排查用了两个办法：一是只读 I2C 轮询两颗功放，每 5 ms 记 PWR_CTRL、TDM_DET（0x11，功放检测到的采样率和比例）、INT_LIVE/LTCH（即 `tests/audio-ampwatch.py`）；二是用内置麦克风录音，算 1 kHz 的 Goertzel 电平，判断扬声器有没有出声。查出三个原因：

1. 主因：ASP PCM 实际读取的位置比报告的 hw_ptr 超前 2 个周期。每次中断把"下一个周期"拷进 DMA 乒乓缓冲的空闲半边，但 `.pointer` 报的是正在播放的周期，驱动实际读到 hw_ptr + 1920 帧。PipeWire 实测只领先 hw_ptr 576-2496 帧，77% 的时间不到 1920，于是每个周期都有一截读的是还没写的位置，播出的是缓冲区一圈以前（32 × 20 ms = 640 ms）的旧数据：声音结尾出现 0.64 s 前的内容（回音），新旧数据接缝处就是爆音。1 kHz 正弦听不出来，因为 640 ms 正好是它的整数个周期，接缝处相位连续。

   改法：`.pointer` 报拷贝位置，`.delay` 报还在 DMA 块里的帧，标 `SNDRV_PCM_INFO_BATCH`（PipeWire 对 batch 设备会自动多留一个周期余量）。启动时 A 块放静音、B 块放第一个周期，所以启动只消耗 1 个周期；拷贝时应用还没写到的帧补静音，不再播旧数据（`ASoC: hisilicon: hi6405: asp-pcm: report the playback copy position`）。代价是 drain 在最后一个周期拷完时就结束，DMA 里最多 40 ms 被截掉；PipeWire 和 PulseAudio 不 drain 设备，不受影响。

2. 功放关断晚于 I2S4 停止。运行时关掉 codec 的 `S4_IF_TX_ENA`，两颗功放立刻报帧时钟无效，可见帧时钟随 `S4_TX_DRV` 停止。而 DAPM 下电顺序里 out_drv（第 5 步）在 dac（第 8 步）之前，所以每次停流时功放还在播放就丢了时钟，报 TDM 时钟错误，这也是爆音来源之一。改法：card 的 Speaker widget 在 `WILL_PMD`（任何 widget 下电之前）把两颗功放写成关断，再等 20 ms（和厂商 POWER_OFF 一样），这期间时钟还在，功放可以正常淡出（`ASoC: hisilicon: hi6405: shut the speaker amps down before I2S4 stops`）。启动侧没改：功放比帧时钟早几毫秒上电，等时钟有效后自己把音量淡入。

3. 功放空闲自动静音阈值。TAS2562 手册 8.4.2.3：输入低于 IDC 阈值（B0_P2 0x64-0x67）超过迟滞时间（0x6c-0x6f，默认 0x12c0 = 100 ms），功放就停止输出。芯片默认阈值约 -60 dBFS，桌面软件音量 28%（约 -33 dB）时，普通的轻声段落就会低于它，功放反复停、起。厂商每次上电写 -90 dBFS（0x00010945），card 初始化表照写（`ASoC: hisilicon: hi6405: vendor idle channel threshold for the speaker amps`）。

修复后实测：PipeWire 领先拷贝位置始终 ≥ 2176 帧；停流时两颗功放先关断（PWR_CTRL 0x0e，时钟仍有效），16-26 ms 后时钟才停，没有时钟错误；启动时仍有约 10 ms 时钟错误，是预期内的（见已知问题）。

### 新内核扬声器完全没声：功放音量读数

上游 tas2562 驱动的 `volume_lvl` 只在控件写入时赋值，所以 `Left/Right Digital Volume Control` 一直读 0（TLV 对应 -110 dB），而芯片复位后实际是 0 dB。第一次 `alsactl store` 把 0 存进 `/var/lib/alsa/asound.state`，下次开机 `alsa-restore` 写回，两颗功放就真的变成 -110 dB。驱动改成 probe 时 `volume_lvl = 110`，读数和硬件一致（`ASoC: tas2562: report the power-on digital volume`）。

用过修复前内核的系统，状态文件里可能已经存了 0，手动改一次：

```sh
amixer -c hi6405 cset name='Left Digital Volume Control' 110
amixer -c hi6405 cset name='Right Digital Volume Control' 110
sudo alsactl store
```

### 跑过 Kylin 之后麦克风录不了音

现象：机器热重启进过一次 Kylin 2403 之后，此后每次启动 6.18，麦克风都只录到一个 20 ms 的块，然后所有上行 ASP DMA 通道在第二块的第一个 burst 后报 ERR1，arecord EIO。换回更早的内核、再进一次 Kylin 都不好。

原因：`asp_pcm` 填的 LLI 节点里 BINDX/CINDX/CNT1 三个字从来没写过，用的是内存里原有的值；HiFi 数据保留区 `hifi-data@26780000` 里还留着 Kylin 2403 的 HiFi 固件写下的内容。热复位不清 DDR，也不复位 ASP 子系统。Kylin 2203 不会触发（它按 `codec_without_hifi` 配置，不用 HiFi）。改法是整个 LLI 节点都写全（`ASoC: hisilicon: hi6405: asp-pcm: write the whole LLI node`）。修复后在出问题的机器上 1/2/4 声道录音正常，DMA 错误 0 次。

一起加的排障手段：DMA 错误按类型统计，debugfs `asp-pcm/dmac`（DMAC 寄存器）和 `asp-pcm/asp_cfg`（`ASoC: hisilicon: hi6405: asp-pcm: report DMA errors per type, dump the DMAC`、`ASoC: hisilicon: hi6405: asp-pcm: dump ASP_CFG in debugfs and at probe`）。SLIMbus probe 时给前一个系统留下配置的 ASP IP 打复位脉冲（`ASoC: hisilicon: hi6405: slimbus: reset the ASP IPs the previous OS left configured`），这一条无害、保留，但不是这个问题的解法。

如果某个 6.18 问题"突然"出现、连旧内核也复现，先看中间是不是进过 Kylin（`journalctl --list-boots` 的空档），再查驱动有没有依赖从没初始化过的内存或寄存器（reserved-memory 保留区、ASP_CFG、常开域模块）。

## TAS2562 的状态位

- INT_LTCH0 bit2 是 TDM 时钟错误：I2S 时钟起停前后功放还在工作就会锁存。播放中实时寄存器为 0，所以测试里只报告、不算失败。真正的故障是过温/过流（bit0/1）和欠压/过压/brown-out（0x25 bit1-3）。这个锁存位读了不清零（要写 INT_CLK 0x30 的 INT_CLR_LTCH），所以 `amps` 里一直显示 0x04。
- 时钟错误持续超过 CLK_HALT_TIMER（INT_CLK 默认 52 ms）后，功放自己进入关断（PWR_CTRL 读回 0x0e），时钟恢复了也不会自己醒，要等下一次 DAPM 上电。厂商的 smartpakit 有中断处理，会重新初始化功放；6.18 没有。
- 采样率本身没问题：播放中 TDM_DET = 0x24（48 kHz，64 fs），PipeWire 没有 xrun（`pw-top` ERR = 0）。

## 检查方法

```sh
sudo dmesg | grep 'Hi6405 version'                   # version 0x11, chip id 64 05 01 00
aplay -l; arecord -l                                  # 卡 hi6405
alsaucm -c hi6405 list _verbs                         # HiFi
amixer -c hi6405 cget name='Left Digital Volume Control'   # 110
cat /proc/asound/card0/pcm0p/sub0/status              # 放音时 appl_ptr - hw_ptr 始终为正
sudo cat /sys/kernel/debug/hi6405-card/amps           # 两颗功放的 PWR_CTRL、PB_CFG1、TDM_CFG2、中断状态/锁存（绕过 regcache 直接读）
```

debugfs 里还有：`/sys/kernel/debug/hi6405/registers` 按厂商 `/proc/audio/rr` 的格式（`w 0x%08X 0x%08X`）导出 IO/CFG/ANA/DIG 页，能直接和厂商内核的输出 diff，写 `"<reg> <val>"` 可以改寄存器；`/sys/kernel/debug/asoc/hi6405/` 是 DAPM widget 状态；`/sys/kernel/debug/asp-pcm/{dmac,asp_cfg}` 见上文。

`tests/audio.sh`（root，需要 alsa-utils、python3，没人听也能跑）：dmesg 里有 `Hi6405 version 0x11`；没有音频设备停在 deferred；声卡 hi6405、`pcmC*D0p/c`、关键控件都在；扬声器放 4 s -30 dBFS 1 kHz，查 aplay 成功、hw_ptr 前进、ASP DMA 中断 ≥ 150 次、DAPM（AUDIO_PLAY_DRV、Speaker Playback、S4_TX_DRV）上电、两颗功放 PWR_CTRL 为工作态且无过温/过流/欠压；耳机开关放 2 s；DMIC 录 3 s，按峰值和取值种类判断不是静音；打印 jack 状态（插拔没人做时 SKIP）。寄存器、DAPM、功放状态导出到 `$AUDIO_DUMP_DIR`（默认 `/tmp/l410-audio`）。

`tests/quick.sh --only audio` 另外查功放音量读数和 `asound.state` 里存的功放音量（都应 > 0）、SLIMbus 空闲时 runtime suspended、UCM、PipeWire 默认输出是 hi6405、放音结束 0.6 s 后两颗功放都已关断。

`tests/audio-ampwatch.py [秒数]`（root）：只读监视两颗功放，用 I2C_RDWR 原子读，不写页寄存器，不打乱内核 regmap 的页缓存，每 5 ms 打印 PWR_CTRL、TDM_DET、中断位的变化。验证爆音修复时，一边跑它一边放一段有停顿的声音，再等流停掉：停流时应先看到 PWR=0e，约 20 ms 后才出现 TDM_DET 无效，LIVE0 不再出现 0x04。

参考数值：扬声器放音时 hw_ptr 0.5 s 前进 24000 帧（正好 48 kHz），4 s 内 ASP DMA 中断 201 次（20 ms 一个 period）；功放 PWR_CTRL=0x0c（工作，I/V sense 关），实时中断寄存器 0x1f/0x20 全 0；安静房间里 DMIC 录音两个声道峰值约 110-128、RMS 约 32。

用内置麦克风判断扬声器有没有出声时，先看 `wpctl get-volume @DEFAULT_AUDIO_SINK@`：输出音量很低（比如 5%）时这类检查会误判失败。

还没进 Debian、没有网络的早期阶段，同一套检查可以放进 initramfs 跑（`tests/audio-probe.sh`），见 [dev/README.md](../../dev/README.md)。

## 已知问题

- 耳机/耳麦插拔、线控按键、耳麦录音需要人插耳机验证；UCM 的耳机切换也一样。
- 每次时钟起停后功放留一个锁存的时钟错误位。启动时约 10 ms 的时钟错误是预期内的：功放比帧时钟早几毫秒上电，等时钟有效后自己淡入。
- 时钟错误超过 52 ms 后功放会自己关断，6.18 没有厂商那样的中断处理把它叫醒，要等下一次放音。
- TAS2562 的 I/V sense 反馈（厂商用在喇叭保护算法里）没用上；放大等级按厂商 0x1c。
- 厂商初始化里 B0_P253 的 ICN 修正位、Book100 P7 的 Class-H "kink" 修正，在上游 regmap 范围（book 0、page 0-4）以外，没写。B0_P1 0x08（厂商关掉了热折返）在范围内，有意没写，保留热保护。
- drain 最多截掉末尾 40 ms（见上文），只影响直接 drain 设备的程序。
- DP/HDMI 音频没做。厂商做法是 `dp_audio@0`（codec DAI `dp-playback`）加 `hisi-pcm-dp`（ASP 的 HDMI DMA 通道，`dp_audio_pll` 393.216/361.2672 MHz，缓冲在 HiFi 区的固定位置）加 `hisi_dp_machine`，DP 控制器侧的音频配置在厂商 DRM 驱动里。6.18 上应由 DP 驱动注册 `hdmi-codec`，再加 ASP HDMI DMA 的 PCM component 和一个 DP link；DP 输出本身还没有，见 [graphics.md](graphics.md)。
- 键盘上的静音灯不会随静音自动亮灭，见 [laptop.md](laptop.md)。

## 试过但没用

- 功放空闲静音的迟滞写成 0xffffffff：功放直接完全静音。
- 提前打开 `S4_IF_TX_ENA`，或放音中把它关掉再打开：帧时钟不稳（TDM_DET 在 0x24 和 0x7c 之间来回跳），52 ms 时钟错误后功放自己关断。
- INT_CLK.CLK_ERR_PWR_EN（按时钟有效与否让功放自动上下电）：能出声，但启动时照样报时钟错误，没有好处。
- WirePlumber 给扬声器 sink 设 `session.suspend-timeout-seconds = 0` 和 `api.alsa.headroom = 2048`：能把爆音和回音压下去，但只是绕开了 PCM 位置报错的问题，内核修好后不需要。
- 麦克风录音坏掉时给 ASP IP 打复位脉冲：不解决问题，根因是 LLI 节点没写全。
