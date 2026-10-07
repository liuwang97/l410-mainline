# WiFi 与蓝牙

L410 的 WiFi 和蓝牙在同一颗海思 Hi110x 连接芯片上。芯片自报 Hi1103（PCI ID 19e5:1103，设备树 `subchip_type = "hi1103"`，固件目录 `hi1103/pilot`）；厂商源码目录叫 hi1105，同一套 host 驱动支持 1103/1105/1106，所以别的地方也会写成 "Hi1105"。WiFi 走 PCIe RC1，蓝牙（厂商叫 BFGX，含 BT/FM/GNSS）走一条串口 BUART。

6.18 上用的是厂商驱动的移植版，在内核仓库的 `drivers/staging/hi110x/`。厂商代码约 32 万行，做的是移植而不是重写，所以放进 staging。目前 WPA2 和 WPA3（SAE）都能连，NetworkManager / Plasma 建的 WPA3 配置约 5 s 连上；蓝牙在 BlueZ 下能上电、扫描；s2idle 睡眠唤醒后 WiFi 和 hci0 都会恢复。

## 硬件

| 项 | 实况 |
|---|---|
| WiFi | PCIe RC1（`pcie_kport_rc@0xf4000000`，rc-id 1，PCI 域 0001），链路 Gen2 x1，BAR0 8 MiB |
| 蓝牙（BFGX） | BUART = uart4 `uart@fa041000`（厂商系统里是 `/dev/ttyAMA4`），4 Mbit/s + RTS/CTS，唤醒字节用 115200；时钟链 uart4 ← sc_div_320m ← PPLL0 |
| GPIO | power_on_enable gpio@fa8b6000 pin1；wlan_power_on gpio@fa8ad000 pin3；bfgx_power_on gpio@fa8ad000 pin4；host_wakeup_wlan gpio@fa8ad000 pin2；wlan_wakeup_host gpio@fa8b4000 pin5；bfgx_wakeup_host gpio@fa8b6000 pin0；SSI 调试 clk gpio@fa8b3000 pin7、data gpio@fa8b4000 pin0；PERST# gpio@fa8b4000 pin3（归 PCIe RC 驱动） |
| 32 kHz 时钟 | PMIC 的 `clk_pmu32kb`（`hisilicon,clk-pmu-gate`，PMIC 寄存器 0x46 bit0） |
| EEPROM | I2C4 地址 0x54，16 位地址，只读：WLAN 校准 0-2047、BT 校准 2048 起、FAC 4096、MACWLAN 4224、MACBT 4352 |
| buck | 厂商的 `buck_power_ctrl` 只在手机配置 `_PRE_SHARE_BUCK_SURPORT` 下有效，L410（ARMPC）上是空操作，host 侧不用管 |

WiFi 的永久 MAC 和蓝牙地址都从 EEPROM 读（华为 OUI 24:81:c7）。扫描时 `wlan0` 的当前地址每次都不一样，那是 NetworkManager 的扫描 MAC 随机化，`ethtool -P wlan0` 看到的永久地址是对的。

## 固件

驱动不走 `request_firmware()`，而是按厂商的绝对路径直接读文件：

- `/vendor/firmware/hi1103/pilot/`：`bfgx_and_wifi_cfg`、`bfgx_cfg`、`wifi_cfg` 和它们引用的 `*.bin`（厂商版本 2021-05-28）
- `/vendor/etc/cfg_udp_1103_pilot.ini`：板级配置

这些文件是厂商的，不能随本仓库分发。`rootfs/deploy.sh` 按 [rootfs/firmware.list](../../rootfs/firmware.list)
从同一台机器出厂的 Kylin 里原样拷到 Debian 根分区的同一路径。手工补拷时（Kylin 下，Debian 分区挂在 `/mnt/debian`）：

```sh
sudo mkdir -p /mnt/debian/vendor/firmware/hi1103 /mnt/debian/vendor/etc
sudo cp -a /vendor/firmware/hi1103/pilot /mnt/debian/vendor/firmware/hi1103/
sudo cp -a /vendor/etc/cfg_udp_1103_pilot.ini /mnt/debian/vendor/etc/
```

