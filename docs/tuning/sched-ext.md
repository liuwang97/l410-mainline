# sched_ext 与 scx_lavd

L410 开机就通过 sched_ext 加载 BPF 调度器 `scx_lavd`，省电、平衡、性能三档都开。
本文说明 lavd 在这台机器上做什么、怎么按档位启动、和 uclamp 怎么配合、A/B 测试的数据、
加载 sched_ext 后内核需要的温控修复，以及怎么关掉、换成 `scx_bpfland`、自己编译。

涉及的文件：

- 内核（[linux-l410](https://github.com/liuwang97/linux-l410) 分支 `l410-6.18`）：`l410/configs/95-sched-ext.config`，
  `kernel/sched/fair.c` 里的温控修复（见[温控](#温控)）。
- 用户态：[system/sched-ext](../../system/sched-ext)：`scx-lavd.service`、`scx-bpfland.service`、`scx-run`、
  `scx-kwin-uclamp`、`patches/`、`build-cross.sh`、`build-native.sh`、`install.sh`。
- 联动：[system/perf](../../system/perf) 里的 `l410-perfd`（cgroup uclamp）和 `profile.sh`（切档）。

## scx_lavd 是什么

LAVD 是 Latency-criticality Aware Virtual Deadline 的缩写，用 BPF 写成，运行时加载，进程退出后内核自动退回 EEVDF/EAS。
它由 Igalia 的 Changwoo Min 在 Valve 资助下为 Steam Deck 开发。主要机制：

- 延迟敏感度：观察任务之间的唤醒关系。一个任务常被别的任务唤醒、又常去唤醒别的任务，就处在“输入 → 逻辑 → 渲染”这类链条中间，
  它会得到更早的虚拟截止时间，必要时抢占别的任务。应用不需要配合。
- 核心收拢（core compaction）：负载低时把任务集中到少数几个核上，其余核进深度空闲。核的先后顺序来自能耗模型
  （`/sys/kernel/debug/energy_model`）。L410 有三个簇：pd0 是 4 个 Cortex-A55，pd4 是 2 个 A76 中核，pd6 是 2 个 A76 大核，
  算力分别是 283、767、1024。
- 自己调频：用 `scx_bpf_cpuperf_set()` 给每个核设性能目标，schedutil 以它为基础定频率。
- futex 持锁者加时：先试着挂 fexit，失败再挂 futex 的 syscall tracepoint；`--no-futex-boost` 可以关掉。
  本内核没开 `FUNCTION_TRACER`，所以总是走 tracepoint。
- 模式：`--autopilot`（默认，按负载自动切换）、`--powersave`、`--balanced`、`--performance`、`--autopower`（跟随 power-profiles 的 D-Bus 档位）。
- 兜底：有任务 30 s 没被调度到，内核会自动卸载 BPF 调度器。按 SysRq-S 或者结束 `scx_lavd` 进程效果一样，所有任务回到 EEVDF/EAS。

`scx_bpfland` 简单得多：按任务主动让出 CPU 的频率区分交互型和非交互型，交互型优先。没有链条分析，也没有省电逻辑。

sched_ext 只调度普通任务。KWin 的合成线程（`kwin_wayland`、`eDP-1`、`libinput-connec`）是 SCHED_RR 实时任务，不归 lavd 管。
lavd 起作用的地方在 KWin 以外：负载竞争下的浏览器和应用、Xwayland、后台任务，以及核心收拢省下的电。

### 在本机上的运行情况

- 运行时 `/sys/kernel/sched_ext/state` 是 `enabled`，`/sys/kernel/sched_ext/root/ops` 是 `lavd_1.1.3_aarch64_unknown_linux_gnu`。
  停止后回到 `disabled`，内核日志打印 “unregistered from user space”，没有看门狗卸载或其他错误。
- futex 加时：启动日志里有 “Fail to attach futex ftraces. Try with tracepoints.”，之后没有 tracepoint 挂载失败，走的是 syscall tracepoint。
- 能耗模型用上了。按负载选核：20% 以下只用小核（顺序 2、3、0、1），30% 左右加上大核 6、7，50% 以上以中核和大核为主，满载 8 核全用。
- s2idle 挂起再唤醒后 lavd 仍在运行。

## 内核要求

`l410/configs/95-sched-ext.config`：

| 选项 | 原因 |
|---|---|
| `# CONFIG_DEBUG_INFO_REDUCED is not set` | arm64 defconfig 开着它，BTF 要求关掉 |
| `CONFIG_DEBUG_INFO_BTF=y` | `SCHED_CLASS_EXT` 依赖 BTF；编译机要有 pahole（实际用的是 1.30） |
| `CONFIG_SCHED_CLASS_EXT=y` | sched_ext 本身 |
| `CONFIG_BPF_JIT_ALWAYS_ON=y` | scx 的 README 列为必需：只用 JIT，去掉 BPF 解释器 |
| `CONFIG_FTRACE_SYSCALLS=y` | 没有 `FUNCTION_TRACER` 时，lavd 的 futex 加时靠 syscall tracepoint |
| `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` | 单独重编、装到已安装内核上的模块（例如 hi110x.ko）BTF 对不上时只打警告，仍然能加载 |

另外 `96-desktop.config` 关掉了 `CONFIG_TRACEFS_AUTOMOUNT_DEPRECATED`：scx 内置的 libbpf 先找 `/sys/kernel/debug/tracing`，
那里的自动挂载每次开机都打印一条弃用提示；关掉后 libbpf 改用 systemd 挂好的 `/sys/kernel/tracing`。

代价：BTF 让 `Image` 从 38.16 MB 变成 39.55 MB（+1.39 MB），`/sys/kernel/btf/vmlinux` 有 7.1 MB。
改调试信息选项会让编译缓存全部失效，第一次要全量重编。

没加载 BPF 调度器时，行为和不带 sched_ext 的内核一样（`tests/quick.sh`、`tests/perf.sh` 结果相同）。在机器上确认：

```bash
ls -l /sys/kernel/btf/vmlinux
cat /sys/kernel/sched_ext/state          # 没加载调度器时是 disabled
zcat /proc/config.gz | grep -E "SCHED_CLASS_EXT|DEBUG_INFO_BTF|BPF_JIT_ALWAYS_ON|FTRACE_SYSCALLS"
```

## scx 的补丁

用的是 scx v1.1.3，加 `system/sched-ext/patches/` 里的两个补丁，编译脚本按顺序自动打上。

`0001-skip-fentry-init-probe.patch`：v1.1.3 原样加载会失败。scx 公共库在 `bpf_scx_reg()` 上挂了一个 fentry 程序 `scx_lib_init_probe`，
挂载返回 -ENOTSUPP（524）：内核没开函数跟踪器，arm64 没有函数入口的补丁点，挂不了 fentry。
这个探针只对 6.18 以前或者没有 PREEMPT_RCU 的内核有意义，本内核两样都不是。
补丁在 scx_utils 的 `__scx_ops_load` 里检查 `/sys/kernel/tracing/available_filter_functions`，没有就不加载这个探针。
它只看 tracefs，不碰 debugfs 下的路径，免得触发上面那条自动挂载提示。内核的函数跟踪器没有为此打开。

`0002-scx_lavd-prefer-big-cores-for-user-tasks.patch`：新增 `--prefer-big-uid`，见[大核优先](#大核优先--prefer-big-uid)。

## 按电源档位启动

`install.sh` 把 `scx-lavd.service` 设为开机启动，服务运行 `/usr/local/lib/l410-perf/scx-run lavd`。
`scx-run` 启动时读 `/sys/kernel/l410_perf/mode`，选参数：

| 档位 | scx_lavd 参数 | KWin 实时线程的 uclamp_min |
|---|---|---|
| 省电 | `--powersave` | 283 |
| 平衡 | `--balanced --prefer-big-uid 1000` | 1024 |
| 性能 | `--performance --prefer-big-uid 1000` | 1024 |

- 档位由 PowerDevil 按电源切换：插电是性能档，电池是平衡档，低电量是省电档。切档时 `profile.sh` 重启 `scx-lavd.service`，新参数随之生效。
  没有用 `--autopower`：lavd 连的是旧的 D-Bus 名 `net.hadess.PowerProfiles`。
- lavd 运行期间，`scx-run` 每 5 s 调一次 `scx-kwin-uclamp set`（KWin 重新登录、新开实时线程都能跟上），lavd 退出时调 `scx-kwin-uclamp clear` 清零。原因见下一节。
- 二进制不认识 `--prefer-big-uid`（例如原版 lavd）时，`scx-run` 不加这个参数。
- 单元带 `ConditionPathExists=/sys/kernel/sched_ext/state`，内核没有 sched_ext 时直接跳过；`Restart=on-failure`，5 s 后重启；
  和 `scx-bpfland.service` 互斥（`Conflicts=`）。
- 环境变量：`SCX_EXTRA` 追加参数（例如对照用的 `--no-use-em`），`SCX_BIG_UID` 改 uid 门槛（默认 1000）。用 `systemctl edit scx-lavd.service` 加：

  ```ini
  [Service]
  Environment=SCX_EXTRA=--no-use-em
  ```

## 大核优先（--prefer-big-uid）

lavd 原来按 `perf_cri` 给任务分大小核，桌面程序经常落在 A55 上：

- 开始菜单的渲染线程 3/4 的时间跑在 A55 上，耗时是放在大核时的两倍。
- 系统设置启动时主线程有 0.3-0.45 s 在小核上。只用 A55 时系统设置启动要 4 s 以上，只用 A76 大核时 1.27 s。
- Chromium 打开 bilibili 时，渲染主线程 49-59% 的时间在 A55 上（EAS 下 70-78% 在大核）。把它绑到大核，它的 CPU 时间从约 75% 降到约 45%，
  但滚动掉帧没有明显变化。

补丁 `0002` 加了两个选项：`--prefer-big-uid N` 和 `--prefer-big-wait-pct`（默认 260）。

- 适用的任务：uid ≥ N、nice ≤ 0、不是 SCHED_IDLE 或 SCHED_BATCH、不是内核线程。系统守护进程、内核线程、降了优先级的后台任务仍按原来的方式放置。
- 选核顺序：上次所在的核如果是空闲的 A76 就用它；否则按大核 6、7，中核 4、5 的顺序找空闲的 A76。
- 四颗 A76 都忙时，挑预计最先空出来的一颗。预计等待 = 正在运行的任务预计结束的时间 + 这颗核自己的队列 + 大核域队列平摊到每颗大核。
  预计等待不超过任务在最快核上平均运行时间的 260%（限制在 1-8 ms）时，任务进这颗核的每核队列排队。
  用每核队列是因为空闲的 A55 不会去偷每核队列里的任务，域队列里的会被偷走。
- 超过预算才交回 lavd 原来的选核逻辑，这时才可能放到 A55 上。260% 的依据：同样的活 A55 大约要 3.6 倍的时间，
  等待超过 2.6 倍运行时间时，放到 A55 上反而先做完。

`scx-run` 在平衡档和性能档加 `--prefer-big-uid 1000`，省电档不加。平衡档（电池供电，核心收拢照样工作）下的效果：
QQ 主线程在 A55 上的时间是 0-20%，Firefox 是 0-1%，其余时间在 A76 大核和中核之间。
WPS 主线程仍有 8-37% 的时间在 A55 上：WPS 自己、wpscloudsvr、Xwayland、KWin 实时线程把四颗 A76 都占满时，按设计退回 A55。

## 和 uclamp 的配合

依据 6.18.54 的源码：`kernel/sched/ext.c` 里 sched_ext 的调度类带 `.uclamp_enabled = 1`，`kernel/sched/cpufreq_schedutil.c` 的 `sugov_get_util()`
和 `kernel/sched/fair.c` 的 `effective_cpu_util()` 照常应用 uclamp；scx_lavd 的源码里没有任何地方读 uclamp。

| 层面 | 加载 lavd 后 | 说明 |
|---|---|---|
| KWin 的实时线程 | 不变 | lavd 不调度 RT 任务。`rt_task_fits_capacity()` 照旧按 uclamp_min 选核，频率也照旧按 uclamp_min 请求 |
| 普通任务的频率 | 叠加 | 基础值是 lavd 设的性能目标，下限和上限由这个核上可运行任务的 uclamp 聚合值决定（频率 ≥ uclamp_min，≤ uclamp_max）。cgroup 的 `cpu.uclamp.min` 仍然有效 |
| 普通任务的选核 | uclamp 不起作用 | EAS 会读 uclamp_min 把任务挪到算力够的核上；lavd 用自己的选核逻辑，不看 uclamp |
| `freq_qos`（输入 boost、启动 boost、各档的频率下限）和温控上限 | 不变 | 和调度器无关 |
| PELT 倍率（`sched_pelt_multiplier`） | 对 lavd 调度的任务无效 | 它只改 CFS 的负载统计，lavd 用自己统计的负载 |

会出问题的组合：普通任务的 uclamp_min 超过它所在核的算力，lavd 又把它放在小核上。这时小核被钉在最高频 1.86 GHz，算力却只有 283，
性能没拿到，功耗照付。EAS 下的配置里有两处会这样：

1. 前台应用：`l410-perfd` 给活动窗口所在的 cgroup 设 `cpu.uclamp.min`，平衡档 37.5%（384），性能档 50%（512），都超过小核的 283。
2. KWin 的 cgroup（`plasma-kwin_wayland.service`）：平衡档和性能档是 `max`。这个 cgroup 里除了 KWin 的实时线程，
   还有普通线程 `QDBusConnection`、`QQmlThread`、`kwin_wa:disk$0`，以及 `kwin_wayland_wrapper` 和 Xwayland 进程。
   EAS 会把这些普通任务送上大核；换成 lavd 后，它们落在哪个核上，就把哪个核钉在最高频。

所以 sched_ext 运行时（`/sys/kernel/sched_ext/state` 为 `enabled`）改成这样：

- `l410-perfd` 不给前台应用设 uclamp 下限，应用启动时也不设 uclamp max（内核的启动 boost 保留），KWin 的 cgroup 设为 0。
  它监视 state 的变化，调度器停掉后恢复 EAS 下的设置。
- KWin 实时线程的下限由 `scx-kwin-uclamp` 用 `sched_setattr()` 逐个线程设（`SCHED_FLAG_UTIL_CLAMP_MIN`，保留调度策略和优先级），
  取值见上一节的表。cgroup 里的 Xwayland 和普通线程不受影响。
- 这一步必须由 root 做：`kwin_wayland` 带文件能力 CAP_SYS_NICE，按 capability 的规则，普通用户的进程改不了它的线程调度参数
  （`sched_setattr` 返回 EPERM）。所以放在以 root 运行的 `scx-run` 里，而不是用户态的 `l410-perfd`。

在机器上确认过：lavd 运行时 KWin 的 cgroup 是 0，三个 RR 线程的 uclamp_min 是 1024；停掉 lavd 后线程回到 0，cgroup 回到 `max`。

## A/B 测试

条件：平衡档、插电，`tests/bench/scx-ab.sh 3`。每轮用 `tests/bench/browser-bench.sh` 在 Chromium 上打开 bilibili，滚动、拖动、最大化、最小化各 8 s，
各配置交替跑 3 轮；bilibili 没加载出来的组（滚动或拖动帧数 < 200）剔除。竞争负载是 app scope 里 8 个 stress-ng 工作线程，相当于终端里在编译。
gapN 是 8 s 内相邻两帧间隔为 N 个刷新周期的次数（gap2 即丢 1 帧）。CPU 功耗是 browser-bench 按能耗模型和忙时估算的，不是电池实测。

| 配置 | 调度 | KWin uclamp | 前台应用 uclamp |
|---|---|---|---|
| A | EEVDF/EAS | cgroup `max` | 37.5% |
| B（现在的默认） | lavd `--balanced` | 只给实时线程 | 不设 |
| C | lavd `--balanced` | cgroup `max` | 37.5%（用来量钉频的代价） |

| 负载 | 配置 | 有效轮 | 滚动 fps | gap2 | gap3 | gap4+ | 拖动 fps | 拖动 gap2+ | CPU mW 滚动 / 拖动 / 最大化 / 最小化 |
|---|---|---|---|---|---|---|---|---|---|
| 8 线程 stress-ng | A EAS | 3/3 | 39.8 | 12.3 | 4.0 | 11.0 | 55.7 | 3.7 | 3548 / 3411 / 3562 / 3607 |
| | B lavd | 3/3 | 45.3 | 6.3 | 1.3 | 11.7 | 56.0 | 4.3 | 3914 / 3914 / 3902 / 3900 |
| | C lavd + 旧 uclamp | 3/3 | 45.8 | 7.0 | 2.7 | 11.0 | 56.2 | 4.7 | 3911 / 3914 / 3901 / 3901 |
| 无 | A EAS | 2/3 | 49.9 | 5.5 | 1.0 | 4.0 | 55.4 | 3.5 | 947 / 320 / 746 / 87 |
| | B lavd | 3/3 | 48.4 | 4.3 | 2.7 | 6.7 | 57.6 | 2.3 | 590 / 324 / 344 / 143 |
| | C lavd + 旧 uclamp | 2/3 | 42.4 | 10.5 | 4.0 | 8.0 | 56.6 | 2.0 | 740 / 381 / 471 / 108 |

- 负载竞争下 B 明显更好：滚动 gap2 从 12.3 降到 6.3，gap3 从 4.0 降到 1.3，帧率高 14%。这正是 lavd 的设计目标：交互链条优先于批处理。
  gap4+（窗口动画开头的长间隔）不变。
- 无竞争时持平：滚动帧率和丢帧在噪声范围内，拖动略好。轻载交互的 CPU 能耗估算明显更低（滚动低 38%，最大化低 54%），来自核心收拢。
  满载时 lavd 让所有核跑在高频，估算多约 10%。
- C 比 B 差（无竞争时 gap2 10.5，功耗也更高），证实了上一节的钉频问题。lavd 下必须用 B 的 uclamp 安排。
- 无竞争时 lavd 下每 8 s 仍有约 4 次 gap2，说明剩下的丢帧不是 CPU 调度造成的。

据此默认开启 lavd：竞争下丢帧明显更少，轻载的估算功耗不高于 EAS。

几点限制：

- 这组数据是在加 `--prefer-big-uid` 之前测的。
- 功耗只有能耗模型的估算。电池实测要拔掉电源，`tests/bench/power-ab.sh` 里有 lavd、lavd-uclamp、bpfland、lavd-powersave 几种配置，还没跑。
- bpfland 是 `scx-ab.sh` 的可选配置 D，没有数据。

复现：在桌面会话里以桌面用户运行 `bash tests/bench/scx-ab.sh [轮数] [配置] [负载]`，需要免密 sudo；结果在 `/var/tmp/l410-scx-ab/<时间>/`。
配置 C 靠 `/run/l410-perfd.noscx`：这个文件存在时 `l410-perfd` 忽略 sched_ext，保留 EAS 下的 uclamp。

## 温控

现象：lavd 运行时温控 IPA（power_allocator）完全不限频。模拟大核所在温区（cluster2）95 °C、cpu6-7 满载，lavd 下一直是 2861 MHz；
EEVDF/EAS 下一个轮询周期就降到 1882 MHz。

原因：cpufreq_cooling（以及 dtpm_cpu）用 `sched_cpu_util()` 估算 CPU 负载，它只读 CFS 的 PELT 统计。sched_ext 上的任务不在里面，
IPA 以为 CPU 空闲，给了全部功率预算。schedutil 的 `sugov_get_util()` 已经处理了这种情况：从 SCX 调度器的 cpuperf 目标出发，
只有不是全部普通任务都在 SCX 上时才加上 CFS 的负载。

修复：内核提交 `sched/fair: count sched_ext load in sched_cpu_util()`（`kernel/sched/fair.c`），让 `sched_cpu_util()` 用和 `sugov_get_util()` 一样的输入：

```c
unsigned long util = scx_cpuperf_target(cpu);

if (!scx_switched_all())
	util += cpu_util_cfs(cpu);

return effective_cpu_util(cpu, util, NULL, NULL);
```

验证：修复后 lavd 下立即限频，但比 EAS 平缓。6 s 时 lavd 是 2218 MHz（冷却状态 6），EAS 是 1536 MHz（状态 12），之后由 IPA 的积分项继续收紧。
持续满载时温度会比 EAS 下略高一些，再被积分项压住。要和 EAS 一样快，可以改成按空闲时间估算负载（cpufreq_cooling 的非 SMP 实现），目前没做。

任何 sched_ext 调度器都有这个问题，不只是 lavd，跑 sched_ext 的内核都要带这个补丁。`tests/quick.sh` 的 `thm.emul-throttle` 检查模拟 95 °C，
3 s 内不限频就判失败。

## 关掉，或者换成 bpfland

```bash
cat /sys/kernel/sched_ext/state /sys/kernel/sched_ext/root/ops   # 当前状态
journalctl -u scx-lavd.service                                   # lavd 的输出

sudo systemctl stop scx-lavd.service                 # 临时停掉，回到 EEVDF/EAS
sudo systemctl disable --now scx-lavd.service        # 以后开机也不启动
sudo SCX_DEFAULT=none system/install.sh sched-ext    # 重装时装成不启用
```

停掉后 `scx-run` 清掉 KWin 实时线程的 uclamp，`l410-perfd` 看到 state 变成 `disabled`，恢复 EAS 下的 cgroup uclamp。

换成 bpfland：`sudo systemctl start scx-bpfland.service`（互斥，会先停掉 lavd）；要开机启动就 `disable scx-lavd.service`、`enable scx-bpfland.service`。
bpfland 不分档位，`scx-run` 只给它加 `SCX_EXTRA`；KWin 实时线程的 uclamp 和 `l410-perfd` 的处理与 lavd 相同。

手动试运行（先停掉服务）：`sudo scx_lavd --stats 1`，Ctrl-C 退出。
卡住时：内核 30 s 内会自动卸载；ssh 还通就 `sudo pkill -x scx_lavd`。

## 编译

`install.sh` 发现 `/usr/local/bin` 里没有 `scx_lavd`、`scx_bpfland` 时，从本仓库的 release 下载预编译的版本（按 `system/assets.sha256` 校验）。
自己编译有两种办法，都会先打上 `patches/` 里的补丁（已经打过的跳过）。scx v1.1.x 要求 Rust ≥ 1.91、clang ≥ 18、libbpf ≥ 1.2.2，
scx_lavd 用到了 BPF arena。Debian trixie 的源里没有 scx 包。

在 PC 上交叉编译（x86-64 的 Debian 或 WSL，16 核的机器上约 80 s）：

```bash
bash system/sched-ext/build-cross.sh            # 默认下载 scx v1.1.3 源码包；也可以给一个本地 tarball
# 产物：~/.cache/l410-scx/<源码目录>/target/aarch64-unknown-linux-gnu/release/scx_{lavd,bpfland}
# 拷到 L410 的 /usr/local/bin/
```

脚本第一次运行时会装 rustup 和 aarch64 目标、clang/llvm，并启用 arm64 多架构，装 arm64 的 libelf、zlib、zstd 用来链接。

在 L410 上原生编译（8 核满载约 30 min）：

```bash
bash system/sched-ext/build-native.sh [--src scx-v1.1.3.tar.gz] [--tag v1.1.3] [--fg]
journalctl --user -fu scx-build                 # 默认在用户单元 scx-build 里以 nice 19 后台编译，ssh 断开也不中断
```

- 以桌面用户运行，apt 和安装用 sudo；编完装到 `/usr/local/bin/`。
- Debian forky 的 rustc 是 1.95，直接用 apt 的工具链；版本低于 1.91 时给当前用户装 rustup（默认走 USTC 镜像，可用 `RUSTUP_DIST_SERVER` 改）。
- crates 走 USTC 镜像（写进 `~/.cargo/config.toml`）。`--src` 用于机器上访问不了 GitHub 的情况。
- 编译时不要做性能或功耗测量。
