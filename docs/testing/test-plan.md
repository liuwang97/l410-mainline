# L410 + Linux 6.18 整机测试计划

对象：华为擎云 L410（KLVU-WDU0B，麒麟 990），`6.18.54-l410` 内核，Debian arm64 + KDE Plasma Wayland。
这份计划按整机的全生命周期列用例，从构建、安装、开关机一直到升级、生产线和报废。
无人值守的那部分已经做成 [`tests/quick.sh`](quick-suite.md)，最近一次回归的结果在 [results.md](results.md)，
脚本清单在 [tests/README.md](../../tests/README.md)。

## 出厂标准指什么

“出厂”在这里的意思是：一台装好 Debian + 6.18 的 L410 交给不碰命令行的最终用户，能长期正常使用；
出了问题能自动恢复、能收集日志，能升级也能回退。

| 方面 | 要求 |
|---|---|
| 功能完整 | 用户看得到的每个硬件功能都能用，或者写进“不支持的功能”清单 |
| 稳定 | 长时间运行、反复开关机、挂起、插拔不出错；出错能自动恢复并留下日志 |
| 性能与续航 | 不低于同一台机器上厂商 4.19 内核的基线 |
| 安全 | 内核加固、LSM 等基本要求满足；固件分区和机器上的其他系统不被破坏 |
| 可维护 | 可升级、可回退、可诊断；每台机器有出厂测试记录 |

放行门限（建议值，有整机规格书时按规格书改）：

| 指标 | 门限 | 用例 |
|---|---|---|
| 冷启动 | 样机验证 500 次 0 失败；每台出厂 ≥ 3 次 | BOOT-02 |
| 热重启 | 1000 次 0 失败 | BOOT-03 |
| 关机 | 200 次 0 失败，下电后整机电流不超过规格 | BOOT-04 |
| 挂起/恢复 | 1000 次 0 失败，每次恢复后设备检查全过 | PM-03 |
| 混合烤机 | 72 h：0 oops、0 挂死、0 数据校验错、0 设备掉线 | REL-01 |
| 出厂老化 | 每台 4 h 混合负载，自动判定通过 | REL-03 |
| 突然断电 | 100 次，文件系统可恢复，已 fsync 的数据 0 丢失 | UFS-08 |
| 性能 | CPU、内存、存储 ≥ 基线 95%；网络 ≥ 基线 90% | PERF-* |
| 续航 | ≥ 基线 90% | PERF-09 |
| 待机耗电 | ≤ 基线；没有基线时先定 ≤ 1 %/h | PM-05 |
| 内核日志 | 启动和长稳中没有 Oops/WARN/BUG/SError/RCU stall/hung task；err/warn 只允许白名单里的条目 | BOOT-10 |
| 调试内核 | KASAN + lockdep 内核跑完 A 类用例，0 报告或逐条处置 | REL-09 |
| 多机 | ≥ 3 台不同批次的机器结果一致 | REL-10 |

## 用例字段

- 类：A 自动（无人值守）；S 半自动（脚本驱动，要人做一个动作，比如插拔、按键、合盖，脚本按内核事件判定）；M 人工判定（看、听）；L 实验室（要仪器或治具）。
- 级：P0 不过不能出厂；P1 必须通过，不过要书面豁免；P2 应该通过，可以带着已知问题出厂。
- 脚本：`tests/` 下检查了这一项（全部或一部分）的脚本，省略 `.sh`。`quick` 即 `tests/quick.sh`，它的每条结果都带对应的用例 ID。
  空着的项目目前只能人工做，或者还没有测试。

## 测试层级

| 层级 | 何时 | 内容 | 时长 |
|---|---|---|---|
| 冒烟 | 每次构建 | `tests/quick.sh` | 约 1 分钟 |
| 集成回归 | 每个候选版本 | 全部 A 类功能用例、REL-08、1 h 混合烤机、50 次重启、50 次挂起、THM-02 | 约半天 |
| 发布验证 | 每个发布版本 | 全部用例（含 S/M/L）、72 h 烤机、1000 次循环、多机、基线对比 | 2 到 3 周 |
| 出厂 | 每台 | MFG-01 到 MFG-05（含 4 h 老化） | 按产线节拍 |
| 维护回归 | 6.18.y 更新、用户态包更新 | 集成回归 + 已修缺陷的回归 + UPD-* | 约 1 天 |

安排上的依赖：挂起和熄屏类用例依赖显示的完整 modeset；循环和长稳类用例要求被测机自己记状态、每轮开机自动接着跑，
并且有正式的看门狗（SOC-10）。人工项（全键、触控板、屏幕、听音、耳机、插拔）适合集中安排一次做完。
破坏性测试（UFS-08、ENV-*）只在专门的样机上做，不在日常使用的机器上做。

## 测试环境

### 样机

- 样机验证阶段至少 3 台，覆盖不同生产批次：触控板 Goodix 或 Elan、有没有 lt9711a 显示桥、UFS 供应商与容量、内存容量。
- 每台记录：序列号、UEFI 与 EC 版本、UFS 型号与固件版本、触控板 ID、电池循环次数。
- 机器上保留出厂的麒麟时，麒麟所在的分区必须保护（UFS-12、COEX-*）。

### 设备与治具

| 用途 | 设备 |
|---|---|
| 冷启动、关机循环 | 接在电源键两端的继电器或机械按键器；也可以用 PMIC RTC 闹钟开机（BOOT-05） |
| 突然断电 | 可编程电源加继电器（只用专门的样机） |
| 功耗、续航 | 直流电源分析仪或 USB-C PD 功率计；EC 报的电压×电流作软件侧读数 |
| AC 插拔循环 | USB-C 继电器或智能插座 |
| 显示 | 测试图；色度计；光电二极管加示波器（PWM 闪烁） |
| 音频 | 3.5 mm TRRS 回环线（耳机输出接耳麦输入，自动测耳机口）；带线控的有线耳麦；声级计、人工耳（实验室） |
| 网络 | 双频 AP（WPA2、WPA3、企业认证 + RADIUS）；同 SSID 的第二台 AP（漫游）；千兆交换机与网线；iperf3 服务器；射频屏蔽箱 |
| 蓝牙 | 蓝牙耳机（A2DP/HFP）、蓝牙鼠标与键盘、手机 |
| USB | USB2 和 USB3 U 盘、总线供电移动硬盘、USB 键鼠、USB 声卡、USB-C 扩展坞（PD 直通、HDMI、网口）、USB hub、打印机、扫码枪、智能卡读卡器 |
| 电源适配器 | 原装 PD 适配器；第三方 PD 45/65/100 W；5 V 普通充电器 |
| 温度 | 温箱；热电偶或红外热像仪 |

### 基线

性能、续航、功耗、温度、WiFi 吞吐都和同一台机器上的厂商 4.19 内核比：

- 首选同一套 Debian 用户态配厂商 4.19.71 内核：只差内核，结果可以直接比。
- 其次是出厂的麒麟（同样是 4.19.71）。在麒麟上只读、不写 MMIO，只跑不用装包的项目。
- 两边用同一个脚本、同一背光占空比（按 PWM 占空比固定，不按百分比）、同一网络位置、同一电量区间、同一室温。

## 脚本约定

新写的测试脚本照这些做：

- 结果行格式和 `quick.sh` 一样：`PASS|FAIL|SKIP|WARN|INFO <ID> <说明>`，最后一行 `RESULT: PASS` 或 `RESULT: FAIL (n)`，退出码是失败数。
- 每次运行记录环境：`uname -r`、`/proc/cmdline`、电量与 AC、各温区、电源档位、序列号。
- 内核日志门禁：开始时记 `journalctl -k` 的游标，结束后只看新增部分；出现
  `Internal error|Unable to handle|SError|BUG:|WARNING: CPU|Oops|rcu.*stall|soft lockup|hung_task|underflow|completion timeout` 即 FAIL，err/warn 对照白名单。
