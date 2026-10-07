# 桌面帧延迟

这篇讲 L410 上 KWin 的帧时序：KWin 什么时候开始合成一帧，原来是什么让桌面「帧率够但手感肉」，现在 60 Hz 还差在哪里，以及为什么没有 120 Hz。
对应的内核和用户态改动（uclamp、各种 boost、调频限速、DDR 调频、三档模式）见 [perf-power.md](perf-power.md)，这里不重复。

KWin 的行为按 v6.3.6 源码核对（`renderjournal.cpp`、`renderloop.cpp`、`drm_commit_thread.cpp`、`glrendertimequery.cpp`）。
现在 Debian forky 上的 KWin 6.7.4 预测器没有变，安全余量的默认值变了（见下）。

## 显示时序

- 内屏由 UEFI 点亮，内核的 kirin990-dss 驱动接管这条管线，从 DSI/LDI 寄存器读回模式：2160×1440，htotal 2320，vtotal 1480，像素时钟 206.016 MHz。
  按这些值算，行时间 11.26 µs，扫描 1440 行 16.22 ms，vblank 40 行 0.45 ms。
- 像素时钟实际来自 D-PHY PLL，从时序寄存器算不出来。面板实测 60.51 Hz，不是 60 Hz。驱动接管时在挂中断前对 16 帧的原始 VSYNC 计时，
  按实测周期上报（内核日志 `measured frame period`）。按 60 Hz 上报时，KWin 用错误的周期排帧，空闲后外推下一个 vblank 会偏几毫秒，
  结果是「提前画完却晚一帧上屏」。
- vblank 中断原来落在 CPU0（小核），时间戳取自中断处理时刻，带着中断延迟的抖动；KWin 的帧调度和内核的 fence 截止时间都以它为基准。驱动现在对它做滤波。

## KWin 怎么排帧

渲染时间：从 CPU 开始合成，到 GPU 执行完最后一条命令（GPU 时间戳），最少按 2 ms 算。它包括 KWin 主线程的 CPU 时间、drm_sched 把 job 交给硬件前的等待、
排在客户端 GPU job 后面的时间和 GPU 执行时间。

预测值（`renderJournal.result`）= 平滑均值 + 2 × 偏差：

- 均值的时间常数是 0.5 s。
- 偏差不是统计意义上的方差，而是峰值保持：`m_variance = max(mix(diff, m_variance, ratio), diff)`。某一帧比均值多出 S ms，偏差立刻变成 S，之后按 6 s 的时间常数衰减。

开始合成的提前量 = `min(result + safetyMargin + 1 ms, 2T)`：

- KWin 6.3.6 的 safetyMargin = vblank 时长 + 1.5 ms = 1.95 ms，固定部分合计 2.95 ms。KWin 6.7 默认是 vblank 时长 + 1000 µs，再加一个自适应部分，日志里是 2.35 ms。
- 提前量超过一帧就立即切到三缓冲，提前约两帧开始合成；切回双缓冲要连续 10 帧低于 0.95 帧。
- KWin 逐帧日志里的 predicted render time 只是 `result`，不含 safetyMargin 和那 1 ms。
- 空闲超过约 100 个帧周期后另有一条提前渲染的分支，统计时冷启动的帧要和连续动画的帧分开。

在 KWin 6.3.6、60 Hz 下，由此得出的门槛：

- 双缓冲要求 `result` ≤ 16.67 - 2.95 = 13.7 ms；从三缓冲回来要连续 10 帧 `result` < 12.9 ms。
- 均值 2.5-3 ms 时偏差要小于约 5.4 ms，也就是只要有一帧渲染超过约 8 ms，KWin 就进三缓冲，并停留约 6 s × ln(S/5.4)：超出均值 10 ms 约 4 s，超出 22 ms 约 8 s。
- 三缓冲时提交到上屏约 2 帧（33-40 ms），双缓冲约 1 帧。

