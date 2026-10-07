# 快速自检 `tests/quick.sh`

`tests/quick.sh` 是 [测试计划](test-plan.md) 里能无人值守、能自动判定、跑得快的那部分，做成了一个脚本。
它有 21 个模块、约 200 项判定，完整模式约 1 分钟（一次实测 63 s），`--fast` 跳过负载、I/O、放音、渲染和扫描，半分钟以内。
换内核、装包、改配置之后都可以跑一次。结果直接给出 PASS/FAIL，不需要人看屏幕、听声音、按键或插拔。

## 运行

| 场景 | 命令 |
|---|---|
| 在 L410 上直接跑 | `sudo bash tests/quick.sh` |
| 从另一台机器经 ssh 跑 | `ssh <host> 'sudo bash -s' < tests/quick.sh` |
| 经 ssh 带参数 | `ssh <host> 'sudo bash -s -- --fast' < tests/quick.sh` |
| 只跑或跳过某几个模块 | `--only ufs,usb`、`--skip audio,gpu` |
| 交付前检查（测试残留算失败） | `--profile prod` |
| 列出模块和各自的时间上限 | `--list` |

经 ssh 用 `bash -s` 时，stdin 已经被脚本占了，`sudo` 没法问密码，所以远端账户要能免密 `sudo`；
不行的话先把脚本 `scp` 过去，再 `ssh -t <host> sudo bash quick.sh`。不是 root 时脚本会自己用 `sudo -n` 重新执行。
结果目录留在 L410 上，需要时用 `scp -r` 拷回来。移植时用的远程运行和拷回工具在 `dev/`，见 [dev/README.md](../../dev/README.md)。

全部选项：

| 选项 | 作用 |
|---|---|
| `--fast` | 跳过慢的检查（负载、I/O、放音、渲染、扫描） |
| `--only a,b` / `--skip a,b` | 只跑 / 跳过这些模块 |
| `--profile dev\|prod` | 默认 dev。prod 下测试残留和调试开关判 FAIL，见下文 |
| `--risky` | 加跑从没在这台机器上试过的操作（目前只有 cpu7 下线再上线） |
| `--out DIR` | 结果目录，默认 `/var/log/l410-quick/<时间>/` |
| `--list` | 列出模块后退出 |

环境变量：`L410Q_COUNTRY`（期望的 WiFi 国家码，默认 `CN`），`L410Q_IPERF`（iperf3 服务器地址，设了才测 WiFi 吞吐）。

## 安全

脚本可以在正在用的桌面上、经 WiFi 的 ssh 跑，不会把自己断开：

- 不断网：不动 wlan0、NetworkManager、rfkill。r8169 解绑重绑只在有线网卡既不承载默认路由、也不承载本次 ssh 时才做。
- 不停显示：不停 sddm/KWin，不抢 DRM master。vblank 测速用不需要 master 的 `DRM_IOCTL_WAIT_VBLANK`。
- 不挂起、不重启、不关机。温度模拟只到 95 °C，碰不到 105 °C 的过热关机。
- 不写块设备。I/O 测试写 `/var/tmp/l410-quick/` 下的文件，结束删除。不读写 MMIO，不用 `lspci`（会读配置空间），
  不读 `/proc/tty/driver/ttyAMA`（时钟关断时读已断时钟的 PL011 会触发外部中止）。
- 改过的都会恢复：cpufreq 调速器、GPU devfreq 上下限、PELT 倍率、温度模拟、混音器开关、背光、电源档位、hub 端口、静音灯。
  每个模块结束立即恢复，脚本被中断也会恢复。温度模拟另有一个 30 s 的 systemd 定时器兜底。
- 每个模块有时间上限（10 到 45 s），超时整棵进程树杀掉并记一条 `<模块>.timeout` FAIL。
- 屏幕关着（DPMS off）而有 Wayland 会话时，脚本先用 `kscreen-doctor` 点亮屏幕做显示检查，结束时再关上。显示链在熄屏时整条断电，不点亮就查不了桥、面板和电源域。

会有的动静：约 2 s 的 -40 dBFS 1 kHz 提示音（很轻）、背光亮度 ±1 一瞬间、摄像头断开再接上一次、
有 Wayland 会话时屏幕上闪一个 320×240 的 glmark2 小窗口 2 s。

## 输出与判定

每项一行：`<结果> <检查ID> <说明>`。

| 结果 | 含义 | 计入失败 |
|---|---|---|
| PASS | 通过 | |
| FAIL | 不符合预期 | 是 |
| XFAIL | 失败，但在脚本开头的 `KNOWN` 清单里（已知问题） | 否 |
| XPASS | `KNOWN` 清单里的项目通过了：问题已修，该把它从清单删掉 | 否 |
| WARN | 需要留意，但不能无人值守地判为错（和环境有关，或可能是别的负载造成） | 否 |
| SKIP | 条件不满足（没插网线、设备被占用、没装工具） | 否 |
| INFO | 记录数值 | 否 |

