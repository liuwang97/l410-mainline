# 电源：PMIC、调压器、IP 电源域、RTC、电源键、温控、cpufreq 与 cpuidle

L410 的 PMIC 挂在 SoC 的 SPMI 总线上，而且所有 PMIC 访问都要经 ATF 转发。PMIC 上有 LDO/BUCK 调压器、RTC、电源键和一组时钟门。
SoC 内部各 IP 的电源域由 ATF 或 LPM3 开关；CPU 调频由 LPM3 做，Linux 只投票。

代码在内核仓库 [linux-l410](https://github.com/liuwang97/linux-l410)（分支 `l410-6.18`），配置片段 `l410/configs/20-power.config`，
DT 修补 `l410/dt/fixups.d/20-power.dtsi`（GPU 温控在 `90-perf.dtsi`）。投票机制本身见 [soc-core.md](soc-core.md)。

| 部件 | 厂商实现 | 6.18 做法 |
|---|---|---|
| SPMI 控制器 fa890000 | 寄存器和主线 Kirin 970 的 `hisi-spmi-controller` 一样，但 DT 带 `spmi-always-sec`：所有 PMIC 访问走 ATF SMC `0xc500eee0`/`0xc500eee1`（x1 = sid，x2 = reg，x3 = val，逐字节） | `drivers/spmi/hisi-spmi-controller.c`：加认 `hisilicon,spmi-controller`、`spmi-channel`；有 `spmi-always-sec` 时走 `arm_smccc_smc`，不碰 MMIO |
| 主 PMIC（usid 9） | `hisilicon-hisi-pmic-spmi`，子节点各带 compatible；中断 5 组 × 8，线接 GPIO fa8b0000 第 6 脚（低电平） | `drivers/mfd/hisi-spmi-pmic.c`：SPMI regmap（16 位地址）、`of_platform_populate` 子节点、按 DT 描述的中断控制器（嵌套线程中断）、重启原因 |
| 调压器 | `hisilicon-hisi-ldo`：每个 LDO/BUCK 一个节点，寄存器和电压表都在 DT | `drivers/regulator/hisi-spmi-regulator.c`（regmap helper + eco 模式）。主线 hi6421v600 的寄存器地址不同，不能复用 |
| 子 PMIC（buck01，usid 1） | 固件 DT 里 `pmic1@1` 是 disabled；厂商内核里也读不到（`g_pmic is NULL`，读数 300 mV 是电压表首项） | 驱动支持，节点 disabled 就不注册 |
| IP 电源域 | `ip-regulator-atf`：SMC `0xc500fff0`（id, on/off），可选先开时钟或降频；`ip-regulator-lpm`：经 IPC 给 LPM3 发两字命令（g3d、mmbuf） | `drivers/regulator/hisi-ip-regulator.c`，LPM 部分用 `kirin_ipc_send("HISI_ACPU_LPM3_MBX_2")` |
| 外设电压 | peri-volt 硬件投票（PMCTRL） | `drivers/soc/hisilicon/kirin-peri-dvfs.c` |
| RTC | PMIC 0x6000 起四个 32 位寄存器（DR/MR/LR/CR，逐字节小端）；厂商另把时间同步到 SoC 的 PL031（fa88c000） | `drivers/rtc/rtc-hisi-spmi.c`：只用 PMIC 计数器（掉电保持），闹钟走 PMIC 中断 3 |
| 电源键 | `hisilicon-hisi-powerkey`，只有 "down" 和 "hold 6s" 中断，ARM-PC 板型按下即报按下加松开 | `drivers/input/misc/hisi_powerkey.c` 加 of_match，"up"、"hold 4s" 可选 |
| 温度 | `hisi,tsens`：SMC `0xc5009900`(regno) 返回 ADC 码，0x19e..0x2bc 线性对应 -40..125 °C | `drivers/thermal/hisi_tsens_smc.c`；DT 有 thermal-zones 就用，没有就注册不带 trip 的同名 zone |
| cpufreq | cpufreq-dt + PMCTRL 硬件投票（`freq-vote-channel`），LPM3 做调频调压 | `drivers/cpufreq/hisi-hwvote-cpufreq.c`：直接写投票寄存器、读结果寄存器 |
| cpuidle | PSCI：cpu-sleep-0（0x10000）、cluster-sleep-0/1（0x1010000） | 主线 psci cpuidle |

`20-power.dtsi` 的修补：SPMI 控制器加 `#address-cells = <2>; #size-cells = <0>`，`pmic@0` 加 `reg = <9 0>`，`pmic1@1` 加 `reg = <1 0>`
（主线 SPMI 核心按 `reg` 找 usid，厂商用的是 `slave_id`）；tsens 加 `#thermal-sensor-cells`；三个 cpu 节点加 `#cooling-cells`；新的 thermal-zones。

## PMIC

- 中断：mask 寄存器 0x2a2/0x2a3/0x2ac/0x2ad/0x2ae，status 在 mask + 0x11。
- 唤醒：RTC 闹钟和电源键都是 PMIC 的子中断。最初 PMIC 中断芯片带 `IRQCHIP_SKIP_SET_WAKE`，挂起时 PMIC 接 SoC 的那条 AO GPIO 线
  和普通中断一起被关，RTC、电源键驱动也没注册 wake IRQ，s2idle 睡下去就醒不来。现在 set_wake 转给父中断，RTC、电源键注册 wake IRQ
  （`mfd: hisi-spmi-pmic: pass wakeup requests on to the PMIC's interrupt line`、`rtc: hisi-spmi: let the alarm wake the system`、
  `Input: hisi_powerkey - wake the system with the power key`）。
- 重启原因：厂商内核在 restart/poweroff 前写 PMIC 0x303（HRST_REG13）：重启写 `COLDBOOT`（0x10），关机写 `AP_S_COLDBOOT`（0x00）；
  不写的话固件记为 `AP_S_ABNORMAL`。PMIC 驱动用 reboot notifier 写同样的值；panic 和看门狗复位不经过 notifier，仍记 ABNORMAL。
  驱动 probe 时把 0x303 的当前值打进日志（`dmesg | grep "last reset reason"`），开机时读到的是 0xff，这是固件启动时写的“未正常关机”标记。
  验证：6.18 重启后进麒麟，麒麟的 `/proc/cmdline` 里是 `reboot_reason=COLDBOOT`（不写时是 `AP_S_ABNORMAL`）。
- PMIC 上的时钟门（clk_pmu32kb 32764 Hz 给 WiFi 芯片，clk_pmuaudioclk 19.2 MHz 给 Hi6405 等）由时钟驱动管理，PMIC 驱动 probe 时把 regmap 交过去，
  见 [soc-core.md](soc-core.md)。

## 调压器

13 路，电压和麒麟下读到的完全一致：

| 调压器 | 电压 | 厂商运行时 | 用途 / 备注 |
|---|---|---|---|
| buck10 | 700 mV | 关 | |
| ldo4 | 1.8 V | 关 | UEFI 打开，6.18 开机时是开的 |
| ldo9 | 1.8 V | 开 | |
| ldo15 | 2.55 V | 开 | UFS VCC（always-on） |
| ldo16 | 1.8 V | 关 | |
| ldo17 | 2.5 V | 关 | |
| ldo21 | 1.5 V | 关 | |
| ldo23 | 3.2 V | 开 | USB PHY 3.3 V（`usb_phy_ldo_33v`），UEFI 打开 |
| ldo24 | 2.8 V | 开 | |
| ldo25 | 1.1 V | 关 | |
| ldo29 | 1.1 V | 关 | |
| ldo32 | 1.0 V | 关 | |
| ldo38 | 1.22 V | 开 | |

6.18 开机时开着的是 ldo4/9/15/23/24/38。内核命令行要带 `regulator_ignore_unused`，否则开机 30 s 后调压器核心会关掉开着但没人认领的 LDO
（以前 ldo23 就这样被关，USB PHY 掉电）。

## IP 电源域

19 个，全部注册，做成调压器，消费者照固件 DT 的 `xxx-supply` 拿：

- 不需要时钟的：media1、media2、npu、g3d、asp、mmbuf、vdec_fake、venc_fake。
- 需要时钟的：vivobus、vcodecsubsys、dsssubsys、ispsubsys、ivp、venc、venc2 及其下游，等时钟注册后才 probe。
- media1、vivobus、dss 要在 SCTRL+0x438 投票（hwspinlock 29）；别人（传感器 hub、TEE）有票时不发 SMC。
  DSS 如果固件已经放开复位，第一次 enable 直接记为开。
- g3d、mmbuf 经 LPM3 IPC 开关。
- `is_enabled` 是软件状态（厂商同样），开机时全部报“关”。vivobus、media1、dsssubsys 在 UEFI 下其实是开的，消费者第一次 enable 会再发一次上电 SMC，
  厂商开机流程也是这样。
- 麒麟运行时 vivobus、dsssubsys、media1、asp 开，其余关。不要在测试里关 vivobus、media1_subsys、dsssubsys，UEFI 留下的显示在用它们
  （显示驱动关屏时连 vivobus/media1 一起关会让整机挂死，见 [graphics.md](graphics.md)）。

## 外设电压投票（peri-dvfs）

`kirin-peri-dvfs` 把 `set_volt(id, level)` 注册给时钟驱动（`kirin_clk_set_perivolt_ops`），共 18 个投票者：

1. `id` 取 DT 的 `perivolt-poll-id`；在 hwspinlock 19 下写 PMCTRL 字段。
2. AVS 投票者清 SCTRL 0x46C bit28。
3. 发 peri-volt 硬件投票，值为 `id << 8 | avs << 4 | level`；和上次相同时翻转 bit3，好让 LPM3 收到中断。
4. 升压时等 PMCTRL 0x350[29:28] ≥ level，最多 400 次 × 150-300 µs。

只能在可睡眠上下文调用，时钟驱动只在 prepare/set_rate 时调。

## RTC 与电源键

- RTC 是 rtc0，开机即用它设系统时间。闹钟中断能触发，也能把系统从 s2idle 唤醒。30 分钟压力测试里系统时间对 PMIC RTC 零漂移。
- 麒麟把 RTC 当本地时间存。和麒麟双系统时，Debian 的 `/etc/adjtime` 要设成 `LOCAL`（`system/base/install.sh` 会写），否则时间差一个时区。
- 电源键是 input 设备 "HISI 65xx PowerOn Key"。"hold 6s" 中断没用，长按关机由 PMIC 自己做。

## 温控

- 传感器：cluster0、cluster1、cluster2、gpu、modem、npu、peri、hisec 八个 zone；ddr 没有传感器（regno 0xff）。空闲时约 35-38 °C，
  和麒麟同一时刻读数（35-41 °C）相当。
- 固件 DT 原有的 `/thermal-zones`（soc_thermal、board_thermal）用的是没有驱动的 ipa-sensor，6.18 下不会注册，保持不动。
- 新加的 zone：cluster0/1/2 在 90 °C 被动降频，接 cpufreq 冷却（每簇 max_state 12）；gpu 在 90 °C 降 Panfrost 频率（`90-perf.dtsi`，
  能耗模型用厂商 kbase 的 `dynamic-power-coefficient = <8538>`）；cluster0/1/2 和 gpu 在 105 °C critical（等于厂商 tsens 的 `temp_shutdown`），
  由 thermal 核心有序关机。LPM3 和 PMIC 自己的过温检测（thsd_otmp 125/140 °C）是最后一道保护。
- 内核默认用 step_wise。装了 `system/perf` 后，`system/perf/profile.sh` 把 CPU 和 GPU 的 zone 换成 `power_allocator`，
  sustainable_power 分别是 cluster0 600、cluster1 1100、cluster2 2300、gpu 2400 mW，在 90 °C 控制温度以下不限频。
- sched_ext 调度器（如 scx_lavd）运行时，cpufreq_cooling 用 `sched_cpu_util()` 估负载，原来只看 CFS 的 PELT，IPA 以为 CPU 空闲，
  模拟 95 °C、大核满载时仍跑 2861 MHz。`sched/fair: count sched_ext load in sched_cpu_util()` 修复后会限频，但比 EAS 下平缓
  （6 s 时 lavd 2218 MHz/state 6，EAS 1536 MHz/state 12），之后由 PID 积分项继续收紧。
- 实测：30 分钟满载/空闲交替最高 65 °C，1 小时混合烤机最高 78 °C，都没到 90 °C。

## cpufreq

| 簇 | CPU | 频率范围 |
|---|---|---|
| cluster0 | cpu0-3（Cortex-A55） | 554-1863 MHz |
| cluster1 | cpu4-5 | 826-2088 MHz |
| cluster2 | cpu6-7 | 1536-2861 MHz |

- 每簇一个 policy（OPP 表 opp-shared，`dev_pm_opp_of_get_sharing_cpus`）。投票值就是 MHz，`get()` 读结果寄存器，即 LPM3 实际给的频率。
  实测三簇在最低、中间、最高档之间切换，LPM3 给出的频率和投票完全一致。
- 固件 OPP 全都带 `opp-supported-hw = <3>`。驱动和厂商一样设 supported_hw = BIT(0)，否则主线 OPP 核心会把它们全丢掉。
- 能耗模型：取厂商（主线之前的 EAS）`sched-energy-costs` 里的 busy-cost-data（每簇的容量和 mW 对），把每个 OPP 的容量插值进去，
  EAS 和 power_allocator 都能用，不用重新测功耗。
- 一票只是一次寄存器写，不睡眠不加锁，所以支持调度器上下文的 fast switch。LPM3 完成一次投票实测 0.4-0.8 ms，固件表写的是 2 ms
  （schedutil 会因此把自己限到 3 ms），驱动默认 rate limit 500 µs。
- HW pressure（把 LPM3 的限频报给调度器）默认关。
- 模块参数（内建时在命令行写 `hisi_hwvote_cpufreq.<参数>=`）：`rate_limit_us`（默认 500）、`fast_switch`（默认开）、`energy_model`（默认开）、`hw_pressure`（默认关）。
- 驱动是冷却设备（`CPUFREQ_IS_COOLING_DEV`）。schedutil 在 stress-ng 下升到最高档，空闲回到最低档。

缺陷记录：驱动 init/exit 原来判断的是调度器的 per-CPU 变量 `hw_pressure`，不是模块参数。启动时读 init 段里的模板得 0，所以 HW pressure 从没运行过；
init 内存释放后，簇的最后一个核下线（系统挂起要关 CPU1-7）时 exit 缺页 oops，持着 hotplug 锁卡死。
修复：`cpufreq: hisi-hwvote: test the hw_pressure parameter, not the scheduler's per-CPU variable`。

## cpuidle

主线 PSCI cpuidle（psci_idle），所有构建默认开。每簇都会进 cpu-sleep-0 和 cluster-sleep-0/1，30 分钟压力测试里每簇 cluster-sleep 进入 6.7k 到 108k 次。
怀疑挂死和 idle 有关时，加 `cpuidle.off=1` 排除。

## 重启、关机与系统睡眠

- 重启（PSCI SYSTEM_RESET）每次都在用，正常，麒麟记为 COLDBOOT。
- 关机（PSCI SYSTEM_OFF）没上机验证过。可以这样测：先 `echo +120 > /sys/class/rtc/rtc0/wakealarm`（PMIC 有 alarm_pwrup 记录位）再 `poweroff`，
  看两分钟后能不能自己开机；不能的话要按电源键开机。
- 系统睡眠默认是 s2idle，可用。deep（`drivers/soc/hisilicon/kirin990-sr.c`，厂商的 LPM3 握手：SCBAKDATA8 bit16 + CPU_SUSPEND 0x01010000）
  唤醒后会冷启动，`kirin990_sr.deep=1` 才把 deep 设为默认。唤醒源：RTC 闹钟验证过；电源键走同一条 PMIC 中断链，没有实按测过。

## 怎么检查

```bash
sudo bash tests/power.sh
```

逐项 PASS/FAIL/SKIP/INFO，退出码是 FAIL 数，约 20 s：SPMI/PMIC、13 路调压器电压、19 个 IP 电源域、peri-dvfs、PMIC 时钟、RTC 和闹钟中断、
电源键、温区、cpufreq 三档切换和 schedutil、冷却设备、cpuidle。期望值是厂商内核 4.19.71 下读到的。装了 `system/perf` 时，
脚本临时切到平衡档（性能档会把每个 policy 钉在最高频），结束时恢复。

手工看：

```bash
cat /sys/class/regulator/regulator.*/name
cat /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp
grep . /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq
grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/usage
```

开发用的辅助脚本在 `dev/bringup/`（说明见 [../../dev/README.md](../../dev/README.md)）：

- `power-soak.sh` + `power-soak-host.sh`：默认 30 分钟满载 20 s / 空闲 20 s 交替，空闲时做 UFS 读写，同时从 PC 走网络收发；
  检查 RCU stall、softlockup、hung task、时钟告警，各 idle 态都在用，系统时间对 PMIC RTC 不漂移，温度低于 95 °C。
  实测结果：dmesg 零警告，系统时间与 RTC 都是 1805 s，最高 65 °C，冷却没触发。
- `power-test.dtsi`：只用于测试的 DT 片段，加上 `CONFIG_REGULATOR_USERSPACE_CONSUMER=y` 后，`power.sh` 会对每个 `power-test-*` 做一次上电和下电
  （media2_subsys 走 ATF，g3d 走 LPM3 IPC）。不要带进正式构建。
- `power-probe-extra.sh` + `power-repack-initrd.sh`：没有网络时把诊断塞进 initramfs，结果从 pstore 取回。

## 已知问题与没做的

- 关机没验证（见上）。
- 子 PMIC（buck01）在固件 DT 里 disabled，没注册，厂商内核里也读不到。
- PMIC 的过流、过温、SMPL 监控（厂商 pmic_mntn，属于 DFX）没移植。这些中断一直屏蔽，PMIC 的硬件保护照常。
- 厂商的 freq-autodown（媒体总线空闲降频）没移植，IP 域上下电前后不再开关它。
- PMIC 上的 UFS 参考时钟 CLK_UFS_EN（0x043）没做成 clk，UFS 目前不需要。
- deep 睡眠唤醒后冷启动，原因没查清。

## 试过但没用

- 复用主线 hi6421v600 调压器驱动：寄存器地址不同。
- 不加 `regulator_ignore_unused`：开机 30 s 后没人认领的 ldo23 被关，USB PHY 掉电。
- 用固件 DT 自带的 thermal-zones：传感器是没有驱动的 ipa-sensor，6.18 不注册这些 zone。
- deep 睡眠走厂商 LPM3 握手：设备挂起、7 个核下线、syscore 都正常，最后一行日志是 `cpu_pm_suspend`，之后整机冷启动，PMIC 0x301（SR tick）读出 0。