所以要压的是尾部：超过 8 ms 的帧要少到每 5-10 s 不到一次（约 p99.8），平均值再低也没用。perf-power.md 里单帧 ≤ 7 ms 的预算就是这么来的。

另外两点：

- KWin 会把每帧的截止时间告诉内核：提交线程对渲染 fence 调 `SYNC_IOC_SET_DEADLINE`，截止 = 目标翻页时刻减 safetyMargin。Panfrost 原来没实现 `.set_deadline`，
  这个提示被丢掉了；现在用它做 deadline boost。
- 客户端提交晚了的时候，KWin 6.3 仍会去赶即将到来的 vblank，不检查来不来得及。画面结果和晚一帧一样，属于客户端出帧慢。

## 原来卡在哪里

改动前（KWin 6.3.6，内核没开 uclamp），KWin 稳定 60 fps，594 帧里没有掉帧，驱动每次翻页都按时；但每帧从提交到上屏要 33-40 ms，
低延迟客户端被拖到 30 fps。帧率不是问题，问题是 KWin 一直在三缓冲。

KWin 逐帧日志，每组 12 s，负载相同：

| 配置 | 渲染 中位 / p90 / 最大 ms | 预测 中位 / p90 ms | 开始渲染到上屏 中位 ms |
|---|---|---|---|
| 基线 | 3.3 / 7.4 / 24.8 | 25.5 / 38.4 | 28.9 |
| KWin 实时线程绑 CPU6-7 | 2.4 / 7.2 / 12.1 | 13.5 / 21.9 | 16.7 |
| GPU 最低频设 600 MHz | 2.3 / 5.0 / 14.8 | 15.7 / 23.8 | 18.8 |
| 两者都做 | 2.1 / 4.0 / 8.9 | 10.0 / 14.7 | 13.5 |
| 再加禁用 cluster-sleep | 2.1 / 3.8 / 8.7 | 8.3 / 12.4 | 12.1 |
| 只禁用 cluster-sleep | 2.9 / 7.6 / 22.6 | 24.3 / 40.8 | 27.8 |

两项都做后 KWin 回到双缓冲，低延迟模式恢复 60 fps。波动的来源有三个：

1. KWin 的三个 SCHED_RR 线程（主线程、`eDP-1` 提交线程、libinput 线程）落在 A55 小核（CPU1-3，算力 283/1024）上，小核频率在 554-1863 MHz 之间跳。
   没开 uclamp 时 `rt_task_fits_capacity()` 恒为真，RT 任务不挑大核。
2. GPU 在 166 和 600 MHz 之间跳。simple_ondemand（upthreshold 45%，采样 50 ms）下桌面合成的 GPU 占用约 8%，按利用率永远选最低档。
   GPU 本身不慢：KWin 每帧的 GPU 时间 166 MHz 下约 1.3 ms，600 MHz 下 0.5-0.75 ms（打开 Panfrost 的 `profiling` 后从 fdinfo 的 `drm-engine-*` 算出的平均值，
   含硬件队列里的等待，不是严格的单帧执行时间）。
3. 显示驱动导入外来 dma-buf 走 swiotlb，每次在 KWin 主线程上卡 1-3.6 ms，发生在开窗口、菜单、弹窗、调整大小时，一次就能把 KWin 推进三缓冲好几秒。

排除了的：

- 驱动翻页：DRM 调试日志里 KWin 在 vblank 前约 1.9 ms 提交，commit_tail 在 0.03-0.3 ms 内写完寄存器，下一个 vblank 翻页，92 次提交全部按时。
- GPU 时间戳频率 1.92 MHz，和 arch timer 一致；GPU runtime resume 只要 0.15 ms；Panfrost 的 profiling 开关不影响延迟。
- cpuidle：见下一节，RT 唤醒 p99 不到 0.65 ms。DT 里 cluster-sleep 标的 5.5 / 6 ms 是进入加退出之和，比实际保守得多。
- EEVDF：KWin 的三个关键线程是 RR，不走 EEVDF；KWin 主线程唤醒延迟 p99 14 µs、最大 318 µs（ftrace 实测）。