最后三行：`RESULT: PASS` 或 `RESULT: FAIL (n)`；`SUMMARY: pass=… fail=… xfail=… …`；`OUT: <结果目录>`。
退出码是意外 FAIL 的个数（上限 100）。

结果目录里的文件：

| 文件 | 内容 |
|---|---|
| `summary.json` | 内核版本、序列号、耗时、各类结果计数，`failures`、`known_failures`、`warnings`、`xpass` 明细 |
| `results.jsonl`、`results.tsv` | 每项一条：`result id plan message`，`plan` 是 [test-plan.md](test-plan.md) 的用例 ID |
| `log.txt` | 完整输出 |
| `klog-boot.txt`、`klog-run.txt` | 本次启动的内核日志（开跑时的快照）；测试期间新增的内核日志 |
| `dt-unbound.txt` | 固件设备树里有节点、6.18 下没有驱动的设备清单 |
| `timing.txt` | 各模块耗时 |

判定：`RESULT: PASS`（退出码 0）表示没有新的回归。有 FAIL 时看 `summary.json` 的 `failures`，
每条的 `plan` 字段对应 test-plan.md 里的用例。出现 XPASS 就更新 `KNOWN`。

## KNOWN 清单

在 `tests/quick.sh` 开头，每行 `<检查ID 通配> <计划ID> <原因>`。列在里面的检查失败时记 XFAIL，不计入失败；通过时记 XPASS。
修好一项、出现 XPASS 就删掉对应行。新发现的问题只有在确认短期内不修时才加进来，这样 `RESULT: PASS` 始终表示“没有新的回归”。

当前清单只有一行：

| 检查 | 用例 | 原因 |
|---|---|---|
| `dsp.edid-size` | DSP-08 | 连接器报告的物理尺寸是 0×0 mm（没有经 eDP 桥读 EDID） |

## dev 与 prod 两种档

有一类检查找的是测试残留和调试开关：开发机上它们是正常的，交付的系统里不该有。
默认的 `--profile dev` 只把它们记成 INFO，`--profile prod` 判 FAIL。涉及的检查：
`sys.cmdline-test-args`、`cfg.debug-off`、`sec.kaslr`、`sec.restrict`、`sec.debugfs`、`sec.sshd` 和 `img` 模块全部。
这些残留大多来自 `dev/` 里的移植工具，清单和清理方法见 [dev/README.md](../../dev/README.md)。

## 检查项目

“慢”列打勾的在 `--fast` 下不跑。期望值来自同一台机器上厂商 4.19 内核的读数和移植时的实测。
每个模块后面列出它的结果会带哪些 `plan` 用例 ID。

开机不到 60 s 时脚本先等到 60 s（异步探测和 WiFi 校准要时间）。

### env：机器与版本

用例：SVC-04。全部是记录项。

| ID | 内容 | 判定 |
|---|---|---|
| env.dmi | SMBIOS 型号、序列号、BIOS、EC 版本 | 型号是 `L410 KLVU-WDU0B` |
| env.kernel / cmdline / power / temps / uptime | 内核版本、命令行、AC 与电量、档位、各温区、开机时长 | 记录 |

### sys：系统与启动

用例：BLD-06、BLD-07、INS-02、INS-07、BOOT-07、BOOT-10、UX-01、UX-10、FLT-01、SVC-02、UFS-04、UFS-09、MEM-04、ETH-04。

| ID | 内容 | 判定 |
|---|---|---|
| sys.kernel | 内核版本 | `6.18.x-l410-*` |
| sys.cmdline-required | 必需的内核参数 | 有 `efi=noruntime`、`regulator_ignore_unused`、`log_buf_len=` |
| sys.cmdline-test-args | 测试参数（`l410_deadman`、`l410.mode`、`systemd.unit`、`nokaslr`、`*_ignore_unused`、`ignore_loglevel` 等） | dev 记录，prod 有则 FAIL |
| sys.state | `systemctl is-system-running` | running；degraded 时列出失败单元 |
| sys.ordering-cycles | 本次启动 systemd 有没有为打破顺序环删掉任务 | 没有（顺序环曾让 `tmp.mount` 被删，`/tmp/.X11-unix` 被盖住，Xwayland 起不来） |
| sys.x11-socket-dir | KWin 在跑时 `/tmp/.X11-unix` | 存在 |
| sys.user-units | 桌面用户会话里失败的用户单元 | 没有 |
| sys.boot-time | `systemd-analyze` 内核加用户态 | ≤ 30 s，否则 WARN |
| sys.graphical | 显示管理器 | display-manager.service active |
| sys.deferred | `devices_deferred` | 空 |
| sys.reset-reason | PMIC 记录的上次复位原因 | 记录 |
| sys.coredumps | 本次启动以来的用户态崩溃（coredumpctl） | 0 |
| sys.pstore | pstore 里的 dmesg 崩溃记录 | 没有；有则 WARN 并给出时间 |
| sys.taint | `/proc/sys/kernel/tainted` 逐位解码 | 不含 M/B/D/W/L（机器检查、坏页、oops、WARN、软锁死）；C/O/E 在开发构建里允许 |
| sys.ntp | NTP 同步 | 已同步，否则 WARN |
| sys.journal | 持久化 journal 与占用 | `/var/log/journal` 存在 |
| sys.rootfs / rootfs-errors / rootfs-space | 根分区 | UFS 用户盘上的分区（`/dev/sddN`），ext4 rw；tune2fs 状态 clean、没有错误记录；使用率 ≤ 90% |
| sys.fstrim | `fstrim.timer` | enabled，否则 WARN |
| sys.swap | swap 或 zram | 有，否则 WARN |
| sys.nm / sys.route | NetworkManager 应答 D-Bus；默认路由 | 有 |