模块加载后（`autoboot=1`，默认）等 `/vendor/firmware/hi1103/pilot/wifi_cfg` 出现，最多等 `fw_wait` 秒（默认 120），然后依次做平台初始化（板级 GPIO、PCIe 枚举、下载固件、BFGX 上电自检）、WiFi 初始化（hmac/wal、cfg80211、`wlan0`/`p2p0`），最后注册 hci0。厂商系统里是 `110x.service` 调 `/vendor/1103start.sh` 往 `/sys/hisys/boot/{plat,wifi}` 写 `init`，再用 `hciattach -n /dev/hwbt hisi` 注册 hci0；6.18 的驱动保留了 `/sys/hisys/boot/{plat,wifi}` 接口，但这些用户态步骤都不需要了。

驱动找不到 `readme.txt`、`ram_reg_test_cfg` 之类的可选文件时只打 info 级日志，正常开机没有错误级日志。

## 监管域（CN）

`system/hardware/install.sh` 做了这几步：

```sh
update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream
echo "options cfg80211 ieee80211_regdom=CN" > /etc/modprobe.d/l410-cfg80211.conf
iw reg set CN
```

第一步是必须的：内核里只内置了上游的 regulatory 签名密钥，Debian 自己签名的 `regulatory.db` 会被 cfg80211 拒掉，监管域就一直停在世界域 00，信道少、发射功率也低。检查：`iw reg get` 的 global 段应是 `country CN`。

## 驱动结构

- 厂商的 plat.ko 和 wifi.ko 合成一个模块 `hi110x.ko`（厂商自带的 "all in one" 开关 `_PRE_WLAN_AIO`），入口是 `hi110x_main.c`。模块不支持卸载（厂商的 autoboot 流程没有对应的退出路径）。
- 构建输入：`l410/configs/70-wifi-bt.config`（CFG80211、BT、HI110X 都是 =m），`l410/dt/fixups.d/70-wifi-bt.dtsi`。
- 特性宏必须和厂商构建一致：hmac/wal 与芯片固件交换的结构体、cfgid 编号都受 `_PRE_*` 宏影响。`hi110x-features.mk` 是把厂商 `hi1105_comm_defconfig` 加 `plat_1105_default_defconfig` / `wifi_1105_default_defconfig` 按 L410 的配置（ARMPC、`CONFIG_ARCH_KIRIN_PCIE=y`、`CONFIG_ARCH_HISI=y`、`CONFIG_HISI_IDLE_SLEEP=y`）求值得到的。plat 和 wifi 两组宏不同，Makefile 按对象分别加。只关掉了两个纯 host 侧、依赖海思内核扩展的宏：`_PRE_FEATURE_PLAT_LOCK_CPUFREQ`、`_PRE_CONFIG_S3_HCI_DEV_OPT`。
- `hi110x_compat.h`（强制包含）：SecureC 子集（`memcpy_s` 等，改名成 `hi110x_*`，避免和别的厂商驱动撞符号）、`set_fs` 空实现（文件读写都已改成 `kernel_read`/`kernel_write`）、`struct timeval/timespec`、`del_timer`/`from_timer`、旧 PM QoS 类（CPU_DMA_LATENCY 映射到 cpu_latency_qos，其余空操作）、`ioremap_nocache` 等。
- PCIe：`hi110x_kport.h` 把厂商的 `kirin_pcie_*` 映射到 6.18 kport 驱动的 `pcie_kport_*`（`include/linux/platform_drivers/pcie-kport-api.h`），见 [pcie.md](pcie.md)。
- cfg80211：适配 MLO 以后的 ops 原型（link_id、`cfg80211_ap_update`、`set_wiphy_params` 的 radio_idx、`update_mgmt_frame_registrations`）、`cfg80211_roam_info.links[0]`、`cfg80211_ch_switch_notify(..., 0)`、`wdev->u.ap.preset_chandef`；写 `dev_addr` 改用 `eth_hw_addr_set()`。
- BUART 改成 serdev：厂商在内核里打开 `/dev/ttyAMA4` 挂自定义 line discipline，6.18 已不导出所需接口。DT fixup 在 `uart@fa041000` 下加子节点 `hisilicon,hi110x-bfgx-uart`，`plat_uart.c` 用 serdev 实现 `open_tty_drv`/`release_tty_drv`/`ps_change_uart_baud_rate`，`ps_core_s::tty` 变成打开期间的 serdev 指针。
- BlueZ：厂商经 `hciattach` 的 ioctl 注册 hci0，并在 `->open` 里手动置 `HCI_RUNNING` 发 HCI 命令。现在驱动在 autoboot 完成后自己 `hci_register_dev()`，BD 地址（EEPROM 的 MACBT）在 `->setup` 里用厂商命令 0xFC32 写入；接收线程先于注册启动。
- EEPROM：厂商 `drivers/hisi/hi1103_eeprom` 的 `drv_e2prom_read()` 在驱动内重写为 `hi110x_eeprom.c`（只读，`i2c_get_adapter(4)`）。
- 32 kHz 时钟：DT fixup 给 `hi110x` 节点加 `clocks = <&clk_pmu32kb>`；拿不到时钟时不报错继续（固件可能已经打开）。
- 手机专用部分：CHR 上报做成空函数（`hi110x_stubs.c`），cpufreq 锁频关掉，`kallsyms_lookup_name` 调试口返回 0。

