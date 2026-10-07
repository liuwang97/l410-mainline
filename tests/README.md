# tests

在 L410 上跑的测试。`quick.sh` 是日常用的一分钟自检（说明见 [docs/testing/quick-suite.md](../docs/testing/quick-suite.md)），
其余是各子系统的测试和长时间测试；`bench/` 是性能测量工具。用例编号和覆盖关系见 [docs/testing/test-plan.md](../docs/testing/test-plan.md)，
最近一次回归结果见 [docs/testing/results.md](../docs/testing/results.md)。

大部分脚本的结果行是 `PASS|FAIL|WARN|SKIP|INFO <名字> <说明>`，最后一行 `RESULT: …`，退出码是失败数。
“root”一列写“是”的脚本不是 root 时多数会自己用 `sudo -n` 重新执行，所以普通用户要能免密 `sudo`；
写“桌面用户”的要在 Plasma 会话的用户下跑（需要 `XDG_RUNTIME_DIR` 和会话 D-Bus），其中的特权操作同样走免密 `sudo`。
经 ssh 跑的写法：`ssh <host> 'sudo bash -s' < tests/<脚本>`。

根分区按 `findmnt /` 取（要求在 UFS 的 sdd 上）；`usb.sh`、`smoke.sh` 找第一个 `enx*` 接口当 USB 网卡（`NIC=` 指定），`usb.sh` 用 `NIC_IP=` 检查它的地址；
`pcie.sh` 没给 `EXPECT_MAC` 时用 RTL8168 当前的固有 MAC 做前后对比。
移植初期用的 initramfs 探测脚本和主机侧的 USB 传输测试在 `dev/bringup/`，见 [dev/README.md](../dev/README.md)。

## 日常与子系统测试