- 每个用例都有 `timeout`；整体可以放进 `systemd-run --wait --pipe -p RuntimeMaxSec=`，结束时 systemd 清掉残留进程。
- 循环测试的状态（计数、失败记录）存在被测机本地，开机由服务接着跑，次数到了或出错就停。
- 半自动项提示操作的同时监听对应事件（evtest、`udevadm monitor`、ALSA jack 控件），按事件判定，操作员的回答只作记录，超时算 FAIL。

安全规则（都是这台机器上踩过的坑）：

- 不用 /dev/mem、devmem 读写寄存器：麒麟下这样读过就把机器读崩了，6.18 下读已关时钟的外设会中止。硬件状态只经驱动提供的 sysfs/debugfs 读。
- 不写 sda/sdb/sdc（固件 LUN）和 sdd1 到 sdd6（麒麟、ESP 等）。测试文件只写 `/var/tmp` 下的目录，结束删除；存储测试对文件做，不对块设备 `dd`。
- 可能挂死的操作（驱动解绑重绑、挂起、温度注入、sysfs 遍历）之前，先用 `systemd-run --on-active=` 另起一个兜底重启。
- 读内核日志用 `journalctl -k -b`，不用 `dmesg`：WiFi 驱动的日志会把环形缓冲里早期的内容挤掉。
- 脚本经 `bash -s` 从 stdin 喂入时，会读 stdin 的程序（kmscube、modetest、evtest）要接 `</dev/null`，或者把整段脚本包进函数。
- 桌面测试在用户会话里跑：设 `XDG_RUNTIME_DIR=/run/user/<uid>` 和 `DBUS_SESSION_BUS_ADDRESS`，用 `kde-inhibit --power --screenSaver` 防锁屏。
  `/tmp` 重启会清空，结果写 `/var/tmp` 或 `/var/log`。
- 不读保存的 WiFi 密码。时间比较按 `/etc/adjtime` 的 LOCAL/UTC 换算（为了和麒麟共存，RTC 存的是本地时间）。

## 这次移植特有的风险

| 风险 | 说明 | 用例 |
|---|---|---|
| 关机没验证过 | PSCI SYSTEM_OFF 没测过。关机后是否真正下电、EC 处于什么状态、能否再按电源键开机都不知道；用户关机、低电量关机、过热关机都依赖它 | BOOT-04/05、BAT-05、THM-03 |
| EFI 运行时服务关着 | 为绕开 GetTime 缺页加了 `efi=noruntime`：没有 efivars，`efibootmgr`、`systemctl reboot --firmware-setup`、Secure Boot 状态读取、UEFI capsule 升级都用不了 | INS-02、SEC-05、UPD-05 |
| 冷启动与热重启不同 | UEFI 留给内核的硬件状态两种启动不一样。USB 就出过这类问题：UEFI 留下的 NoC 不在 idle，驱动重新初始化时触发 SError | BOOT-01/02 |
| 读寄存器即中止 | 时钟真实关断默认打开，读已关时钟外设的寄存器会同步外部中止（PL011 是一例）。proc/sysfs/debugfs 里可能还有同类路径 | REL-08 |
| 厂商 WiFi/BT 代码 | hi110x 是 staging 里的厂商驱动，模块不能卸载；企业认证、热点、漫游、WiFi/BT 共存、蓝牙音频和键鼠需要专门测；没在 KASAN/lockdep 下跑过 | WLAN-*、BT-*、REL-09 |
| 扬声器没有保护 | TAS2562 的 I/V sense 没用，厂商的喇叭保护算法没有；时钟错误超过 52 ms 功放自己休眠后，没有厂商那样的恢复处理 | AUD-04、AUD-13 |
| 崩溃采集与看门狗 | 没有正式的看门狗配置和 kdump；厂商的 PMIC 异常监控（pmic_mntn：过流、过温、SMPL）没有移植，售后分不清是不是硬件保护复位 | SOC-10、FLT-01/02、SVC-02/08 |
| 批次差异 | 固件设备树里有 Elan 触控板（6-0015）、lt9711a 显示桥等其他批次的器件，一台样机覆盖不了 | REL-10、INP-12 |
| 有线网没插过网线 | 链路、吞吐和 MSI 的实际投递都没验证 | ETH-02/03 |

## 用例

### 构建与发布（BLD）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| BLD-01 | 可复现 | 内核仓库的 `l410-6.18` 分支在干净的 v6.18.54 上重建，config、DTB、模块列表与发布的一致 | A | P0 | |
| BLD-02 | 编译警告 | 新增和移植的非 staging 驱动 `make W=1` 警告不多于上一版；checkpatch 0 error | A | P2 | |
| BLD-03 | DT 校验 | `dtc -W` 检查最终 DTB 没有新增警告；每个 fixup 的目标属性都存在且生效 | A | P1 | |
| BLD-04 | 内核配置审计 | 与 Debian 官方 arm64 内核配置逐项对比：cgroup v2、BPF、seccomp、user namespace、AppArmor、nftables、TUN/WireGuard/IPsec、CIFS/NFS、exFAT/NTFS3/UDF/ISO9660、UAS、USB 串口、HIDP/BNEP/RFCOMM、uinput、zram、fuse、overlayfs、squashfs、loop 齐全，其余缺失项有理由 | A | P0 | quick、desktop-cfg |
| BLD-05 | 生产配置去调试化 | DMATEST 关；STRICT_DEVMEM、IO_STRICT_DEVMEM 开；改硬件的 debugfs 写接口不编进或受控；`hi110x.ssi_dump=0`；测试看门狗关掉或换成正式看门狗 | A | P0 | quick |
| BLD-06 | 版本标识 | `uname -r`、`/proc/version`、模块 vermagic、包版本一致，能追溯到 git 提交 | A | P1 | quick |
| BLD-07 | 许可与 taint | 只允许 staging 的 C 标志；没有 P、O、W | A | P1 | quick |
| BLD-08 | 调试内核 | 开 KASAN、PROVE_LOCKING、DEBUG_ATOMIC_SLEEP、UBSAN、KMEMLEAK、DEBUG_OBJECTS 能编译、能启动（给 REL-09 用） | A | P1 | |
| BLD-09 | 可重复构建 | 固定 KBUILD_BUILD_TIMESTAMP/USER/HOST，两次构建的 Image 与模块哈希一致 | A | P2 | |
| BLD-10 | 固件清单 | 内建固件（USB PHY）、`rtl8168h-2.fw`、WiFi/BT 固件与 ini、UFS/PCIe PHY 补丁表，每项有来源、版本、许可、安装路径 | A | P0 | |

### 安装与部署（INS）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| INS-01 | Debian 包 | linux-image、linux-headers、固件包能 `dpkg -i`；initramfs 和 GRUB 菜单项自动生成；headers 能用 DKMS 编一个外部模块 | A | P0 | |
| INS-02 | 内核参数 | 最终 `/proc/cmdline` 带必需参数（`efi=noruntime`、`regulator_ignore_unused`、`log_buf_len`），不带测试参数（见 [dev/README.md](../../dev/README.md)） | A | P0 | quick |
| INS-03 | DTB 加载 | 多个内核并存时各用各的 DTB；`/proc/device-tree` 里能看到 fixup 属性 | A | P0 | |
| INS-04 | initramfs | 根分区按 UUID 挂载；fsck 执行；需要的固件在内；`update-initramfs -u` 可重复执行 | A | P0 | |
| INS-05 | 多内核并存 | 装两个 6.18 包，GRUB 里还有麒麟：每一项都能启动；删旧包不影响当前内核 | A | P0 | |
| INS-06 | 全新安装 | 装到空分区，首次开机除了 OOBE 输入没有人工干预；首启后冒烟全过 | S | P0 | |
| INS-07 | 系统卫生 | 没有测试服务、NOPASSWD sudo、测试用 authorized_keys、自动登录、与麒麟相同的 ssh 主机密钥、实验室静态 IP 的 networkd 配置、被屏蔽的 systemd-pstore、KWin 逐帧日志、`*.orig` 启动脚本、驱动备份、`/var/tmp` 测试数据 | A | P0 | quick（`--profile prod`） |
| INS-08 | 单机个性化 | 同一镜像装到两台机器，machine-id、ssh 主机密钥、主机名、DHCP client-id 各不相同，都在首启时生成 | A | P0 | quick（记录） |
| INS-09 | 无线固件与校准 | 校准数据和 MAC 从本机 EEPROM 读，不跨机拷贝 | A | P0 | |
| INS-10 | 离线安装 | 没有公网时用本地源安装和升级成功 | S | P1 | |