## 移植中修掉的问题

### 开机后网络卡死：regulatory 更新自锁

校准完成时厂商代码调 `wiphy_apply_custom_regulatory()`，6.18 里它要拿 RTNL 和 wiphy 锁；而 NetworkManager 的 `ndo_open` 正持着 RTNL 等校准结束。改为放进有序工作队列异步执行；厂商的 wiphy 标志 0x200 换成 `NL80211_EXT_FEATURE_DFS_OFFLOAD`（`staging: hi110x: apply regulatory updates from a work item; drop vendor wiphy flag`）。

### 扫描时 RCU stall：P2P 设备重复注册

6.18 的 nl80211 会自己注册一次 P2P_DEVICE wdev，厂商代码又注册一次，重复注册导致 RCU stall、网络卡死。驱动不再提供独立的 P2P_DEVICE wdev（`staging: hi110x: do not offer a stand-alone P2P-device wdev`）。

### probe 死锁

端点 probe 运行在 `pcie_kport_enumerate()` 持锁期间，里面调 `pcie_kport_register_event()` 又要拿同一把锁，枚举到 19e5:1103 之后就停住，没有 wlan0 和 hci0。修在 PCIe 驱动里（`PCI: dwc: kport: let endpoint probe call back into the API; skip L2 wait`）。

### 蓝牙收不到数据：BUART 时钟

hci0 注册了，芯片也能用 GPIO 唤醒主机，但 BUART 一个字节都收不到，`bluetoothctl power on` 失败。原因是上游 pl011 不认海思 UART 节点的 `clock-rate` 属性，uart4 停在 clkmux_uarth 的 19.2 MHz 那一路，出不了 4 Mbit/s。DT fixup 用 `assigned-clocks` 改选 clkdiv_uarth，166 MHz（`l410: wifi-bt: clock the BUART from clkdiv_uarth (166 MHz)`）。改完后 `bluetoothctl power on` 成功，扫描到 11 个设备。

同一组改动里还有两处：打开 BUART 前按父节点的厂商属性给 CRG 复位打一个脉冲（厂商 pl011 做这一步，上游不做；`staging: hi110x: pulse the BUART's CRG reset before opening it`）；BUART 去掉 `dmas`，pl011 走 PIO（`l410: wifi-bt: run the BUART without DMA`）。别的 UART 要跑高波特率也会碰到 `clock-rate` 不生效的问题，办法一样。

### 开机校准和 NetworkManager 抢跑

现象：开机十几分钟后发现蓝牙没有控制器、`wlan0` 起不来。看日志，故障在开机 16 s 就发生了，和空闲无关。

开机校准（上电、校准、下电）通常约 2.4 s，那一次用了 9 s。NetworkManager 在 7.1 s 打开 `wlan0`，厂商的 open 只等 6 s，超时后照常往下走；15.7 s 校准结束时的下电把芯片从刚建好的 VAP 底下拿走，出现 `hmac_hcc_tx_netbuf` WARN 和 `SSI_ERR_HCC_EXCP_PCIE`。出错处理接着做 GPIO-SSI 寄存器 dump，dump 会把芯片常开域的时钟切到 SSI 时钟，正好赶上蓝牙启动：BT 起不来（`BFGX_OPEN_FAIL`，反复 `BFG_WAKE_UP_FAIL`），16.3 s RC1 completion timeout，之后每次上电读配置空间都是 0xffffffff，直到重启。

改法：

