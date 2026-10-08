# 桌面：Plasma 6.7、KWin 和浏览器滚动

这份文档说明为什么系统用 Debian forky、KWin 怎么配置，以及浏览器滚动掉帧查到了哪一步。
启动速度见 [launch-latency.md](launch-latency.md)，触控板滚动见 [touchpad-scroll.md](touchpad-scroll.md)，
电源模式和 KWin 的 CPU 设置见 [perf-power.md](perf-power.md)，调度器见 [sched-ext.md](sched-ext.md)。

## 为什么用 Debian forky

本项目的 Debian 直接装 testing（forky），不是 Debian 13（trixie）：

- trixie 里的 Plasma 是 6.3.6，trixie-backports 里没有 Plasma。6.7 只在 forky 和 sid 里。
- Plasma 6.7 依赖 Qt 6.10 和新版 KF6，它们又依赖 forky 的 glibc 2.43。只从 forky 拉 KDE 相关的包，最后会连带换掉大半个系统，
  变成混源的系统，比整个系统跟着 forky 更难维护。从源码编整套 Qt、KF6、Plasma 要好几个小时，以后每次更新都要重编。
- forky 是滚动的 testing。Plasma 6.8 进入 testing 后，`apt full-upgrade` 一次就能升上去。

只想要新 Mesa、不想换 Plasma 的话，trixie-backports 里有 Mesa 26.1.6 和 PipeWire 1.6.9。

当前 forky 上和这台机器关系最大的版本：

| 组件 | 版本 | 说明 |
|---|---|---|
| Plasma / KWin | 6.7.4 | 新的帧调度；shm 缓冲区经 udmabuf 导入 |
| Qt / glibc / Python | 6.10.2 / 2.43 / 3.14 | |
| Mesa | 26.1.6 | Panfrost |
| systemd | 262 | 内核里 cgroup BPF、seccomp、fhandle、autofs、PSI 都开着 |
| NetworkManager / wpa_supplicant | 1.58.1 / 2.10-25 | WiFi 是唯一的网络 |
| PipeWire / WirePlumber | 1.6.9 / 0.5.17 | |
| sddm | 0.21 | plasma-login-manager 只在 sid 里，不用 |
| Chromium / Firefox ESR | 154 / 140 | |

测试机最早是从 trixie 整机升级上来的，那个升级脚本 `dev/forky-upgrade.sh` 只留作记录（见 [dev/README.md](../../dev/README.md)），新装直接装 forky。

forky 上有几处要处理，`system/install.sh` 已经做了：

- smartmontools 在 UFS 上找不到 SMART 设备，开机就失败：关掉。
- 网络由 NetworkManager 管，`systemd-networkd-wait-online` 等不到它要的网卡（测试机上是遗留的 USB 网卡 networkd 配置），
  开机卡在 "Wait for Network to be Online" 2 分钟：关掉。
- forky 的 iputils-ping 没有文件能力，普通用户 ping 报 "missing cap_net_raw"：设 `net.ipv4.ping_group_range`
  （[90-l410-net.conf](../../system/hardware/90-l410-net.conf)）。
- WiFi 国家码：内核只内置上游的签名密钥，Debian 签名的 regulatory.db 会被 cfg80211 拒绝，一直停在世界域 00，所以改用上游签名版。

## KWin 用 GLES

KWin 在 Panfrost 上默认用桌面 OpenGL 3.1（日志里一直在刷 `glDrawBuffers(GL_BACK_LEFT)`）。改成 GLES 后，小窗口低延迟模式的掉帧基本消失：

| frame-budget 低延迟模式（`weston-presentation-shm -p`，10 s） | 掉帧 |
|---|---|
| KWin 6.3.6（trixie） | 0 |
| KWin 6.7.4，桌面 GL 3.1 | 8、67 |
| KWin 6.7.4，GLES | 0、1、5 |

