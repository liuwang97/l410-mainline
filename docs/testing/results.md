# 最近一次回归结果（2026-10-01）

按 [测试计划](test-plan.md) 的集成回归层级做的一轮测试，样机只有一台。先在一个较早的内核构建上跑完整套，
修掉发现的问题后，再在最终配置（scx_lavd 开机启用）上复测。

## 环境

| 项 | 内容 |
|---|---|
| 样机 | HUAWEI L410 KLVU-WDU0B，麒麟 990，8 GB 内存，BIOS 1.00.72，1 台 |
| 内核 | 6.18.54-l410，内核仓库 [linux-l410](https://github.com/liuwang97/linux-l410) 的 `l410-6.18` 分支 |
| 用户态 | Debian forky/sid，Plasma 6.7.4（KWin 用 GLES），Mesa 26，systemd 262 |
| 调度 | sched_ext `scx_lavd` 1.1.3，开机启用，所有电源档都用 |
| 内存 | zswap（zstd）+ 8 GB swapfile，MGLRU，THP madvise/defer，systemd-oomd，cgroup 保护 |
| 电源 | 插电用性能档，电池用平衡档，低电量切省电档（PowerDevil） |
| 网络 | 只用 WiFi，没接网线，也没接 USB 网卡 |

## 第一轮

| 项 | 结果 | 说明 |
|---|---|---|
| `quick.sh` | 197 PASS / 0 FAIL（XPASS 1，WARN 4） | WARN：Spectre-BHB 列表、没网线时 RTL8168 停在 D0、性能档下深度空闲次数少、测试自己引起的 FAT 和 trace_printk 提示 |
| `desktop-cfg.sh` | PASS | 内核配置补齐项的实际功能：文件系统、CIFS、nftables、WireGuard、AppArmor、Yama、LUKS 等 |
| `mem.sh --load over` | PASS（修复后） | 130% 超量内存压力下前台探针的 p99 停顿 21.6 ms；修了 oomd 不监视用户会话的问题（见下表） |
| `perf.sh` | PASS | |
| 子系统套件 smoke、soc-core、power、ufs、usb、pcie、audio、laptop、wifi-bt | 9/9 PASS（修复后） | |
| `tools/l410-diag` | 2 s 生成 72 KB 诊断包 | SVC-01 |
| 1 h 混合烤机 `soak-mix.sh 3600` | 脚本判 10/11 | CPU、内存、UFS 校验（670 MB/s）、GPU 3600 s、摄像头、EC、会话存活都通过，最高温度 78 °C。判失败的一项是 WiFi：ping 统计解析错了，实际 3596/3596 全部收到。klog 一项判了通过，其实应该失败：烤机中触控板所在的 i2c-6 总线卡死过（见下表）。两处脚本问题都已修 |
| 蓝牙重新登录场景 20 次 | 0 次 HCI 超时 | 修复前约 1/3 的重新登录会超时 |

## 最终配置复测（scx_lavd 开机启用）

| 项 | 结果 | 说明 |
|---|---|---|
| 开机检查 | 全过 | lavd 开机即运行；oomd 监视用户会话；没有 systemd 顺序环；Xwayland 正常；没有失败单元；4 条 I2C 总线的 GPIO 恢复已启用；触控板、键盘可用；蓝牙已上电 |
| 开机的错误级内核日志 | 0 行（修复前 31 行） | 警告级只剩已知的正常项：不关闭未使用的时钟和电源、i2c-hid 的占位稳压器、staging 模块标记 |
| `quick.sh` | 200 PASS / 0 FAIL（WARN 2） | WARN 只剩 Spectre-BHB 列表和没网线时 RTL8168 停在 D0；klog 的错误和警告检查全部干净 |
| `perf.sh`、`power.sh` | PASS | |
| `suspend.sh s2idle none 20` | PASS | 挂起 1 次，前后 WiFi、蓝牙、显示、15 个 USB 设备、8 个输入节点、UFS 一致；唤醒后 lavd 仍在运行 |
| `display-power.sh 3` | 24 PASS / 0 FAIL | 3 次熄屏断电再亮屏：eDP 桥和面板 GPIO、eDP 链路、LDI、背光全部正常 |

## 这一轮发现并修好的问题

| 级别 | 问题 | 原因 | 修复 |
|---|---|---|---|
| 阻断 | scx_lavd 运行时温控 IPA 完全不限频：模拟 95 °C、大核满载时仍在 2861 MHz，而 EAS 下立即降到 1882 MHz。由 `quick.sh` 的 `thm.emul-throttle` 发现 | cpufreq_cooling 用 `sched_cpu_util()` 估算负载，它只看 CFS 的 PELT，sched_ext 的任务不在里面，IPA 以为 CPU 空闲 | `sched/fair: count sched_ext load in sched_cpu_util()`：和 schedutil 一样计入 sched_ext 调度器的 cpuperf 目标。修复后 lavd 下立即限频，但比 EAS 平缓（6 s 时 lavd 2218 MHz、冷却状态 6，EAS 1536 MHz、状态 12），之后由 PID 积分项继续收紧 |
| 严重 | 重新登录后蓝牙偶尔 HCI 命令超时（0x0c52） | 芯片同意睡眠约 1 s 后又被唤醒时，GPIO 应答比 115200 波特率的唤醒字节发完还早，主机随即切换波特率；`pl011_set_termios()` 不等发送器空闲，PL011 的发送端因此坏掉 | `staging: hi110x: let the wake-up byte go out before switching the BUART rate`：切波特率前先 `serdev_device_wait_until_sent()` |
| 严重 | 触控板失效，直到重启 | i2c-6 上的从设备在被打断的传输之后一直拉住 SDA，6.18 没有总线恢复 | `l410: dt: GPIO bus recovery for the four DesignWare I2C buses`：四条 DesignWare I2C 按厂商的 `cs-gpios` 补上 GPIO 总线恢复 |
| 严重 | 开机后 Xwayland、ksmserver、kaccess 起不来 | `mem-tune.service` 的 `Before=swap.target` 和 `tmp.mount` 构成顺序环，systemd 删掉了挂载任务，tmpfs 晚挂上，盖住了 `/tmp/.X11-unix` | 去掉这条顺序（`system/mem/systemd/mem-tune.service`）；`quick.sh` 加了 `sys.ordering-cycles` 和 `sys.x11-socket-dir` 两项检查 |
| 一般 | systemd-oomd 开机后不监视用户会话 | systemd 262 不把晚启动的 user@UID 推给 oomd | 用户管理器启动 30 s 后由 `l410-oomd-resync@.timer` 让 oomd 重新订阅（`system/mem/systemd/`） |
| 一般 | 极限内存压力下 kswapd 打印整页分配失败 | 6.18 swap table 的睡眠分配在 PF_MEMALLOC 下必然失败，失败本身已被处理 | `mm, swap: don't warn when the sleeping swap table allocation fails`（加 `__GFP_NOWARN`） |
| 轻微 | 开机有 31 行错误级日志 | 厂商驱动把可选项缺失当错误打印；固件设备树里有占位节点和老式属性 | `staging: hi110x: log missing optional configuration at info level`、`PCI: dwc: kport: keep a repeated power-off out of the error log`、`l410: dt: drop what only puts errors in the boot log` |
| 轻微 | 每次开机打印 trace_printk 横幅和 debugfs 自动挂载的弃用提示（都是这轮开发新加的代码带来的） | hi110x 的 `ftrace_vprintk()` 宏留下了 `__trace_printk_fmt` 段；sched_ext 用户态程序内置的 libbpf 先去探测 /sys/kernel/debug/tracing | `staging: hi110x: keep the verbose=2 trace path out of __trace_printk_fmt`（改调 `__ftrace_vprintk()`）；`l410: config: no tracefs automount on debugfs`（关掉 `TRACEFS_AUTOMOUNT_DEPRECATED`）；sched_ext 的补丁不再探测 debugfs |
| 测试 | 约 10 处测试脚本问题 | GPU 调频测试恢复时钉在 600 MHz；依赖测试用的 USB 网卡；恢复期的 USB 复位误报；ufs 测试的日志标记串号；性能档下 power.sh 误判；性能档的延迟 QoS 下 cpu.idle 误报；蓝牙测完被关掉；klog 白名单和过滤；烤机的 ping 统计和 klog 漏判 | 各脚本已修 |

## 已知问题

| 问题 | 状态 |
|---|---|
| 在最终内核上，开机 4 h 18 min 后系统日志突然中断，没有关机记录，最后一条是一次普通的 ssh 登录登出 | 原因不明，未关闭。下一次开机覆盖了 pstore；journald 默认 5 分钟才同步一次磁盘，死机前几分钟的日志可能没写进去。内核已开软/硬锁死检测、hung task 检测和 pstore 控制台记录，再出现时如果以热重启结束就能留下记录，长按电源键冷关机则会丢失 |
| 连接器物理尺寸读成 0×0 mm（没有经 eDP 桥读 EDID） | `quick.sh` 里登记为已知失败（`dsp.edid-size`） |
| UFS `rpm_lvl` 设为 5 时，恢复后第一次退出 auto-hibern8 失败 | 默认用 1，不受影响；`ufs.sh` 只在 `UFS_TEST_RPM5=1` 时测这一级 |
| Spectre-v2 BHB 只显示部分缓解 | 大核（0xd40）不在内核的 BHB 列表里；`quick.sh` 记 WARN |
| 没插网线时 RTL8168 停在 D0，不进 D3hot | `quick.sh` 记 WARN |
| KVM 不可用 | 固件只给 EL1（`HYP mode not available`） |
| 指纹不可用 | 传感器在 TEE（iTrustee）后面，6.18 没有 tzdriver |
| lavd 下温控限频比 EAS 平缓 | 持续满载时温度会比 EAS 略高，之后被积分项压住。要和 EAS 一致，可以改成按空闲时间估算负载（cpufreq_cooling 的非 SMP 实现） |
| lavd 下 Chromium 渲染主线程常在小核上 | bilibili 页面的渲染主线程 49% 到 59% 的时间在 A55 小核（EAS 下 70% 到 78% 在大核）。绑到大核后 CPU 时间从约 75% 降到约 45%，但滚动掉帧没有明显变化 |
| lavd 下的电池续航 | 没测（要拔电源） |

## 没覆盖的部分

要人或仪器的项目这轮都没做：全键、触控板手势、合盖、耳机插拔和听音、看屏（画质、亮度、偏色）、外设插拔、
实验室仪器（功耗、温升、射频）、多台样机一致性。压力类也没做：lavd 下的烤机、`sysfs-sweep.sh` 只读遍历、
10 次重启循环、72 h 烤机和 1000 次循环。外接显示目前不支持，不在测试范围内。