### 开机、重启与关机（BOOT）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| BOOT-01 | 冷启动 | 关机状态按电源键，进到图形登录界面，无人工干预；记录各阶段耗时 | S | P0 | |
| BOOT-02 | 冷启动循环 | 继电器按电源键或 RTC 闹钟开机自动循环：样机 500 次 0 失败，每批抽检 ≥ 50 次 | L | P0 | |
| BOOT-03 | 热重启循环 | `systemctl reboot` 循环，每轮跑冒烟：1000 次 0 失败，pstore 没有新 panic，UFS 错误计数 0 | A | P0 | cycle |
| BOOT-04 | 关机 | `systemctl poweroff` 后整机下电（电源灯灭、电流不超过规格），再按电源键正常开机；200 次 0 失败 | S | P0 | |
| BOOT-05 | RTC 闹钟开机 | 设 PMIC RTC wakealarm 后关机，到点自动开机（无人值守冷启动循环要用）。第一次试要有人在旁边，失败了得按电源键 | S | P1 | |
| BOOT-06 | 关机/重启耗时 | 命令到下电 ≤ 10 s；没有 90 s 超时的 stop job | A | P1 | |
| BOOT-07 | 启动耗时 | `systemd-analyze`、首帧、到 sddm、到桌面可用，各阶段不比基线慢 10% 以上 | A | P1 | quick、cycle |
| BOOT-08 | 电源条件 | 插 AC、只有电池、电量 < 5%、电量 0% 插 AC 立刻开机：都能启动，或按 EC 设计拒绝开机并有提示；不出现开到一半断电 | S | P0 | |
| BOOT-09 | 外设条件 | 插着 USB 网卡、U 盘、耳机启动：都能启动，设备都枚举 | S | P1 | |
| BOOT-10 | 启动日志 | 没有 Oops/WARN/BUG/SError/RCU stall；err/warn 只有白名单条目；`devices_deferred` 为空 | A | P0 | quick、smoke、cycle |
| BOOT-11 | 启动一致性 | 连续 20 次启动，网卡名、声卡号、DRM card 号、hci0、input 设备名每次相同 | A | P1 | cycle |
| BOOT-12 | 启动画面 | 屏幕一直有输出，没有长时间黑屏或花屏，平滑过渡到 sddm | M | P1 | |
| BOOT-13 | 与麒麟共存的 GRUB | 麒麟原有的默认启动项不变；Debian 的菜单项能启动 | A | P0 | |
| BOOT-14 | 强制关机 | 长按电源键整机断电；再开机 fsck 通过，没有数据损坏；重启原因可区分 | S | P0 | |
| BOOT-15 | 电源键短按 | 桌面、sddm、锁屏下各按一次，触发 logind/Plasma 配置的动作 | S | P1 | quick（只查设备） |
| BOOT-16 | kexec | kexec 到同一内核不挂死（kdump 的前提） | A | P2 | |

### 平台核心（SOC）与内存（MEM）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| SOC-01 | CPU 拓扑 | 8 核在线；4×A55 + 4×0xd40；簇划分、capacity、cache 与 4.19 一致 | A | P0 | quick |
| SOC-02 | CPU 热插拔 | cpu1 到 cpu7 逐个下线上线 100 轮，不挂死，cpufreq/cpuidle 状态恢复 | A | P1 | quick（`--risky`，cpu7 一次） |
| SOC-03 | cpufreq | 三簇每个 OPP 设置后回读等于请求；满载升频、空闲降频 | A | P0 | quick、power、perf |
| SOC-04 | cpuidle | 空闲 60 s，各簇都进 cpu-sleep-0 和 cluster-sleep，空闲占比 > 90% | A | P0 | quick、power |
| SOC-05 | 时钟 | 502 个节点、0 孤儿、关键频率与厂商一致 | A | P0 | quick、soc-core |
| SOC-06 | IPC/LPM3 | 往返正常；长稳后超时计数仍为 0 | A | P1 | quick、soc-core |
| SOC-07 | 中断 | 空闲 60 s 前后比较 `/proc/interrupts`：没有中断风暴，没有 spurious | A | P1 | |
| SOC-08 | PMIC 与调压器 | 13 路调压器和 19 个 IP 电源域的电压与状态和厂商一致 | A | P0 | quick、power |
| SOC-09 | RTC | 读写与闹钟正常；关机 1 h 后时间正确；24 h 对 NTP 漂移 ≤ 2 s/天；与麒麟互切后时间一致 | S | P1 | quick、power |
| SOC-10 | 生产看门狗 | SP805 正式驱动 + systemd `RuntimeWatchdogSec`；人为制造用户态挂死和内核硬锁，都能自动复位，pstore 留下日志，下次启动能读到 | A | P0 | |
| SOC-11 | GPIO | `/sys/kernel/debug/gpio` 与 4.19 逐条对照，用到的 GPIO 方向和电平一致，没有冲突 | A | P1 | |
| SOC-12 | I2C 健康 | i2c-3/4/6/7 上的 EC、HID、功放、桥长时间轮询 0 错误、0 超时；总线卡死能恢复 | A | P1 | quick、soc-core |
| SOC-13 | 外设 DMA | dmatest 0 错；UART4/SPI3 改 DMA 后收发数据一致 | A | P2 | quick |
| SOC-14 | 共享 GPIO 组 | 长稳前后对比 GPIO 配置快照，没被 LPM3 等其他核改乱（主线 pl061 没有厂商的 hwspinlock） | A | P2 | |
| SOC-15 | 设备树对账 | 固件设备树中启用的每个设备节点归入“已绑定”或“有意不支持”，遗漏为 0 | A | P0 | quick |
| SOC-16 | 性能计数器 | `perf stat` 分别绑在 A55 和 0xd40 核上都能计数；DSU PMU 可用或已声明 | A | P2 | quick |
| MEM-01 | 内存容量 | 可用内存与 4.19 一致；保留区（CMA、hifi-data、ramoops）大小符合设计 | A | P0 | quick |
| MEM-02 | 内存压力 | stressapptest/memtester 覆盖 ≥ 90% 空闲内存：样机 24 h、出厂老化 2 h，0 错误 | A | P0 | quick（5 s）、soak-mix |
| MEM-03 | CMA/DMA 分配 | 长时间运行后开多窗口，显示缓冲仍能分配；swiotlb 用量不持续增长 | A | P1 | |
| MEM-04 | OOM | 吃光内存时 OOM killer 生效，系统不挂死，桌面能恢复 | A | P1 | quick、mem |
| MEM-05 | 内核内存泄漏 | 24 h 混合负载前后 slab 不持续增长；调试内核 kmemleak 0 报告或逐条处置 | A | P1 | quick（记录） |

### 温控与散热（THM）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| THM-01 | 温区读数 | 同负载同室温下与 4.19 相差 ≤ 3 °C | A | P0 | quick |
| THM-02 | 被动降频 | `emul_temp` 注入 90 °C 以上（CPU 簇、GPU），冷却生效，撤掉后恢复 | A | P0 | quick |
| THM-03 | 过热关机 | 注入 105 °C 时有序关机并记录原因；正常负载下不误触发（依赖 BOOT-04） | S | P0 | |
| THM-04 | 持续满载 | 性能档 CPU+GPU+DDR 满载 1 h：结温 < 95 °C，降频平滑，不关机；输出频率温度曲线 | A | P0 | soak-mix |
| THM-05 | 表面温度 | 满载、视频播放、边充电边负载时键盘面、掌托、底壳热点不超过规格，不比基线高 2 °C 以上 | L | P0 | |
| THM-06 | 环境温度 | 规格上下限环境温度下 A 类用例和 THM-04 全过 | L | P1 | |
| THM-07 | 充电温升 | 边充电边满载，EC 报的电池温度不超规格，EC 降流正常 | L | P1 | |
| THM-08 | 最后防线 | 长稳结束后查 PMIC 记录：没有过流/过温复位，重启原因不是异常 | A | P1 | |