- open 等完整个校准流程，最长 60 s，还没完就返回 -EBUSY（`staging: hi110x: wait for the boot calibration before opening wlan0`）。
- 驱动的 `printk()`/`print_hex_dump()` 都经过 `hi110x_log.c` 的闸门，默认只放行 KERN_ERR 及更严重的；出错时不再做 SSI dump（`staging: hi110x: log errors only by default, no SSI register dumps`）。改之前一次开机的 1603 行 dmesg 里驱动占 1304 行。

验证：开机后空闲 11 分钟（芯片已进低功耗）再测，hci0 仍 UP RUNNING，`bluetoothctl power on` 成功、扫描到 26 个设备，`wlan0` up、扫描到 46 个 BSS。

### WPA3 连不上，界面报密码错误

plasma-nm 给 WPA3 网络写的配置带 `wifi-security.auth-alg=open`，NetworkManager 把 `auth_alg=OPEN` 交给 wpa_supplicant。这个驱动没有用户态 SME，supplicant 走 connect 路径，于是用 OPEN 覆盖了自己选的 SAE（日志里是 `Overriding auth_alg selection: 0x1`，然后 `Auth Type 0`、`akm=0xfac08`）。hmac 只看认证类型决定跑不跑 SAE（外部认证），结果是 Open 认证加 SAE AKM 去关联，没有 PMK，约 1 s 后 AP 以 reason 3 断开，NetworkManager 反复要密码。直接用 wpa_supplicant 配 SAE 是能连上的，所以问题只在这条组合上。

改法（`staging: hi110x: run SAE for Open System + SAE AKM, fix auth type 8`）：

- SAE / FT-SAE AKM 配 Open 或 Automatic、RSN 里没有 PMKID 时按 SAE 处理；带 PMKID 是 SAE PMKSA 缓存，保持 Open，由 hmac 自己处理。驱动日志里会有 `SAE AKM with auth_type[0], use SAE`。
- 厂商认证枚举的 8 是华为 TBPEKE，上游 8 是 `NL80211_AUTHTYPE_AUTOMATIC`，连接和开 AP 两条路径都做了转换。
- 外部认证事件结构体先清零（6.18 多了 `mld_addr`/`pmkid` 字段，原来是栈上垃圾）。

### NetworkManager 连上后卡死

连上之后 NetworkManager 占满一个 CPU，D-Bus 不应答，`nmcli` 报 "NetworkManager 未运行"，`iw station dump` 也卡住。厂商的 `dump_station` 是永远返回成功的空桩，cfg80211 要等到 -ENOENT 才结束 dump；NetworkManager 1.52 连上后会 dump station 取信号和速率，于是无限循环（strace 看到无尽的 `NL80211_CMD_NEW_STATION`，MAC 全 0）。Kylin 带的 NetworkManager 1.22 不做这一步，所以那边没事。现在已连接的 STA 在第 0 项返回所连 AP（走 get_station），其余返回 -ENOENT（`staging: hi110x: end station dumps`）。

修完后：NetworkManager 用 WPA3 配置连上，CPU 占用 4.5%，`iw station dump` 返回 1 条（-47 dBm，tx 400 Mbit/s，40 MHz）；断开重连 4 次全成功，每次 3-4 s；`connectivity: full`，外网下载约 10 MB/s。

### 系统睡眠时卡死

从电源菜单点"睡眠"后桌面停在锁屏、整机失联，写 `/sys/power/state` 的进程永远停在 D 状态。hi110x 的平台 PM notifier 在挂起时注销 hci0（`suspend_hi110x` 调 `hw_bt_ioctl(HCIUNSETPROTO)`，再到 `hci_unregister_dev`），唤醒时再注册。5.8 起 `hci_register_dev()`/`hci_unregister_dev()` 会同时注册/注销 HCI 核心自己的 PM notifier，于是在遍历 PM 通知链（持读锁）时去拿写锁（4.19 没有这个 notifier）。给 hdev 设 `HCI_QUIRK_NO_SUSPEND_NOTIFIER`，注册时就不挂 notifier，注销也就不碰那把锁；休眠期间 hci0 本来就不存在（`staging: hi110x: keep the HCI core's PM notifier off hci0`）。