feedback 模式和 EGL 客户端在各种配置下都是 0 掉帧。GLES 下 KWin 渲染中位 2.1 ms、p99 4.3-6.1 ms，100% 双缓冲。
KWin 6.8 会删掉桌面 GL 后端（MR !9488），以后只剩 GLES 这一条路。

配置是 `KWIN_COMPOSE=O2ES`，放在 `/etc/systemd/user/plasma-kwin_wayland.service.d/l410-gles.conf`
（源文件 [plasma-kwin_wayland.service.d-l410-gles.conf](../../system/perf/systemd/plasma-kwin_wayland.service.d-l410-gles.conf)，`perf` 阶段安装），
重新登录后对所有用户生效。低延迟模式下还剩 0-5 帧的掉帧，原因没有查完。

## udmabuf：CPU 渲染的窗口不再逐帧上传

KWin 6.7 带了 MR !9178：用 CPU 渲染（wl_shm）的客户端，KWin 经 udmabuf 直接导入它的缓冲区，不再每帧上传纹理。
MR 作者实测 KWin 单核占用从 80-90% 降到约 20%（不是本机数据）。受益的是 Qt Widgets 程序（Konsole、Dolphin、Kate）、GTK3 程序和 XWayland 程序；
Chromium 和 Firefox 本来就走 dma-buf，不受影响。客户端的 shm pool 要按页对齐、stride 按 256 字节对齐，不满足时退回旧路径。

内核开了 `CONFIG_UDMABUF=y`。`/dev/udmabuf` 是 root:kvm 0660，加上 uaccess ACL，登录的桌面用户可以读写。

## 显示缩放 150%

面板是 2160×1440，本项目按 150% 缩放使用和测量，这里和 [touchpad-scroll.md](touchpad-scroll.md) 的数字都是 150% 下的。
现在的内核能读到面板 EDID 里的尺寸，KWin 可能因此自己选 125%。改回 150%：

```bash
kscreen-doctor output.eDP-1.scale.1.5
```

原生 Wayland 客户端（Qt 6、Chromium）通过 fractional-scale 直接按目标尺寸渲染，分数缩放不会多一次重采样；只有 XWayland 程序会被放大。

## 浏览器滚动

### 怎么测

- [browser-bench.sh](../../tests/bench/browser-bench.sh)：Chromium 154（或 `BROWSER=firefox`）打开哔哩哔哩首页，分阶段各 8 s：
  极限滚动（滚轮 3 格 / 20 ms，先下后上）、拖动窗口、最大化/还原、最小化/恢复。输入由 [uinput-bench.py](../../tests/bench/uinput-bench.py) 的虚拟设备注入。
- [frame-budget.sh](../../tests/bench/frame-budget.sh)：小测试窗口，feedback、lowlat、egl、idle 四个阶段。
- KWin 逐帧日志：KWin 的环境里加 `KWIN_LOG_PERFORMANCE_DATA=1`，它会往 `~/kwin perf statistics eDP-1.csv` 写每一帧的目标翻页、实际翻页、
  渲染开始和结束、safety margin、刷新率、VRR、撕裂和预测的渲染时间，每帧约 100 字节。测完要去掉这个变量再重新登录，否则文件一直变大。
- [tests/bench/desktop-ab/](../../tests/bench/desktop-ab/)：A/B 工具，用法见各脚本开头。
  `relogin.sh VAR=value ...` 写 KWin 的环境 drop-in（总是带上逐帧日志）并重新登录；`ab.sh` 跑 frame-budget 和 browser-bench；
  `scrollprobe.sh` 只跑滚动，同时按线程采样 CPU 和 GPU；`latch.py` 从 KWin 日志算翻页间隔、missed 和 KWin 开始合成距目标 vblank 的提前量；
  `cdptrace.py`、`traceprobe.sh` 在滚动时抓 Chrome trace；`framegaps.py`、`mainstall.py` 分析 trace；`tweak.py` 改 Chromium 线程的亲和性和调度策略。