### 存储：UFS 与文件系统（UFS）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| UFS-01 | 链路 | FAST-G4 ×2 rate B | A | P0 | quick、ufs |
| UFS-02 | 固件 LUN 保护 | 器件上电写保护开；三个 LUN 只读；udisks 忽略；普通用户访问 /dev/sd* 被拒 | A | P0 | quick、ufs、smoke |
| UFS-03 | 性能 | fio 顺序读写、4K 随机读写 QD1/QD32（在文件上）≥ 基线 95% | A | P1 | quick（顺序读） |
| UFS-04 | 数据完整性 | fio verify（crc32c）大文件、多线程、随机，24 h 0 校验错 | A | P0 | quick、ufs、soak-mix |
| UFS-05 | 错误处理 | host reset、AH8 压力后恢复，读写不报错（rpm_lvl 5 的已知问题见 results.md） | A | P1 | quick、ufs |
| UFS-06 | 运行时 PM | 空闲时进 auto-hibern8、LUN 运行时挂起；唤醒延迟在规格内 | A | P1 | quick |
| UFS-07 | 系统挂起 | 随 PM-03 挂起/恢复 1000 次 0 错误 | A | P0 | |
| UFS-08 | 突然断电 | 写入中切断电源 100 次（专门样机）：ext4 日志恢复、fsck 无错，已 fsync 的数据不丢 | L | P0 | |
| UFS-09 | TRIM | `fstrim -v /` 成功；`fstrim.timer` 启用 | A | P1 | quick |
| UFS-10 | 健康信息 | 能读 bPreEOLInfo、bDeviceLifeTimeEstA/B，纳入诊断包 | A | P1 | quick |
| UFS-11 | 常驻写入量 | 空闲 1 h 的写扇区数低于阈值；UFS 能进低功耗 | A | P2 | |
| UFS-12 | 其他分区保护 | 6.18 下 sdd1 到 sdd6 没有写入（授权的 ESP/GRUB 更新除外） | A | P0 | quick（查读写挂载） |
| UFS-13 | 软件全盘加密 | LUKS 下读写正常，性能下降可接受；inline crypto、RPMB、HPB 不支持已声明 | A | P2 | desktop-cfg |

### 显示与背光（DSP）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| DSP-01 | 内屏 | 2160×1440 @ 60.51 Hz；没有 LDI underflow | A | P0 | quick、graphics |
| DSP-02 | 背光 | 0 到 100 逐级亮度单调；最低档可见；0 是关；2 kHz PWM 没有可闻啸叫和可见闪烁 | S | P0 | quick（读写与 PWM 周期） |
| DSP-03 | 亮度热键与保持 | OSD 与背光同步；重启、重新登录后亮度保持且不为 0 | S | P0 | |
| DSP-04 | 熄屏 | 空闲超时、锁屏熄屏后背光和面板真的关闭；按键唤醒后画面正常 | S | P0 | display-power |
| DSP-05 | 完整 modeset | 面板断电再上电（DSI + eDP 桥重新初始化）1000 次，每次画面恢复，没有 underflow | A | P0 | display-power |
| DSP-06 | 挂起后显示 | 随 PM-02，恢复后画面正常 | S | P0 | suspend |
| DSP-07 | 画面内容 | 纯色、灰阶、棋盘格、渐变测试图：坏点在规格内，没有色偏、撕裂、偏移 | M | P0 | |
| DSP-08 | 物理尺寸 | 连接器 mm 尺寸正确；KDE 默认缩放合理 | A | P1 | quick（已知失败） |
| DSP-09 | VT 切换 | Wayland 与 tty 来回切 100 次，没有黑屏和 underflow | A | P1 | |
| DSP-10 | 硬件光标 | 移动、换形状、隐藏时不闪、不残留、位置准 | M | P1 | |
| DSP-11 | 外接显示 | 目前不支持 DP/HDMI 输出；支持后测热插拔、EDID、1080p60/4K30、镜像与扩展、≥ 3 款显示器、插拔 100 次 | S | P0 | |
| DSP-12 | 外接屏 + 挂起 | 依赖 DSP-11 | S | P1 | |
| DSP-13 | 坞站模式 | 依赖 DSP-11：合盖 + 外接屏 + 外接键鼠时内屏关、外屏工作、不挂起 | S | P1 | |
| DSP-14 | 显示长稳 | 24 h 动态画面，没有 underflow 和 DSS 错误 | A | P0 | |
| DSP-15 | 夜间模式 | KWin 夜间模式生效，或确认 DSS 没有 gamma 支持并声明 | M | P2 | |

### GPU 与图形栈（GPU）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| GPU-01 | 识别 | Mali-G76 (Panfrost)，GLES 3.1 | A | P0 | quick、graphics |
| GPU-02 | 调频 | devfreq 钉最低、最高后回读一致（166 到 600 MHz）；冷却设备在 | A | P0 | quick、graphics、perf |
| GPU-03 | 一致性 | dEQP-GLES2/GLES3/EGL mustpass 抽样通过率不低于 Mesa 对 Bifrost 的公开结果 | A | P1 | |
| GPU-04 | 长稳 | glmark2 循环 24 h，没有 job timeout、GPU reset、MMU fault | A | P0 | quick（2 s）、soak-mix |
| GPU-05 | 挂死恢复 | 提交一个超时作业后 panfrost 复位，桌面继续可用 | A | P1 | |
| GPU-06 | Vulkan | vulkaninfo 可用，或确认应用回退到 GL 并声明 | A | P2 | |
| GPU-07 | 浏览器加速 | chrome://gpu、about:support 里 GPU 合成与 WebGL 开启 | S | P1 | bench/desktop-ab/gpu-check |
| GPU-08 | 显存压力 | 大纹理、多上下文耗尽时优雅失败，不 oops | A | P2 | |
| GPU-09 | 运行时下电 | g3d 电源域空闲下电、再上电 1000 次无错误 | A | P1 | |

### 音频（AUD）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| AUD-01 | 声卡与通路 | aplay/arecord、DAPM、DMA、功放状态全过 | A | P0 | quick、audio |
| AUD-02 | 左右声道 | 只放左、只放右，DMIC 录音比电平加人听，左右正确 | S | P0 | |
| AUD-03 | 爆音与回音 | 启停、暂停 1000 次；功放没有时钟错误（上电时已知的约 10 ms 除外）；录音里没有瞬态尖峰；人听提示音、说话、音乐、小音量都没有爆音和回音 | S | P0 | quick（功放状态）、audio-ampwatch |
| AUD-04 | 喇叭保护与老化 | 最大音量粉红噪声 4 h（实验室按喇叭规格做更久），喇叭无损，功放没有过温/过流故障 | L | P0 | |
| AUD-05 | 音量 | 0 到 100% 单调；最大不削波；功放数字音量读数与硬件一致，`alsactl store`/`restore` 往返后仍有声 | A | P0 | quick |
| AUD-06 | 麦克风 | 4 路 DMIC 逐路非静音、声道映射正确、噪底在规格内。另在机器跑过麒麟后热重启进 Debian 再录放一次：麒麟会在 HiFi 保留内存里留下残留，曾让 DMA 链表节点带上垃圾数据，由 `ASoC: hisilicon: hi6405: asp-pcm: write the whole LLI node` 修复 | S | P1 | quick、audio |
| AUD-07 | 耳机 | 插拔 100 次（回环线自动测）每次都有 jack 事件；PipeWire 自动切换；左右正确；耳麦录音；线控按键报对应键码 | S | P0 | quick（只查检测设备） |
| AUD-08 | UCM/PipeWire | `alsaucm`、`wpctl status`、KDE 音量小部件里端口名正确，设备切换正常 | A | P0 | quick |
| AUD-09 | 格式与混音 | 44.1 kHz 源、S16/S32、两路流同时放，重采样与混音正常 | A | P1 | |
| AUD-10 | 长时间播放 | 24 h 播放，`pw-top` 的 ERR（xrun）= 0；视频音画同步在规格内 | A | P1 | |
| AUD-11 | 挂起中的音频 | 播放中挂起再恢复，继续播放，没有爆音 | S | P0 | |
| AUD-12 | 静音键与灯 | 按静音键、麦克风静音键，灯与状态同步 | S | P1 | quick（灯）、laptop |
| AUD-13 | 功放自休眠恢复 | 制造超过 52 ms 的时钟中断后再播放，下一次播放有声 | A | P1 | |
| AUD-14 | 蓝牙音频 | 见 BT-03 | S | P0 | |
| AUD-15 | USB 音频 | USB 耳机或声卡即插即用，可放可录，自动切换 | S | P2 | |
| AUD-16 | HDMI 音频 | 依赖 DSP-11 | S | P1 | |
| AUD-17 | 音频省电 | 停流约 2 s 后 SLIMbus/ASP runtime suspend，codec 下电 | A | P1 | quick |