## 一帧 CPU 突发在各簇上的表现

`tests/bench/framelat.c` 模拟合成器的一帧：每 16.67 ms 由绝对定时器唤醒一次，然后做一段在该核最高频下要 2 ms 的计算，统计唤醒延迟、突发的实际耗时、
突发开始后多久升到最高速度的 90%。桌面空闲时测，每组 300 帧，schedutil 限速是原来的 3000 µs：

| 配置 | 唤醒 p99 / 最大 µs | 突发 中位 / p90 / p99 / 最大 ms（理想 2.0） | 升到 90% 速度 中位 / p90 ms |
|---|---|---|---|
| 小核 cpu1，RR | 464 / 714 | 2.36 / 4.26 / 6.59 / 6.76 | 0.60 / 3.35 |
| 中核 cpu4，RR | 610 / 646 | 2.41 / 2.61 / 3.99 / 4.35 | 0.67 / 1.07 |
| 大核 cpu6，RR | 434 / 771 | 2.33 / 3.81 / 4.14 / 4.14 | 0.36 / 3.55 |
| 小核 cpu1，CFS | 510 / 592 | 4.95 / 6.79 / 6.80 / 6.81 | 3.11 / 6.79 |
| 中核 cpu4，CFS | 610 / 620 | 5.31 / 5.62 / 5.64 / 5.64 | 5.31 / 5.62 |
| 大核 cpu6，CFS | 1920 / 3965 | 3.90 / 4.12 / 4.14 / 4.17 | 2.58 / 4.12 |

改 schedutil 的 `rate_limit_us` 后 RT 突发的耗时：

| rate_limit_us | 小核 RR：p90 / p99 / 最大 ms | 大核 RR：p90 / p99 / 最大 ms |
|---|---|---|
| 3000（原来） | 4.26 / 6.59 / 6.76 | 3.81 / 4.14 / 4.14 |
| 1000 | 2.61 / 4.99 / 6.68 | 2.44 / 3.94 / 4.08 |
| 500 | 2.54 / 3.00 / 4.68 | 2.42 / 2.60 / 2.80 |
| 200 | 2.55 / 2.58 / 2.68 | 2.34 / 2.50 / 3.18 |

CFS 在各档限速下都是 4.1-6.8 ms，没有改善；小核在 500 和 200 两档下 CFS 反而更慢，因为降频也变快了。

读法：

1. 唤醒不是瓶颈：RT 唤醒 p99 不到 0.65 ms，最大不到 0.9 ms。大核 CFS 那组的 1.9 / 4.0 ms 只出现过一次，重测 p99 是 0.4 ms。
2. LPM3 实际调一次频约 0.4-0.8 ms（RT 升频时间的中位数）。固件写的 2 ms 让限速变成 3 ms，一帧开始时离上次调频不到 3 ms 就只能在低频跑完，
   RT 突发的 p90、p99 因此翻倍。限速 500 µs 后 p99 从 6.6 / 4.1 ms 降到 3.0 / 2.6 ms，平衡、性能档现在用 500 µs。
3. 普通任务的 60 Hz 短突发始终升不上频，比最高频慢 2-2.7 倍。这是按利用率调频的必然结果：占空比 12% 的任务，平均需求本来就只够低频。
   KWin 的 RT 线程不受影响，受影响的是所有客户端（plasmashell、Qt / GTK 应用、Xwayland、浏览器）和跑在 CFS 上的 kworker。现在靠前台 uclamp、输入和启动 boost。
4. 「理想 2.0 ms」是按各核自己的最高频算的。同样的活小核要 1024/283 ≈ 3.6 倍的时间，KWin 在小核上吃两层亏：本身慢，再加调频抖动。

## 提交路径上的等待