根分区按 `findmnt /` 取，`ufs.ah8-exits` 也从它读，Debian 装在 sdd 的哪个分区都可以。

### klog：本次启动的内核日志

用例：BOOT-10、WLAN-15。

| ID | 内容 | 判定 |
|---|---|---|
| klog.splat | Oops、BUG、WARNING、SError、Unable to handle、RCU stall、软/硬锁死、hung task、panic | 0 |
| klog.errors | 错误级（0 到 3）日志，去掉白名单 | 0 |
| klog.warnings | 警告级（4）日志，同一白名单 | 0，否则 WARN（列出最多的几类） |
| klog.wifi-volume | 开机前 120 s 内 WiFi/BT 驱动的日志行数 | ≤ 100 |
| klog.dss-underflow | `LDI underflow` | 0 |
| klog.pcie-timeout | completion timeout、kport link down | 0 |
| klog.usb-errors | xHCI 死机或超时、枚举失败、USB PHY 超时 | 0 |
| klog.ufs-errors | ufshcd 错误、中止、超时，块设备 I/O error | 0 |
| klog.i2c-errors | DesignWare I2C 超时、仲裁丢失 | 0 |
| klog.gpu-errors | panfrost job timeout、MMU fault、复位 | 0 |
| klog.thermal-critical | 过热关机 | 0 |
| klog.ipc-timeouts | IPC 邮箱超时或无 ACK | 0 |
| klog.oom | OOM 杀进程 | 0，否则 WARN |
| run.klog | 测试期间新增的内核日志里有没有 splat 类 | 0 |

白名单是脚本里的 `KLOG_ALLOW`，收的是已知无害的行：Hi110x 开机时的几类提示、SPI3 厂商子节点片选越界、
TAS2562 缺 imon/vmon slot、PCI I/O 窗口、dummy regulator、DMA mask、固件设备树里 `pddevice`/`fastboot` 节点引用非 GPIO 控制器、
systemd 对 SysV 脚本的提示、staging 模块的 taint 提示等。`tests/ufs.sh` 故意做 host reset 的那一段时间里的日志也会被排除。

### cpu：处理器

用例：SOC-01 到 SOC-04、SOC-16、PERF-08、SEC-01。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| cpu.online | 在线 CPU | 0-7 | |
| cpu.midr | 每核 MIDR | 4× 0x411fd050（A55 r1p0）+ 4× 0x483fd400（HiSilicon 0xd40） | |
| cpu.capacity | cpu_capacity | 283×4、767×2、1024×2，否则 WARN | |
| cpu.freq-policy0/4/6 | 簇划分、频率范围、OPP 数、驱动 | 0-3 / 4-5 / 6-7；554-1863、826-2088、1536-2861 MHz；各 13 档；hisi-hwvote | |
| cpu.vote-policy0/4/6 | userspace 调速器依次投最低、中间、最高、最低，读 `cpuinfo_cur_freq`（LPM3 实际给的） | 投多少给多少；档位把范围收窄时 SKIP | |
| cpu.schedutil-load | 8 线程 stress-ng 2.5 s 后各簇频率 | ≥ 最高频的 90%；调速器不全是 schedutil 时 SKIP | ✓ |
| cpu.schedutil-idle | 停止负载后 4 s 内（每 0.25 s 看一次） | 各簇回到范围下半段；否则 WARN 并列出最忙的 3 个进程 | ✓ |
| cpu.idle | psci_idle；cpu0/4/6 最深的可用状态 1.5 s 内使用次数增加；没有被禁用的状态 | 满足；没进最深态 WARN。性能档有 100 µs 的延迟 QoS，只算退出延迟不超过它的状态 | |
| cpu.eas | 3 个簇的能耗模型、`sched_energy_aware` | 3 个、=1 | |
| cpu.uclamp / cpu.pelt | uclamp sysctl；PELT 倍率 1/2/4 可切、拒绝 3 | 满足（恢复原值） | |
| cpu.rate-limit | schedutil `rate_limit_us` | 省电档 3000，其余 500，否则 WARN；读不到时记录 | |
| cpu.vulnerabilities | CPU 漏洞缓解状态 | 没有 Vulnerable；`not BHB` 或 Unknown 记 WARN | |
| cpu.pmu | 性能计数器 PMU 覆盖的 CPU、DSU PMU | 有 | |
| cpu.hotplug | cpu7 下线再上线（只在 `--risky`） | 两步都成功 | |