这个修好之后还有一层：hi110x 在 PM notifier 里就给芯片和 RC1 断电，PCI 核心在 noirq 阶段访问不到根端口，唤醒时等链路超时，把下面的端点永久标成已断开，之后的配置读全返回 ~0。修在 PCIe 驱动里（`PCI: dwc: kport: keep the PM core off a hierarchy whose RC is off during system sleep`）。现在 `systemctl suspend` 的流程是 NetworkManager 断开 WiFi，s2idle，唤醒后 WiFi 自动重连，hci0 恢复。

### 蓝牙 HCI 命令超时，心跳超时刷屏

现象：登录桌面后约 30 s（sddm 自动登录，WirePlumber 注册 A2DP 端点，bluetoothd 改写 EIR），先出一条 `command 0x0c52 tx timeout`，1 s 后开始每 3.07 s 一次 `bfgx beat timeout`，一直到关机，蓝牙不可用。厂商 4.19 下从来没出现过。

根因：芯片同意睡眠约 1 s 后（UART 还没下电，打开端口时 CTS 已有效）主机又要唤醒它。芯片对 115200 唤醒字节的 GPIO 应答在写入后 56 µs 就到了，而这个字节要 87 µs 才发完，主机随即切到 4 Mbaud。`serdev_device_write_flush()` 只丢队列里的数据，PL011 FIFO 里的字符照发；上游 `pl011_set_termios()` 不等发送器空闲就改 IBRD/FBRD/LCR_H（PL011 手册不允许，厂商 5.10 的 pl011 会先关 UART、等 BUSY 清零）。发送端因此坏掉，之后的 DISALLOW_SLP、HCI 命令、ALLOWDEV_SLP 芯片一个都没收到，唤醒 GPIO 一直高（`device does not agree to sleep`，info 级，平时看不到）。成功的唤醒里芯片都在 0.4 ms 内发来第一个包。现在切波特率前先 `serdev_device_wait_until_sent()`，只有这种快速再唤醒会多等最多一个 jiffy（`staging: hi110x: let the wake-up byte go out before switching the BUART rate`）。修复前完整重登录约 1/3 次出现超时，修复后 20 次 0 次。

为什么会无限刷屏：心跳定时器只在主机认为 BFGX 醒着时运行，芯片发来的任何包都算心跳。链路坏掉以后主机永远不关串口、不再重新唤醒，厂商唯一的恢复手段是 BFGX 复位（DFR），本移植里关着。现在心跳超时时按睡眠握手的方式把主机侧退回睡眠态（状态 SLEEP/UART_NOT_READY、放唤醒锁、关串口、丢发送队列），下一次收发重新唤醒；唤醒 GPIO 已经是高时走厂商的 "ack lost" 路径。关串口前先关硬件流控：CTS 无效时残留字节会让 `uart_close()` 等满 30 s 的 closing_wait，堵住唤醒工作队列。这条兜底不管主机侧是哪种原因都能恢复链路，日志每分钟最多一行（`staging: hi110x: resync the BFGX sleep state on a beat timeout`、`staging: hi110x: report BUART bytes of the silent beat period`）。

那一行 `resync #N ...` 带着链路状态：唤醒 GPIO、modem 线（`tiocm`）、累计收发字节、队列长度、这个心跳周期里 BUART 收到的字节数。读法：

- 周期字节数大于 0：芯片在发，主机解不出，主机线路设置不对。
- `tiocm` 里没有 0x20（CTS）：芯片不收。
- resync 反复出现：芯片那边卡死了，要考虑只复位 BFGX。

### 5G 二次功率系数解析读到栈垃圾

全量编译时 `-Wsizeof-array-div` 报出：`hwifi_config_sepa_coefficient_from_param()` 把 ini/nvram 字符串拷进没清零的栈缓冲区，不带结尾 NUL，strtok 会一路读进栈垃圾，参数个数随机，5G 二次系数检查时好时坏；调用方还把 int32 数组的容量按 `sizeof/sizeof(int16_t)` 算成了两倍，可能写越界。现在缓冲区先清零，放不下 NUL 就拒绝，容量用 `ARRAY_SIZE`（`staging: hi110x: parse calibration coefficients within their buffers`）。这个检查的结果从随机变成了确定，可能和以前不一样。

## 模块参数

都在 `/sys/module/hi110x/parameters/`。

