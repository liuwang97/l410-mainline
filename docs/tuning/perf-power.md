# 电源模式与性能

L410 上 CPU、GPU、内存的调频和调度按两个目标来配：桌面在 60 Hz 下不掉帧、交互跟手；不操作的时候尽量省电。
实现分两部分：

- 内核（[linux-l410](https://github.com/liuwang97/linux-l410) 分支 `l410-6.18`）提供机制：三档模式和各种 boost、CPU 能耗模型、运行时可切的 PELT 半衰期、
  Panfrost 的帧感知升频、显示驱动的实时提交和硬件光标、DDR 调频、时钟真实关断。全部编进内核，不用另外装。
- 用户态（本仓库 `system/perf/`，由 `system/install.sh` 的 `perf` 阶段安装）：tuned 的三个 profile、tuned-ppd、按电源状态切档的 PowerDevil 设置、
  给 KWin 和前台应用设 uclamp 的 `l410-perfd`，以及告诉它哪个窗口在前台的 KWin 脚本。

KWin 怎么排帧、桌面原来为什么「帧率够但手感肉」，见 [desktop-latency.md](desktop-latency.md)。
系统默认还会跑 scx_lavd 调度器，它和本文机制的关系见下文「sched_ext 下的差别」和 [sched-ext.md](sched-ext.md)。

## 组成

| 部分 | 位置 | 作用 |
|---|---|---|
| 模式与 boost | `drivers/soc/hisilicon/l410-perf.c` | `/sys/kernel/l410_perf/`：三档、输入 boost、启动 boost、出帧下限、DDR 跟随负载 |
| CPU 调频 | `drivers/cpufreq/hisi-hwvote-cpufreq.c` | 能耗模型、fast switch、500 µs 限速、LPM3 限频回报 |
| PELT | `kernel/sched/pelt.c`、`pelt.h`、`core.c` | `/proc/sys/kernel/sched_pelt_multiplier` |
| GPU | `drivers/gpu/drm/panfrost/panfrost_devfreq.c`、`panfrost_job.c` | idle / deadline / wait boost，高优先级提交 |
| 显示 | `drivers/gpu/drm/hisilicon/kirin990/kirin990_drv.c` | 实测刷新率、vblank 时间戳滤波、SCHED_FIFO 提交线程、硬件光标、拒绝外来 dma-buf、帧统计 |
| 内存 | `drivers/devfreq/kirin990-ddr-devfreq.c`、`drivers/soc/hisilicon/kirin-hw-vote.c` | DDR 调频（PMCTRL 硬件投票） |
| 时钟 | `drivers/clk/hisilicon/kirin990/clk-kirin.c` | 时钟在硬件上真正关断（默认） |
| 内核配置 | `l410/configs/90-perf.config`、`l410/dt/fixups.d/90-perf.dtsi` | UCLAMP、能耗模型、IPA、devfreq 调速器、ftrace/PSI/SCHEDSTATS；GPU 能耗模型与冷却、DDR 节点 |
| 切档 | `system/perf/tuned/`、`system/perf/profile.sh` | tuned profile，切档时写各项参数 |
| 每用户 | `system/perf/l410-perfd`、`kwin-script/`、`systemd/` | KWin 和前台应用的 cgroup uclamp、应用启动检测 |

## 切档链路

```
KDE 电池小部件 / PowerDevil（按电源状态）
        │  power-profiles-daemon 的 D-Bus 接口 org.freedesktop.UPower.PowerProfiles
tuned-ppd：/etc/tuned/ppd.conf 把 power-saver / balanced / performance 映射到 l410-* profile
        │
tuned：/etc/tuned/profiles/l410-<档>/script.sh → /usr/local/lib/l410-perf/profile.sh <档> start
        │  写 /sys/kernel/l410_perf/mode 和其余 sysfs、sysctl
内核 l410-perf：按档位改所有 PM QoS 请求和 boost 参数
        │
l410-perfd（每个桌面用户一个）：每 5 s 读一次 mode，改 KWin 和前台应用的 cpu.uclamp.min
```

- 原版 power-profiles-daemon 靠 `/sys/firmware/acpi/platform_profile` 工作，这台机器用设备树启动，没有 ACPI。
  tuned-ppd 提供同样的 D-Bus 接口，会替换 power-profiles-daemon 包。
- `ppd.conf` 里 `battery_detection=false`：插拔电源由 PowerDevil 切档，tuned-ppd 自己不判断，免得两边打架。
- `tuned-main.conf` 设 `dynamic_tuning = 0`，tuned 只在切档时动作，平时不轮询。
- 三档的参数表都在内核模块里，切档是一次写入，不会停在改了一半的状态。
- boost、QoS 请求和超时撤销都在内核里，用户态进程挂掉也会按时撤销；「谁在前台」「谁在启动」这种需要桌面信息的判断放在用户态。
- 所有下限都是 PM QoS 最小值请求（`freq_qos`、`dev_pm_qos`、`cpu_latency_qos`）或 uclamp。温控设的是上限，上限总是优先，
  所以性能档的「锁最高」也会被温控压下来。

自动切档写在 `/etc/xdg/powerdevilrc`。用户在 系统设置 → 节能 → 交流供电 / 电池供电 / 低电量 →「切换到电源配置」里改的会覆盖它：

| 电源状态 | 档位 |
|---|---|
| 插电 | 性能 |
| 电池 | 平衡 |
| 低电量（阈值在同一个设置页） | 省电 |

## 三档各做了什么

| 项 | 省电 | 平衡 | 性能 |
|---|---|---|---|
| CPU、GPU、DDR 下限（l410-perf） | 无 | 平时无；输入、应用启动、出帧时临时抬高 | 三簇 CPU、GPU、DDR 全部锁最高档 |
| cpuidle | 不限 | 不限 | `cpu_latency_qos` 100 µs：空闲时不关簇（簇级睡眠退出要 5-6 ms） |
| schedutil `rate_limit_us` | 3000 | 500 | 500 |
| PELT 半衰期 | 32 ms（倍率 1） | 16 ms（2） | 8 ms（4） |
| KWin cgroup `cpu.uclamp.min` | 27.64（283） | max | max |
| 前台应用 `cpu.uclamp.min` | 不设 | 37.50 | 50.00 |
| 应用启动 boost | 无 | 有 | 无（已锁最高） |
| Panfrost idle / deadline / wait boost | 关 | ×2 | ×2 |
| GPU devfreq 采样周期 | 50 ms | 20 ms | 20 ms |
| DDR 调速器 | powersave（跟随 QoS 和负载） | powersave | performance（2133 MHz） |
| UFS auto-hibern8 空闲时间 | 5 ms | 20 ms | 150 ms |
| UFS LU 运行时挂起、无网线时有线网卡 D3hot | 开 | 开 | 关 |
| WiFi `power_save` | 开 | 开 | 关 |

三档相同的部分：EAS 开（`sched_energy_aware=1`）；RT 任务默认 `sched_util_clamp_min_rt_default` = 0；温控用 IPA；
GPU 和显示的中断放在 CPU4-5；用户 cgroup 的各级父节点允许 uclamp 往下传。

省电档基本是没有这套机制时的行为：没有任何 boost，GPU 按占用率调频。KWin 的 283 正好是小核的算力，在小核上等于小核满频，
接近没开 uclamp 时「有 RT 任务可运行就给最高频」的行为。代价是 GPU 常停在 166 MHz，KWin 容易进三缓冲，延迟多一帧。

## 60 Hz 帧预算

面板 2160×1440，按寄存器里的时序（像素时钟 206.016 MHz，htotal 2320，vtotal 1480）一帧 16.667 ms，vblank 40 行约 0.45 ms；
面板实际跑在 60.51 Hz（见 [desktop-latency.md](desktop-latency.md)）。

KWin 在 vblank 前「预测渲染时间 + 固定开销」开始合成。预测值是均值加两倍峰值保持的偏差，一帧尖峰就会让 KWin 进三缓冲好几秒，
所以预算按尾部定（阈值的来历见 desktop-latency.md）：

| 指标 | 目标 |
|---|---|
| KWin 渲染（开始合成到 GPU 做完）中位 | ≤ 3 ms |
| p99 | ≤ 5 ms |
| 任意 10 s 内的单帧最大 | ≤ 7 ms |
| KWin 预测值 | ≤ 11 ms（KWin 6.3 回双缓冲的门槛是 12.9 ms，留 2 ms 余量） |

7 ms 的分配，以及每一段靠什么保证：

| 段 | 典型 ms | 上限 ms | 机制 |
|---|---|---|---|
| 输入唤醒（libinput 线程到主线程） | 0.1 | 0.5 | KWin 实时线程在大核 |
| KWin CPU 合成 | 1.8 | 3.0 | uclamp 上大核（同样的活小核慢 3.6 倍）；调频限速 500 µs；显示驱动拒绝外来 dma-buf |
| 提交到 GPU 开始 | 0.1 | 0.5 | Panfrost 提交走高优先级工作队列；合成器用高优先级运行队列 |
| GPU 执行（桌面合成） | 0.8 | 2.0 | 出帧下限 332 MHz；idle / deadline boost |
| 完成中断到 fence 信号 | 0.1 | 0.3 | GPU 中断从 CPU0（小核）挪到中核 |
| 合计 | 2.9 | 6.3 | |

之后 KWin 的提交线程在 vblank 前约 1.95 ms 提交，显示驱动 0.03-0.3 ms 写完寄存器，下一个 vblank 翻页。
写寄存器这一步现在在 SCHED_FIFO 线程上，CPU 忙时不会被普通任务挤掉。

应用这一侧：从收到 frame callback 算，应用大约有 8-10 ms 做完 CPU 和 GPU 的活（按 CPU ≤ 5 ms、GPU ≤ 4 ms 分）。
普通（CFS）任务的 60 Hz 短突发按利用率永远升不上频，比最高频慢 2-2.7 倍，这一段靠前台 uclamp、输入 boost 和启动 boost。

## 各项机制

### KWin 实时线程上大核（UCLAMP）

KWin 的主线程、`eDP-1` 提交线程和 libinput 线程都是 SCHED_RR。没开 `CONFIG_UCLAMP_TASK` 时 `rt_task_fits_capacity()` 恒为真，
这几个线程常落在 A55 小核（算力 283/1024）上，渲染 p90 7.4 ms、最大 24.8 ms，KWin 一直在三缓冲。

`90-perf.config` 开了 `UCLAMP_TASK`、`UCLAMP_TASK_GROUP`（5 个桶）。RT 任务只放到算力不低于 uclamp_min 的核上，频率也按 uclamp_min 请求。

- RT 默认值 `sched_util_clamp_min_rt_default` 设 0，不用主线的 1024。大核只有两个，1024 会让 WiFi 驱动的 `hisi_rxdata`、`pci_rx_hi_task`（FIFO 50）、
  `hisi_hcc`、`hisi_hci_recv`（FIFO 1）、`watchdogd` 和 PipeWire 的 RT 线程全挤到大核上，还一直满频。KWin 是 RR 1，在 RT 里优先级最低，
  有网络流量时会被 `hisi_rxdata` 抢占。
- KWin 单独通过 cgroup 拿：`plasma-kwin_wayland.service` 的 `cpu.uclamp.min` 在平衡、性能档是 `max`。只有大核满足，
  KWin 跑在 CPU6-7 的 2861 MHz 上，一帧约 2 ms。小核满频一帧要 7.2 ms，超预算。
- 代价：按厂商能耗表，60 fps 持续合成时 KWin 在大核满频平均约 137 mW，放中核满频是 82 mW。平衡档因此多约 55 mW，只在画面有更新时产生。
- 子 cgroup 的有效 uclamp 不能超过父级（`cpu_util_update_eff()`）。`user.slice`、`user-UID.slice`、`user@UID.service` 由 `user@.service` 的 drop-in
  （`ExecStartPost`）和 profile.sh 设成 `max`；用户管理器自己建的 `session.slice`、`app.slice` 默认是 0，由 l410-perfd 改成 `max`。
  这些父节点里不直接放进程，设 max 没有副作用。cpu 控制器要沿路径打开，所以给 `plasma-kwin_wayland.service`、`app-*.scope`、`app-*.service`
  各加了一个 `CPUWeight=100` 的 drop-in。
- systemd 没有 uclamp 的单元属性，l410-perfd 直接写 cgroupfs。`kwin_wayland` 带文件能力 CAP_SYS_NICE，普通用户进程改不了它线程的调度参数
  （`sched_setattr` 返回 EPERM），这也是走 cgroup 的原因。

### 前台应用

KWin 脚本 `l410-perf`（装在 `/usr/share/kwin/scripts/l410-perf`，默认对所有用户启用）在窗口激活时通过 D-Bus（`org.l410.perfd`）把窗口的 pid 发给 l410-perfd。
l410-perfd 把这个进程所在 cgroup 的 `cpu.uclamp.min` 设成 37.50%（平衡）或 50.00%（性能），上一个前台恢复 0。

- 37.5% 即 384，高于小核的 283：前台应用避开小核，在中核上落在最省电的那几档（对应 Android 的 top-app 做法）。目的是让应用的 60 Hz 短突发能升上频。
- Chromium 的窗口出来一两秒后会把自己挪进 `app-org.chromium.Chromium-<pid>.scope`，所以 l410-perfd 在激活后 1 s 和之后每 5 s 按 pid 重新找 cgroup。
- 只处理用户管理器（`user@UID.service`）下面的进程，登录会话 scope 里的进程（比如从 ssh 启动的）不动。
- 实测这个下限对 Chromium 重页面滚动没有可测的影响（下限生效前 49.3-49.8 fps，生效后 48.4-49.8 fps），保留它是因为做法本身是对的。

### 应用启动 boost

Plasma 从开始菜单、任务栏、KRunner 启动的每个应用都放在一个 `app-*.scope` 或 `app-*.service` 里。l410-perfd 在用户 systemd 总线上订阅 `UnitNew`
（内核没开 proc connector，也不需要），看到新的 `app-*` 单元就：

- 向 `/sys/kernel/l410_perf/launch` 写 3000：内核把三簇 CPU 下限设成最高，GPU 不低于 461 MHz，DDR 不低于 1660 MHz；
- 单元的 cgroup 出现后把它的 `cpu.uclamp.min` 设 `max`，主线程直接上大核；
- KWin 脚本报告这个应用的第一个普通窗口或对话框之后再保持 400 ms，最长 3 s。结束后 cgroup 回到前台下限或 0，没有别的启动在进行时向 `launch` 写 0。

只在平衡档生效。每次启动到首个窗口的耗时记在 `~/.local/state/l410-perfd/launch.log`。
`launch` 文件属组是 `l410`（profile.sh 设置），安装时把桌面用户加进这个组。应用启动速度的其他优化见 [launch-latency.md](launch-latency.md)。

### 输入 boost

l410-perf 用 `input_handler` 挂在所有带 EV_KEY、EV_REL 或 EV_ABS 的输入设备上（参考高通厂商内核的 `cpu-boost.c` 和 kerneltoast 的 `cpu_input_boost`，
但只用主线的 QoS 接口）。事件回调在原子上下文里只记时间戳，由一个 SCHED_FIFO 的 kthread worker 设下限、到期撤销。

- 重事件：按键（含自动重复）、点击、滚轮（含高精度滚轮）、按住按键或两指以上时的移动（拖动、触控板滚动和手势）。
  下限是三簇 CPU、GPU、DDR 全部最高档：用 Chromium 或 Firefox 滚动哔哩哔哩首页这类重页面时，GPU 在 600 MHz 下占用约 50-65%，同时有 4 个 CPU 核在忙，
  哪一项低于最高档都会掉帧。
- 轻事件：只有指针移动。有硬件光标后移动光标不需要重画，默认下限为空。
- 最后一个事件后保持 300 ms（`input_ms`），覆盖惯性滚动。
- 只在平衡档生效。连续滚动、拖动时平衡档的功耗和帧率与性能档一样，这是有意的；平衡档省电靠的是空闲和轻负载的时间。

### 出帧下限

显示驱动每翻一帧新画面就通知 l410-perf。画面在更新（距上一帧新画面不到 `frame_hold_ms` = 100 ms）时，平衡档保持 GPU 不低于 332 MHz、DDR 不低于 900 MHz。
输入停了但动画还在继续（惯性滚动、窗口动画、视频）时也由它兜住。

桌面合成只占 GPU 几个百分点，simple_ondemand 按占用率总是选最低的 166 MHz。166 MHz 下 KWin 一帧的 GPU 时间约 1.3 ms，600 MHz 下 0.5-0.75 ms；
实测 332 MHz 起 KWin 才能 100% 双缓冲。

### Panfrost：msm 式升频

照上游 msm（`msm_gpu_devfreq.c`、`msm_fence.c`）做了三种 boost。每种都是在 PM QoS 上请求「当前频率 × 倍数」作为下限，保持一个采样周期后撤销；
连续 boost 会一级级升到最高档。触发点可能在原子上下文或提交路径上，所以由 SCHED_FIFO 的 `panfrost-boost` 线程去改 QoS。

- idle boost：GPU 空闲超过一个采样周期后的第一个 job（挂在 `panfrost_devfreq_record_busy()`）。166 MHz ×2 正好是 332 MHz 档。
- deadline boost：`panfrost_fence_ops` 实现了 `.set_deadline`。KWin 对每帧的渲染 fence 调 `SYNC_IOC_SET_DEADLINE`（截止 = 目标翻页时刻减安全余量），
  drm_sched 把它转给硬件 fence。驱动在截止前 `deadline_margin_us`（3000）挂 hrtimer，到点 fence 还没完成就 boost。和 msm 一样只跟踪最早的一个截止时间。
  按时完成的帧不多耗电。
- wait boost：CPU 用 `PANFROST_WAIT_BO` 等一个还在忙的 buffer（Mesa 的 glFinish、映射 buffer）时立即 boost。

提交路径：

- drm_sched 的提交工作原来在普通优先级（nice 0）的 ordered 工作队列上，KWin 调 SUBMIT 之后要等这个 kworker 被调度，GPU 寄存器才会被写。
  CPU 忙时要等当前任务的 slice 保护期（最长 2.8 ms）再等一个 tick（HZ=250，最多 4 ms），把 kworker 设成 nice -20 也不缩短这段。
  现在每个 job slot 用 `WQ_HIGHPRI | WQ_MEM_RECLAIM` 的 ordered 工作队列（`highpri_submit`）。
- 所有上下文原来都是 NORMAL 优先级，KWin 申请的高优先级 EGL 上下文不起作用。现在带 CAP_SYS_NICE 的打开者（实际只有 KWin）用 `DRM_SCHED_PRIORITY_HIGH`
  （`compositor_priority`），权限模型和 Linux 6.19 的 JM 上下文优先级一致。它只决定下一个上硬件的是谁，已经在 GPU 上跑的 job 抢占不了。

温控：`90-perf.dtsi` 给 GPU 加了能耗模型和冷却设备。`dynamic-power-coefficient` 是 8538（厂商 kbase 的 `gpu_dyn_capacitance`），
每档电压照抄厂商 operating-points，只用于能耗模型（电压由 LPM3 自己配）。90 °C 被动降频，滞回 5 °C。原来 GPU 只有 105 °C 关机点，
性能档把 GPU 锁在 600 MHz 之前必须先有这一步。

GPU 和显示的中断（`panfrost-job`、`panfrost-mmu`、`panfrost-gpu`、`kirin-dss`）由 profile.sh 挪到 CPU4-5：离开 CPU0（小核、所有中断的默认落点，也是最深的 idle），
也不和 KWin 抢大核。

### 显示驱动

`kirin990_drv.c` 里和帧时序有关的部分：

- 接管时测刷新率，按实测的 60.51 Hz 上报（细节见 desktop-latency.md）。按 60 Hz 上报时 KWin 会「提前画完却晚一帧上屏」，现在没有了。
- vblank 时间戳滤掉中断延迟（`vblank_filter`）。KWin 的帧调度和 fence 截止时间都以这个时间戳为基准。
- 非阻塞提交的硬件部分在 SCHED_FIFO kthread 上执行（`rt_commit`，msm 也这样做），不再用普通优先级的 `system_unbound_wq`。
- 拒绝外来 dma-buf（`foreign_import` 默认 0）。Mesa 的 kmsro 会把 KWin 导入的每个客户端 buffer 也导入显示驱动；DSS 是 32 位 DMA、没有 IOMMU，
  而内存有 4.5 GB 在 4 GB 以上，映射走 swiotlb 反弹，12 MB 的 buffer 卡 2.5-3.6 ms、4 MB 约 1 ms，最后还因为不连续而失败。
  这发生在 KWin 主线程上，开窗口、菜单、弹窗、调整大小时都会触发。现在在映射前就拒绝，Mesa 退回合成。
- 硬件光标默认开（`cursor_plane`）：RCH6（固件用的是 RCH6 时改用 RCH7）接在 OV0 的 layer 1，最大 256×256。隐藏光标时换成全透明 buffer，不关 OV 层
  （关 OV 层再写 `OV0_FLUSH_EN` 会让 LDI 永久 underflow）。在 Plasma 下测过移动、换形状、隐藏、拖窗口、反复最大化，没有 underflow。
  移动鼠标不再触发整帧合成，光标延迟和渲染预测脱钩，移鼠标时 CPU 和 GPU 也保持空闲。
- debugfs `kirin_frames`：vblank 数、翻页数、相邻两帧新画面之间隔了 1/2/3/4+ 个 vblank 的次数、在消隐期写入的次数、拒绝的外来导入数、underflow 次数、帧周期。

### CPU 调频

`hisi-hwvote-cpufreq` 调一次频就是往 PMCTRL 写一次投票，由 LPM3 执行。

- 限速：LPM3 实际调一次频 0.4-0.8 ms，固件表写的是 2 ms，内核据此把 schedutil 限速设成 3 ms（2 ms × 1.5）。一帧开始时离上次调频不到 3 ms，
  这一帧就只能在低频跑完，RT 突发的 p90、p99 因此翻倍。驱动把限速初值设成 500 µs（`rate_limit_us`），profile.sh 在省电档改回 3000。
  实测 RT 突发 p99 从 6.6 ms（小核）/ 4.1 ms（大核）降到 3.0 / 2.6 ms（数据见 desktop-latency.md）。
- fast switch：投票是一次不睡眠、不加锁的寄存器写，可以在调度器上下文里直接做，省掉每次唤醒 sugov kthread（参考 `qcom-cpufreq-hw`）。
- LPM3 给的频率低于投票（固件限频）时，按 HW pressure 报给调度器（`arch_update_hw_pressure()`）。默认关，
  启动参数 `hisi_hwvote_cpufreq.hw_pressure=1` 打开，还没单独验证。

### 能耗模型和 EAS

主线 EAS 要求每个性能域都有能耗模型，原来的 cpufreq 驱动没有 `.register_em`，EAS 实际没生效。
固件设备树里 CPU 节点的 `sched-energy-costs` 指向厂商旧式 EAS 的能耗表，`busy-cost-data` 是每簇的（算力, 功耗 mW）点对。
驱动把每个 OPP 的算力（簇最大算力 × f / fmax）插值到这条曲线上，注册成能耗模型（参数 `energy_model`）。

| 簇 | （算力, 功耗） | 功耗/算力 |
|---|---|---|
| 小核 A55（最高 283） | (122,43) (198,74) (259,117) (283,149) | 0.35 到 0.53 |
| 中核 A76（最高 767） | (308,103) (518,220) (586,267) (657,322) (739,441) (767,515) | 0.33 到 0.67 |
| 大核 A76（最高 1024） | (570,346) (772,573) (880,758) (980,989) (1024,1143) | 0.61 到 1.12 |

中核低档和小核一样省电，中核满频比大核满频省约 40%，大核只在要延迟的时候值得用。

- `sched_energy_aware=1`，唤醒时 `find_energy_efficient_cpu()` 按能耗选核：轻任务放小核，中等负载放中核低档。EAS 会考虑 uclamp，
  所以 uclamp_min 为 max 的 KWin 不会被挪到小核或中核。
- 有了 CPU 和 GPU 的能耗模型，温控从 step_wise（90 °C 开关式）换成 IPA（`power_allocator`）。profile.sh 给 cluster0/1/2/gpu 四个温区设
  `sustainable_power` 600/1100/2300/2400 mW，约等于各温区的满载功耗，所以 90 °C 控制温度以下不会降频。

### PELT 半衰期

主线 6.18 没有调 PELT 半衰期的接口。内核里的 `sched/pelt: run-time switchable PELT multiplier` 移植了 Android 通用内核带的
「sched/pelt: Introduce PELT multiplier」（Qais Yousef）：用一个快 1、2、4 倍的 `rq->clock_task_mult` 驱动 PELT，对应 32、16、8 ms 半衰期。
和原补丁不同的是可以运行时通过 `/proc/sys/kernel/sched_pelt_multiplier` 切换，profile.sh 按档位设。

按计算，它管得到和管不到的：

- 从空闲进入持续负载（开始滚动、动画头几帧、开应用）：利用率升到 0.8 要 2.32 个半衰期，32/16/8 ms 下分别是 74/37/19 ms；小核上的任务也更早被判为 misfit、迁到大核。
- 60 Hz 周期短突发（跑 2 ms、睡 14.7 ms）：出队时利用率的稳态值在 32/16/8 ms 下是 0.14/0.16/0.21，schedutil 算出的频率仍低于中核、大核的最低档。
  这部分靠 uclamp 和 boost。
- KWin 的 RT 线程选频率不看 PELT。

### DDR 调频

UEFI 留下一个 2133 MHz 的投票，没有驱动时内存一直在最高档（厂商内核在桌面下是 1660 MHz）。
`kirin990-ddr-devfreq` 在 PMCTRL 0x270（厂商的 `clk_ddrc_min` 硬件投票，bit 14:0 是 MHz，bit 15 写使能）投 DDR 最低频率，由 LPM3 做 DVFS；
实际频率从 SCTRL 0x41c 的 bit 11:8 读回，是固件 operating-points 表的下标。共 7 档：415、900、1106、1370、1660、1800、2133 MHz。
`90-perf.dtsi` 把固件 DT 的 `ddr_devfreq` 节点改成这个驱动的 compatible。

- 驱动启动时用 performance 调速器（保持 2133 MHz），省电、平衡档切到 powersave 调速器：取满足所有 `DEV_PM_QOS_MIN_FREQUENCY` 请求的最低档。性能档保持 performance。
- 请求来自 l410-perf：各 boost 的下限（输入 boost 最高档、启动 1660、出帧 900 MHz），以及每 50 ms 一次的负载联动（可推迟的工作，不会唤醒空闲的系统）：
  中核、大核里在自己频率范围中位置最高的那一簇，位置不低于 85/60/40/20% 时分别要 1660/1370/1106/900 MHz；GPU 不低于 461/304/208 MHz 时分别要 1370/1106/900 MHz；
  两者取大。性能档不做联动。
- 位置按（当前 − 最低）/（最高 − 最低）算，不按当前 / 最高：大核最低档 1536 MHz 已是最高档的 54%，按当前 / 最高算的话空闲时 DDR 总停在 1106 MHz。
- 显示不投带宽：2160×1440@60 扫描约 750 MB/s，远低于最低档，厂商 DSS 驱动也从来不投。

### 时钟真实关断

`clk-kirin.c` 默认在硬件上真正关时钟：厂商内核稳态下常开的 73 个时钟和所有启用的 PL011 串口的时钟固定开着，其余按引用计数关。
会 runtime suspend 的设备（GPU 空闲 50 ms 后、I2C 等）现在真的停时钟，三档都受益。整机验证过显示接管与扫描（无 underflow）、GPU、录放音、WiFi、蓝牙、
USB hub、鼠标和摄像头、UFS、I2C HID 键盘触控板，桌面基准帧率不变。启动参数 `kirin_clk_keep_on` 回到不关时钟的旧行为。

串口时钟要钉住：串口没打开时 PL011 的功能时钟真的关了，root 读 `/proc/tty/driver/ttyAMA` 时 serial_core 会对这些端口调 `get_mctrl` 读寄存器，
触发同步外部中止（持着端口锁 oops，只能重启）；hi110x 每次蓝牙睡眠、唤醒也会开关 BUART（uart4）。

**这块 SoC 读已关时钟的外设寄存器会直接中止，不会读回 0。** 把新的时钟交给引用计数之前，要先找出设备没打开时仍会碰寄存器的所有路径（proc、sysfs、debugfs）。

### 设备

- UFS：auto-hibern8 空闲时间按档 5/20/150 ms；LU 2 s 没有访问后运行时挂起，所有 LU 都空闲后主机跟着进 hibern8、关时钟（性能档不挂起）。
- 板载 RTL8168 没插网线时进 D3hot（r8169 的运行时 PM，性能档关）。WiFi（厂商驱动）不在此列。
- WiFi `power_save`：省电、平衡档开。打开后从外部连进来的包延迟约 130 ms，出站不受影响。

### sched_ext 下的差别

`system/install.sh` 的 `sched-ext` 阶段默认开机启动 scx_lavd。lavd 管所有普通任务：

- 普通任务的选核由 lavd 决定，EAS 和 uclamp 都不再影响选核；频率仍受 uclamp 约束。所以 uclamp_min 高于小核算力的任务被 lavd 放到小核时，会把小核钉在最高频。
- 因此 lavd 运行时 l410-perfd 不给前台应用设下限，应用启动时也不设 uclamp max（内核的启动 boost 照旧），KWin 的 cgroup 设成 0。
  KWin 的 RT 线程不归 lavd 管，仍按 uclamp 选核，由 root 运行的 `scx-run` 每 5 s 给它们单独设 uclamp_min（各档取值和上面一样）。
- lavd 的模式跟着档位走（`--powersave` / `--balanced` / `--performance`），profile.sh 切档时重启 `scx-lavd.service`。
- IPA 估算负载用的 `sched_cpu_util()` 原来只看 CFS 的 PELT，lavd 下温控完全不限频；内核已改成也计入 sched_ext 的性能目标。

下面的帧率和功耗数据，除特别说明外是在 EAS 下测的。

## 实测结果

### 帧率（平衡档）

工具：`tests/bench/browser-bench.sh`（浏览器打开哔哩哔哩首页，用 uinput 注入滚轮和拖动）和 `tests/bench/frame-budget.sh`（小测试窗口）。
掉帧看两样：画面在动时内核翻页间隔隔了 2 个或 3 个 vblank 的次数（gap2、gap3），以及 KWin 日志里错过目标 vblank 的次数（missed）。
browser-bench 的 fps 把阶段内的静止时间也算进去，最大化、最小化阶段 fps 低不代表掉帧。

Plasma 6.7.4，KWin 用 GLES 合成，每阶段 8 s：

| 场景 | Chromium 154 | Firefox ESR 140 |
|---|---|---|
| 极限滚动（每 20 ms 三格） | 49.3-49.8 fps，gap2 5-8，gap3 3-5，missed 0-3 | 58.3 fps，gap2 7，gap3 3，missed 0 |
| 拖动窗口 | 55.4 fps | 60.4 fps，无掉帧 |
| 最大化 / 还原 | missed 0-2 | gap2 2，gap3 4，missed 2 |

小窗口：KWin 渲染中位 2.1 ms、p99 4.3-6.1 ms，100% 双缓冲；feedback 客户端 0 掉帧；低延迟模式（提交紧跟上一次 presentation）10 s 里残留 0-5 帧掉帧，原因没查完。

- 合成器这一侧满足 60 Hz。Chromium 在重页面上到不了 60 fps，原因在页面自己的主线程（排版和 JS），不在 CPU 调度或 GPU：性能档结果相同，
  滚动时 GPU 占用 Chromium 21%、KWin 8%。分析见 desktop-latency.md。
- 页面状态影响很大：Plasma 6.3.6 时在页面加载完成的状态下测到过 Chromium 60.4-60.5 fps、0 掉帧，新访客状态是 44-51 fps。
- KWin 用 GLES 合成是 `perf` 阶段装的 drop-in（`KWIN_COMPOSE=O2ES`）：KWin 6.7.4 在 Panfrost 上用桌面 GL 3.1 时，低延迟模式的小窗口 10 s 掉 8、67 帧，GLES 下 0、1、5 帧（见 [desktop.md](desktop.md)）。

### 功耗

拔电，用 EC 报的电池电压 × 电流（驱动 10 s 读一次），屏幕亮度 60/100，整机功耗含背光和 WiFi。
按顺序测会把开机后的后台任务和电池电压漂移混进结果，所以用 `tests/bench/power-ab.sh` 交错测（A B C A B C），每项 60 s 平均，刚登录时那一轮不计。
「轻负载」是一个线程每 16.7 ms 做一份固定的活（大核最高频约 2 ms），相当于一个按帧出图的应用；各档做的活一样多，只比谁做得省电。
「改动前」是省电档加 DDR 锁 2133 MHz、KWin 不设 uclamp。

| 配置 | 空闲桌面 | 轻负载 | DDR |
|---|---|---|---|
| 改动前 | 2576 mW | 2604-2735 mW | 2133 MHz |
| 平衡 | 2232 mW | 2495 mW | 空闲平均 518 MHz，轻负载平均 1063 MHz |
| 性能 | 2902 mW | 2963 mW | 2133 MHz |

平衡档比性能档空闲省约 670 mW、轻负载省约 470 mW，比改动前空闲省约 340 mW。
连续滚动、拖动时平衡档的输入 boost 把 CPU、GPU、DDR 全部拉到最高，功耗和性能档相当（顺序测：平衡 4826 mW，性能 4902 mW）。

### 温度

有风扇，但由 EC 固件按板上 NTC 自主控制，内核和厂商用户态都不参与，主机调不了。CPU 加 GPU 满载时整机约 10 W（比空闲多约 6.5 W），
5 分钟后大核稳定在 73 °C，没观察到风扇启动，也没到 90 °C 的降频点。

## 使用

### 安装

```sh
sudo /opt/l410/system/install.sh perf
```

装的内容：tuned、tuned-ppd（替换 power-profiles-daemon）、python3-dbus、python3-gi；`/usr/local/lib/l410-perf/` 下的 `profile.sh` 和 `l410-perfd`；
`/etc/tuned/profiles/l410-*` 和 `/etc/tuned/ppd.conf`；cgroup 相关的 systemd drop-in；用户服务 `l410-perfd.service`（对所有用户启用）；KWin 脚本；
PowerDevil 的默认切档设置；KWin 用 GLES 合成的 drop-in。默认档位是平衡。

装完注销重新登录一次，KWin 脚本和 GLES 设置在下次登录生效。不要用 `systemctl --user restart plasma-kwin_wayland` 代替重新登录，它会结束整个 Plasma 会话。

### 切档

平时用电池小部件里的电源配置，或者交给 PowerDevil 按电源状态切。插电时 PowerDevil 会切到性能档，要在插电时用平衡档就用命令切过去：

```sh
# 和小部件一样走 PPD 接口；通过 ssh 执行时 polkit 会拒绝，要加 sudo
gdbus call --system --dest org.freedesktop.UPower.PowerProfiles \
    --object-path /org/freedesktop/UPower/PowerProfiles \
    --method org.freedesktop.DBus.Properties.Set org.freedesktop.UPower.PowerProfiles \
    ActiveProfile '<"balanced">'

# 档位没变时 tuned 不会重跑 profile.sh；手动改过参数之后用它重新套用
sudo tuned-adm profile l410-balanced
```

### 查看状态

```sh
cat /sys/kernel/l410_perf/mode          # 当前档位在方括号里
cat /sys/kernel/l410_perf/stats         # 当前各项下限、各种 boost 的次数、累计 boost 时长
tuned-adm active
cat /sys/fs/cgroup$(systemctl --user show -P ControlGroup plasma-kwin_wayland.service)/cpu.uclamp.min
journalctl --user -u l410-perfd         # 档位变化、KWin 的 uclamp
cat ~/.local/state/l410-perfd/launch.log
cat /proc/sys/kernel/sched_pelt_multiplier
cat /sys/class/devfreq/*.ddr_devfreq/cur_freq
sudo sh -c 'cat /sys/kernel/debug/dri/*/kirin_frames'    # 翻页间隔统计
sudo sh -c 'cat /sys/kernel/debug/dri/*/devfreq_boost'   # GPU 当前频率和 boost 次数
```

scx_lavd 运行时 KWin cgroup 的 `cpu.uclamp.min` 是 0，这是正常的（见上文）。

### 可调参数

`/sys/kernel/l410_perf/`：

| 文件 | 含义 | 默认 |
|---|---|---|
| `mode` | `powersave` / `balanced` / `performance`；开机时的值来自启动参数 `l410_perf.mode=`，之后由 tuned 设 | balanced |
| `launch` | 只写：写 N 开始 N ms 的启动 boost（不超过 `launch_max_ms`），写 0 结束 | |
| `input_ms` | 最后一个输入事件后保持多久 | 300 |
| `frame_hold_ms` | 最后一帧新画面后出帧下限保持多久 | 100 |
| `launch_max_ms` | 启动 boost 最长时间 | 3000 |
| `perf_latency_us` | 性能档的 `cpu_latency_qos` | 100 |
| `heavy_floor`、`light_floor`、`frame_floor`、`launch_floor`、`perf_floor` | 五个数：小核、中核、大核、GPU、DDR 的下限（kHz），0 表示不设，2147483647 表示最高档 | 见上文 |
| `stats` | 只读统计 | |

`/sys/module/panfrost/parameters/`：`idle_boost`、`deadline_boost`、`wait_boost`（倍数，0 或 1 为关，默认 2，profile.sh 在省电档设 0）、
`deadline_margin_us`（3000）、`compositor_priority`（Y）；`highpri_submit` 只能在启动时设。

只能在启动参数里设的：`hisi_hwvote_cpufreq.rate_limit_us`（500）、`.fast_switch`（1）、`.energy_model`（1）、`.hw_pressure`（0）；
`kirin990_drm.cursor_plane`（1）、`kirin990_drm.rt_commit`（1）；`kirin990_ddr_devfreq.governor`（performance）；`kirin_clk_keep_on`。
运行时可改：`/sys/module/kirin990_drm/parameters/vblank_filter`、`foreign_import`。

profile.sh 写的那些值（schedutil 限速、PELT 倍率、GPU 采样周期、DDR 调速器、中断亲和性、设备参数）下次切档时会被覆盖。
要长期改，改 `system/perf/profile.sh` 后重新跑 `perf` 阶段。

### 测试

| 脚本 | 内容 |
|---|---|
| `tests/perf.sh` | 功能检查（root）：能耗模型和 EAS、uclamp 和 PELT 接口、调频限速、l410_perf 档位和 boost、GPU boost 和冷却、显示提交线程、光标层、帧统计 |
| `tests/bench/frame-budget.sh [秒]` | 小窗口 60 Hz 预算：feedback、低延迟、EGL、空闲四段，每段的掉帧、提交到上屏延迟、翻页间隔、boost 次数、按能耗模型估的 CPU 能耗 |
| `tests/bench/browser-bench.sh [每段秒数]` | `BROWSER=chromium`（默认）或 `firefox`，哔哩哔哩首页上极限滚动、拖窗、最大化、最小化 |
| `tests/power-modes.sh [秒]` | 拔电后三档和「改动前」的整机功耗：空闲、Chromium 连续滚动 |
| `tests/bench/power-ab.sh [秒] [轮数] [配置...]` | 交错测功耗，功耗对比用这个 |

基准脚本以桌面用户身份在 Plasma 会话里跑，要免密 sudo（读 debugfs、注入 uinput）。要 KWin 的渲染和预测列，得让 KWin 带 `KWIN_LOG_PERFORMANCE_DATA=1` 运行
（做法见 desktop-latency.md）。开机自动登录后 Chromium 第一次启动会停在钥匙环解锁框（自动登录没有密码），页面空白；测试时给 Chromium 加 `--password-store=basic`。

## 已知限制

- Chromium 滚动重页面约 50 fps，受页面主线程限制，性能档也一样。
- KWin 的峰值保持预测器在窗口动画之后会进三缓冲；换上游正在做的新预测算法实测更差（见 desktop-latency.md）。
- 省电档没有出帧下限和 GPU boost，GPU 常在 166 MHz，KWin 容易进三缓冲。
- 省电、平衡档开着 WiFi 省电，入站延迟约 130 ms。
- HW pressure 默认关，没单独验证过。
- 测试中出现过一次「平衡 → 省电 → 5 秒后 → 性能」的误切换：tuned-ppd 收到了外部请求，怀疑是 PowerDevil 短暂判成了低电量。没有复现。
- scx_lavd 下的整机功耗还没有电池实测，只有按能耗模型的估算（见 [sched-ext.md](sched-ext.md)）。

## 没做的

- EEVDF：KWin 主线程唤醒延迟 p99 14 µs、最大 318 µs（ftrace 实测），瓶颈不在这里，`base_slice_ns`、每任务 slice、HZ=1000 都没动。
- 光标更新合并到 vblank 前 1 ms 一次写入（msm 的 async commit 做法）。
- 读 LDI 当前行算精确 vblank 时间戳（`get_scanout_position`）；现在是对中断时刻做滤波。
- GPU 空闲时钳到最低频（msm 的 `gpu_clamp_to_idle`）。
- Panfrost 上下文优先级的正式方案：回移植 6.19 的 JM 上下文 uAPI（Mesa 25.3 起支持）。Mali JM 的 soft-stop 抢占不做。
- DDR 按带宽监控调频（厂商用 DMSS 流量计数，高通是 bwmon）；现在只按 CPU、GPU 频率联动。
- PCIe ASPM、USB autosuspend、UFS WriteBooster、I/O 调度器的分档；启动 boost 期间延长 UFS hibern8 空闲时间。
- Panfrost 和 l410-perf 的 tracepoint；现在靠 debugfs、sysfs 计数。
- Android ADPF 式按目标帧时长闭环调 uclamp。

## 试过但没用

- 去掉 `pd_ignore_unused`、`regulator_ignore_unused`：没用到的电源域（ISP、NPU、编解码、mmbuf）本来就关着，没有可省的电。
- scx_lavd 下照旧给前台应用设 uclamp 下限：小核被钉在最高频，无竞争时滚动 gap2 10.5（不设时 4.3），估算功耗更高。

## 参考

厂商和其他平台的做法，在 6.18 主线上的对应物：

| 来源 | 做法 | 这里 |
|---|---|---|
| 厂商 4.19 | 默认 performance 调速器；HISI_RT_CAS（RT 任务放大核） | UCLAMP 的 RT 容量匹配，只给 KWin |
| 厂商 4.19 | SCHED_TUNE（按 cgroup boost） | cgroup uclamp |
| 厂商 4.19 | WALT | PELT 倍率 + util_est |
| 厂商 4.19 | GPU_SCENE_AWARE 调速器 | deadline / idle boost + 出帧下限 |
| 厂商 4.19 | ddr_devfreq（PM QoS 投票） | devfreq + 硬件投票 + QoS 聚合 |
| 上游 msm / qcom | GPU active / idle / deadline / wait boost、FIFO 工作线程、cpufreq-hw fast switch 和 HW pressure | Panfrost boost、显示驱动 FIFO 提交线程、hisi-hwvote-cpufreq |
| 高通厂商内核 | `cpu-boost.c`（input boost） | l410-perf 输入 / 启动 boost |
| Android | PowerHAL INTERACTION / LAUNCH 提示、top-app uclamp | l410-perfd + cgroup uclamp |

上游资料：
[Utilization Clamping](https://docs.kernel.org/scheduler/sched-util-clamp.html)、
[Energy Aware Scheduling](https://docs.kernel.org/scheduler/sched-energy.html)、
[PELT halflife at runtime（LWN）](https://lwn.net/Articles/906375/)、
[PELT multiplier v2](https://patchew.org/linux/20231208002342.367117-1-qyousef@layalina.io/20231208002342.367117-9-qyousef@layalina.io/)、
[dma-fence deadline 系列 v10](https://patchwork.kernel.org/project/intel-gfx/cover/20230308155322.344664-1-robdclark@gmail.com/)、
[LWN：dma-fence deadline awareness](https://lwn.net/Articles/925071/)、
[msm_gpu_devfreq.c](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/msm/msm_gpu_devfreq.c)、
[msm_fence.c](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/msm/msm_fence.c)、
[msm_gpu.c](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/msm/msm_gpu.c)、
[msm_atomic.c](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/msm/msm_atomic.c)、
[dpu_core_perf.c](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/msm/disp/dpu1/dpu_core_perf.c)、
[qcom-cpufreq-hw.c](https://github.com/torvalds/linux/blob/v6.18/drivers/cpufreq/qcom-cpufreq-hw.c)、
[tuned-ppd（Debian）](https://packages.debian.org/sid/tuned-ppd)、
[PPD 的 platform_profile 驱动](https://freedesktop-team.pages.debian.net/power-profiles-daemon/power-profiles-daemon-Platform-Profile-Drivers.html)。
