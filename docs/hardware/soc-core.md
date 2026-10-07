# SoC 基础：时钟、IPC、硬件锁、DMA、引脚与低速总线

这一篇讲 Kirin 990 上其他驱动都要依赖的基础部件：时钟、和 LPM3 通信的 IPC mailbox、hwspinlock、外设 DMA、
硬件投票（PMCTRL），以及 pinctrl、GPIO、I2C、SPI、UART。

低速外设基本都能用主线驱动直接认厂商固件设备树：pinctrl-single ×8、pl061 GPIO ×37（带中断）、pl011 UART ×4、
pl022 SPI、DesignWare I2C ×4。固件 DT 里没有 `resets` 引用，不需要复位控制器。新写的驱动在内核仓库
[linux-l410](https://github.com/liuwang97/linux-l410)（分支 `l410-6.18`）：

| 部分 | 内核树里的位置 |
|---|---|
| 时钟 | `drivers/clk/hisilicon/kirin990/`（`clk-kirin.c`、`clk-kirin-pll.c`、`clk-kirin-lpm3.c`），头文件 `include/linux/clk/kirin.h` |
| IPC mailbox | `drivers/mailbox/kirin-ipc-mailbox.c`，头文件 `include/linux/mailbox/kirin-ipc.h` |
| hwspinlock | `drivers/hwspinlock/kirin_hwspinlock.c` |
| 外设 DMA | `drivers/dma/hisi-dma64.c` |
| 硬件投票 | `drivers/soc/hisilicon/kirin-hw-vote.c`，头文件 `include/linux/soc/hisilicon/kirin-hw-vote.h` |
| I2C | `drivers/i2c/busses/i2c-designware-platdrv.c` 加了 `hisilicon,designware-i2c` |
| 配置 | `l410/configs/10-soc-core.config`（上述驱动，加 PINCTRL_SINGLE、GPIO_PL061、SPI_PL022、SERIAL_AMBA_PL011、DMATEST） |
| DT 修补 | `l410/dt/fixups.d/01-psci.dtsi`、`08-i2c-recovery.dtsi` |

## 固件分工

Kirin 990 上很多事不归 Linux 管。移植时要先弄清楚哪件事归谁：

| 谁 | 管什么 | Linux 怎么跟它打交道 |
|---|---|---|
| LPM3（电源管理协处理器） | CPU 三簇、GPU、DDR 的调频调压与 AVS；外设电压；g3d、mmbuf 电源域；PPLL 投票；过温保护；deep 睡眠 | PMCTRL 硬件投票寄存器；IPC mailbox（`HISI_ACPU_LPM3_MBX_1` 时钟、`HISI_ACPU_LPM3_MBX_2` IP 电源域） |
| ATF（EL3） | 所有 PMIC 访问（SPMI）、大部分 IP 电源域开关、温度传感器读数、外设 DMA 通道 0、PSCI | SMC：0xc500eee0/0xc500eee1（SPMI）、0xc500fff0（IP 电源域）、0xc5009900（tsens）、0xc501de00（DMA 通道登记），见 [power.md](power.md) |
| UEFI | 点亮显示链，打开 ldo4、ldo23，配好 UFS 子系统时钟和 PCIe RC0 的门控 | Linux 接管它留下的状态 |
| 传感器 hub、TEE | 和 Linux 共用部分 hwspinlock、GPIO 组，对 IP 电源域投票 | hwspinlock，SCTRL+0x438 投票位 |

固件 DT 的 `/psci` 只报 v0.1，没有 SYSTEM_RESET，`reboot` 会挂住；`01-psci.dtsi` 把它改成 psci-1.0（固件实际是 PSCI v1.1）。
EFI 运行时服务的 GetTime 会缺页，要加 `efi=noruntime`，见 [../kernel.md](../kernel.md)。

## 时钟

### 注册方式

- 按固件 DT 一个节点一个时钟注册（`CLK_OF_DECLARE`，在 time_init 时）。容器节点（`clk-crgctrl` 等）在 DT 里是 disabled，
  所以时钟只能靠 `of_clk_init()` 注册；寄存器基址取父容器的 `reg`，和顶层的 `hisilicon,crgctrl`、`sysctrl`、`pmctrl` 等节点是同一块物理地址。
- 支持的类型：`hi3xxx-clk-gate`（PEREN/PERDIS）、`hi3xxx-clk-div`、`hi3xxx-clk-mux`、`clk-gate`、`clk-pmu-gate`、`hi3xxx-xfreq-clk`、
  `interactive-clk`、`kirin-ppll-ctrl`、`ppll-ctrl`（SCPLL）、`clkdev-dvfs`。fixed-clock、fixed-factor-clock 走主线。
- 分频器全是 `div = val + 1` 的 hiword 寄存器，用主线 `clk_divider` 加表实现；mux 用主线 `clk_mux`（hiword 和非 hiword 都有）。
- `clock-friend-names`（clk_timer5、socp、12 个 clkdev-dvfs 媒体时钟）：prepare/enable 时连带打开友时钟。
- 名字短于 16 个字符的时钟同时注册 clkdev（con_id 就是时钟名），厂商风格的 `clk_get(NULL, "clk_xxx")` 可以用。
- 启动末尾（late_initcall_sync）打印 `kirin-clk: N clock nodes, M without provider, K orphans`，正常是 502 个节点、0、0。
  内核参数 `kirin_clk_dump` 把每个时钟的频率和父时钟打进日志。

频率和厂商内核一致，`tests/soc-core.sh` 核对这几项（允许取整差 1 Hz）：clkin_sys 38.4 MHz，clk_ppll0 1660 MHz，clk_ap_ppll2 1920 MHz，
clk_ap_ppll6 1720 MHz，sc_div_aobus 37449142 Hz，clkmux_i2c 和 clk_i2c7 110666666 Hz，clk_uart4 166 MHz，uart6clk 19.2 MHz，clk_g3d 开机 166 MHz。

### PMIC 上的时钟

6 个 `clk-pmu-gate`（clk_abb_192、clk_nfc、clk_pmu32ka/b/c、clk_pmuaudioclk）的寄存器在 PMIC 里。时钟在 time_init 注册，
PMIC 驱动要到 SPMI 起来以后才 probe，所以 PMIC 驱动 probe 时调用 `kirin_clk_set_pmic_regmap()` 把 regmap 交过来。
在这之前被 prepare 的门控只记下状态，prepare 本身不失败；regmap 交过来时补写使能位，日志是 `kirin-clk: <名>: enabled in the PMIC`。
音频就是这样：clk_pmuaudioclk 在 0.518 s 被 prepare，0.551 s PMIC 到位后才写入，Hi6405 驱动 defer 后重试成功。

clk_abb_192 和 LPM3 共用，开关要经 hwspinlock 9 和 SCTRL SCBAKDATA12 投票。

### 外设电压与 xfreq 时钟

- `kirin_clk_set_perivolt_ops(ops)`：外设电压投票的回调，由 `kirin-peri-dvfs` 注册（见 [power.md](power.md)）。`peri_volt_hold/middle/low`、
  `clk_atdvfs` 和 12 个 `clkdev-dvfs` 时钟在 prepare/set_rate 时调用它（可睡眠上下文）；没注册时不动电压，`-ENODEV` 当成功。
- xfreq 时钟（cpu-cluster.0/1、clk_g3d、DDR）：频率从 SCTRL SCBAKDATA（0x41c）里的 OPP 下标读出，再到“clocks 引用本时钟且带 OPP 表”的
  节点里查表。启动时不写任何寄存器。set_rate 按 DT 描述发 LPM3 IPC `{set-rate-cmd, MHz}`，但 LPM3 不理 GPU 的 IPC 调频请求；
  现在 xfreq 时钟可以用 `hisilicon,hw-vote-channel` 指定一个硬件投票通道，`60-graphics.dtsi` 给 clk_g3d 配了 `gpu-freq`/`vote-src-1`。
  cpufreq 不经过这些时钟，直接投票。

### 真实门控

默认开（`clk: kirin990: gate clocks in hardware by default`）：引用计数降到 0 的时钟会在硬件上关掉，GPU 空闲 50 ms、I2C 等 runtime suspend
时时钟真的停了。内核参数 `kirin_clk_keep_on` 回到移植初期的行为（从不在硬件上关，相当于厂商的 `CONFIG_HISI_CLK_ALWAYS_ON`）；
`kirin_clk_gating` 仍然接受，等于默认值。

难点在共享父时钟。很多硬件用的是 UEFI 或固件打开的时钟，没有 Linux 驱动计数（显示、媒体总线等）；它们的父时钟（比如 `sc_div_320m`，
厂商内核里有 4 个用户）会在某个 Linux 驱动 runtime suspend 时被连带关掉。所以在 `subsys_initcall_sync`（IPC、hwspinlock 已就绪，
设备驱动还没 probe）把 `clk-kirin.c` 里 `kirin_clk_pinned[]` 列出的 73 个时钟永久 `clk_prepare_enable`，连同它们的父时钟一起钉住。
这 73 个是厂商内核稳态下 enable_count > 0 的时钟（去掉固定时钟），涵盖显示链（dss、edc0、mmbuf、txdphy0、blpwm）、USB、PCIe、音频
（asp_subsys、codecssi、pmuaudioclk）、总线和分频（sc_div_320m、div_sysbus_pll、ioperi、vivobus、clk_ppll0_media）、I2C、UART、SPI、DMA、看门狗。
所有启用的 PL011 的时钟也钉住，原因见下面 UART 一节。启动日志：`kirin-clk: gating on, 73 of 73 clocks pinned, <n> UART clocks`。

在整机上验证过：显示接管与扫描无 underflow、GPU、音频、WiFi、蓝牙、USB、UFS、I2C HID，桌面基准的帧率和不门控时相同。
某个驱动自己持有时钟以后，可以把对应条目从 `kirin_clk_pinned[]` 删掉；总线和分频类要一直留着。

UFS 子系统总线时钟（SCTRL 0x1b0 bit14 / 0x274）DT 里没有描述，没有注册，不受门控影响。

## IPC mailbox

- 控制器是 HiIPCV230，固件 DT 里有三个：`ipc@FE101000`、`ipc@FA899000`、`ipc@e5e01000`（NPU 的）。驱动是主线 `mbox_controller`：
  txdone 靠 ACK 中断，ACK 数据经 `rx_callback` 交回。
- probe 时不碰寄存器，每次发送前才解锁（NPU 下电时访问 e5e01000 会 SError）。
- 所有 RX mailbox 在 probe 时就挂好中断，没人监听也照样读出并 ACK，远端不会卡住。
- 便捷接口（`#include <linux/mailbox/kirin-ipc.h>`），`name` 是固件 DT 里 mailbox 子节点的 `rproc` 字符串，比如 `HISI_ACPU_LPM3_MBX_1`：
  - `kirin_ipc_send(name, msg, len, ack, ack_len)`：发送后睡眠等对端 ACK，ACK 数据拷回；IPC 没 probe 前返回 `-EPROBE_DEFER`。
  - `kirin_ipc_send_async(name, msg, len)`：任意上下文，排进有序工作队列（`name` 必须是常量字符串）。
  - `kirin_ipc_register_rx(name, nb)`：对端发给 ACPU 的消息，notifier 在进程上下文调用（action = 字数，data = `u32 *`）。
- 主线 mailbox 客户端也能用：给 IPC 节点加 `#mbox-cells = <1>`，参数是硬件 mailbox 号（DT `index` % 100），消息是 `struct kirin_ipc_msg`。
- debugfs：`/sys/kernel/debug/kirin-ipc/channels` 列出每个 mailbox 的方向和 sent/acked/timeout/rx 计数；
  `/sys/kernel/debug/kirin-ipc/xfer` 写入 `"<rproc 名> 字0 字1 ..."` 发一条并等 ACK，读回 `返回值 ACK×8`。
  无害的测试消息是 `HISI_ACPU_LPM3_MBX_1 0xd0002 0x0`（PPLL0 保持投票，厂商内核启动时也发）。

## hwspinlock

PCTRL 0x400 起 8 组 × 8 把，共 64 把锁，编号和 LPM3、传感器固件共用，所以 Linux 侧用到的锁号必须和厂商一致：

| 锁 | 用途 |
|---|---|
| 9 | clk_abb_192 投票（SCTRL SCBAKDATA12） |
| 19 | 外设电压投票（PMCTRL 字段） |
| 29 | media1/vivobus/dss 电源域投票（SCTRL+0x438） |

厂商的 pl061 节点带 `gpio,hwspinlock`，和传感器、LPM3 固件共用 GPIO 组时加锁。主线 pl061 不加锁，目前没发现冲突。

## 外设 DMA

`hisilicon,hisi-dma64-1.0`（fa000000），和 k3dma 同族，64 位地址。通道 0 归安全侧，要经 ATF SMC 0xc501de00 登记，Linux 不用。
只用 dmatest 验证过 memcpy：20 次 0 错，约 77 MB/s。SPI3 在 DMA 驱动出来之前一直 defer。

## 引脚与 GPIO

pinctrl-single ×8、pl061 ×37 都是主线驱动，厂商 DT 属性直接兼容。pl061 的 bank 带 `gpio-ranges`，申请 GPIO 线时会顺带切引脚复用。
笔记本外设用到的 GPIO 中断（gpio29 边沿/电平、gpio2、gpio24）和输出（gpio30）都验证过，见 [laptop.md](laptop.md)。

## I2C

主线 DesignWare 驱动直接驱动 fa04c000/d000/e000/f000，总线号来自 DT aliases：

| 总线 | 地址 | 设备 |
|---|---|---|
| i2c3（fa04c000） | 0x4c、0x4e | TAS2562 功放 ×2，见 [audio.md](audio.md) |
| i2c4（fa04d000） | 0x2c | SN65DSI86 DSI 转 eDP 桥（ID `68ISD`，rev 2） |
| i2c4 | 0x54 | WiFi 校准 EEPROM，见 [wifi-bt.md](wifi-bt.md) |
| i2c6（fa04e000） | 0x5d | 触控板（Goodix 27c6），I2C-HID |
| i2c7（fa04f000） | 0x3a | 键盘，I2C-HID |
| i2c7 | 0x38 | EC（带 PEC） |

功放在音频驱动给它上电、解复位之前不应答（NACK），这是正常的。

### 总线恢复

现象：长时间运行中，触控板所在的 i2c-6 先报 5 次 "lost arbitration"，然后每次传输都超时（"controller timed out"，i2c-hid 返回 -110），
触控板一直失效到重启。原因是某次传输被打断后从设备拉住了 SDA，而 6.18 的 DesignWare 节点没有配总线恢复。
要给 SCL 打时钟直到 SDA 释放，厂商内核用 DT 里的 `cs-gpios`（SCL、SDA）做这件事。

改法：`08-i2c-recovery.dtsi` 给四条总线加 `scl-gpios`/`sda-gpios`（开漏）和名为 `gpio` 的 pinctrl 状态，i2c-designware 在超时或总线忙时
调用 `i2c_generic_scl_recovery`。I2C 核心在 probe 取 GPIO 时把引脚切到 `gpio` 状态，取完切回 `default`。两个 IOMG 块上复用功能 0 都是 GPIO。

| 总线 | SCL / SDA |
|---|---|
| i2c3 | gpio005 / gpio006 |
| i2c4 | gpio029 / gpio030 |
| i2c6 | gpio237 / gpio238 |
| i2c7 | gpio177 / gpio178（`gpio@fa8aa000` 上 SCL 是 2 脚、SDA 是 1 脚，和另外三条相反） |

## UART

pl011 ×4 由主线驱动。两个要注意的地方：

- 主线 pl011 不认海思的 `clock-rate` 属性。蓝牙用的 BUART（uart4）要用 `assigned-clocks` 选 166 MHz，见 [wifi-bt.md](wifi-bt.md)。
- 真实门控打开后，root 读 `/proc/tty/driver/ttyAMA` 会在 `pl011_read` 上同步外部中止：serial_core 对没打开的串口也调 `get_mctrl`，
  而这时时钟已关。蓝牙驱动每次睡眠/唤醒都开关 uart4，问题会反复出现。所以所有启用的 PL011 的时钟都钉住，代价可以忽略。

## SPI

pl022 只有 SPI3 一个控制器。厂商 DT 里 SPI3 下的 `spi_dev31/32/33`（片选 1 到 3）被主线 pl022 拒绝（`cs1 >= max 1`），
这些子节点本来就没有驱动；TPM 子节点是 disabled。不影响使用。

## 看门狗

`arm,sp805`（fe026000）的 `pclk_wd0`（32.764 kHz）能解析。正式的看门狗驱动没开，SP805 留给移植用的 deadman 看门狗
（正式安装时不启动，见 [../../dev/README.md](../../dev/README.md)）。这台机器上 SP805 的中断走 FIQ，内核在超时一半时就 panic，满时硬复位。

## 硬件投票（PMCTRL）

频率和电压请求以“投票”的形式写进 PMCTRL 寄存器，由 LPM3 裁决。每个通道（little-freq、middle-freq、big-freq、gpu-freq、l3-freq、peri-volt 等）
有一个结果寄存器，每个投票者占一个字段。固件 DT 的 `hw_vote` 节点（`hisi,freq-hw-vote`）里，每个通道子节点有
`result_reg = <offset rd_mask wr_mask>` 和单位 `ratio`（频率是 MHz），下面的 `vote-src-N` 子节点有 `vote_reg`。

`kirin-hw-vote.c` 绑定 `/hw_vote`（PMCTRL 0xfff01000，只映射不占用，和时钟驱动共用无冲突），并创建 `hisi-hwvote-cpufreq` 设备。
写一票是一次写入：`wr_mask | 值 << (ffs(rd_mask) - 1)`（wr_mask 位告诉硬件更新寄存器的哪一半）；读结果寄存器得到 LPM3 实际给的值。
接口在 `<linux/soc/hisilicon/kirin-hw-vote.h>`：`kirin_hv_get(channel, src)`、`kirin_hv_set`、`kirin_hv_get_vote`、`kirin_hv_get_result`；
固件 DT 没描述的投票寄存器用 `kirin_hv_get_reg()` 按偏移和掩码拿。一个投票者只给一个用户：

| 通道 / 寄存器 | 投票者 | 用户 |
|---|---|---|
| little-freq、middle-freq、big-freq | vote-src-1 | cpufreq（`hisi-hwvote-cpufreq`，见 [power.md](power.md)） |
| gpu-freq | vote-src-1 | clk_g3d，Panfrost 调频，见 [graphics.md](graphics.md) |
| peri-volt | vote-src-1 | `kirin-peri-dvfs` |
| PMCTRL 0x270 | （DT 未描述） | DDR 最低频率，`drivers/devfreq/kirin990-ddr-devfreq.c` |

## 怎么检查

在 L410 上（屏幕开着）：

```bash
sudo bash tests/soc-core.sh
```

逐项输出 PASS/FAIL，退出码是失败数。检查内容：时钟报告（0 缺提供者、0 孤儿）、上面列的频率、IPC ×3 / hwspinlock / DMA 绑定、
一次 LPM3 IPC 往返和超时计数、dmatest memcpy、pinctrl ×8 / pl061 ×37 / pl011 ×4 / pl022 / I2C ×4 绑定、没有 defer 的设备、
SN65DSI86 ID、键盘和触控板 HID 描述符、EC 应答。关屏时整条显示链断电，读 `clk_summary` 和 SN65DSI86 两项会跳过。

手工看：

```bash
dmesg | grep kirin-clk                       # 502 clock nodes, 0 without provider, 0 orphans；gating on, 73 of 73 pinned
sudo cat /sys/kernel/debug/devices_deferred  # 应为空
sudo cat /sys/kernel/debug/kirin-ipc/channels
```

移植初期没有网络时，`dev/bringup/soc-core-probe-extra.sh` 和 `soc-core-repack-initrd.sh` 把这些检查塞进 initramfs，结果从 pstore 取回，
见 [../../dev/README.md](../../dev/README.md)。

## 已知问题与没做的

- DMA 只验证过 memcpy。UART4、SPI3 的外设 DMA 还没有真正的客户端跑过（蓝牙的 BUART 现在走 PIO）。
- 主线 pl061 没有 hwspinlock 包装。如果哪天 GPIO 方向或中断配置被改乱，要先查和固件共用的 GPIO 组。
- `kirin_clk_pinned[]` 还是按厂商稳态整表钉住，各驱动自己持有时钟后应逐项删掉。
- UFS 子系统总线时钟没有建模。需要时可以用 DT 修补加节点。

## 试过但没用

- 靠 `clk_ignore_unused` 保住固件打开的时钟：hi3xxx gate、pmu gate、interactive、clkdev-dvfs 没有 `is_enabled`/`is_prepared`，`clk_disable_unused()`
  本来就当它们是关的；bit gate 和 PLL 有 `is_enabled`，但都带 `CLK_IGNORE_UNUSED`。关断只来自引用计数，所以要钉住时钟。
- IPC 在 probe 时统一解锁三个控制器：NPU 下电时访问 e5e01000 直接 SError。
- clk_g3d 按 DT 发 LPM3 IPC 调频：LPM3 不响应，GPU 停在开机的 OPP；改成硬件投票。
- I2C 总线卡死时解绑再绑定控制器：从设备仍拉着 SDA，没用。