### 输入：键盘、触控板、热键、合盖（INP）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| INP-01 | 枚举 | HID 描述符 md5、键码位图与 4.19 一致 | A | P0 | quick、laptop |
| INP-02 | 全键 | 交互脚本逐键提示，含 Fn 组合，每个键都报预期键码，没有多报漏报 | S | P0 | |
| INP-03 | 热键 | 亮度、音量、静音、麦克风静音、飞行模式、投屏、键盘背光、Fn 锁、截图：桌面动作与 OSD 正确；键盘背光各档正常（由 EC 固件管） | S | P0 | quick（键码位图） |
| INP-04 | 按键可靠性 | 机械手连续击键或人工快打 5 min：不丢键、不重复，常用组合不冲突 | L | P1 | |
| INP-05 | 指示灯 | Caps Lock 等灯与状态同步 | S | P1 | |
| INP-06 | 触控板 | 移动、轻触、按压、双指滚动（含惯性）、双指右键、三/四指手势、缩放、打字时禁用、掌压、画线画圆没有跳点 | S | P0 | scroll-accel-test（滚动加速） |
| INP-07 | 负载下输入 | CPU/GPU 满载时操作键盘和触控板没有明显卡顿；延迟在规格内 | S | P1 | bench/uinput-bench |
| INP-08 | 合盖 | 合开 100 次，每次都有 SW_LID 事件，logind 动作正确 | S | P0 | quick、laptop（只读状态） |
| INP-09 | 电源键 | 见 BOOT-14/15 与 PM-04 | S | P0 | |
| INP-10 | 唤醒源 | 键盘、触控板、电源键、开盖分别按设计唤醒 s2idle | S | P0 | |
| INP-11 | 外接输入 | USB/蓝牙键鼠与内置设备同时用，互不干扰 | S | P1 | |
| INP-12 | 触控板批次 | Elan 触控板（6-0015）样机枚举与手势正常 | L | P1 | |

### EC、电池与充电（BAT）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| BAT-01 | 读数 | power_supply 读数与麒麟一致 | A | P0 | quick、laptop |
| BAT-02 | 充电 | 从低电量充到满：Charging、电流为正、电量上升；满后 Full、电流趋零；时长与基线相当 | S | P0 | |
| BAT-03 | 放电 | 拔 AC：Discharging、电流为负；UPower 剩余时间合理 | S | P0 | quick（状态一致性） |
| BAT-04 | AC 插拔 | 继电器插拔 100 次，每次 1 s 内有 uevent，UPower 与 PowerDevil 切档正确 | S | P0 | quick（UPower 一致） |
| BAT-05 | 低电量链路 | 放电到底：10% 提醒、自动切省电、临界电量有序关机或休眠，都在 EC 硬断电之前完成；下次开机没有 fsck 错误 | S | P0 | |
| BAT-06 | 电量精度 | EC 百分比与电流积分误差 ≤ 5%，电量不跳变 | S | P1 | |
| BAT-07 | 适配器兼容 | 原装、第三方 PD 45/65/100 W、PD 扩展坞、5 V 慢充：能充的都能充，状态正确，慢充有提示 | L | P1 | |
| BAT-08 | 电池健康 | 循环次数、满充/设计容量、温度可读，纳入诊断包 | A | P1 | quick |
| BAT-09 | EC 长稳 | 72 h 轮询 0 PEC 错、0 超时；挂起恢复后状态同步 GPIO 正确 | A | P0 | quick、laptop、soak-mix |
| BAT-10 | 关机与挂起下充电 | 能充电，充电指示灯正常 | S | P1 | |
| BAT-11 | 电池故障位 | EC 故障位、过热位到 power_supply health 的映射正确（不能注入时用代码审查加模拟读数） | A | P2 | |
| BAT-12 | 深度放电 | 放空后放置再充电能开机；RTC 丢失后时间自动同步 | L | P2 | |
| BAT-13 | 不写 EC 充电参数 | 驱动与 debugfs 不改 EC 的充电和保护参数 | A | P1 | |

### USB 与摄像头（USB、CAM）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| USB-01 | 控制器与 hub | 拓扑、速率与麒麟一致；RTL8153 5000M | A | P0 | quick、usb |
| USB-02 | 每个物理口 | 先在麒麟上逐口插设备建“物理口到拓扑”映射表；6.18 下每口插 USB2、USB3 设备速率正确 | S | P0 | |
| USB-03 | U 盘 | USB3 顺序读写速率 ≥ 基线 90%，sha256 一致；FAT32/exFAT/NTFS；安全弹出 | S | P0 | |
| USB-04 | 热插拔 | 每口 100 次，没有枚举失败、xHCI 错误、oops | S | P0 | quick（摄像头端口） |
| USB-05 | 供电 | 总线供电移动硬盘正常；过流后端口恢复 | L | P1 | |
| USB-06 | 外设兼容 | 键鼠、USB 声卡、USB 网卡、打印机、扫码枪、智能卡（pcscd/CCID）、Type-C 扩展坞、hub 级联都可用 | S | P0 | desktop-cfg（驱动别名） |
| USB-07 | 挂起 | 带设备挂起恢复后设备可用；USB 键鼠能唤醒 | S | P0 | |
| USB-08 | 运行时 PM | 空闲设备与 hub 端口 autosuspend | A | P1 | |
| USB-09 | 摄像头供电 | 不用时 GPIO48 与 hub 端口状态符合设计 | A | P2 | |
| USB-10 | 长时间传输 | USB 网卡或 U 盘满带宽 8 h 0 错误 | A | P1 | |
| USB-11 | Type-C 正反插 | 正反各插 USB3 设备速率相同 | S | P1 | |
| CAM-01 | 枚举与抓帧 | uvcvideo，能抓帧 | A | P0 | quick、usb |
| CAM-02 | 格式 | `--list-formats-ext` 每种分辨率和帧率都能抓帧，帧率达标 | A | P1 | |
| CAM-03 | 应用 | 浏览器 WebRTC、视频会议软件、Kamoso 可用 | S | P0 | |
| CAM-04 | 画质与指示灯 | 对焦、曝光、白平衡正常；采集时灯亮 | M | P1 | |
| CAM-05 | 摄像头按键 | HID 按钮接口事件正确 | S | P1 | |
| CAM-06 | 挂起与长时间 | 挂起恢复后可用；采集 1 h 不丢帧 | S | P1 | |

### 有线网络（ETH）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| ETH-01 | 枚举 | RC0、r8169、MAC、固件正确 | A | P0 | quick、pcie |
| ETH-02 | 链路 | 10/100/1000 自协商、全双工；插拔 100 次，链路检测 < 3 s | S | P0 | quick、pcie（插网线时） |
| ETH-03 | 吞吐 | iperf3 TCP ≥ 900 Mb/s；UDP 丢包 < 0.1%；24 h 0 错误；MSI-X 中断计数增长（验证中断投递） | A | P0 | pcie（插网线时 ping 与中断计数） |
| ETH-04 | 地址 | DHCP、静态、IPv6、DNS 由 NetworkManager 管理，正常 | A | P0 | quick |
| ETH-05 | 802.1X | 有线 802.1X 认证通过 | S | P1 | |
| ETH-06 | 省电 | 没网线时 D3hot，插线唤醒；ASPM L1；挂起恢复后链路正常 | S | P1 | quick（D3hot）、pcie（可选挂起） |
| ETH-07 | 网络唤醒 | WoL 能唤醒，或声明不支持 | S | P2 | |
| ETH-08 | 多网卡共存 | 板载网口与 USB 网卡同时接，没有地址冲突 | A | P1 | |