### mem：内存

用例：MEM-01、MEM-02、MEM-05、SVC-02。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| mem.total | MemTotal | ≥ 7.7 GB（约 7683 MiB） | |
| mem.cma | CMA 总量、剩余 | 128 MiB、剩余 ≥ 16 MiB，否则 WARN | |
| mem.ramoops | ramoops 与 pstore | `26e00000.pstore-mem` 由 ramoops 驱动，`/sys/fs/pstore` 已挂载 | |
| mem.slab | Slab、SUnreclaim、内核栈、页表、vmalloc | 记录（长稳前后对比用） | |
| mem.stress | stress-ng 2×256 MiB 全部 vm 方法 5 s，带校验 | 0 错误 | ✓ |

### soc：时钟、IPC、总线、设备树对账

用例：SOC-05、SOC-06、SOC-12、SOC-13、SOC-15。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| soc.clk-report | 时钟注册报告 | `502 clock nodes, 0 without provider, 0 orphans` | |
| soc.clk-gating | 真实关断的状态（钉住的时钟数） | 记录 | |
| soc.clk-orphans | debugfs 孤儿时钟 | 0 | |
| soc.clk-rates | 11 个关键时钟频率（clkin_sys、PPLL0/2/6、aobus、I2C、uart4 166 MHz、uart6、32k、audio MCLK） | 与厂商内核一致（±2 Hz） | |
| soc.ipc-bound / ipc-timeouts / ipc-lpm3 | 3 个 IPC 块；开机以来 ACK 超时数；向 LPM3 发一条无害的 PPLL0 保持投票 | 3 个；0；返回 0 且 ACK 计数加 1 | |
| soc.bound-hwspinlock/dma/pinctrl/gpio/uart/spi/i2c | 驱动绑定数量 | 1/1/8/37/≥4/1/4 | |
| soc.i2c-buses | i2c-3/4/6/7 | 都在 | |
| soc.sn65dsi86 | 读 eDP 桥的 ID 寄存器（只读） | `68ISD` | |
| soc.dmatest | dma0chan0 上 20 次 memcpy | 0 failures | ✓ |
| soc.dt-core-bound | 这台机器需要的 53 个设备（UFS、USB、PCIe、DSS、GPU、音频、PMIC、IPC、EC、HID、WiFi/BT、PCI 端点等）绑定的驱动名 | 全部正确 | |
| soc.dt-unbound | 固件设备树里有节点、没有驱动的设备 | 记录数量，清单写进 `dt-unbound.txt` | |

### pmic：电源管理芯片

用例：SOC-08、SOC-09、BOOT-15。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| pmic.probe | PMIC 在 SPMI usid 9 | 探测成功 | |
| pmic.regulators | 13 路 LDO/BUCK 电压；ldo9/15/23/24/38 必须开着 | 与厂商内核一致 | |
| pmic.ip-domains | 19 个 IP 电源域 | 全部注册 | |
| pmic.display-domains | dsssubsys、media1_subsys、vivobus | 开着 | |
| pmic.peri-dvfs | 外设调压投票者 | 已探测 | |
| pmic.rtc | PMIC RTC 与系统时间（按 `/etc/adjtime` 的 LOCAL/UTC 换算） | 相差 ≤ 5 s | |
| pmic.rtc-alarm | 设 +2 s 闹钟，看 RTC 中断（已有闹钟时不做） | 中断到来 | ✓ |
| pmic.powerkey | 电源键输入设备 | 存在 | |
| pmic.clk32k | clk_pmu32kb（WiFi/BT 芯片的 32 kHz） | 已使能 | |

### thermal：温控

用例：THM-01、THM-02。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| thm.zones | 9 个温区（cluster0/1/2、gpu、modem、npu、peri、hisec、电池） | 都在，10 到 85 °C | |
| thm.trips | cluster0/1/2、gpu 的触发点、策略、冷却绑定 | 被动 90 °C、临界 105 °C、power_allocator、有冷却设备 | |
| thm.cooling | 冷却设备 | cpufreq-cpu0/4/6 和 GPU 的 devfreq | |
| thm.not-throttling | 此刻有没有冷却设备在工作 | 没有，否则 WARN | |
| thm.emul-throttle | cluster2 模拟 95 °C，大核上跑 2 线程负载 | 3 s 内 cpufreq-cpu6 冷却状态 > 0 或大核最高频下降 | ✓ |
| thm.emul-recover | 撤掉模拟 | 5 s 内限频解除 | ✓ |

### ufs：存储