怎么读：browser-bench 的 fps 把阶段里的静止时间也算进去了（滚到顶以后不再变化、最大化动作之间等 1.2 s），所以最大化、最小化的 fps 低不代表掉帧。
掉帧看两样：画面在动时内核翻页的 2 帧、3 帧间隔（gap2、gap3），和 KWin 日志里错过目标 vblank 的次数（missed）。
哔哩哔哩的页面状态会漂，A/B 要交错测（A B A B），不要先测完一组再测另一组。调度器和电源档在两组之间要一致，并记进结果。

### 现状

平衡档、插电（Chromium 极限滚动，每 8 s）：

| 配置 | fps | gap2 | gap3 | KWin missed |
|---|---|---|---|---|
| trixie，KWin 6.3.6 | 49.7 | 11 | 4 | |
| forky，桌面 GL（2 轮） | 50.9 / 49.8 | 3 / 5 | 2 / 4 | 0 / 4 |
| forky，GLES（4 轮） | 49.3-49.8 | 5-8 | 3-5 | 0-3 |

Firefox ESR 140，同样的测试：

| 阶段 | fps | gap2 | gap3 | KWin missed |
|---|---|---|---|---|
| 极限滚动 | 58.3 | 7 | 3 | 0 |
| 拖动窗口 | 60.4 | 0 | 0 | 0 |
| 最大化/还原 | 59.2 | 2 | 4 | 2 |
| 最小化/恢复 | 37.3 | 2 | 0 | 0 |

剩下的问题是 Chromium 在重页面上滚动掉帧，以及窗口动画时 KWin 有一部分帧进三缓冲（多一帧延迟，动画时只有 50-65% 的帧是双缓冲）。

### chrome://gpu

Canvas、合成、光栅化（所有页面）、WebGL、WebGPU 都是硬件加速，ANGLE → Panfrost（Mesa 26.1.6），没有黑名单项，不需要 `--ignore-gpu-blocklist`。
Debian 的 `/etc/chromium.d/default-flags` 已经带了 `--enable-gpu-rasterization`。

视频：v6.18.54-l410.2 起有硬件解码驱动 `hisi-vdec`。Chromium 用它自带的 V4L2 解码器（`system/video/`），硬解 H.264、HEVC Main、VP8、VP9 profile 0；
AV1 和 VP9 profile 2 仍是软解，HEVC 10 bit 放不了，Chromium 的 VA-API 路径用不了，见 [../hardware/vcodec.md](../hardware/vcodec.md)。Vulkan（PanVK）在 Bifrost v7 上被 Mesa 拒绝。

### Chromium 为什么掉帧：页面主线程

滚动时 GPU 不忙（panfrost fdinfo，`profiling=1`）：Chromium 片元 18%、合计 21%，KWin 8%。

在滚动阶段用 CDP 抓 Chrome trace，同时开 KWin 逐帧日志。两边都是 CLOCK_MONOTONIC，`framegaps.py` 把 Chromium 每次
`WaylandBufferManagerHost::CommitOverlays` 对到 KWin 开始合成的时刻，给每个没有新 Chromium 画面的 vblank 归类，
`mainstall.py` 列出这期间页面主线程的长任务。抓 trace 有开销（这两轮 45 fps，平时约 50），绝对数偏大，比例可以参考：

| 没有新画面的 vblank | 第 1 轮（387 个 vblank） | 第 2 轮（427 个） |
|---|---|---|
| 渲染进程 Compositor 在等页面主线程（`SKIPPED_REASON_WAITING_ON_MAIN`） | 28 | 47 |
| 交帧晚了（Chromium 提交时 KWin 已经开始合成这一帧，多数晚 0.1-6 ms） | 20 | 33 |
| Chromium 主动跳过（`DRAW_THROTTLED`、无变化等） | 12 | 50 |
| 无法归因（多在开头、结尾和静止时） | 25 | 19 |

