# 睡眠（挂起到内存）

L410 上 s2idle（suspend-to-idle）可用，是默认的睡眠方式：Plasma 菜单里的“睡眠”、`systemctl suspend` 都走它，
唤醒后显示、WiFi、蓝牙、USB、UFS 都能恢复。deep（厂商 LPM3 睡眠）能睡下去，但唤醒时整机冷启动，所以默认不用。

## 现状

| 方式 | 状态 |
|---|---|
| s2idle | 默认，可用。挂起设备约 0.5-0.7 s，唤醒设备约 2 s（其中 USB 设备复位约 1.2 s，屏幕恢复 252-337 ms） |
| deep | 能进，回不来：RTC 闹钟到点后约 15 s 整机冷启动 |

`cat /sys/power/mem_sleep` 应显示 `[s2idle] deep`。

## 怎么工作

默认方式：`drivers/soc/hisilicon/kirin990-sr.c` 在启动时把 `mem` 的默认方式设成 s2idle（除非命令行给了 `mem_sleep_default=`），
deep 仍可选。`kirin990_sr.deep=1` 让 deep 成为默认。

设备树修补把 PSCI 声明成 1.0（固件 DT 只报 0.1），于是通用 PSCI 代码会把 PSCI SYSTEM_SUSPEND 当作 deep 提供出来。
厂商内核从来没用过这条固件路径，kirin990-sr 让 deep 改走厂商的 LPM3 握手（见下面“deep 的现状”），不走 SYSTEM_SUSPEND。

挂起时各部分做的事：

- 显示：kirin990-dss 关闭 CRTC，整条显示链断电（背光、面板、eDP 桥、DSI、DSS 电源域），唤醒后从复位重建。见 [graphics.md](graphics.md)。
- WiFi/蓝牙：NetworkManager 先断开 WiFi；hi110x 在自己的 PM notifier 里给芯片和 PCIe RC1 断电，唤醒后重新上电，WiFi 自动重连。
- PCIe：RC1 已被端点驱动关掉时，kport 在 prepare 阶段把根端口及以下的设备设成 syscore，complete 时恢复，PCI 核心就不会去碰断了电的层级。
- EC：电池轮询跑在可冻结的工作队列上，挂起期间不再读 EC。
- 唤醒：RTC 闹钟和电源键都是 PMIC 的子中断。PMIC 中断芯片把 `irq_set_wake` 转给它接到 SoC 的那根线（AO GPIO fa8b0000.gpio 的 6 号脚，
  这版内核里是 IRQ 88），RTC 和电源键驱动各自注册了唤醒中断。

## 修过的问题

最初从 Plasma 菜单点“睡眠”后画面停在锁屏上，ssh 断开，只能长按电源键。下面是逐级排查出来的问题和对应的内核提交：