| 脚本 | 测什么 | root | 对系统的影响 | 时长 |
|---|---|---|---|---|
| `quick.sh` | 21 个模块约 200 项无人值守自检：内核日志、CPU、内存、时钟、PMIC、温控、UFS、USB、PCIe、WiFi、蓝牙、显示、GPU、音频、输入、EC、电源档、内核配置、测试残留 | 是 | 不断网、不停桌面；改过的设置都恢复。有很轻的提示音、背光 ±1、摄像头重连一次、2 s 的小窗口 | 约 1 分钟；`--fast` 半分钟内 |
| `smoke.sh` | 冒烟：8 核在线、根分区在 UFS、固件 LUN 只读、时钟/调压器/RTC/温区/I2C 已注册、网络、RTL8168、deferred、内核 oops | 是 | 只读 | 几秒 |
| `soc-core.sh` | 时钟树（无孤儿、关键频率与厂商一致）、IPC 邮箱和一次 LPM3 往返、hwspinlock、DMA、pinctrl/GPIO/I2C/UART/SPI 绑定、eDP 桥/HID/EC 的 I2C 应答 | 是 | 只读（发一条无害的 LPM3 投票） | 几秒 |
| `power.sh` | SPMI/PMIC、13 路调压器、19 个 IP 电源域、RTC 与闹钟中断、电源键、温区、cpufreq、cpuidle；期望值是厂商 4.19 的读数 | 是 | 测试期间切到平衡档，退出时恢复；设一个 3 s 的 RTC 闹钟 | 十几秒 |
| `ufs.sh` | UFS 链路、LUN、写保护、数据校验、host reset、运行时 PM、auto-hibern8 压力；`UFS_TEST_RPM5=1` 加测 rpm_lvl 5 | 是 | 在 `/var/tmp` 写测试文件后删除，不写块设备；做一次 host reset | 取决于 `UFS_TEST_MB`（默认 2048 MiB）和 2×`UFS_TEST_AH8`（默认 300）次 AH8 退出；`UFS_TEST_QUICK=1` 跳过数据测试 |
| `usb.sh` | DWC3/PHY、板载 RTS5411 hub、RTL8153 USB 网卡（链路、地址、持续 ping）、摄像头抓帧 | 是 | 抓 3 帧；没接 RTL8153 且默认路由在 WiFi 上时网卡部分跳过 | 几秒；接着网卡时约半分钟 |
| `pcie.sh` | 两个 RC、RTL8168 枚举、MAC、MSI-X、r8169 解绑重绑、链路 retrain；插网线时 ping 并看中断计数；`PCIE_TEST_SUSPEND=1` 时 s2idle 一次 | 是 | 有线网卡解绑重绑（有线网会断一下）；可选挂起 | 十几秒 |
| `graphics.sh` | Panfrost、kirin KMS、kmscube、modetest 翻页、GPU 调频回读、glmark2（DRM 和 Wayland）、weston | 是 | **会停掉 sddm，当前桌面会话结束，测完不会自动重新启动 sddm**；全屏测试画面 | 十几分钟（两轮完整 glmark2 各约 5 分钟） |
| `audio.sh` | Hi6405 识别、DAPM、ASP DMA 推进、功放状态、扬声器和耳机放音、DMIC 录音不是静音 | 是 | 扬声器放 4 s 的 -30 dBFS 1 kHz 音；改扬声器和耳机的混音器开关 | 十几秒 |
| `audio-ampwatch.py` | 每 5 ms 读两颗 TAS2562 的电源状态、TDM 时钟检测和中断标志，打印每次变化（查爆音用） | 是 | 只读 I2C，不写页寄存器 | 参数指定，默认 10 s |
| `laptop.sh` | 键盘和触控板的 HID 描述符、键码位图、EC 通信与错误计数、电池和 AC 读数、静音灯、合盖状态；也能在 busybox 下跑 | 是 | 静音灯亮 1 s | 约 1 分钟（EC 轮询 12×5 s） |
| `wifi-bt.sh` | hi110x 驱动、驱动日志量、WiFi 扫描、hci0、蓝牙扫描；不连网、不配对、不读已存的密码；`SUSPEND=1` 加测挂起 | 是 | wlan0 承载默认路由时只在连接状态下扫描。否则在运行期间让 NetworkManager 不管 wlan0、自己拉起扫描再关掉，并设一个 300 s 后强制重启的保护定时器（正常结束时取消） | 最长等 WiFi 150 s，蓝牙扫描 15 s |
| `perf.sh` | 能耗模型和 EAS、uclamp、PELT 倍率、schedutil 限速、l410_perf 档位与 boost、GPU boost 与冷却、显示提交线程和帧统计 | 是 | 临时切换档位，结束时恢复 | 几秒 |
| `desktop-cfg.sh` | 内核配置补齐项的实际功能：模块能加载，exFAT/NTFS3/VFAT cp936/UDF/ISO9660 Joliet 在 loop 文件上往返，CIFS 连本机 samba，USB 设备别名，蓝牙 RFCOMM/BNEP，uhid/hidraw，fq_codel，锁死检测，AppArmor，Yama，LUKS2 | 是 | 默认用 apt 装测试依赖（要能上网，`--no-apt` 跳过）；临时起停 samba 并恢复；重启一次 bluetoothd | 几十秒到几分钟（看要不要装包） |
| `mem.sh` | 内存调优的检查：内核配置、运行时参数、swap/zswap、oomd、cgroup 保护，再加一段内存压力并测前台探针的停顿 | 是 | 压力阶段会把其他程序换出（有时间和 MemoryMax 上限）；`--no-load` 只查配置 | 压力阶段默认 60 s |
| `mem-scenario.sh` | 桌面内存场景：Chromium 开 N 个真实网站标签页加后台吃内存程序，测每个标签切回前台到重新渲染的时间 | 桌面用户 | 先关掉正在运行的 Chromium；把内存吃满；需要上网 | 默认 20 个标签，中间空闲 300 s |
| `power-modes.sh` | 电池供电下三个电源档和“优化前”配置的整机功耗（EC 电压×电流），负载是空闲桌面和 Chromium 快速滚动 | 桌面用户 | 要先拔电源；切换电源档；关掉 Chromium。调用 `bench/browser-bench.sh` | 4 种配置 × 2 种负载 × 默认 120 s |
| `display-power.sh` | 经 KWin 熄屏再亮屏若干次：整条显示链真的断电（背光、eDP 桥和面板供电、DSI 时钟、DSS 电源域）又能恢复（链路训练、vblank、没有 underflow）；电池供电时测熄屏前后功耗 | 桌面用户 | 屏幕熄灭和点亮；每轮挂着测试看门狗，挂死时机器重启（见 [dev/README.md](../dev/README.md)） | 默认 3 轮；电池供电时每次功耗测量 60 s |
| `scroll-accel-test.sh`、`scroll-accel-test.c` | 在 L410 上编译测试程序，用 uinput 虚拟触控板做双指滑动，检查打过补丁的 libinput 的滚动加速曲线（`system/input/libinput/`） | 是 | 临时 udev 规则把虚拟设备放进单独的 seat，桌面收不到这些滑动 | 几秒 |