用例：UFS-01 到 UFS-06、UFS-10、UFS-12。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| ufs.driver / ufs.link | 驱动；链路 | ufshcd-kirin；HS-G4 ×2、FAST、rate B | |
| ufs.luns | 4 个 LUN 的型号与大小 | WDC SDINFDO4-512G；8192 / 131072 / 2621440 / 997433344 扇区 | |
| ufs.fw-lun-protect | sda/sdb/sdc：器件上电写保护，内核只读（含全部分区） | 全部满足 | |
| ufs.other-os-parts | 固件 LUN、sdd1 到 sdd6（麒麟等）有没有被读写挂载 | 没有 | |
| ufs.ah8 / ufs.pm-levels | auto-hibern8；rpm_lvl/spm_lvl | 已开；1/3（5 有已知问题，WARN） | |
| ufs.writebooster | WriteBooster 开关 | 记录 | |
| ufs.error-counters | debugfs 错误事件计数（复位类除外） | 全 0 | |
| ufs.health | 健康描述符 pre-EOL、寿命估计 A/B | 0x01 / ≤ 0x05 通过；pre-EOL ≥ 3 或寿命 ≥ 0x0A 失败 | |
| ufs.io-verify | fio 128 MiB 随机 4k 到 256k O_DIRECT 写，crc32c 校验 | 0 错误，记录读写速率 | ✓ |
| ufs.read-rate | O_DIRECT 顺序读 | ≥ 500 MB/s，否则 WARN | ✓ |
| ufs.ah8-exits | 25 次“空闲超过 AH8 定时，再读一下” | 读全成功，AH8 错误计数不变 | ✓ |
| ufs.no-new-errors | I/O 检查前后的错误计数 | 不变 | ✓ |

### usb

用例：USB-01、USB-04、CAM-01。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| usb.drivers | PHY、glue、dwc3、xhci、板载 hub | 都绑定 | |
| usb.phy | combo PHY 启动日志 | SRAM 固件已加载，mux 3（USB + DP 2 lane） | |
| usb.topology | 两个根 hub、RTS5411 的两半、摄像头 | 位置与速率：usb1 480M、usb2 10G、1-1 480M、2-1 5G、1-1.4 480M | |
| usb.external / usb.rtl8153 | 外接设备清单；插着 RTL8153 时查 5000M 和 r8152 | 记录；满足 | |
| usb.camera | 摄像头的 uvcvideo 与 V4L2 节点 | 有 | |
| usb.camera-grab | 抓 5 帧（摄像头被占用时 SKIP） | 有数据 | ✓ |
| usb.camera-replug | hub 端口 4 断电再上电 | 设备消失、回来，uvcvideo 重新绑定 | ✓ |
| usb.resets | 开机以来 USB 总线复位次数 | ≤ 2，否则 WARN | |

### pcie：PCIe 与有线网

用例：ETH-01、ETH-02、PM-09、REL-07、WLAN-10。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| pcie.rc-f0000000 / rc-f4000000 | 两个 RC | 绑定 pcie-kport | |
| pcie.rc0-nic | RTL8168 | 10ec:8168、r8169、2.5 GT/s x1 | |
| pcie.rc0-mac | 当前 MAC 与永久 MAC | 相同，华为 OUI 24:81:c7 | |
| pcie.eth-link / eth-ping | 插着网线时：1000 Mb/s 全双工；ping 网关 20 次 0 丢包，MSI-X 中断计数增长 | 满足；没网线 SKIP | |
| pcie.rc0-d3 | 没网线时 RTL8168 的电源状态 | D3hot，否则 WARN | |
| pcie.rc0-rebind | r8169 解绑再绑定（有线网承载路由或 ssh 时 SKIP） | 网卡回来，MAC 不变 | ✓ |
| pcie.rc1-wifi | WiFi 端点 | 19e5:1103、hi110x_pci、5.0 GT/s x1 | |

### wifi

用例：WLAN-01、WLAN-02、WLAN-04、WLAN-05、WLAN-10、WLAN-11、WLAN-13、PM-10。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| wifi.module / debug-params | hi110x 已加载；`verbose`、`ssi_dump` | 已加载；两者为 0，否则 WARN | |
| wifi.netdev | wlan0 的永久 MAC | 来自 EEPROM（24:81:c7） | |
| wifi.rfkill | 软/硬阻断 | 都没有 | |
| wifi.country | 全局监管域 | 等于 `L410Q_COUNTRY`（默认 CN） | |
| wifi.link | 已连接时 SSID、频率、速率、信号 | 信号 ≥ -70 dBm；未连接 WARN | |
| wifi.station-dump | `iw station dump` | 5 s 内结束且只有 1 条（防 dump_station 死循环回归） | |
| wifi.tx-stats | 发送包数、重传、失败 | 记录 | |
| wifi.nm | NetworkManager 状态 | connected，connectivity full 或 limited | |
| wifi.power-save | WiFi 省电与档位 | 性能档关，其余开，否则 WARN | |
| wifi.ping | ping 网关 20 次 | 0 丢包，平均 ≤ 30 ms（超过 WARN） | ✓ |
| wifi.dns | 解析 www.baidu.com | 成功，否则 WARN | ✓ |
| wifi.throughput | 设了 `L410Q_IPERF` 时 iperf3 5 s | ≥ 100 Mbit/s，否则 WARN | ✓ |
| wifi.chip-errors | 开机以来的芯片异常（SSI_ERR、hcc 异常）、DFR、BFG 唤醒或打开失败、端点配置空间读到全 1 | 0 | |