| 参数 | 含义 |
|---|---|
| `verbose` | 0 只留错误（默认）；1 全部打进内核日志；2 错误进内核日志，其余写进 ftrace 缓冲区（`/sys/kernel/tracing/trace`） |
| `ssi_dump` | 出错时经 GPIO-SSI dump 芯片寄存器，只用于调试（会扰乱芯片时钟，见上文） |
| `buart_flowctl` | BUART 硬件流控：-1 按设备树（默认），0 关，1 开 |
| `beat_resync` | 1 心跳超时时退回睡眠态（默认），0 只打日志 |
| `bt` | 启动时是否注册 hci0（只读，加载时指定） |
| `autoboot` | 是否在 `/vendor` 就绪后自动起平台和 WiFi（只读） |
| `fw_wait` | autoboot 等固件目录的秒数，默认 120（只读） |

排查睡眠/唤醒时序问题用 `verbose=2`：`verbose=1` 把每一步打到控制台，会改变时序，开着它 12 次重登录都没复现蓝牙超时。厂商日志还有自己的限流，要看全得同时设 `g_print_limit_enable_hi1105=0`。

## 检查方法

```sh
lspci -nn | grep 19e5:1103                  # 0001:01:00.0，hi110x_pci
ethtool -P wlan0                            # 永久 MAC，24:81:c7:...
iw reg get | sed -n '/^global/,/^$/p'       # country CN
iw dev wlan0 scan | grep -c '^BSS'
iw dev wlan0 station dump                   # 已连接时只有 1 条，且马上返回
bluetoothctl show                           # Powered: yes
sudo dmesg | grep -E 'resync #|beat timeout'   # 正常应没有
```

`tests/wifi-bt.sh`（root）：驱动与平台设备绑定、BUART serdev、`wlan0`、PCIe 19e5:1103、BUART 时钟与引脚状态；蓝牙 hci0、`bluetoothctl power on`（失败时关掉 RTS/CTS 再试一次）、`bluetoothctl scan`；WiFi 在一个 `systemd-run` 重启守护（默认 300 s）下执行 `ip link set wlan0 up` 和 `iw dev wlan0 scan`，完成后取消守护；开机以来驱动日志超过 100 行判失败。它只扫描，不连接任何网络、不配对、不读保存的 WiFi 密码，只在运行时让 NetworkManager 不管 `wlan0`。每行结果同时写进 journal（标签 `wifi-bt-test`），网络卡死后也能事后看。环境变量：`WIFI_WAIT`、`BT_SCAN`、`GUARD`、`SUSPEND=1`（加测睡眠唤醒）、`MIN_UPTIME=660`（先空闲到开机 11 分钟，测芯片低功耗后的唤醒）、`VERBOSE=1`（测试期间打开 `hi110x.verbose`）。例如：

```sh
sudo MIN_UPTIME=660 bash tests/wifi-bt.sh
```

`tests/quick.sh --only wifi,bt` 查得更细：模块与调试参数、永久 MAC、rfkill、监管域、连接质量、station dump 能否结束、NetworkManager 状态、省电档位、芯片异常（SSI_ERR、hcc 异常、DFR、BFG 唤醒失败、配置空间全 1）。

连网测试、蓝牙压力工具（`bt-hcistress.py`：原始 HCI socket，`sweep` 在 1.5 s 睡眠窗口附近每 2 ms 发一条命令，`random` 随机间隔）和只用于测试的 `bfgx-test-knobs.patch`（`dbg_fake_wkup`、`dbg_disallow_delay_ms`、`dbg_extra_wake_byte`、`dbg_bad_baud`、`dbg_wkup_window_ms` 几个一次性参数）在 `dev/wifi-diag/`，说明见 [dev/README.md](../../dev/README.md)。`dbg_bad_baud=1` 加 `beat_resync=0` 能稳定复现心跳超时刷屏。复现真实的 HCI 超时：DPMS 关屏，停 sddm，停 KWin 和 graphical-session.target，再起 sddm（完整重登录）。

已测过的结果：扫描 46-147 个 BSS（2.4 + 5 GHz），蓝牙扫描 11-26 个设备；1 小时混合烤机中 WiFi 0% 丢包（3596/3596）。

## 单独重编模块

只改了 hi110x 时可以只编这个模块，装到已安装的内核上（模块不能卸载，装完要重启）：

```sh
make -C <内核源码> O=<该内核的对象目录> M=$PWD/drivers/staging/hi110x MO=<输出目录> modules
strip --strip-debug <输出目录>/hi110x.ko
```