## 长时间与会中断使用的测试

| 脚本 | 测什么 | root | 对系统的影响 | 时长 |
|---|---|---|---|---|
| `suspend.sh` | 一次系统睡眠（`deep` 或 `s2idle`，可选 `pm_test` 级别），开内核睡眠调试，RTC 唤醒，比较前后的 WiFi、蓝牙、显示、USB、输入、UFS | 是 | 机器睡眠，WiFi 断开；挂着测试看门狗；唤醒后 60 s WiFi 没回来就自动重启。`deep` 唤醒会变成冷启动 | 默认睡 20 s |
| `cycle.sh` | 热重启循环，在被测机上自己接着跑：每次开机查内核、WiFi、内核日志、deferred、UFS 错误、复位原因、设备名是否稳定、启动耗时 | 是 | 反复重启；依赖 `dev/` 里的单次启动项和 grubenv 工具（见 [dev/README.md](../dev/README.md)）；`stop` 移除开机服务 | 次数 × 每轮开机时间 |
| `soak-mix.sh` | 混合烤机：stress-ng CPU 和内存带校验、fio crc32c 校验、glmark2、静音音频流、WiFi ping 和定时下载、定时抓帧、EC 轮询，同时看温度和限频 | 是（GPU 和音频部分要有 Plasma 会话） | 满负载、发热；在 `/var/tmp` 写 1 GiB 文件，结束删除；定时下载要能上网 | 参数指定，默认 3600 s |
| `sysfs-sweep.sh` | root 读 /sys、/proc、debugfs 下所有可读文件（跳过已知有副作用的），找读了会中止、oops、卡住或刷屏的路径 | 是 | 可能让机器崩溃，这正是它要找的；每读一个文件前先把路径落盘，崩溃后用 `sysfs-sweep.sh last` 看最后读的是哪个 | 取决于文件数，每次读最多 2 s |

## bench：性能测量

这些工具测量和对比，不判 PASS/FAIL。都在 Plasma 会话里以桌面用户跑，特权操作走免密 `sudo`。

| 脚本 | 测什么 | root | 对系统的影响 | 时长 |
|---|---|---|---|---|
| `bench/browser-bench.sh` | 浏览器（默认 Chromium，`BROWSER=firefox` 可换）打开 bilibili：快速滚轮滚动、拖窗口、最大化、最小化四个阶段，每阶段统计内核翻页间隔、KWin 帧日志、boost、CPU 能耗估计、GPU 和 DDR 频率 | 桌面用户 | 关掉并重开浏览器；用 `uinput-bench.py` 模拟输入；需要上网。KWin 要带 `KWIN_LOG_PERFORMANCE_DATA=1` 才有 KWin 那几列 | 每阶段默认 8 s |
| `bench/uinput-bench.py` | 给 `browser-bench.sh` 用的合成输入：绝对坐标指针、按键、滚轮，从 FIFO 读命令 | 是 | 临时 uinput 设备 | 随调用方 |
| `bench/frame-budget.sh` | 60 Hz 帧预算：weston-presentation-shm 两种模式、weston-simple-egl、空闲，统计呈现间隔、提交到呈现延迟、翻页间隔、boost、CPU 能耗 | 桌面用户 | 屏幕上出现小测试窗口 | 4 个阶段，每阶段默认 10 s |
| `bench/desktop-latency.sh` | weston-presentation-shm 三种模式下的提交到呈现延迟和呈现间隔；开了 KWin 帧日志时加上 KWin 的渲染时间与预测 | 桌面用户 | 屏幕上出现小测试窗口 | 约 25 s |
| `bench/framelat.c` | 在单个 CPU 上模拟一帧合成器工作：定时唤醒加固定工作量，报告唤醒延迟、工作时长和调频爬升时间 | `rr` 策略要 root | 无 | 默认 300 帧（约 5 s） |
| `bench/power-ab.sh` | 电池供电下交替测各配置（A B C A B C…）的功耗，抵消漂移；配置包括电源档和 sched_ext 调度器 | 桌面用户 | 要先拔电源；切换电源档和 sched_ext 调度器 | 默认 3 轮 × 2 种配置 × 2 个窗口 × 90 s |
| `bench/scx-ab.sh` | sched_ext 调度器 A/B：每种配置交替跑 `browser-bench.sh`，空闲和后台有 8 个 stress-ng 两种负载 | 桌面用户 | 切换 sched_ext 调度器和 uclamp 设置 | 默认 3 轮 × 3 种配置 × 2 种负载 |