### bt：蓝牙

用例：BT-01、BT-06。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| bt.hci0 | 控制器、总线、地址 | UART，BD 地址来自 EEPROM（24:81:C7） | |
| bt.hci-errors | hciconfig 的 RX/TX 错误 | 0 | |
| bt.service / bt.powered | bluetoothd；控制器上电 | active；Powered yes | |
| bt.hci-roundtrip | `hciconfig hci0 version`：一次 HCI 命令和事件往返（经 BUART 唤醒芯片） | 8 s 内有应答 | |
| bt.heartbeat | 最近 5 分钟的 bfgx heartbeat 超时 | 0 | |
| bt.cmd-timeouts | 开机以来的 HCI 命令超时 | 0，否则 WARN | |
| bt.scan | 6 s 扫描 | ≥ 1 个设备，否则 WARN | ✓ |

### display：显示与背光

用例：DSP-01、DSP-02、DSP-08、PERF-08。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| dsp.kms | kirin990-dss 的 DRM 卡、eDP-1 | connected、enabled、DPMS On、2160x1440 | |
| dsp.refresh | 驱动实测的帧周期 | 60.3 到 60.7 Hz | |
| dsp.underflows / dsp.frames | kirin_frames | underflows 0；记录 vblank、翻页、延迟 | |
| dsp.commit-thread | kirin-commit 线程 | SCHED_FIFO 50 | |
| dsp.vblank-rate | 等 60 个 vblank（`DRM_IOCTL_WAIT_VBLANK`，DPMS 关时不做） | 60.2 到 60.8 Hz | ✓ |
| dsp.edid-size | 连接器物理尺寸 | 不是 0x0（已知失败，在 `KNOWN` 里） | |
| dsp.planes | 平面数 | 记录（主平面加光标） | |
| dsp.backlight | 背光设备 | max 100、亮度 > 0、bl_power 0（亮度 0 就是黑屏） | |
| dsp.backlight-set | 亮度 ±1 写入、回读、恢复 | 一致 | |
| dsp.pwm | blpwm 周期 | 497.8 µs（2 kHz，厂商值） | |

### gpu

用例：GPU-01、GPU-02、GPU-04。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| gpu.driver | panfrost、GPU ID、renderD128 | Mali-G76，id 0x7211 | |
| gpu.devfreq | OPP、范围、调速器 | 14 档、上限 600 MHz、simple_ondemand | |
| gpu.egl | `eglinfo -p surfaceless` | Mali-G76 (Panfrost)，记录 GLES 版本 | |
| gpu.dvfs | 钉 600 MHz、再钉 166 MHz，读 devfreq 与 clk_g3d（LPM3 实际给的） | 两者都等于请求值 | ✓ |
| gpu.render | 有 Wayland 会话：以桌面用户跑 glmark2-es2-wayland 320×240 的 build 场景 2 s；没有会话且显示没被占用：glmark2-es2-drm --off-screen | 返回 0、得分 > 0 | ✓ |
| gpu.dvfs-activity | 渲染期间 devfreq 切换次数 | 记录 | ✓ |
| gpu.boost-thread | panfrost-boost 线程 | SCHED_FIFO | |
| gpu.cooling | GPU 温区的冷却设备 | devfreq-fe140000.mali | |

### audio：音频