一帧从 KWin 到屏幕要经过：libinput 线程 → KWin 主线程 → SUBMIT → drm_sched 的提交 kworker → GPU 完成中断 → KWin 提交线程 → 显示驱动写寄存器 → vblank。
原来这条路上有几处普通优先级的环节，RT 的 KWin 会被它们拖住：

- Panfrost 的提交 kworker 是 nice 0 的 CFS 线程，CPU 忙时要等当前任务的 slice 保护期（最长 2.8 ms）再等一个 tick（HZ=250，最多 4 ms）。
- 所有 GPU 上下文都是 NORMAL 优先级，先来先服务；每个 job slot 的硬件队列里还能压 2 个 job（`credit_limit` 2）。
- 显示驱动的 commit_tail 在 `system_unbound_wq` 上；空闲时提交线程在 vblank 前 1.95 ms 提交，余量足够，有 CPU 负载时可能被吃掉。
- GPU 完成中断和 vblank 中断都在 CPU0（小核）上。

这几处现在的处理见 perf-power.md 的「Panfrost：msm 式升频」和「显示驱动」两节。

## 现在剩下的掉帧

条件：Plasma 6.7.4，KWin 用 GLES 合成，平衡档。合成器这一侧已经满足 60 Hz：小窗口测试里 KWin 渲染中位 2.1 ms、p99 4.3-6.1 ms，100% 双缓冲；
Firefox ESR 140 在哔哩哔哩首页上极限滚动 58.3 fps、拖窗 60.4 fps。升级到 Plasma 6.7 时的逐项对照见 [desktop.md](desktop.md)。剩下的问题有两个。

### KWin 的预测器仍会被动画带进三缓冲

33 000 多帧的 KWin 日志（滚动和窗口动画）：实际渲染中位 2.2 ms、p99 7.9 ms，预测值中位 9.4、p90 20.0、p99 37.6 ms，
vblank 前中位 12.8 ms 就开始合成，24% 的帧需要三缓冲。原因还是峰值保持：窗口动画里偶尔一帧长，偏差就被撑起来好几秒。
换预测算法、去掉三缓冲、把安全余量设成 0 都试过，都没让客户端更顺（见「试过但没用」）。

### Chromium 在重页面上到不了 60 fps

Chromium 154 在哔哩哔哩首页上极限滚动（每 20 ms 三格）约 49-50 fps，每 8 s 有 5-8 次隔一帧。滚动时 GPU 不忙（Chromium 21%、KWin 8%），性能档结果也一样。

用 CDP 抓 Chromium 的 trace，同时开 KWin 逐帧日志，两边都是 CLOCK_MONOTONIC，把 Chromium 每次提交（`WaylandBufferManagerHost::CommitOverlays`）
对到 KWin 开始合成的时刻，给每个没有新画面的 vblank 归类（抓 trace 有开销，这两轮是 45 fps，比例可参考）：

| 没有新画面的 vblank | 第 1 轮（387 个 vblank） | 第 2 轮（427 个） |
|---|---|---|
| 渲染进程的 Compositor 在等页面主线程（`SKIPPED_REASON_WAITING_ON_MAIN`） | 28 | 47 |
| 交帧晚了（KWin 已开始合成这一帧，多数晚 0.1-6 ms） | 20 | 33 |
| Chromium 主动跳过（`DRAW_THROTTLED`、无变化等） | 12 | 50 |
| 无法归因（多在开头、结尾和静止时） | 25 | 19 |

- 滚动本身在 Compositor 线程上（`SCROLL_COMPOSITOR_THREAD`），没有被 JS 卡住。
- 页面主线程忙 61-64%，超过 16 ms 的任务 43 个，合计约 2.8 s / 7 s。最长的是 `BeginMainFrame` 里的样式和布局（`LocalFrameView::performLayout`），
  信息流追加新卡片时一次 85-290 ms；其次是页面 JS 定时器，77-205 ms。一次 290 ms 的布局就是连续 11 帧没有新画面。