### WiFi（WLAN）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| WLAN-01 | 驱动与扫描 | 2.4 与 5 GHz 都扫到 | A | P0 | quick、wifi-bt |
| WLAN-02 | 连接矩阵 | 2.4/5 GHz × WPA2-PSK、WPA3-SAE、WPA2/WPA3 混合、开放、隐藏 SSID × Plasma 界面和 nmcli，每组 20 次 100% 成功，连接 ≤ 5 s | S | P0 | quick（当前连接） |
| WLAN-03 | 企业认证 | WPA2/WPA3-Enterprise 的 PEAP-MSCHAPv2、EAP-TLS 认证通过，证书校验生效 | S | P0 | |
| WLAN-04 | 吞吐与延迟 | iperf3 TCP/UDP 上下行 ≥ 基线 90%；省电开关两种情况下的入站延迟记录在案 | A | P1 | quick（ping、可选 iperf3） |
| WLAN-05 | 稳定性 | 24 h 流量加 ping 0 断线；AP 重启后自动重连；断开重连 100 次 | A | P0 | quick（station dump）、soak-mix |
| WLAN-06 | 漫游 | 两台同 SSID 的 AP 间切换，中断时长在规格内 | L | P1 | |
| WLAN-07 | 飞行模式 | 热键和设置里切换 100 次，WiFi、BT 同步关开，恢复后自动重连 | S | P0 | |
| WLAN-08 | 挂起恢复 | 连接中挂起，恢复后 ≤ 10 s 重连；1000 次 0 失败 | S | P0 | suspend |
| WLAN-09 | 开机校准 | 统计 100 次启动的校准时长；偶尔超过 9 s 时不导致失败 | A | P1 | |
| WLAN-10 | 端点异常恢复 | 触发固件异常或 completion timeout 后驱动自恢复，做不到至少明确报错 | A | P0 | quick（只查有没有异常） |
| WLAN-11 | 法规与射频 | 国家码与销售地一致；信道表、DFS、发射功率；屏蔽箱测传导功率和 EVM，与麒麟相同（同一份 EEPROM 校准） | L | P0 | quick（监管域） |
| WLAN-12 | 热点/P2P | NetworkManager 开热点可用，或声明不支持 | S | P2 | |
| WLAN-13 | MAC 地址 | 真实 MAC 来自 EEPROM、每台唯一；随机 MAC 策略正常 | A | P1 | quick |
| WLAN-14 | IPv6、门户、代理 | 各测一次正常 | S | P2 | |
| WLAN-15 | 日志量 | 24 h 内驱动日志行数低于阈值 | A | P1 | quick、wifi-bt |
| WLAN-16 | 调试内核 | KASAN/lockdep 内核跑 WLAN-02/05/08 的缩短版，0 报告或逐条处置 | A | P0 | |

### 蓝牙（BT）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| BT-01 | 控制器 | hci0、上电、扫描正常 | A | P0 | quick、wifi-bt |
| BT-02 | 配对 | 鼠标、键盘、耳机、手机配对成功，重启后自动回连 | S | P0 | |
| BT-03 | 音频 | A2DP 播放、HFP 双向通话正常不断续；确认 SCO 走 HCI 还是 PCM | S | P0 | desktop-cfg（RFCOMM/BNEP） |
| BT-04 | 文件传输 | OBEX 可用或声明 | S | P2 | |
| BT-05 | 与 WiFi 共存 | A2DP 播放同时 WiFi iperf3，音频不断续，吞吐下降在规格内 | S | P1 | |
| BT-06 | 心跳 | 没有 bfgx heartbeat 超时；空闲 24 h 后仍可用 | A | P0 | quick |
| BT-07 | 挂起与飞行模式 | 挂起恢复、飞行模式开关后控制器恢复，设备回连 | S | P0 | suspend（只查 hci0） |
| BT-08 | 蓝牙唤醒 | 蓝牙键盘按设计唤醒 | S | P2 | |
| BT-09 | 地址 | BD 地址来自 EEPROM、每台唯一 | A | P1 | quick |
| BT-10 | BUART | 长时间高速收发（音频、文件）没有溢出；PIO 模式下 CPU 占用可接受 | A | P1 | |
| BT-11 | BLE | 扫描、连接 BLE 设备正常 | S | P2 | |

### 电源管理（PM）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| PM-01 | 睡眠能力 | 明确支持哪些睡眠状态（`/sys/power/state`、`mem_sleep`、PSCI SYSTEM_SUSPEND） | A | P0 | |
| PM-02 | s2idle | `rtcwake -m freeze` 后显示、输入、USB、WiFi、BT、音频、UFS、EC、有线网全部恢复，驱动回调无错 | A | P0 | suspend、quick（EC 同步 GPIO） |
| PM-03 | 挂起循环 | 1000 次 0 失败、0 挂死 | A | P0 | |
| PM-04 | 唤醒源矩阵 | 电源键、开盖、键盘、触控板、RTC、AC 插拔、USB 键鼠、蓝牙按设计唤醒或不唤醒 | S | P0 | |
| PM-05 | 待机耗电 | 挂起 8 h ≤ 基线，没有基线时 ≤ 1 %/h | L | P0 | |
| PM-06 | 挂起/恢复耗时 | 挂起 ≤ 5 s；恢复到画面 ≤ 2 s；到网络可用 ≤ 10 s | A | P1 | suspend |
| PM-07 | 合盖与挂起中变化 | 合盖挂起；挂起中插拔 AC、USB、耳机，恢复后状态正确 | S | P0 | |
| PM-08 | 休眠到磁盘 | 支持则 100 次通过；不支持则隐藏菜单并声明 | A | P2 | |
| PM-09 | 运行时 PM 总表 | 空闲时所有设备的 `power/runtime_status` 都是 suspended，或有写明的常开理由 | A | P1 | quick（部分设备） |
| PM-10 | 三档 | tuned-ppd 切换正确；PowerDevil 按电源切档；24 h 内没有非预期切换 | A | P0 | quick、perf |
| PM-11 | 场景功耗 | 亮屏空闲（固定占空比）、熄屏空闲、视频、网页，每档不高于基线 | L | P0 | power-modes、bench/power-ab |
| PM-12 | 时钟关断两种模式 | 默认和 `kirin_clk_keep_on` 各跑 A 类用例，功能结果一致 | A | P1 | |
| PM-13 | 挂起中低电量 | 挂起时电量降到临界，唤醒并有序关机或休眠 | L | P1 | |

### 性能（PERF，与同机 4.19 对比）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| PERF-01 | CPU | sysbench cpu、7-zip b、openssl speed 单核/多核 ≥ 基线 95% | A | P1 | |
| PERF-02 | 内存 | mbw、stream、lat_mem_rd ≥ 基线 95% | A | P1 | |
| PERF-03 | 存储 | 同 UFS-03 | A | P1 | quick（顺序读） |
| PERF-04 | GPU | glmark2、WebGL 记录（与闭源 Mali 对比仅供参考） | A | P2 | graphics |
| PERF-05 | 浏览器 | Speedometer 3、JetStream、MotionMark ≥ 基线 90%；滚动帧率达到 [调优文档](../tuning/) 的目标 | A | P1 | bench/browser-bench |
| PERF-06 | 视频播放 | 本地 1080p30/60、4K30（H.264/HEVC/VP9/AV1）和网络视频的掉帧率、CPU 占用、功耗记录；1080p 不掉帧。没有硬件解码，软解能力要明确告诉用户 | S | P0 | |
| PERF-07 | 应用启动 | 浏览器、文件管理器、办公软件冷/热启动不比基线慢 | A | P1 | bench/launch、quick（launch boost） |
| PERF-08 | 桌面流畅度 | 帧预算和桌面延迟达到调优文档的指标 | A | P1 | quick、perf、bench/frame-budget、bench/desktop-latency |
| PERF-09 | 续航 | 本地视频循环（固定亮度、WiFi 开）、网页循环、亮屏空闲直到关机，≥ 基线 90% | L | P0 | |
| PERF-10 | 多任务 | 浏览器 20 个标签 + 办公 + 视频会议，不卡死，内存可控 | S | P1 | mem-scenario |
| PERF-11 | IO 调度 | none 与 mq-deadline 对比，选择有数据依据 | A | P2 | |