用例：AUD-01、AUD-03、AUD-05 到 AUD-08、AUD-17。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| aud.card / aud.codec | 声卡与 PCM；Hi6405 版本 | hi6405，放音加录音；version 0x11、chip id 64 05 01 00 | |
| aud.controls | 11 个必需控件 | 都在 | |
| aud.amp-volume | 两颗 TAS2562 的数字音量读数 | 110/110（0 dB）。读成 0 说明 `ASoC: tas2562: report the power-on digital volume` 的修复丢了 | |
| aud.state-file | `/var/lib/alsa/asound.state` 里的功放音量 | 都 > 0（否则开机 alsa-restore 会让喇叭没声） | |
| aud.amps / amps-idle | 功放 debugfs；空闲时状态 | 两颗都能读；关断，没有实时故障位 | |
| aud.idle-pm | 空闲时 SLIMbus 的运行时状态 | suspended，否则 WARN | |
| aud.jack | 耳机检测输入设备 | 存在，记录耳机插拔状态 | |
| aud.ucm | `alsaucm -c hi6405 list _verbs` | 有 HiFi | |
| aud.pipewire | PipeWire 默认输出设备（按 ALSA 卡属性识别，界面名是本地化的“内置音频”） | 是 hi6405 声卡 | |
| aud.play | 扬声器放 2 s -40 dBFS 1 kHz（PCM 空闲时用 `aplay hw:`，被占用时以 PipeWire 用户 `pw-play`） | 成功，hw_ptr 前进 | ✓ |
| aud.dma | ASP DMA 中断 | 2 s 内 ≥ 60 次（20 ms 周期） | ✓ |
| aud.amps-play | 放音中两颗功放 | 工作态、没有故障、没有实时 TDM 时钟错误 | ✓ |
| aud.amps-stop | 放音结束后 0.6 s | 两颗都已关断 | ✓ |
| aud.mic | 内置 DMIC 录 1 s | 峰值 ≥ 20、取值种类 ≥ 20（不是静音） | ✓ |
| aud.idle-after | 放音录音结束 2.5 s 后的 SLIMbus | runtime suspended，否则 WARN | ✓ |

### input：键盘、触控板、合盖

用例：INP-01、INP-03、INP-08。

| ID | 内容 | 判定 |
|---|---|---|
| inp.keyboard / inp.touchpad | HID 设备的驱动与报告描述符 | hid-generic / hid-multitouch；描述符 md5 与厂商内核相同 |
| inp.devices | 输入设备 | 键盘、飞行模式键、触控板、电源键、合盖、耳机检测 |
| inp.hotkeys | 键盘设备的键码位图 | MUTE、VOLUME±、BRIGHTNESS±、POWER、SLEEP、RFKILL 必须有；只缺 MICMUTE 记 WARN |
| inp.lid | `evtest --query` 的 SW_LID | 开着（合着 WARN） |
| inp.irqs | 键盘、触控板中断 | 已注册 |
| inp.libinput | 装了 libinput-tools 时：触控板能力含 gesture | 满足 |

### ec：EC、电池、AC

用例：BAT-01、BAT-03、BAT-04、BAT-08、BAT-09、AUD-12、PM-02。

| ID | 内容 | 判定 |
|---|---|---|
| ec.bound / ec.errors | EC 驱动；开机以来的传输、错误、重试、状态错、PEC 错 | 已绑定；错误总和 0 |
| ec.traffic | 经 debugfs 连续 5 次带 PEC 的寄存器读（电量） | 传输 +5，错误不变 |
| bat.present / bat.values | 在位、电量、电压、设计容量、温度、循环、健康 | 1 到 100%、6.0 到 8.9 V、7230 mAh、10 到 50 °C、1 到 2000 次、Good |
| bat.health | 满充容量占设计容量 | ≥ 80%，否则 WARN |
| bat.consistent | AC 状态、电池状态、电流方向 | 插电：Charging 电流为正，或 Full 电流近 0；拔电：Discharging 电流为负 |
| bat.thermal-zone | 电池温区与 power_supply 温度 | 相差 ≤ 1 °C |
| bat.upower | UPower 百分比 | 与 sysfs 相差 ≤ 1 |
| ec.mute-led | 静音灯开关、恢复 | EC 没有新增错误 |
| ec.sync-gpio | EC 状态同步 GPIO | 输出高（运行中） |

### perf：性能档位

用例：PM-10、PERF-08。结束时恢复原档位。

| ID | 内容 | 判定 | 慢 |
|---|---|---|---|
| perf.l410 | l410_perf 档位；CPU、GPU、DDR 下限都挂上 | `bound cpufreq 1 1 1 gpu 1 ddr 1` | |
| perf.tuned | tuned 当前 profile 与 l410_perf 档位；tuned-ppd | `l410-<档位>`；active | |
| perf.ddr | DDR devfreq | 性能档锁最高，其余用 powersave 调速器 | |
| perf.mode-performance | 切到性能档 | CPU 下限等于最高频，GPU 在最高频 | ✓ |
| perf.mode-balanced | 切到平衡档（空闲） | CPU 没有下限 | ✓ |
| perf.launch-boost | 写 launch 800 ms | 期间 CPU 在最高频，之后恢复 | ✓ |
| perf.input-boost | 临时 uinput 设备发一次按键（游戏手柄键，桌面不处理） | CPU 下限立即抬高 | ✓ |

### sec：内核配置与加固

用例：BLD-04、BLD-05、SEC-02、SEC-03、SEC-13。