- 不要用 `make ... drivers/staging/hi110x/hi110x.ko` 单目标编译：cfg80211 和 bluetooth 是模块，modpost 会报未定义符号，而且它会把对象目录的 `modules.order` 改写成只剩一行。
- vermagic 取对象目录里的 `include/config/kernel.release`，`LOCALVERSION=` 改不了它。
- 内核配置开了 `MODULE_ALLOW_BTF_MISMATCH`，单独重编的模块 BTF 和内核不完全一致时也能加载。
- 重启前用 `nm -u` 列出未定义符号，和目标机的 `/proc/kallsyms` 对一遍。缺符号模块就加载不上，WiFi 也就断了；如果只能经 WiFi 访问这台机器，这一步别省。

## 已知问题

- NetworkManager 每次连接的第一次 connect 会被驱动拒掉（-EPERM，`hmac_config_connect::find bss failed`），supplicant 重扫后第二次成功，多花约 1 s。原因：NM 连接前要把扫描用的随机 MAC 改回真实 MAC，得 down/up 网卡，hmac 的扫描缓存随之清空，而 wpa_supplicant 拿自己缓存的结果直接连。Kylin 的 NM 配了不改 MAC，所以不出现。可以给连接设 `wifi.scan-rand-mac-address=no` 绕开，或者以后在驱动里保留扫描缓存。
- 开机校准偶尔很慢（一次 9 s，其余约 2.4 s），原因不明，可能在芯片那边。现在 open 会等它；超过 60 s 时 `wlan0` 的 open 返回 -EBUSY。
- RC1 一旦出现 completion timeout，之后每次上电链路能起来，但端点配置空间一直读到 0xffffffff（`PCI_COMMAND:0xffff`），WiFi 和蓝牙在重启前都用不了。已知会触发它的路径都已消除，RC 侧还没有恢复手段（例如上电时重建 iATU/配置访问、重新训练）。
- AP 模式（热点）的认证类型转换没有上机测；SAE PMKSA 缓存路径（Open + PMKID）也没专门测，NM 断开时会清掉 PMKSA，重连走的都是完整 SAE。
- WiFi 不能唤醒系统，睡眠中远程连不上。
- BUART 走 PIO，hisi-dma64 配 pl011 没验证。
- 模块不支持卸载。
- 发射功率没有用仪器测过。
- 运行时走不到的手机功能还没删：SDT/OAM netlink 调试口、hi1106/bisheng 芯片分支、CHR 空函数、GNSS/FM/IR 源文件（`HAVE_HISI_FM/GNSS/IR` 已经不编译）。
- 想让 DHCP 拿到和 Kylin 一样的地址，给 NM 连接设 `ipv4.dhcp-client-id=none`。

## 试过但没用

- BUART 收不到数据时加 CRG 复位、关 RTS/CTS：仍然一个字节都收不到，根因是时钟（见上）。CRG 复位留着，和厂商一致。
- 对已经下电的端点跳过第二次 BUSDOWN，以去掉 kport 的 `pm_control(2) failed` 报错：probe 下电时端点标记本来就是 down，跳过后 RC 留着过期的 link-up 状态，下一次 POWERON 走了"已经 up"的捷径，开机第一次给 BT 下载固件就 completion timeout。已撤回；那条报错是厂商流程里正常的重复下电，现在由 PCIe 驱动降成非错误级（`PCI: dwc: kport: keep a repeated power-off out of the error log`）。
- 用 `verbose=1` 抓蓝牙超时：打印本身改变时序，12 次重登录没复现。改用 `verbose=2`。
- 用压力手段复现蓝牙超时，都没复现：`bt-hcistress.py sweep` 1008 条加 hcitool 30 轮加 8 核满载；`dbg_fake_wkup`（命令超时 1 次后自己恢复）；`dbg_disallow_delay_ms` 300/1000/3000；`dbg_extra_wake_byte` 5 次；LE 扫描加 `random` 1256 条（芯片主动唤醒 85 次）。
- 排查蓝牙超时时排除的方向：固件不发心跳、主机响应慢、唤醒应答丢失、芯片醒着时多收唤醒字节、睡眠窗口竞争、芯片主动唤醒和主机唤醒撞车、uart4 时钟被改（PPLL0 固定频率，运行时没人改 sc_div_320m）、PMIC 32 kHz 被音频时钟误关（一个在 0x46，一个在 0x42，不同寄存器）。