- 滚动本身在 Compositor 线程上（`SCROLL_COMPOSITOR_THREAD`），没有被 JS 卡住。
  帧状态：全部更新 181，部分更新（主线程内容没跟上）180，不需要更新 100，丢弃 24。
- 页面主线程忙 61-64%，超过 16 ms 的任务 43 个，共约 2.8 s / 7 s。最长的是 `BeginMainFrame` 里的样式和布局（`LocalFrameView::performLayout`），
  一次 85-290 ms，发生在信息流追加新卡片时；其次是页面 JS 定时器（DOMTimer），77-205 ms。
  等主线程的跳帧有 19/27、40/44 落在这些长任务里。一次 290 ms 的布局就是连续 11 帧没有新画面。
- Wayland 帧回调限流：浏览器主线程提交下一帧前要等 KWin 发回上一帧的帧回调（`WaitForFrameCallback`，7 s 内 189 次，中位 5.5 ms，最长 16.9 ms），
  最多 3 帧在途（`kMaxFramesInFlight`）。Chromium 只在录屏时跳过这一步，没有用户开关；也没有查到它支持 `fifo-v1` 或 `commit-timing-v1`。

结论：Chromium 剩下的掉帧主要来自页面自己的主线程负载（排版和 JS）。Chromium 选择等主线程，而不是先画出空白；
Firefox 的 APZ 不等主线程，所以能到 58-60 fps。A76 的单线程性能让这些任务更长，但即使在快得多的 CPU 上，这些任务也超过一帧。
重页面日常用 Firefox 更顺。

cc 里的 `kWaitingOnMain` 只是一个标签：这一帧没画，同时主线程有 BeginMainFrame 在跑或者有待激活的树（`scheduler.cc` 的 `FinishImplFrame()`），
不代表 Compositor 一定在主动等主线程。那一帧没画的确切原因，还要往 cc 调度器里查。

还没做的对照：同样的极限滚动换轻页面（例如维基百科长文章）；移动版哔哩哔哩（m.bilibili.com，手机上不卡的一个前提是手机访问的是这个轻得多的页面）；
广告和脚本拦截。

上游 Chrome 2023-2026 年减少滚动卡顿的工作里，Input Vizard（输入直接交给 Viz，不经过浏览器主线程）、Browser Controls in Viz、
Android 输入线程提优先级这三项只在 Android 上，依赖 Android 的系统接口；Input Framer（`WaitForLateScrollEvents`，最多等 1/3 帧的晚到输入）
在所有平台默认开启，Linux 上已经有了。

### CPU 调度

EAS 下，Chromium 出帧路径上的线程大部分时间在 A55 上：渲染进程 Compositor 76%、GPU 进程 VizCompositorThread 72%、Chrome_ChildIOThread 79%；
渲染主线程 70% 在大核。滚动时中核、大核都忙，唤醒时只能挑空闲核，`select_idle_capacity()` 找不到空闲的合适核就退回小核。
scx_lavd 下渲染主线程约一半时间在 A55 上。但把这些线程挪出小核都没有改善掉帧（见下面"试过但没用"），CPU 放置不是原因。

scx_lavd 和 EAS 对照（平衡档，3 轮，每 8 s 的平均）：

| 条件 | 调度 | fps | gap2 | gap3 | gap4+ |
|---|---|---|---|---|---|
| 无竞争 | EAS | 49.9 | 5.5 | 1.0 | 4.0 |
| 无竞争 | lavd | 48.4 | 4.3 | 2.7 | 6.7 |
| 8 线程 stress-ng 竞争 | EAS | 39.8 | 12.3 | 4.0 | 11.0 |
| 8 线程 stress-ng 竞争 | lavd | 45.3 | 6.3 | 1.3 | 11.7 |