| ID | 检查的配置项 | 用途 |
|---|---|---|
| cfg.hardening | STRICT_DEVMEM IO_STRICT_DEVMEM RANDOMIZE_BASE STACKPROTECTOR_STRONG FORTIFY_SOURCE HARDENED_USERCOPY STRICT_KERNEL_RWX SECCOMP SECURITY_YAMA | 基本加固；经 /dev/mem 读 MMIO 会让机器中止 |
| cfg.lsm | SECURITY SECURITY_APPARMOR AUDIT | Debian 默认用 AppArmor |
| cfg.containers | CGROUPS MEMCG CPUSETS NAMESPACES USER_NS NET_NS BPF_SYSCALL OVERLAY_FS VETH BRIDGE | systemd、Chromium 沙箱、flatpak 和容器 |
| cfg.netfilter | NETFILTER NF_TABLES NFT_CT NFT_NAT NF_CONNTRACK | Debian 的防火墙是 nftables |
| cfg.vpn | TUN WIREGUARD XFRM_USER INET_ESP PPP L2TP | VPN 客户端 |
| cfg.netfs | CIFS NFS_FS | 网络共享盘 |
| cfg.usbfs | EXFAT_FS NTFS3_FS VFAT_FS UDF_FS ISO9660_FS JOLIET BLK_DEV_SR NLS_UTF8 NLS_CODEPAGE_936 NLS_CODEPAGE_437 FUSE_FS | U 盘、光盘、USB 光驱、中文文件名 |
| cfg.usb | USB_STORAGE USB_UAS USB_ACM USB_SERIAL USB_SERIAL_CH341 USB_SERIAL_PL2303 USB_PRINTER SND_USB_AUDIO USB_VIDEO_CLASS USB_NET_CDCETHER USB_NET_RNDIS_HOST | U 盘、串口设备、打印机、USB 耳机、扩展坞网口、手机 USB 共享网络 |
| cfg.bluetooth | BT_RFCOMM BT_BNEP BT_HIDP UHID | 蓝牙耳机通话（HFP 走 RFCOMM）、网络共享、经典与 BLE 键鼠 |
| cfg.hid | HIDRAW USB_HIDDEV HID_BATTERY_STRENGTH | 直接访问 HID 设备的工具、UPS、键鼠电量 |
| cfg.wwan | USB_NET_HUAWEI_CDC_NCM USB_NET_CDC_MBIM USB_NET_QMI_WWAN USB_WDM PPP | 4G 上网卡 |
| cfg.qdisc | NET_SCH_FQ_CODEL | systemd 默认的队列规则，大流量时的网络延迟 |
| cfg.storage | BLK_DEV_LOOP DM_CRYPT ZRAM SQUASHFS | 镜像、全盘加密、压缩内存交换 |
| cfg.system | INPUT_UINPUT EFIVAR_FS DMI PSTORE_RAM WATCHDOG SOFTLOCKUP_DETECTOR HARDLOCKUP_DETECTOR DETECT_HUNG_TASK WQ_WATCHDOG | 输入注入、固件变量、崩溃采集、卡死检测 |

每组缺任何一项就 FAIL 并列出缺的项。读不到内核配置（没开 IKCONFIG_PROC，也没有 `/boot/config-*`）时记 `cfg.present` FAIL。

| ID | 内容 | 判定 |
|---|---|---|
| cfg.debug-off | DMATEST | 不应有（dev 记录，prod FAIL） |
| sec.kaslr | 命令行里的 `nokaslr` | 没有（dev 记录） |
| sec.restrict | kptr_restrict ≥ 1、dmesg_restrict = 1 | 满足（dev 记录） |
| sec.debugfs | 能直接写硬件的 debugfs 文件（`kirin-ipc/xfer`、`hi6405/registers`、`huawei-echub/read`） | 没有（dev 记录） |
| sec.sshd | 密码登录、root 登录 | 都关（dev 记录） |

### img：系统里的测试残留

用例：INS-07、BOOT-10。dev 记录，prod FAIL。

| ID | 内容 |
|---|---|
| img.test-units | 启用的 `l410-*` 测试服务（其中有的会在一段时间没人操作后重启机器） |
| img.sudo | NOPASSWD sudo 规则 |
| img.autologin | sddm 自动登录 |
| img.networkd | 实验室静态 IP 的 networkd 配置 |
| img.pstore | systemd-pstore 被屏蔽 |
| img.leftovers | KWin 逐帧日志 drop-in、`*.orig` 启动脚本、hi110x.ko 备份 |
| img.kernel-path | 跑的是测试工具放在 `/boot/l410/Image` 的内核，而不是打包安装的内核 |
| img.identity | machine-id、ssh 主机密钥指纹（多台机器之间必须不同，只记录） |

## 加新检查

- 写成 `pass|fail|warn|skip|info <模块.名字> "<说明>"`，之前先设 `PLAN=<test-plan 用例 ID>`。
- 会改系统状态的检查：改之前 `on_restore "<恢复命令>"`；可能卡住的外部命令一律加 `timeout`。
- 慢的放进 `if slow; then … fi`；从没在这台机器上试过的操作放进 `[ "$RISKY" = 1 ]`。
- 期望值写死在脚本里（厂商 4.19 读数或实测值）。改了硬件相关的实现，要同时改期望值和本文档。

最近一次回归里 quick.sh 和其他测试的结果见 [results.md](results.md)。