| 现象 | 原因 | 改法 |
|---|---|---|
| 写 `/sys/power/state` 的进程永远停在 D 状态，systemd 已冻结用户会话，所以画面停住 | hi110x 的 PM notifier（`pf_suspend_notify` → `suspend_hi110x` → `hci_unregister_dev`）在挂起时注销 hci0。5.8 起 HCI 核心自己也注册 PM notifier，注销它要拿 notifier 链的写锁，而遍历链时读锁已被持有，死锁。唤醒时重新注册 hci0 同理 | hci0 设 `HCI_QUIRK_NO_SUSPEND_NOTIFIER`（`staging: hi110x: keep the HCI core's PM notifier off hci0`） |
| pm_test processors 级卡死（能 ping，不能 ssh） | cpufreq 驱动 hisi-hwvote 的 init/exit 判断的是调度器的 per-CPU 变量 `hw_pressure`，而不是同名模块参数的变量 `report_pressure`。启动时读到 init 段里的模板，值为 0，HW pressure 回报从来没运行过；init 内存释放后，簇的最后一个核下线时 exit 缺页 oops，而且持着 hotplug 锁 | 改判断模块参数，并默认关（`cpufreq: hisi-hwvote: test the hw_pressure parameter, not the scheduler's per-CPU variable`） |
| platform 级之后 WiFi/蓝牙起不来 | hi110x 在 PM notifier 里就给 RC1 断电。PCI 核心在 noirq 阶段访问不到根端口，唤醒时等链路超时，把下面的端点永久标成已断开，之后 hi110x 的配置读全被挡掉，返回 ~0。4.19 的 PCI 核心没有这套检查 | `PCI: dwc: kport: keep the PM core off a hierarchy whose RC is off during system sleep` |
| `i2c-7: Transfer while suspended` 警告 | EC 电池轮询在挂起过程中还在读 EC | `power: supply: huawei-echub-battery: poll on a freezable workqueue` |
| s2idle 睡下去醒不来 | PMIC 中断芯片带 `IRQCHIP_SKIP_SET_WAKE`，它接 SoC 的那根线在挂起时和普通中断一起被关掉；RTC、电源键驱动也没注册唤醒中断 | `mfd: hisi-spmi-pmic: pass wakeup requests on to the PMIC's interrupt line`、`rtc: hisi-spmi: let the alarm wake the system`、`Input: hisi_powerkey - wake the system with the power key` |
| Plasma 6.7 下第一次挂起必定中止（`Freezing user space processes aborted after 0.001 seconds`），systemd-sleep 立即用 freeze 重试 | PowerDevil 经 `/sys/power/wakeup_count` 挂起，防止和唤醒事件竞争。hi110x 厂商 OAL 层把内部 wakelock（hcc_tx、wlan_bus_lock、wlan_wal_lock、wifi_pm_wakelock、bfg_wake_lock 等）实现成系统唤醒源，读 wakeup_count 之后 NetworkManager 断 WiFi、驱动关芯片产生的收发都算唤醒事件，几十次 | wakelock 只在驱动内部计数，不再报给 PM 核心（`staging: hi110x: keep the driver's wake locks out of the PM core`） |
| 唤醒后屏幕亮了，但 KWin 冻着、键鼠没反应，几十秒后才恢复或干脆睡死 | 中止后的重试里，驱动在 PM_POST_SUSPEND 刚同步重开蓝牙，一秒内又要关掉，HCI 设置命令超时，notifier 卡 33 s；systemd 要等写 `/sys/power/state` 返回（包括唤醒时的 PM_POST_SUSPEND notifier）才解冻用户会话，RTC 闹钟也因此错过 | 唤醒后用 1.5 s 后的工作项给芯片上电，挂起前先取消它；还没恢复就再次挂起时直接跳过（`staging: hi110x: resume the chip from a work item after system sleep`） |
| deep 默认走 PSCI SYSTEM_SUSPEND | 设备树修补声明了 PSCI 1.0；厂商 DT 是 0.1，厂商内核从没用过 SYSTEM_SUSPEND | `soc: hisilicon: kirin990-sr: deep suspend through the LPM3 handshake`、`soc: hisilicon: kirin990-sr: default to suspend-to-idle` |

内核另外打开了睡眠调试接口（`pm_test`、`pm_debug_messages`、`pm_print_times` 等，`l410: build the system sleep debugging interfaces`）。

## 唤醒源

| 来源 | 路径 | 状态 |
|---|---|---|
| RTC 闹钟 | PMIC → IRQ 88 | 验证过，日志 `PM: Triggering wakeup from IRQ 88` |
| 电源键 | 同一条 PMIC 中断链 | 短按能唤醒（实机确认） |
| 开盖 | 合盖开关是 gpio-keys，设备树里带 `wakeup-source` | 没有实测 |
| 键盘 | i2c-hid | 不能唤醒：节点还没加 `wakeup-source` |
| 网络 | Hi1103 没有网络唤醒（WoWLAN），挂起时芯片断电 | 不支持 |

## 实测结果

