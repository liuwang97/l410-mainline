# 内核配置

L410 的内核配置是 arm64 defconfig 加上内核树（[linux-l410](https://github.com/liuwang97/linux-l410) 分支 `l410-6.18`）里
`l410/configs/*.config` 这些片段。`l410/build.sh` 每次编译都重新生成配置：先 `make defconfig`，再用 `scripts/kconfig/merge_config.sh -m`
按文件名顺序合并全部片段（后面的片段覆盖前面的），最后 `make olddefconfig` 补齐依赖。

- 合并日志在构建目录的 `merge.log`。片段里某一项没能生效时，日志里会有 “Value requested for CONFIG_… not in final .config”。
- `l410/build.sh -f 片段文件` 在最后再合并一个自己的片段，不用改树里的文件。
- 最终的 `.config` 在 bundle 里（文件名 `config`）；机器上用 `zcat /proc/config.gz` 查看。

| 片段 | 内容 |
|---|---|
| `00-base` | 版本后缀、启动方式、控制台、pstore、Debian 用户态的基本需求 |
| `01-noarch` | 只保留 HiSilicon 平台 |
| `09-laptop` 到 `80-audio` | 各个硬件的驱动 |
| `90-perf` | uclamp、能耗模型、温控、性能档位、观测 |
| `95-sched-ext` | BPF 调度器（sched_ext） |
| `96-desktop` | 移动存储、网络共享、USB 和蓝牙外设、4G 上网卡、网络排队、卡死检测、udmabuf |
| `97-security-net` | 加固、LSM、nftables、VPN、dm-crypt |
| `98-memory` | zswap、MGLRU、THP |

## 基础：00-base、01-noarch

- 版本：`CONFIG_LOCALVERSION="-l410"`，不自动加 git 后缀，内核版本是 `6.18.54-l410`（`build.sh -n NAME` 再加后缀）。`ARCH_HISI`。
- 启动：未压缩的 `Image` 加 EFI stub，不用 `EFI_ZBOOT`，因为 GRUB 2.04 要认 arm64 Image 头。gzip 的 initrd、devtmpfs 自动挂载、`IKCONFIG_PROC`。
- 控制台：simpledrm 接 UEFI 留下的 GOP 帧缓冲（`SYSFB_SIMPLEFB`、`DRM_SIMPLEDRM`、fbdev 仿真、fbcon）。
- 崩溃日志：pstore/ramoops，和厂商内核共用 0x26e00000 起 1 MiB 的区域，带控制台、pmsg 和压缩；崩溃后从 `/sys/fs/pstore` 取。另开 `DEBUG_FS`。
- `CONFIG_L410_DEADMAN=y`：移植期间的兜底看门狗，开机就启动 SP805（WDT0）且不喂狗。`build.sh` 生成的启动参数带 `l410_deadman=0`，正常使用时它不起作用，
  见 [dev/README.md](../dev/README.md)。通用的 `ARM_SP805_WATCHDOG` 驱动不开，WDT0 由这个驱动直接操作。
- 先关掉、等 SoC 支持做好才开的：`ARM_PSCI_CPUIDLE`、`CPU_FREQ`（这两项在 `20-power` 里重新打开）、`CORESIGHT`、`I3C`、`POWER_RESET_HISI`、`ARM_SMMU_V3`。
  它们开着会去绑定厂商设备树里的节点。
- Debian 用户态需要的：ext4（ACL、安全标签）、autofs、cgroups 和 memcg、BPF 系统调用和 cgroup BPF、fanotify、seccomp。`ZRAM` 编成模块，默认不用（见 [tuning/memory.md](tuning/memory.md)）。
- RTL8153 USB 网卡驱动（`USB_RTL8152`）编进内核，开发时用它连 ssh。
- `01-noarch` 把 defconfig 里其他厂商的 `ARCH_*` 全部关掉，只留 HiSilicon，少编很多用不上的驱动。

## 硬件驱动：09 到 80

| 片段 | 主要选项 | 内容 |
|---|---|---|
| `09-laptop` | `MFD_HUAWEI_ECHUB`、`BATTERY_HUAWEI_ECHUB`、`LEDS_HUAWEI_ECHUB`、`I2C_HID_OF`、`HID_MULTITOUCH`、`KEYBOARD_GPIO` | EC（电池、指示灯）、I2C-HID 键盘和触控板、合盖开关。见 [hardware/laptop.md](hardware/laptop.md) |
| `10-soc-core` | `COMMON_CLK_KIRIN990`、`KIRIN_IPC_MBOX`、`HWSPINLOCK_KIRIN`、`PINCTRL_SINGLE`、`GPIO_PL061`、`I2C_DESIGNWARE_PLATFORM`、`SPI_PL022`、`SERIAL_AMBA_PL011`、`HISI_DMA64` | 时钟、IPC 邮箱、硬件自旋锁、引脚和 GPIO、I2C、SPI、串口、DMA。`DMATEST=y` 是 DMA 自检钩子，不写 `/sys/module/dmatest/parameters/run` 就什么都不做；`tests/quick.sh` 的 `cfg.debug-off` 会把它标成留在内核里的测试代码。见 [hardware/soc-core.md](hardware/soc-core.md) |
| `20-power` | `SPMI_HISI3670`、`MFD_HISI_SPMI_PMIC`、`REGULATOR_HISI_SPMI`、`REGULATOR_HISI_IP`、`RTC_DRV_HISI_SPMI`、`INPUT_HISI_POWERKEY`、`HISI_TSENS_SMC`、`KIRIN_HW_VOTE`、`KIRIN_PERI_DVFS`、`ARM_HISI_HWVOTE_CPUFREQ`、`ARM_PSCI_CPUIDLE` | PMIC、稳压器、IP 电源域、RTC、电源键、温度传感器。CPU 调频是 LPM3 的 DVFS，经 PMCTRL 硬件投票，不用 cpufreq-dt（`CPUFREQ_DT`、`ARM_SCMI_CPUFREQ` 关掉），默认调速器 schedutil。cpuidle 用固件设备树里的 PSCI 空闲状态。见 [hardware/power.md](hardware/power.md) |
| `30-ufs` | `SCSI_UFS_KIRIN` | UFS 主机控制器，根文件系统在 LUN3（`sdd`）上。`SCSI_UFS_CRYPTO` 不开：厂商的内联加密要安全世界写入密钥，不支持。见 [hardware/ufs.md](hardware/ufs.md) |
| `40-usb` | `USB_DWC3_KIRIN990`、`PHY_KIRIN990_USB3`、`USB_ONBOARD_DEV`、`EXTRA_FIRMWARE` | DWC3 主机、USB 3.1/DP 组合 PHY、RTS5411 hub 供电。PHY 的 SRAM 固件 `hisilicon/kirin990-usb31phy.bin` 从内核树的 `l410/firmware/` 编进内核。见 [hardware/usb.md](hardware/usb.md) |
| `50-pcie` | `PCIE_KPORT`、`PCIEASPM`、`R8169` | kport PCIe 根复合体、板载 RTL8168。见 [hardware/pcie.md](hardware/pcie.md) |
| `60-graphics` | `DRM_KIRIN990`、`DRM_PANFROST`、`PWM_HISI_BLPWM`、`BACKLIGHT_PWM` | 显示（DSS）、Mali-G76、背光。见 [hardware/graphics.md](hardware/graphics.md) |
| `70-wifi-bt` | `STAGING`、`HI110X=m`、`CFG80211=m`、`BT=m`、`RFKILL=m` | Hi110x 的 WiFi（PCIe RC1）和蓝牙（BUART，uart4）。见 [hardware/wifi-bt.md](hardware/wifi-bt.md) |
| `80-audio` | `SND_SOC_HI6405_L410`、`SND_SOC_TAS2562` | Hi6405 编解码器（SSI + SLIMbus）、ASP DMA、TAS2562 智能功放。见 [hardware/audio.md](hardware/audio.md) |

## 性能与功耗：90-perf

| 选项 | 作用 |
|---|---|
| `UCLAMP_TASK`、`UCLAMP_TASK_GROUP`、`UCLAMP_BUCKETS_COUNT=5` | uclamp：KWin 的实时线程上大核，前台应用的 cgroup 下限（[system/perf](../system/perf) 的 `l410-perfd`） |
| `ENERGY_MODEL` | 能耗模型（CPU 来自厂商能耗表，GPU 来自它的 OPP），开启 EAS |
| `THERMAL_GOV_POWER_ALLOCATOR` | IPA 温控（power_allocator）。加载 sched_ext 时需要的修复见 [tuning/sched-ext.md](tuning/sched-ext.md#温控) |
| `L410_PERF` | `/sys/kernel/l410_perf`：省电、平衡、性能三档和交互 boost |
| `DEVFREQ_GOV_PERFORMANCE`、`DEVFREQ_GOV_POWERSAVE`、`DEVFREQ_GOV_USERSPACE`、`ARM_KIRIN990_DDR_DEVFREQ` | devfreq 调速器；DDR 调频经 PMCTRL 投票，开机从最高档开始 |
| `FTRACE`、`ENABLE_DEFAULT_TRACERS`、`PSI`、`SCHEDSTATS` | 观测：sched、irq、dma_fence、drm 的 tracepoint，PSI，调度统计 |
| `INPUT_UINPUT` | 测试时注入输入（`tests/perf.sh` 的输入 boost 检查） |
| `PM_DEBUG`、`PM_ADVANCED_DEBUG`、`PM_SLEEP_DEBUG` | 系统睡眠调试：`/sys/power/pm_test`、`pm_debug_messages`、`pm_print_times` |
| `KIRIN990_SUSPEND` | deep 睡眠走厂商 LPM3 握手。deep 唤醒后还会冷启动，所以默认是 s2idle，`kirin990_sr.deep=1` 才默认 deep |

为了性能，`FUNCTION_TRACER` 和 `STACK_TRACER` 不开，只有 tracepoint。结果是 BPF 程序挂不了 fentry/fexit，这对 sched_ext 的影响见下一节。

## sched_ext：95-sched-ext

`SCHED_CLASS_EXT`，以及它需要的 `DEBUG_INFO_BTF`（为此关掉 defconfig 的 `DEBUG_INFO_REDUCED`）、`BPF_JIT_ALWAYS_ON`、`FTRACE_SYSCALLS`、
`MODULE_ALLOW_BTF_MISMATCH`。每项的原因、BTF 带来的体积（`Image` +1.39 MB）和用户态的配置见 [tuning/sched-ext.md](tuning/sched-ext.md#内核要求)。

## 桌面外设：96-desktop

前面的片段只管让板载硬件工作。Debian 桌面常用、但和板载硬件无关的功能 arm64 defconfig 里没开，这个片段补上。这些项的依赖都已满足，只是没打开，
不涉及代码改动。除少数布尔项外都编成模块，由 udev、mount、bluetoothd 按需加载，启动时间不变。合并时另外自动带出 16 个依赖
（`CDROM`、`SMBFS`、`SLHC`、`SND_HWDEP`、`SND_RAWMIDI`、`SND_SEQ_*`、`LOCKUP_DETECTOR`、`HARDLOCKUP_DETECTOR_BUDDY` 等）。

### 移动存储和中文文件名

| 选项 | 作用 |
|---|---|
| `EXFAT_FS=m` | exFAT：64 GB 以上的 U 盘、SDXC 卡的默认格式 |
| `NTFS3_FS=m`、`NTFS3_LZX_XPRESS=y`、`NTFS3_FS_POSIX_ACL=y` | NTFS 读写（内核驱动，比 ntfs-3g 快），能读 Windows 压缩过的文件，支持 ACL |
| `ISO9660_FS=m`、`JOLIET=y`、`ZISOFS=y` | 光盘和 ISO 镜像；Joliet 是 Windows 刻的盘上的长文件名和中文文件名；压缩镜像 |
| `UDF_FS=m` | DVD、蓝光、部分刻录盘 |
| `BLK_DEV_SR=m` | USB 光驱（自动选上 `CDROM`），没有它插上连设备都不出现 |
| `CHR_DEV_SG=m` | SCSI 通用接口，刻录软件和部分 USB 存储类外设要用 |
| `NLS_UTF8=m` | `iocharset=utf8`：光盘、网络共享上的中文文件名 |
| `NLS_CODEPAGE_936=m` | GBK：Windows 中文系统在 FAT 盘上写的 8.3 短文件名 |
| `NLS_CODEPAGE_950=m` | Big5（繁体），同上 |
| `NLS_ASCII=m` | 个别文件系统的默认字符集 |

defconfig 里已经有 `VFAT_FS`、`NLS_CODEPAGE_437`、`NLS_ISO8859_1`、`FUSE_FS`（ntfs-3g、exfat-fuse 这类用户态驱动能用）、`BTRFS_FS`、`NFS_FS`。
`FAT_DEFAULT_IOCHARSET` 保持 `iso8859-1`：桌面自动挂载（udisks）挂 FAT 盘时带 `utf8=1`，不依赖这个默认值。

### 网络共享

`CIFS=m`：访问 Windows 和 NAS 的共享文件夹（SMB2/3），需要的算法库会自动选上。

### USB 外设

| 选项 | 作用 |
|---|---|
| `SND_USB_AUDIO=m` | USB 耳机、USB 声卡、会议麦克风和扬声器 |
| `USB_UAS=m` | USB3 移动硬盘和高速 U 盘的 UAS 协议；没有它退回老协议，速度明显下降 |
| `USB_PRINTER=m` | USB 打印机的 `usblp`（CUPS 的一部分驱动需要） |
| `USB_SERIAL_CH341=m`、`USB_SERIAL_PL2303=m` | CH340/CH341、PL2303 串口线 |
| `USB_SERIAL_GENERIC=y`、`USB_SERIAL_SIMPLE=m` | 通用 USB 串口，以及一批简单的 USB 串口设备 |
| `USB_NET_RNDIS_HOST=m` | 安卓手机的“USB 网络共享” |

defconfig 里已经有 `USB_STORAGE`、`USB_ACM`、`USB_SERIAL_CP210X`、`USB_SERIAL_FTDI_SIO`、`USB_SERIAL_OPTION`、`USB_VIDEO_CLASS`、
`USB_NET_CDCETHER`、`USB_NET_CDC_NCM`、`USB_NET_AX88179_178A`、`USB_RTL8152`、`BT_HCIBTUSB`（USB 蓝牙适配器）。

### 蓝牙

| 选项 | 作用 |
|---|---|
| `BT_RFCOMM=m`、`BT_RFCOMM_TTY=y` | 蓝牙耳机通话：HFP/HSP 的控制通道走 RFCOMM，没有它只能用 A2DP 听音乐，耳机麦克风用不了；`/dev/rfcomm*` 串口节点 |
| `BT_BNEP=m`、`BT_BNEP_MC_FILTER=y`、`BT_BNEP_PROTO_FILTER=y` | 蓝牙网络共享（PAN），BlueZ 默认用这两个过滤 |
| `UHID=m` | 低功耗蓝牙（BLE）键盘鼠标：BlueZ 通过 `/dev/uhid` 建 HID 设备，没有它能配对但没有任何输入。现在的蓝牙鼠标大多是 BLE |
| `HID_BATTERY_STRENGTH=y` | 桌面显示在 HID 报告里带电量的无线键鼠的电量 |

defconfig 里已经有 `BT_HIDP`（经典蓝牙键鼠）、`BT_LE`、`BT_LEDS`。

### HID 和输入

| 选项 | 作用 |
|---|---|
| `HIDRAW=y` | `/dev/hidraw*`：厂商工具直接访问 HID 设备（USB 外设的厂商驱动、无线键鼠配对工具、固件升级工具） |
| `USB_HIDDEV=y` | `/dev/usb/hiddev*`：UPS、部分行业用的 USB HID 设备 |
| `INPUT_JOYDEV=m`、`INPUT_JOYSTICK=y`、`JOYSTICK_XPAD=m` | 游戏手柄的 `/dev/input/js*`，Xbox 类手柄 |
| `HID_WACOM=m` | Wacom 数位板、签名板 |

### 4G 上网卡

| 选项 | 作用 |
|---|---|
| `USB_NET_HUAWEI_CDC_NCM=m` | 华为 4G 上网卡（NCM 模式） |
| `USB_NET_CDC_MBIM=m`、`USB_NET_QMI_WWAN=m`、`USB_WDM=m` | MBIM 模式、高通 QMI 模式的模块，以及它们的控制通道 |
| `USB_SERIAL_QUALCOMM=m` | 高通模块的 AT 和诊断串口 |
| `PPP=m`、`PPP_ASYNC=m`、`PPP_SYNC_TTY=m`、`PPP_DEFLATE=m`、`PPP_BSDCOMP=m` | 串口拨号的上网卡（ModemManager 用 pppd 拨号） |

defconfig 里已经有 `USB_SERIAL_OPTION`、`USB_SERIAL_WWAN`、`USB_NET_CDCETHER`。

### 网络排队

`NET_SCH_FQ_CODEL=m`：没有它网卡用简单的 FIFO，WiFi 上传大文件时延迟猛涨，网页和会议跟着卡。
开机把它设成默认的是 [system/hardware/90-l410-net.conf](../system/hardware/90-l410-net.conf)（`net.core.default_qdisc = fq_codel`），设了以后内核自动加载模块。
`NET_SCH_FQ=m`：fq，配合 BBR 一类的拥塞控制。

### 卡死检测

| 选项 | 作用 |
|---|---|
| `SOFTLOCKUP_DETECTOR=y` | 某个 CPU 在内核里长时间不让出（死循环）时打印栈 |
| `HARDLOCKUP_DETECTOR=y` | 某个 CPU 关着中断卡死时打印栈。arm64 上用 buddy 方式（各 CPU 互相检查），不需要 NMI |
| `DETECT_HUNG_TASK=y`、`DEFAULT_HUNG_TASK_TIMEOUT=120` | 进程在 D 状态卡住超过 120 s 时打印栈 |
| `WQ_WATCHDOG=y` | 工作队列卡住时报告 |

没有这些选项时，“系统没死，但某个设备或进程不动了”（WiFi 驱动卡在锁上、UFS 请求不回来）这类问题在内核日志里一行都没有，pstore 也拿不到线索。
这里只打开检测和报告，不开对应的 `BOOTPARAM_*_PANIC`，复位仍然交给看门狗。厂商移植代码（hi110x 等）里长时间的忙等会因此被报出来，那是要修的缺陷，不是误报。

开机后应该看到：`/proc/sys/kernel/soft_watchdog` 为 1，`nmi_watchdog` 为 1（buddy 硬锁检测也用这个开关），`watchdog_thresh` 为 10，
`hung_task_timeout_secs` 为 120，`/sys/module/workqueue/parameters/watchdog_thresh` 大于 0。

### 其他

- MIDI：`SND_SEQUENCER=m`，MIDI 键盘和音序器软件。
- `UDMABUF=y`：KWin 6.7 把 wl_shm 客户端缓冲区通过 `/dev/udmabuf` 导入，不再每帧上传（KWin MR !9178）。
- `# CONFIG_TRACEFS_AUTOMOUNT_DEPRECATED is not set`：不在 `/sys/kernel/debug/tracing` 自动挂载 tracefs。scx_lavd 里的 libbpf 先找这个路径，
  自动挂载每次开机都会打印一条弃用提示；关掉后 libbpf 用 systemd 挂好的 `/sys/kernel/tracing`。

这些功能对应的用户态工具 `system/install.sh` 不装，需要时自己装：`exfatprogs`、`ntfs-3g`（只为 `mkntfs` 这类工具）、`udftools`、`cifs-utils`、
`cups`、`ppp`、`usb-modeswitch`、`modemmanager`。

## 安全与网络：97-security-net

| 分组 | 选项 | 作用 |
|---|---|---|
| 加固 | `IO_STRICT_DEVMEM`、`FORTIFY_SOURCE`、`HARDENED_USERCOPY` | `/dev/mem` 访问不到驱动占用的 MMIO；字符串和内存函数带边界检查；`copy_{to,from}_user` 对照 slab 和栈对象检查 |
| LSM | `SECURITY_APPARMOR`、`SECURITY_YAMA`、`SECURITY_LANDLOCK`、`DEFAULT_SECURITY_APPARMOR`、`LSM="landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor,ipe,bpf"` | 和 Debian 的内核一样：AppArmor（Debian 的默认 profile）、Yama 的 ptrace 限制、Landlock。运行时 `/sys/kernel/security/lsm` 是 `capability,landlock,yama,apparmor` |
| nftables | `NF_TABLES`（inet、netdev、ipv4、ipv6）、`NFT_CT`、`NFT_NAT`、`NFT_MASQ`、`NFT_REDIR`、`NFT_REJECT`、`NFT_COMPAT`、`NFT_LOG`、`NFT_LIMIT`、`NFT_QUOTA`、`NFT_CONNLIMIT`、`NFT_FIB_*`、`NF_NAT`、`NETFILTER_XT_NAT`、`NETFILTER_XT_TARGET_MASQUERADE` | NetworkManager 的连接共享，经 iptables-nft 工作的 firewalld、ufw |
| VPN | `WIREGUARD`、`XFRM_USER`、`XFRM_INTERFACE`、`INET_ESP`、`INET6_ESP`、`L2TP`、`PPPOL2TP`、`PPPOE`、`PPP_MPPE` | WireGuard、IPsec（strongSwan、libreswan）、L2TP/PPP |
| 加密盘 | `DM_CRYPT`、`CRYPTO_XTS` | LUKS（加密的 USB 硬盘） |

AppArmor 的用户态（`apparmor` 包和服务）由 `system/install.sh` 的 desktop 阶段装上。

Spectre-v2 的 BHB 缓解：这颗 A76 的变体（0xd40）不在内核的 BHB 列表里，内核报告为部分缓解。

## 内存：98-memory

zswap 开机启用（zstd、shrinker）、`ZSMALLOC` 和 `CRYPTO_ZSTD` 编进内核、MGLRU 开机启用、透明大页默认只给 `madvise()`。
原因、运行时参数和测试数据见 [tuning/memory.md](tuning/memory.md)。

## 沿用 defconfig 的部分

片段没有改、直接用 arm64 defconfig 的：完全抢占（`PREEMPT=y`，RCU 也是可抢占的）、`HZ=250`、`NO_HZ_IDLE`、`SCHED_MC`、`SCHED_CLUSTER`。
`KVM=y` 也在，但用不了：固件只让内核从 EL1 启动，开机日志是 `HYP mode not available`。`KSM=y` 编进了内核，没有启用。

## 刻意没开的

| 选项 | 原因 |
|---|---|
| `FUNCTION_TRACER`、`STACK_TRACER` | 为了性能，只用 tracepoint。BPF 因此挂不了 fentry，scx 需要一个补丁（见 [tuning/sched-ext.md](tuning/sched-ext.md#scx-的补丁)） |
| `BOOTPARAM_SOFTLOCKUP_PANIC`、`BOOTPARAM_HARDLOCKUP_PANIC`、`BOOTPARAM_HUNG_TASK_PANIC` | 卡死检测只报告，不 panic |
| `SCSI_UFS_CRYPTO` | 厂商的 UFS 内联加密要安全世界写入密钥 |
| `CPUFREQ_DT`、`CPUFREQ_DT_PLATDEV`、`ARM_SCMI_CPUFREQ` | CPU 调频走 PMCTRL 硬件投票 |
| `CORESIGHT`、`I3C`、`POWER_RESET_HISI`、`ARM_SMMU_V3` | 没有对应的 SoC 支持，开着会绑定厂商设备树里的节点 |
| `EFI_ZBOOT` | GRUB 2.04 要认 arm64 Image 头 |
| `ARM_SP805_WATCHDOG` | WDT0 由 `L410_DEADMAN` 直接操作 |
| `TRACEFS_AUTOMOUNT_DEPRECATED` | 避免 libbpf 触发的开机弃用提示 |
| `TRANSPARENT_HUGEPAGE_ALWAYS` | 缺页时的同步规整会造成停顿，改为 madvise |
| `DAMON` | 内存回收用 MGLRU，不用 DAMON_RECLAIM |

## 验证

- `tests/quick.sh` 的配置审计按组检查 `/proc/config.gz`：`cfg.hardening`、`cfg.lsm`、`cfg.containers`、`cfg.netfilter`、`cfg.vpn`、`cfg.netfs`、`cfg.usbfs`、
  `cfg.usb`、`cfg.bluetooth`、`cfg.hid`、`cfg.wwan`、`cfg.qdisc`、`cfg.storage`、`cfg.system`。当前内核全部通过。
- `sudo bash tests/desktop-cfg.sh` 在机器上实际用这些功能，约 2 分钟，不需要插任何设备，只写 `/var/tmp/l410-cfg/`，结束时清理。
  缺的工具（exfatprogs、ntfs-3g、dosfstools、udftools、xorriso、samba、cifs-utils、nftables、cryptsetup-bin）会用 apt 装上，`--no-apt` 跳过。检查内容：
  - 新模块逐个 `modprobe` 再卸载；`/proc/filesystems` 里有 exfat、ntfs3、iso9660、udf、cifs。
  - 在回环文件上做 exFAT、NTFS3、FAT（`codepage=936,iocharset=utf8`）、ISO（Joliet）、UDF 的读写往返，带中文文件名，校验内容。
  - 本机临时开一个 samba 共享，用 SMB 3.1.1 挂载 CIFS，往返中文文件名和 64 MiB 文件，结束后恢复 samba 原来的状态。
  - 用 `modprobe -R` 确认各类 USB 设备（CH340、PL2303、USB 音频、打印机、UAS、RNDIS、MBIM、华为 NCM）的别名都能解析到模块，插上时 udev 会自动加载。
  - `sr_mod`、`sg` 加载后为现有 SCSI 设备生成 `/dev/sg*`；能建 RFCOMM 和 BNEP 套接字；bluetoothd 初始化没有 RFCOMM/BNEP 错误；`/dev/uhid`、`/dev/hidraw*` 存在。
  - 默认 qdisc 和 wlan0 上的 qdisc 是 fq_codel；卡死检测的各个开关取值正确，内核日志里没有 soft lockup、hard LOCKUP、hung task、workqueue lockup。
  - 97-security-net：nftables、WireGuard、AppArmor、Yama、LUKS。
- 体积：`96`、`97`、`98` 三个片段让模块从 803 个变成 891 个，`modules.tar.gz` 从 18.4 MB 变成 20.4 MB。`Image` 从 38.16 MB 变成 39.55 MB，主要是 sched_ext 要的 BTF。

要去掉某一项，删掉片段里对应的行重新编译即可，96-desktop 里的各项互不依赖。