拖动从 55.4 提高到 57.6 fps；滚动时的 CPU 能耗估算从 947 降到 590 mW。无竞争时 lavd 下 gap2 仍有约 4 次/8 s，所以这部分掉帧不是 CPU 调度造成的；
有竞争时 lavd 把 gap2 压掉一半。现在默认用 scx_lavd。

厂商 4.19 内核走的是另一套办法：配置里有 `CONFIG_HUAWEI_SCHED_VIP=y`、`CONFIG_SCHED_WALT=y`、`CONFIG_HISI_RT_CAS=y`（`HISI_RTG` 没开），
靠给界面和渲染线程标 VIP、WALT 快速升频来保证流畅。

Chromium 154 在窗口出来后会把自己挪进 `app-org.chromium.Chromium-<pid>.scope`。l410-perfd 原来只在窗口激活那一刻按 pid 解析一次 cgroup，
前台下限一直落在空的启动 scope 上（新 scope 的 `cpu.uclamp.min` 是 0）；现在在激活后 1 s 和之后每 5 s 重新解析。
修好后 cgroup 下限 37.5% 生效，滚动数字没有变化（49.8 / 48.4 fps，gap2 3 / 8），修复本身保留。

### 否定掉的假设：KWin 开始合成太早

KWin 逐帧日志（33382 帧）里，KWin 在目标 vblank 之前中位 9-15 ms 就开始合成，而实际渲染中位只要 2.2 ms（p99 7.9 ms）。
6.7.4 的预测器（`src/core/renderjournal.cpp`）：预测值 = 均值 + 2 × 峰值保持的偏差（偏差按 6 s 的时间常数衰减），
开始时刻再往前推 safety margin（6.7 默认是 vblank 时长 + 1000 µs，日志里含自适应部分是 2.35 ms）和 1 ms。一个慢帧会把之后几秒的预测都抬高。
看起来客户端必须在上一个 vblank 后几毫秒内交帧才赶得上，所以曾怀疑这是 Chromium gap2 的来源。三组实验都否定了它：

- `KWIN_DRM_OVERRIDE_SAFETY_MARGIN=0`（单位 µs）：fps 50.6 / 49.4，gap2 12 / 8；同一时段默认是 50.8 / 50.6，gap2 5 / 5。没有改善。
  safety margin 只占提前量的约 1 ms，大头是预测值（中位 8-11 ms）。
- `KWIN_DRM_DISABLE_TRIPLE_BUFFERING=1`：Chromium 滚动 gap2/gap3/missed 是 4/5/4、3/5/2，默认 2/5/0，没有改善；
  窗口动画时 KWin 自己错过 vblank 明显变多（最大化/还原 missed 13、8，默认 1；最小化/恢复 5、4，默认 0）。
  KWin 渲染偶尔超过 8 ms，原来靠提前一帧开始兜住。三缓冲保持开启。
- 上游 MR !8517（预测改成最近 100 帧的均值 + 3 × 标准差，去掉峰值保持；仍是 Draft，6.8 里没有）。
  用本机日志离线重放（[predictor-replay.py](../../tests/bench/desktop-ab/predictor-replay.py)，现行算法的重放结果和日志里记录的预测值完全一致）：
  预测中位 9.4 → 4.1 ms，开始合成提前量中位 12.8 → 7.4 ms，需要三缓冲的帧 24% → 1%，KWin 自己会 miss 的帧 0.04% → 0.28%。
  实测时提前量中位降到 8.1 ms，三缓冲没有了，但 Chromium 滚动掉到 40.0、43.4 fps（原来 49-51），交给 KWin 的新帧少了约四分之一
  （303、304 帧，原来 380-480），拖动 gap2 从 0 变成 4、5；Firefox 最大化 gap2 从 2 变成 16，KWin missed 从 2 变成 10。