### bench/desktop-ab：浏览器滚动掉帧分析

调桌面延迟时用的一次性研究脚本。工作目录、桌面用户和 UID 是写死的，要按自己的环境改后才能用。

| 脚本 | 用途 | root | 对系统的影响 | 时长 |
|---|---|---|---|---|
| `ab.sh` | 一个标签下连跑 `frame-budget.sh` 和 `browser-bench.sh` 若干次 | 桌面用户 | 解锁会话、点亮屏幕 | 每次一两分钟，默认 2 次 |
| `gpu-check.sh` | 带指定参数启动 Chromium，导出 chrome://gpu | 桌面用户 | 关掉正在运行的 Chromium | 约 10 s |
| `gpuinfo.py` | 经 DevTools 协议读出 chrome://gpu 的文字 | 否 | 无 | 几秒 |
| `cdptrace.py` | 经 DevTools 协议录 Chrome trace，时间戳和 KWin 帧日志同一时钟 | 否 | 无 | 参数指定 |
| `framecause.py` | 离线分析 trace：滚动时 Chromium 丢帧的原因分布 | 否 | 无 | 几秒 |
| `framegaps.py` | 离线把 Chromium 的 Wayland 提交和 KWin 的帧对齐，说明每个没出新帧的 vblank 里 Chromium 在做什么 | 否 | 无 | 几秒 |
| `mainstall.py` | 离线分析 trace：合成线程等主线程时主线程在跑什么 | 否 | 无 | 几秒 |
| `traceinfo.py`、`tracepeek.py` | 离线查看 trace 里有哪些进程、线程和事件 | 否 | 无 | 几秒 |
| `latch.py` | 离线分析 KWin 帧日志：连续动画里的翻页间隔、KWin 错过的帧、开始合成到目标 vblank 的提前量 | 否 | 无 | 几秒 |
| `predictor-replay.py` | 用 KWin 帧日志重放两种渲染时间预测算法 | 否 | 无 | 几秒 |
| `thrsample.py` | 每 20 ms 采样 chromium/firefox/kwin/Xwayland 各线程的 CPU 占用和所在的核 | 否 | 无 | 参数指定 |
| `tweak.py` | 把 Chromium 出帧关键线程挪离小核，或设成 SCHED_RR | 是 | 改 Chromium 线程的亲和性和调度策略 | 几秒 |
| `scrollprobe.sh` | 只跑 `browser-bench.sh` 的滚动阶段，同时按线程采样 CPU，可先套用 `tweak.py` | 桌面用户 | 同 `browser-bench.sh` | 不到 1 分钟 |
| `traceprobe.sh` | 滚动阶段加 Chrome trace，并把 KWin 帧日志拷到旁边 | 桌面用户 | 同 `browser-bench.sh` | 不到 1 分钟 |
| `relogin.sh` | 写 KWin 环境变量 drop-in（总带帧日志），然后重开一个 Plasma 会话 | 桌面用户 | 重启 sddm，结束当前 Plasma 会话 | 几十秒 |
| `queue8.sh`、`queue9.sh`、`queue10.sh` | 排队执行的几组 A/B（Chrome trace 加 KWin 帧日志、渲染主线程绑核、一个 Chromium 特性开关），结束后恢复常规会话 | 桌面用户 | 关掉 Chromium，重启 Plasma 会话 | 几分钟 |

### bench/launch：应用和弹窗启动时间

测应用冷启动和开始菜单弹出时间的研究脚本，用 KWin 脚本 `watch.js` 记录窗口出现的时刻。工作目录和会话环境（`env.sh`）是写死的，要按自己的环境改。