- `pm_test` 的 freezer、devices、platform、processors、core 五级全部通过，唤醒后 WiFi、hci0、显示、USB、UFS 正常。
- s2idle 真实睡眠，RTC 20 s 唤醒：`PM: Triggering wakeup from IRQ 88`，计时挂起 19.2 s，所有设备恢复。
- `systemctl suspend`（和 Plasma 菜单同一条路径）：NetworkManager 断开 WiFi → systemd 冻结 user.slice → s2idle → RTC 唤醒 → 解冻 → WiFi 自动重连，用户会话正常。
  Plasma 6.3（Debian 13）和 Plasma 6.7.4（forky）下各连续两轮通过，屏幕 252-337 ms 恢复；forky 下 KWin 还是原来的进程。
- Plasma 6.7.4 下经 PowerDevil 挂起（和合盖、菜单“睡眠”同一条路径），RTC 30 s 唤醒，连续 6 次：全部第一次就挂起成功，`/sys/power/suspend_stats` 的 fail 为 0；从 `PM: suspend exit` 到 user.slice 解冻约 0.1 s，KWin 还是原来的进程，glmark2 4800-5000 分；WiFi（5 GHz WPA2/WPA3 混合 AP）20 s 内自动重连、ping 不丢包，hci0 和 USB 网卡恢复。挂起期间报唤醒事件的只有 RTC。
- `tests/suspend.sh s2idle none 20`（开着 sched_ext lavd）：挂起前后 WiFi、蓝牙、显示、15 个 USB 设备、8 个输入节点、UFS 状态一致，lavd 唤醒后仍在运行。

## 怎么检查

```bash
cat /sys/power/mem_sleep               # [s2idle] deep
sudo dmesg | grep kirin990-sr          # deep through the LPM3 handshake, default s2idle

# 设一个 30 s 后的 RTC 闹钟，然后睡眠
echo +30 | sudo tee /sys/class/rtc/rtc0/wakealarm
systemctl suspend
# 醒来后
cat /sys/power/pm_wakeup_irq           # 88：RTC 或电源键
cat /sys/power/suspend_stats/{success,fail,last_failed_dev,last_failed_step}
```

### tests/suspend.sh

做一轮挂起，打开内核的睡眠调试输出，脱离当前 ssh 会话运行（WiFi 会跟着睡下去）。以 root 运行：

```bash
sudo bash tests/suspend.sh <deep|s2idle> [freezer|devices|platform|processors|core|none] [唤醒秒数]
```

- 第二个参数是 `pm_test` 级别：前五级在对应阶段停下、等 5 s 后恢复，不真睡；`none`（默认）真睡，由 RTC 闹钟唤醒（默认 20 s）。
- 结果写到 `/var/tmp/suspend/<时间>-<方式>-<级别>.log`，命令本身只打印这个路径。日志里有挂起前后的设备状态（wlan0、hci0、显示、背光、USB 和输入设备数、UFS、电量、`suspend_stats`）和这一轮的内核日志。
- 打开 `pm_debug_messages`、`pm_print_times`，把看门狗设成 600 s，醒不来时会自己复位。
- 唤醒后 60 s 内 WiFi 没回来，就同步日志并重启（远程测试时 WiFi 是唯一的入口）。

## 调试卡住的挂起

1. 先判断卡在哪：画面停住，但 journal 还在写、logind 还响应电源键，说明用户态还活着，卡在冻结进程之前。
2. 用户态活着时可以现场看：从一个脱离 ssh 的 root 进程直接写 `/sys/power/state`（绕开 NetworkManager，WiFi 和 ssh 不断），再读它的内核栈：
   ```bash
   sudo setsid sh -c 'echo mem > /sys/power/state' < /dev/null > /dev/null 2>&1 &
   sleep 10; sudo cat /proc/$(pgrep -f 'echo mem > /sys/power/state')/stack
   ```