- Chromium 的 Wayland 后端提交下一帧前要等 KWin 回上一帧的 frame callback（7 s 内 189 次，中位 5.5 ms，最长 16.9 ms），最多 3 帧在途，只在录屏时跳过，没有用户开关。
- Firefox 的 APZ 不等页面主线程，所以同一个页面能到 58-60 fps。

结论：剩下的掉帧主要是页面自己的主线程负载（排版和 JS）。A76 的单线程性能让这些任务更长，但即使在快得多的 CPU 上它们也超过一帧，CPU 调度解决不了。
重页面日常用 Firefox 更顺。

有后台 CPU 竞争时，scx_lavd 能让 Chromium 滚动的隔帧减半、帧率提高约 14%；没有竞争时持平（见 [sched-ext.md](sched-ext.md)）。

## 试过但没用

- 只禁用 cluster-sleep：平均值略好，KWin 仍在三缓冲（见上面的表）。
- `KWIN_DRM_OVERRIDE_SAFETY_MARGIN=0`（单位 µs）：Chromium 滚动 gap2 12、8 次，默认 5、5 次。安全余量只占提前量约 1 ms，大头是预测值。
- `KWIN_DRM_DISABLE_TRIPLE_BUFFERING=1`：Chromium 掉帧不变；窗口动画时 KWin 自己错过 vblank 的次数明显变多（最大化 / 还原 13、8 次，默认 1 次），
  偶尔超过 8 ms 的帧原来靠提前一帧兜住。
- KWin MR !8517 的预测算法（最近 100 帧均值 + 3σ，去掉峰值保持）：离线重放时三缓冲帧从 24% 降到 1%；实机上提前量中位从 12.8 ms 降到 8.1 ms，三缓冲消失，
  但 Chromium 交给 KWin 的新帧少了约四分之一（滚动 40-43 fps），Firefox 窗口动画掉帧和 KWin 自己 miss 都变多。「KWin 开始合成太早导致客户端隔帧」的假设不成立。
- Chromium 的 `--enable-zero-copy`、关掉模糊和背景对比度、`--disable-features=NewContentForCheckerboardedScrolls`：没有收益；`--disable-gpu-rasterization` 更差；
  ANGLE 改 GLES、关 AV1 软解：没有变化。
- 把 Chromium 的 Compositor、Viz、GPU 主线程、IO 线程绑到 CPU4-7 或设 SCHED_RR：没有变化。把浏览器关键线程强制放大核（Android 式）：降到约 42 fps。
- 把渲染进程主线程绑到大核：CPU 时间从约 75% 降到约 45%，掉帧没有可测的变化。80-290 ms 的布局快 1.6 倍也还是远超一帧。
- 前台应用的 uclamp 下限：对 Chromium 滚动没有可测的影响。

## 为什么没有 120 Hz

面板现在只有 UEFI 设好的 60.51 Hz 这一个模式，驱动接管的就是它；面板能不能跑更高的刷新率没有验证过。所以桌面没有 120 Hz 输出。

按 120 Hz（一帧 8.33 ms）算过工作预算，结论是即使有这个模式，现在的软件也撑不住双缓冲：

- 安全余量约 2 ms 加 1 ms 不变的话，KWin 要 `result` < 8.333 - 2 - 1 = 5.33 ms 才能双缓冲。原来优化后的预测中位 10 ms、现在动画和滚动时的 6-12 ms 都不够。
  实际切到 120 Hz 后安全余量会随时序变，要重新算。
- 一次 2.5-3.6 ms 的 dma-buf 导入就占 8.33 ms 的 30-43%（现在这条路已经拒绝了）。
- GPU 50 ms 的采样窗口在 120 Hz 下横跨 6 帧；HZ=250 下 devfreq 的定时有 jiffy 量化，sysfs 里的毫秒数不能当精确的帧时钟。
- 测量也要跟着改：10 分钟约 72 000 个帧机会；`tests/bench/desktop-latency.sh` 按 p2p > 20 ms 判掉帧，在 120 Hz 下会漏掉单次丢帧（16.67 ms），要按实际刷新周期统计。