| 脚本 | 用途 | root | 对系统的影响 | 时长 |
|---|---|---|---|---|
| `env.sh` | 被其他脚本 source：会话环境变量、加载 `watch.js`、跟踪 KWin 日志、记录触发时刻 | 否 | 无 | |
| `watch.js` | KWin 脚本：记录每个窗口映射和取消映射的时刻 | 否 | 无 | |
| `launch.sh` | 像 Plasma 那样以临时 app 单元启动命令 N 次，报告到第一个窗口和第一个普通窗口的时间 | 桌面用户 | 每次之间停掉应用 | N × 等待时间 |
| `launch2.sh` | 同上，但像用户那样经 KWin 关窗口，等进程退出 | 桌面用户 | 同上 | N × 等待时间 |
| `warmapp.sh` | 已有常驻实例时的启动时间 | 桌面用户 | 每次之间经 KWin 关窗口 | N × 等待时间 |
| `baseline.sh` | 目标应用的启动时间基线 | 桌面用户 | 启动并关闭应用 | 默认每个应用 4 次 |
| `compare.sh` | 目标应用的启动时间，按用户的方式关闭，结果按标签存档 | 桌面用户 | 启动并关闭应用 | N 次 × 应用数 |
| `abapps.sh` | 每个应用交替跑多个变体（默认、关 AFBC、绑大核等） | 桌面用户 | 启动并关闭应用 | 轮数 × 变体 × 应用数 |
| `abcmd.sh`、`abcmd2.sh` | 交替对比整条命令的启动时间（后者像用户那样关窗口） | 桌面用户 | 启动并关闭应用 | 轮数 × 变体 |
| `abknob.sh`、`abknob2.sh` | 交替对比一个 sysfs 参数的不同取值（后者冷启动、并暂停常驻服务），结束恢复原值和服务 | 是（写 sysfs） | 改一个 sysfs 参数；`abknob2.sh` 临时停常驻服务 | 轮数 × 取值 × 应用数 |
| `kickoff.sh` | 用 Meta 键同样的 D-Bus 调用开关开始菜单 N 次，报告弹出耗时 | 桌面用户 | 开始菜单反复弹出 | 几秒到几十秒 |
| `kcmhide.sh` | 对比系统设置在有无 9 个数据类 KCM 时的启动时间 | 是 | 临时把 KCM 文件移开，结束时一定移回 | 约 1 分钟（3 轮） |
| `closewin.sh` | 经一次性 KWin 脚本关掉某个窗口类的所有窗口 | 桌面用户 | 关窗口 | 几秒 |
| `settle.sh` | 等 plasmashell 运行满 60 s 且系统安静下来 | 否 | 无 | 最多 3 分钟 |
| `relogin.sh` | 重开一个 Plasma 会话，其他不变 | 桌面用户 | 重启 sddm，结束当前 Plasma 会话 | 几十秒 |
| `trace.sh` | 在系统级 perf（调度切换、唤醒、4 kHz 采样）下跑一段命令，再用 `ana.py` 分析每个触发窗口 | 是（perf） | 无 | 参数指定 |
| `t-app.sh`、`t-kick.sh`、`t-ss.sh` | `trace.sh` 的包装：一次应用启动、4 次开始菜单、3 次系统设置启动 | 是（perf） | 启动并关闭应用 | 十几秒 |
| `lprof.sh` | 一次启动在系统级 `perf -g` 下，按进程、DSO、内核路径统计到第一个窗口的 CPU 时间 | 是（perf） | 启动并关闭应用 | 参数指定 |
| `gpuone.sh` | 一次启动加 GPU ioctl 计数 | 是（bpftrace） | 启动并结束应用 | 十几秒 |
| `bocount.sh`、`bocount.bt` | 开关一次开始菜单，统计 plasmashell 的 GPU 缓冲创建、提交、释放 | 是（bpftrace） | 无 | 几秒 |
| `gpucount.bt` | 系统级统计各进程的 panfrost 缓冲创建、提交、等待次数和大小 | 是（bpftrace） | 无 | 参数指定 |
| `sstimeline.sh` | 用 strace 看系统设置启动各阶段，加上 KWin 记录的窗口出现时刻 | 桌面用户 | 关掉并重开系统设置 | 几秒 |
| `ana.py`、`sysprof.py`、`fold.py`、`under.py` | 离线分析 perf 输出：按线程和簇统计 CPU 时间、按进程/DSO 汇总、折叠调用栈、找含某个内核符号的样本 | 否 | 无 | 几秒 |
| `chrtrace.py`、`ffprof.py` | 离线分析 Chromium trace 和 Firefox 启动 profile 里主线程最长的片段 | 否 | 无 | 几秒 |
| `psrsample.py` | 等某个进程出现，采样它的主线程跑在哪个核上 | 否 | 无 | 参数指定 |
| `to-original.sh`、`to-current.sh` | 把被测应用切回优化前的状态（停常驻服务、换回原版 scx_lavd、装回 Noto 字体）和切回来 | 是 | 改系统：用 apt 装或删字体包、替换 `/usr/local/bin/scx_lavd`、重启 scx-lavd | 主要花在 apt 上 |