3. 用 `tests/suspend.sh` 按 `pm_test` 逐级往下测：freezer → devices → platform → processors → core → none，每级只修一个问题。
4. s2idle “睡下去醒不来”时先查唤醒链：经 PMIC 唤醒的东西（电源键、RTC）全靠 PMIC 中断芯片把 wake 请求转给 IRQ 88。
5. 整机挂死要靠 pstore：启动参数加 `no_console_suspend`，挂起过程的日志才会进 pstore。复位后要直接回到同一个 6.18 内核去读 `/sys/fs/pstore`，
   先进出厂麒麟的话 pstore 会被它覆盖。看门狗、单次启动和 pstore 的设置见 [dev/README.md](../../dev/README.md)。
   s2idle 睡着时看门狗半周期的 FIQ panic 不会触发，只有到点的硬件复位。

## deep 的现状

厂商内核 `drivers/hisi/pm/old/pm.c` 的做法，kirin990-sr 照做：

1. 等其他核的 PERPWRACK（CRGPERIPH 0x15C bit 11-18）都清零；
2. 置 SCTRL SCBAKDATA8（0x42C）的 bit16；
3. PSCI CPU_SUSPEND(0x01010000)，和 cpuidle 的 cluster sleep 是同一个状态。

BL31 看到这个标志，就把系统交给 LPM3 做 DDR 自刷新、关时钟和 IO，而不只是关这个簇。
这个标志寄存器所有簇共用，所以只能在其他核都下线之后设，否则 cpuidle 进 cluster sleep 时也会走系统睡眠路径。

实测（`echo deep > /sys/power/mem_sleep`）：设备挂起、7 个核下线、syscore（包括 EC 同步）都正常，最后一行日志是 `cpu_pm_suspend`。
之后内核再没有输出，RTC 闹钟到点后约 15 s 整机冷启动。PMIC 0x301（SR tick）读出 0，说明固件没有写进度。

要试 deep：启动参数加 `kirin990_sr.deep=1`，或者运行时 `echo deep > /sys/power/mem_sleep`。失败时会自己冷启动。

待查的方向：

- 时钟默认在硬件上真正关断，LPM3 的睡眠/唤醒流程也许要用到某个被关掉的时钟。可以加 `kirin_clk_keep_on` 对比。
- DDR 调频投票（PMCTRL 0x270）和 LPM3 的 `SYS_SUSPEND_DDRDFS`。
- 出厂麒麟的启动参数带 `resume=` 和 `systemd.kylin_force_hibernate=true`。这台机器的固件可能本来就不支持 S3，厂商实际用的可能是休眠到磁盘。

## 远程使用时注意

睡眠能用之后，PowerDevil 的空闲自动睡眠会真的让机器进 s2idle，WiFi 跟着睡下去，远程就连不上了。
能唤醒它的只有电源键、开盖和 RTC 闹钟，网卡不支持网络唤醒。无人值守的机器要关掉空闲自动睡眠：

- 在桌面用户的 `~/.config/powerdevilrc` 里，把 `[AC][SuspendAndShutdown]`、`[Battery][SuspendAndShutdown]`（以及 `[LowBattery][SuspendAndShutdown]`）的 `AutoSuspendAction` 设为 0；
  `dev/testrig-nosleep.sh` 就是做这件事的，`restore` 参数恢复；
- 或者需要长时间空闲时用 `systemd-inhibit --what=idle:sleep` 包住；
- 或者加一个 systemd-sleep 钩子，每次挂起前设一个 +10 min 的 RTC 闹钟。

## 已知问题

- deep 唤醒变冷启动（见上）。
- s2idle 的耗电还没测：需要拔掉电源睡 10 分钟，对比 `energy_now`。
- 键盘不能唤醒：i2c-hid 节点要加 `wakeup-source`。
- 开盖唤醒还没有实测。
- Plasma 6.7 的 PowerDevil 在 RTC 闹钟这类不是用户触发的唤醒之后，会很快自动再次睡眠，这是它的设计，不是故障。
- forky 上睡眠和唤醒时 journal 里有 bluetoothd、wireplumber 的 dbus `Rejected send message`，来自 forky 的 dbus 策略，不影响功能。

## 试过但没用

- deep 走厂商的 LPM3 握手：能睡下去，回不来，整机冷启动，固件没留下进度（PMIC 0x301 为 0）。