### 桌面与系统集成（UX）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| UX-01 | 图形登录 | 开机自动出 sddm 登录界面 | A | P0 | quick |
| UX-02 | 登录注销 | 登录、注销、切换用户 100 次：会话稳定，重新登录后亮度不为 0，声音设备正常 | S | P0 | |
| UX-03 | 锁屏 | 锁屏、解锁、屏保正常 | S | P0 | |
| UX-04 | 缩放与中文 | HiDPI 缩放、中文字体、fcitx5、中文 locale：显示清晰，输入法可用 | M | P1 | |
| UX-05 | 系统设置 | 显示、电源、网络、蓝牙、音频、输入设备各页反映真实硬件，设置生效 | M | P0 | |
| UX-06 | 通知与 OSD | 音量、亮度、低电量、网络的通知与 OSD 正常 | M | P1 | |
| UX-07 | X11 回退 | X11 会话和 XWayland 应用可用（有些应用只支持 X11） | S | P1 | quick（X11 socket 目录） |
| UX-08 | 常用应用 | 浏览器、办公、PDF、图片、视频、文件管理（U 盘自动挂载）、终端正常 | M | P0 | |
| UX-09 | 打印 | CUPS 下 USB 与网络打印机能打印 | S | P1 | |
| UX-10 | 时间 | NTP、时区、与麒麟互切后时间正确 | A | P1 | quick |
| UX-12 | 无障碍 | 放大镜、高对比、屏幕阅读基本可用 | M | P2 | |

### 可靠性与长稳（REL）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| REL-01 | 72 h 混合烤机 | 性能档 stress-ng + glmark2 + fio verify + 网络 + 音频循环 + 定时抓帧 + EC 轮询：0 oops、0 挂死、0 校验错、0 设备掉线 | A | P0 | soak-mix |
| REL-02 | 168 h 轻载 | 模拟办公开机不关（定时网页、音频、空闲熄屏）：设备不掉线，WiFi/BT 可用，时间不漂 | A | P0 | |
| REL-03 | 出厂老化 | REL-01 的 4 h 简化版，自动判定通过 | A | P0 | soak-mix |
| REL-04 | 开关机循环 | 见 BOOT-02/03/04 的门限 | A/L | P0 | cycle（热重启） |
| REL-05 | 挂起循环 | 见 PM-03 | A | P0 | |
| REL-06 | 外设循环 | USB、耳机、AC、合盖、WiFi 开关、BT 开关各 100 到 1000 次，0 失败 | S/L | P0 | |
| REL-07 | 解绑重绑 | r8169、dwc3 glue、声卡等能解绑的驱动各 100 次，没有泄漏和 oops；hi110x 不能卸载已声明 | A | P1 | quick（r8169 一次）、pcie |
| REL-08 | 只读遍历 | 时钟真实关断开着，root 读 /sys、/proc、debugfs 所有可读文件（跳过有副作用的清单），0 次外部中止、0 oops | A | P0 | sysfs-sweep |
| REL-09 | 调试内核全套 | KASAN + lockdep + DEBUG_ATOMIC_SLEEP + UBSAN 内核跑全部 A 类用例和 4 h 烤机，0 报告，staging 驱动的报告逐条处置 | A | P0 | |
| REL-10 | 多机一致 | ≥ 3 台不同批次跑同一套用例，结果一致 | L | P0 | |
| REL-11 | 长稳后时间 | RTC、系统时间与 NTP 的偏差在规格内 | A | P2 | |

### 异常与故障注入（FLT）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| FLT-01 | panic | `echo c > /proc/sysrq-trigger` 后 pstore 保存，`panic=10` 自动重启，下次启动能取回日志 | A | P0 | quick（查 pstore 与 coredump） |
| FLT-02 | 锁死 | 软锁死、硬锁死测试模块触发后看门狗复位，pstore 留日志 | A | P0 | |
| FLT-03 | WiFi 固件异常 | 触发驱动的异常恢复（DFR）后自动恢复 | A | P1 | |
| FLT-04 | 缺固件 | 分别移走 WiFi/BT、rtl8168 固件，系统照常启动，设备报错清楚 | A | P1 | |
| FLT-05 | EC 通信错误 | 驱动层注入错误：电池显示未知，不挂死，恢复后正常 | A | P2 | |
| FLT-06 | UFS 错误 | host reset、错误注入后恢复，不丢数据 | A | P1 | ufs |
| FLT-07 | 磁盘满 | 填满根分区或 inode 后能登录、能清理 | A | P2 | |
| FLT-08 | 温度注入 | 见 THM-02/03 | A | P0 | quick |
| FLT-09 | 突然断电 | 见 UFS-08 | L | P0 | |
| FLT-10 | 网络异常 | DHCP 失败、DNS 失败、AP 消失时 NetworkManager 行为正常，恢复后自动连 | S | P2 | |
| FLT-11 | GPU 挂死 | 见 GPU-05 | A | P1 | |

### 安全（SEC）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| SEC-01 | CPU 漏洞缓解 | 0xd40 核不是 Unknown/Vulnerable，或有书面评估 | A | P1 | quick |
| SEC-02 | 内核加固 | KASLR（两次启动地址不同）、STACKPROTECTOR、FORTIFY、hardened usercopy、STRICT_KERNEL_RWX、STRICT_DEVMEM、kptr_restrict、dmesg_restrict 都生效；用户态经 /dev/mem 访问 MMIO 被拒 | A | P0 | quick、desktop-cfg |
| SEC-03 | debugfs | 生产环境不挂载或只有 root 能访问；改硬件的写接口（`kirin-ipc/xfer`、`hi6405/registers` 等）移除或受控 | A | P0 | quick |
| SEC-04 | 模块签名 | 全部模块已签名；是否强制有评估 | A | P1 | |
| SEC-05 | Secure Boot | 有 shim/GRUB/内核签名方案并验证（依赖 EFI 运行时服务） | A | P1 | |
| SEC-06 | 用户态安全 | AppArmor、systemd 默认加固、user namespace 策略启用且应用正常 | A | P1 | desktop-cfg |
| SEC-07 | 固件分区 | 同 UFS-02 | A | P0 | quick、ufs |
| SEC-08 | WiFi 攻击面 | 实验室注入畸形管理帧和信标不 oops；厂商代码的拷贝路径做一次安全审查 | L | P1 | |
| SEC-10 | CVE 跟踪 | 有 6.18.y 安全修复的同步流程；说明厂商驱动不在上游 CVE 覆盖范围内 | M | P1 | |
| SEC-11 | USB 存储管控 | 需要时能用 usbguard 或 udev 规则按策略禁用 U 盘 | S | P2 | |
| SEC-12 | 没有 TPM 和指纹的影响 | 对全盘加密、登录方式的影响有书面说明 | M | P1 | |
| SEC-13 | 自动登录与远程登录 | sddm 自动登录、sshd 密码登录和 root 登录出厂默认关闭 | A | P0 | quick（`--profile prod`） |

### 可维护与诊断（SVC）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| SVC-01 | 一键诊断包 | 版本、cmdline、内核日志、journal、pstore、EC 统计、电池健康、UFS 健康、温度、频率、WiFi/BT、PCI/USB 拓扑在 1 min 内打包完成，不含密码 | A | P0 | `tools/l410-diag` |
| SVC-02 | 崩溃采集 | pstore 在 Debian 下可用（kdump 可选），panic 后能取回日志 | A | P0 | quick |
| SVC-03 | 日志量 | 开机日志行数低于阈值；journald 有上限 | A | P1 | |
| SVC-04 | 资产信息 | `/sys/class/dmi/id/*` 里的型号、序列号、BIOS 版本可读 | A | P0 | quick |
| SVC-05 | 固件版本 | UEFI、EC、UFS、WiFi/BT、功放、触控板/键盘的固件版本可读并记录 | A | P1 | |
| SVC-07 | 调试手段保留 | 调试内核里各驱动的 debugfs 与 trace 事件可用 | A | P2 | |
| SVC-08 | 上次重启原因 | 正常重启、panic、看门狗、长按关机、低电量后开机能区分（PMIC 重启原因或 pstore） | A | P1 | quick（记录） |