提前量变小没有让客户端更顺，这个假设不成立，KWin 保持 6.7.4 原样。相关的上游改动：!9367（renderloop 改用 timerfd 唤醒）和
!9862（OpenGL 渲染时间只计 GPU 时间）已合入 master；!9407（从唤醒目标时刻开始计渲染时间，去掉固定的 1 ms）还是 Draft。

实测 !8517 时，是把算法编成一个小库、用 LD_PRELOAD 替换 libkwin 里的 `RenderJournal::add`。kwin_wayland 带文件能力，处于安全执行模式，
`LD_LIBRARY_PATH` 和带斜杠的 `LD_PRELOAD` 路径都被忽略，只有放在系统库目录里、按裸名字给出、带 set-user-ID 位的库才能预加载进去。
这样的库任何用户都能预加载进 sudo 之类的程序，以 root 身份运行，是本地提权漏洞。**不要这样做。** 测完已经删除；要试 KWin 的改动，重编 Debian 的 kwin 包。

### 试过但没用

Chromium 极限滚动，平衡档，多数配置测 2 轮（基线见"现状"）：

| 做法 | fps | gap2 | gap3 | KWin missed | 结果 |
|---|---|---|---|---|---|
| 关模糊和背景对比度（`blurEnabled`、`contrastEnabled`） | 48.8 | 5 | 4 | 3 | 无收益，已恢复 |
| `--enable-zero-copy` | 49.2 | 5 | 5 | 1-3 | 无收益 |
| `--disable-gpu-rasterization` | 48.2 / 48.7 | 16 / 16 | 5 / 6 | 2 / 5 | 更差 |
| 出帧线程（Compositor、Viz、GPU 主线程、IO 线程）亲和性 4-7 | 49.3 / 49.6 | 8 / 3 | 6 / 3 | 3 / 0 | 无变化 |
| 同上，SCHED_RR 1 + 亲和性 4-5 | 50.3 / 48.9 | 6 / 4 | 3 / 2 | 0 / 3 | 无变化 |

- 出帧线程挪到 A76 后，Compositor 线程的 CPU 占用从 18% 降到 9%（跑得更快了），掉帧不变。
- 渲染进程主线程（JS、样式、布局、绘制）用 `tweak.py rmain` 绑核（scx_lavd 下）：绑 6-7 时 CPU 时间降到约 60%，确实快了，
  但 gap2+gap3 没有可测的变化（不绑 12、13；绑 6-7 是 10、10；绑 4-7 是 15、13），差别在轮间波动之内。80-290 ms 的布局即使快 1.6 倍，仍然远超一帧。
- `--disable-features=NewContentForCheckerboardedScrolls`：这个特性默认开，滚动会出现空白方块时把树优先级切到"优先新内容"，看起来像"等主线程"的原因。
  关掉后 fps 41.8 / 46.9，gap2+gap3 10 / 8（同一时段默认 49.9 / 42.2 fps，7 / 10）；trace 里 `WAITING_ON_MAIN` 跳过 29 次（默认 27、44），
  丢弃的帧反而从 24 变成 53。不是它，不采用。
- ANGLE 改 GLES 后端、关 AV1 软解：没有收益。强制把 Chromium 放到大核反而掉到约 42 fps。
- `--passive-listeners-default`：Chromium 154 已经没有这个开关。
- KWin 的 safety margin 置 0、关三缓冲、换预测算法：见上一节。

## 对这台机器不适用的常见建议