## 怎么测

- KWin 逐帧日志：在 `~/.config/systemd/user/plasma-kwin_wayland.service.d/` 放一个 drop-in，内容是 `[Service]` 加 `Environment=KWIN_LOG_PERFORMANCE_DATA=1`，
  注销重新登录。KWin 会往 `~/kwin perf statistics eDP-1.csv` 每帧写约 100 字节（只在有画面更新时写）。用完删掉 drop-in 再重新登录一次。
- 不要用 `systemctl --user restart plasma-kwin_wayland` 让环境变量生效：它会结束整个 Plasma 会话；`systemctl --user set-environment` 设的变量也会随会话结束被清掉。
- KWin 6.3.6 可用的环境变量：`KWIN_LOG_PERFORMANCE_DATA`、`KWIN_DRM_DISABLE_TRIPLE_BUFFERING`、`KWIN_DRM_OVERRIDE_SAFETY_MARGIN`（µs）、`KWIN_FORCE_SW_CURSOR`、
  `KWIN_DRM_NO_DIRECT_SCANOUT`、`KWIN_NO_TIMER_QUERY`。
- `tests/bench/desktop-latency.sh`：在会话里跑，屏幕上会弹出测试小窗口约 25 s，输出 weston-presentation-shm 三种模式下的提交到上屏（c2p）和上屏间隔（p2p）；
  KWin 开着逐帧日志时还按阶段给出实测和预测的渲染时间。健康的指标是低延迟模式 p2p 约 16.7 ms，KWin 预测值小于 13.7 ms。
- `tests/bench/frame-budget.sh`、`tests/bench/browser-bench.sh`：见 perf-power.md。
- `tests/bench/framelat.c`：`gcc -O2 -o framelat framelat.c`，然后 `for c in 1 4 6; do for p in rr fair; do sudo ./framelat $c $p; done; done`（RR 要 root）。
- 内核开了 ftrace（sched、irq、dma_fence、drm 跟踪点）和 PSI，可以用 trace-cmd 或 perfetto 把一帧经过的每一步量出来。只看 DRM 提交时序也可以把
  `/sys/module/drm/parameters/debug` 设成 0x30，日志量很大，只开一两秒。
- 闲置约 10 分钟会锁屏并关显示，测试用 `kde-inhibit --power --screenSaver` 包起来；已经锁了就用 `loginctl unlock-session <id>` 加 `kscreen-doctor --dpms on`。
- 非交互 shell 的后台进程会忽略 SIGINT，`timeout -s INT` 结束不了后台的 weston 测试客户端，用 `timeout -k 2 <秒>`。
  通过 ssh 执行 `pkill -f weston-simple-egl` 会把这条 ssh 会话自己也杀掉（命令行里含匹配的字符串），用 `pkill -x`。

## 依据

- KWin：[renderjournal.cpp](https://github.com/KDE/kwin/blob/v6.3.6/src/core/renderjournal.cpp)、
  [renderloop.cpp](https://github.com/KDE/kwin/blob/v6.3.6/src/core/renderloop.cpp)、
  [drm_commit_thread.cpp](https://github.com/KDE/kwin/blob/v6.3.6/src/backends/drm/drm_commit_thread.cpp)、
  [drm_buffer.cpp](https://github.com/KDE/kwin/blob/v6.3.6/src/backends/drm/drm_buffer.cpp)（deadline ioctl）、
  [MR !8517](https://invent.kde.org/plasma/kwin/-/merge_requests/8517)。
- 内核：`kernel/sched/{fair,rt,pelt,cpufreq_schedutil}.c`、`drivers/cpufreq/hisi-hwvote-cpufreq.c`、`drivers/gpu/drm/panfrost/{panfrost_devfreq,panfrost_job}.c`、
  `drivers/gpu/drm/hisilicon/kirin990/kirin990_drv.c`。