### 升级与回退（UPD）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| UPD-01 | 内核小版本升级 | 6.18.54 升到新的 6.18.y：重打补丁、全量回归通过后才发布，升级成功 | A | P0 | |
| UPD-02 | 自动回退 | 新内核起不来时自动回到上一个可用内核（单次启动 + 启动成功确认），不需要人工 | A | P0 | |
| UPD-03 | 用户态升级回归 | Mesa、KWin/Plasma、PipeWire/WirePlumber、NetworkManager、wpa_supplicant、BlueZ、linux-firmware、systemd 升级后回归通过（NetworkManager 升级就曾触发 dump_station 死循环） | A | P0 | quick |
| UPD-04 | Debian 点版本 | 点版本升级后回归通过 | A | P1 | |
| UPD-05 | 固件升级路径 | 在麒麟下用厂商工具升级 UEFI/EC 后回 Debian 仍正常；Debian 下能否升级有结论 | S | P1 | |
| UPD-06 | 配置保留 | 内核升级前后用户数据、WiFi 配置、蓝牙配对保留 | A | P1 | |
| UPD-07 | LTS 生命周期 | 评估 6.18 LTS 的维护期和下一次前移的成本 | M | P2 | |

### 生产线单机测试（MFG）

| ID | 项目 | 通过条件 | 类 | 级 |
|---|---|---|---|---|
| MFG-01 | 出厂测试程序 | 专用启动项或专用用户进入，按清单逐项执行，生成以序列号为键的测试记录 | S | P0 |
| MFG-02 | 标识核对 | 序列号、WiFi MAC、BT 地址、有线 MAC 可读、格式正确、同批不重复 | A | P0 |
| MFG-03 | 快速功能 | 测试图、背光全档、全键、触控板、左右喇叭、麦克风、耳机口（回环线）、摄像头、每个 USB 口、网口、WiFi 信号（金样 AP 固定距离）、BT 扫到金样设备、充电电流、合盖、指示灯全过 | S | P0 |
| MFG-04 | 老化 | 同 REL-03 | A | P0 |
| MFG-05 | 出厂清理 | 删除测试记录与用户、恢复 OOBE；充到出货电量 | S | P0 |
| MFG-06 | 金样机 | 每条线一台金样机定期跑全套，确认测试环境本身正常 | L | P1 |
| MFG-07 | 节拍 | 单机测试时长满足产线要求 | M | P2 |

### 环境与法规（ENV，实验室）

| ID | 项目 | 通过条件 | 类 | 级 |
|---|---|---|---|---|
| ENV-01 | 高低温运行 | 规格上下限温度下 A 类用例全过 | L | P1 |
| ENV-02 | 高低温存储 | 存储后开机全功能正常 | L | P1 |
| ENV-03 | 湿热 | 按规格，之后全功能正常 | L | P2 |
| ENV-04 | 振动与跌落 | 之后开机全功能正常 | L | P1 |
| ENV-05 | ESD | 各接口按规格放电后不死机，或能自己恢复（USB、音频口的软件恢复路径） | L | P1 |
| ENV-06 | EMC/射频复核 | WLAN/BT 发射功率与杂散、背光 2 kHz PWM 对音频和 EMC 的影响与原认证状态一致（原认证基于 4.19 软件，驱动变了要复核） | L | P0 |

### 报废与数据清除（EOL）

| ID | 项目 | 通过条件 | 类 | 级 |
|---|---|---|---|---|
| EOL-01 | 数据清除 | 只对用户数据所在的 LUN 做 purge/secure erase（或全盘覆写），抽样读回不可恢复；绝不作用于 sda 到 sdc | A | P0 |
| EOL-02 | 恢复出厂 | 清除后重装出厂镜像成功 | S | P1 |
| EOL-03 | 注销记录 | 诊断包记录最终电池健康和 UFS 寿命 | A | P2 |

### 与麒麟共存（COEX）

| ID | 项目 | 通过条件 | 类 | 级 | 脚本 |
|---|---|---|---|---|---|
| COEX-01 | 互相切换 | 麒麟与 Debian 互相切换后各自功能不受影响（时间、WiFi 配置、分区） | S | P0 | |
| COEX-02 | 不写别人的分区 | 同 UFS-12 | A | P0 | quick |
| COEX-03 | GRUB 默认项 | Debian 上 update-grub、os-prober 不改麒麟的 GRUB 默认项 | A | P0 | |

## 缺陷分级与放行

| 级别 | 定义 | 例子 |
|---|---|---|
| 阻断 | 丢数据、损坏其他系统或固件、不能开关机、核心功能不可用、安全要求不满足 | 关机不下电；挂起醒不来；写了固件 LUN |
| 严重 | 功能可用但不可靠，或有明确的用户可见故障 | WiFi 每天掉线；耳机插拔不切换 |
| 一般 | 有规避办法，影响体验 | 首次连接慢 1 s；缩放要手动调 |
| 轻微 | 日志、文案、外观 | 无害的驱动报错日志 |

放行条件：

- P0 用例全过。
- P1 通过率 ≥ 95%，每个失败项有规避办法和书面豁免。
- 没有未关闭的阻断缺陷；严重缺陷全部关闭或有书面豁免。
- 放行门限全部达到；≥ 3 台样机结果一致。
- 交付的系统通过 INS-07/08 的卫生检查（`quick.sh --profile prod`）。

每个层级出一份报告：版本、样机、通过率、失败项、与基线的对比、已知问题与豁免。每台出厂机器一份以序列号为键的记录。

## 不支持的功能

交付前要逐项确认并写给用户：指纹（传感器在 TEE 后面，6.18 没有对应的驱动）；TPM（固件设备树里是 disabled）；NPU；ISP；
硬件视频编解码；DP/HDMI 外接显示和 DP 音频；USB OTG/gadget、BC1.2、Type-C PD 角色切换；KVM（固件只给 EL1）；
UFS inline 加密、RPMB、HPB；hi110x 模块不能卸载；休眠到磁盘、WiFi 热点/P2P、Vulkan（如果测下来不可用）。

## 还没有脚本的用例

| 计划的脚本 | 用例 | 内容 |
|---|---|---|
| 通用库与日志白名单 | 全部 | 结果行、环境记录、日志门禁、半自动项的事件判定 |
| 关机与挂起循环 | BOOT-02/04、PM-03 | `tests/cycle.sh` 目前只做热重启；关机要配 RTC 闹钟开机（BOOT-05） |
| 睡眠全流程 | PM-01/04/06/09 | `tests/suspend.sh` 只做单次；还缺能力检查、唤醒源矩阵、运行时 PM 总表 |
| 电池 | BAT-02 到 BAT-06、PM-05 | 充放电记录、AC 事件、低电量链路 |
| 有线网 | ETH-02 到 ETH-04、ETH-08 | 链路、iperf3、中断计数 |
| WiFi 矩阵 | WLAN-02 到 WLAN-08 | 按配置文件跑连接矩阵、吞吐、重连 |
| 蓝牙配置 | BT-02/03/05/07 | 配对、A2DP/HFP、共存 |
| 性能基线 | PERF-01 到 PERF-03、PERF-07 | 4.19 与 6.18 两边跑同一个脚本 |
| 续航 | PERF-09 | 视频/网页循环到关机，记录曲线 |
| 交互测试 | INP-02/03/06、AUD-02/07、DSP-07、USB-02 | 全键、触控板、测试图、左右声道、耳机回环、端口遍历，按事件判定 |
| 出厂测试程序 | MFG-01 到 MFG-05 | 调用上面的交互测试，按序列号生成记录 |