- "cpu4-7 都是 A76 大核"：CPU0-3 是 A55（算力 283），CPU4-5 是中核 A76（767），CPU6-7 是大核 A76（1024）。
- uclamp、KWin 实时优先级：已经做了（内核开了 `UCLAMP_TASK_GROUP`，KWin 是 SCHED_RR，所在 cgroup 的 uclamp.min=max），见 [perf-power.md](perf-power.md)。
- 切 performance governor：不需要，三档电源模式加输入 boost 已经覆盖交互场景。
- `KWIN_DRM_PREFER_COLOR_DEPTH=24`：kirin990-dss 只提供 32 bpp 的 XRGB/ARGB，eDP 链路本身是 24 bpp，没有 30-bit。
- `AllowTearing`：只对主动请求撕裂的全屏游戏生效，对桌面没用。
- 给 Chromium 用 Vulkan（PanVK）：Bifrost v7 上的 PanVK 不是 conformant 的，Mesa 也不在 v7 上启用它。
- 按 Google Chrome 官方包写的参数配置：这里用的是 Debian 的 chromium，包装脚本不同，参数放在 `/etc/chromium.d/`。
- 开 X11 会话对比：6.7 还有 X11 会话，但本项目的测量工具都是按 Wayland 写的，对照意义不大。

## 桌面会话的坑

- 新装的库（Mesa、libinput）要等进程重启才加载。KWin 和 plasmashell 只在重新登录时一起重启，所以装完要注销再登录。
  确认 KWin 用的是哪个库：`sudo grep libinput /proc/$(pgrep -x kwin_wayland)/maps`（Mesa 看 `gallium`）。
- 不要单独重启 KWin：`systemctl --user restart plasma-kwin_wayland` 会结束整个 Plasma 会话（logind 会话关闭，回到 SDDM），
  `QT_WAYLAND_RECONNECT` 也救不回来（在 KWin 6.3.6 上确认过）。
- 给 KWin 加环境变量：写 drop-in `~/.config/systemd/user/plasma-kwin_wayland.service.d/*.conf`（对所有用户就放在 `/etc/systemd/user/` 下），
  内容是 `[Service]` 加 `Environment=...`，然后重新登录。`systemctl --user set-environment` 设的变量在会话结束时会被清掉。
- 如果同时有 ssh 登录着，systemd 用户实例会一直活着，注销或者只 `sudo systemctl restart sddm` 都不会重启 KWin，新的 drop-in 也不会被读到。
  要按这个顺序：`systemctl --user daemon-reload` → `sudo systemctl stop sddm` → `systemctl --user stop plasma-kwin_wayland.service graphical-session.target`
  → `sudo systemctl start sddm`（设了自动登录时直接进桌面）。在 ssh 里要用 `setsid nohup … &` 放到后台跑，直接跑会挂住。
  [desktop-ab/relogin.sh](../../tests/bench/desktop-ab/relogin.sh) 就是这么做的。
- 这样强制重新登录后，用户实例的环境里没有 `DISPLAY` 和 `XAUTHORITY`，经 systemd 单元启动的 X11 程序会崩溃或变慢，
  修法见 [launch-latency.md](launch-latency.md) 的"怎么测"。
- 重新登录后 PowerDevil 有时把亮度设成 0（背光 1/1777，屏幕看起来是黑的）。调回来：
  `qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/BrightnessControl setBrightness 6000`。
- ssh 里跑 `kscreen-doctor` 要带上 `WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland`，否则它会悄无声息地 core dump。
- 空闲约 10 分钟会锁屏。显示相关的测试放在 `kde-inhibit --power --screenSaver` 下跑；唤醒用 `loginctl unlock-session` 加 `kscreen-doctor --dpms on`。
- Chromium 开机后第一次启动会卡在钥匙环解锁框，测试脚本都带 `--password-store=basic`。
- ssh 里不要用 `pkill -f <模式>`：ssh 自己的命令行里也有这个模式，会被一起杀掉。用 `pkill -x` 或者按 PID 杀。
- 测试前先看负载（`uptime`、`pgrep -a 'stress-ng|fio|cc1plus|ninja'`），后台在编译或跑压力测试时测出来的数没用。
- KWin 能用的调试开关：`KWIN_LOG_PERFORMANCE_DATA=1`（逐帧日志）、`KWIN_DRM_DISABLE_TRIPLE_BUFFERING`、`KWIN_DRM_OVERRIDE_SAFETY_MARGIN`、`KWIN_FORCE_SW_CURSOR`。
