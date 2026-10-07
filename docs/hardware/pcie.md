# PCIe 与有线网卡

Kirin 990 有两个 PCIe 根复合体，厂商叫 kport，都是 DesignWare 控制器加 Synopsys C10 PHY。L410 上 RC0 接板载有线网卡 RTL8168H，
RC1 接 WiFi/蓝牙芯片（Hi110x，19e5:1103，见 [wifi-bt.md](wifi-bt.md)）。

6.18 的主机驱动是 `drivers/pci/controller/dwc/pcie-kport.c`（`CONFIG_PCIE_KPORT`，内建），PHY 补丁固件在 `pcie-kport-phy-fw.h`，
给端点驱动的接口在 `include/linux/platform_drivers/pcie-kport-api.h`（和厂商 5.10 同名）。配置片段 `l410/configs/50-pcie.config`
（还开了 r8169），DT 修补 `l410/dt/fixups.d/50-pcie.dtsi`。驱动匹配固件 DT 的 `pcie-kport,rc`，不改绑定。
代码在内核仓库 [linux-l410](https://github.com/liuwang97/linux-l410)（分支 `l410-6.18`）。网卡用主线 r8169，固件是 Debian firmware-realtek 包里的
`rtl_nic/rtl8168h-2.fw`。

## 硬件

| | RC0 `f0000000.pcie_kport_rc` | RC1 `f4000000.pcie_kport_rc` |
|---|---|---|
| PCI 域 / RC ID | 0000 / 19e5:3690 | 0001 / 19e5:3691（厂商驱动把 device id 加上 rc_id） |
| 端点 | RTL8168H 10ec:8168 rev 16（Gen1 x1），厂商用 r8168 | Hi110x 19e5:1103（Gen2 x1），厂商 hi110x 驱动 |
| 谁触发枚举 | 厂商 r8168 模块初始化时调 `kirin_pcie_enumerate(0)` | WiFi 驱动给芯片上电后调 `kirin_pcie_enumerate(1)`，平时用 `pm_control` 开关 |
| PERST# | gpio@fa8b4000 第 2 脚（厂商 gpio-258，输出高） | 第 3 脚（厂商从不驱动，芯片靠自己的上电 GPIO 复位） |
| 中断（固件 DT） | INTa..d 282..285，MSI 控制器输出接在 INTb（283），link_down 281，cpl_timeout 211 | INTa..d 416..419，INTb 417，link_down 383，cpl_timeout 212 |

- 控制器：DesignWare，iATU unroll 在 dbi+3 MiB（8 出 8 进，对齐 64K）。DBI 和出站 AXI 窗口共用 0xf0000000：读写 DBI 前要置 ELBI
  CTRL1/CTRL0 的 bit21（sideband），不置时同一地址经 iATU 发 TLP。`config` 就是这个窗口的前 8 KiB。
- PHY：Synopsys C10。`phy` 区里 natural（CR）寄存器在 0，SRAM 在 0x30000，APB 在 0x40000。上电时要往 SRAM 灌 ECO 补丁（6k 个 u16）。
- 参考时钟：HSDT CRG 的 FNPLL（两个 RC 共用，2.4 GHz VCO 分出 100 MHz）。PHY 参考时钟和 IO 输出的门控交给 CLKREQ# 硬件控制。
- 其他：sysctrl 的隔离（`iso_info`）、HSDT 复位（`assert_info`）、PMCTRL 的 NoC power idle（0x380/0x388 bit10/11）。
- MAC 地址在 RTL8168 自己的 eFuse 里。厂商 r8168 从 ERI 0xE0/0xE4 读，主线 r8169 的 `rtl_read_mac_address()` 读同一处，所以和厂商内核一致。

麒麟下 RC0 的状态（只读）：FNPLL 锁定，CFG6 = 0x3a603e05（与 chip_type = 2 的分支一致）；ELBI CTRL7 = 0x800、CTRL12 = 0x2006、CTRL25 超时 0x36；
PHY CTRL40 bit4（SRAM ext ld done）= 1，STATE39 sram_init_done = 1，STATE0 PIPE 时钟稳定；LTSSM = 0x14（ASPM L1），L1 子状态开着（CTRL1 bit23）。

**不要在麒麟下读 PHY natural（CR）区。** 链路在 L1/L1SS 时 PHY 参考时钟被 CLKREQ# 关掉，这时读会把总线挂死，整机死机。

## 驱动

上电顺序照搬厂商 `pcie_turn_on`（apr 版）：

1. 去隔离 → 复位和 APB 时钟 → AXI 超时 → RC 模式、PERST 输出
2. FNPLL 和参考时钟路由 → AXI/AUX 时钟
3. PHY：ECO、复位、perst_in、SRAM 补丁、vboost、cdr_legacy
4. 端点上电回调，按 DT 的 `t_ref2perst`/`t_perst2access` 释放 PERST#
5. 等 PIPE 时钟稳定 → 眼图参数 → NoC 退出 idle → GEN3_RELATED 修正

下电反序。其他要点：

- DBI 读写走 sideband 并加自旋锁。根总线的 config 走 DBI；子总线的 config（iATU TLP）也用同一把锁串行，避免和 MSI 中断里的 DBI 访问在 sideband 上撞车。
- link up 看 ELBI STATE0（0x8020），LTSSM 看 STATE4。MSI 用 DWC 内部 MSI 控制器（中断是 INTb）。PME_Turn_Off 经 iATU 发 MSG，再等 PME_TO_Ack。
- `dbi` 区包含 `config`：驱动自己 ioremap `dbi`（不 request），让 DWC 核心去 request `config`。
- ASPM 保守：RC 的 LNKCAP 只报 DT 的 `aspm_state`（L1），不开 L1 子状态（DWC 核心默认隐藏 L1SS）。6.18 在 DT 平台上默认开 L0s/L1，所以实际只开 L1。
  r8169 自己又把 ASPM L1 关了（l1_aspm=0）。
- 时钟走时钟框架（DT 里 4 个 `hisilicon,hi3xxx-clk-gate`，见 [soc-core.md](soc-core.md)）。
- 同步 probe：异步 probe 时 r8169 在异步上下文里 request_module，会报 WARN。
- RC1（`ep_device_type = 2`，Hi110x）probe 时不上电、不训练链路，等 WiFi 驱动调 `pcie_kport_enumerate(1)`。调试时可以用内核参数
  `pcie_kport.probe_enum=<位掩码>` 强制在 probe 时枚举（2 = RC1）。
- `50-pcie.dtsi`：`linux,pci-domain` 固定成 0/1，和厂商内核一样，不受 probe 顺序影响；删掉两个 disabled 的 `pcie_kport_ep` 节点上的 `device_type`，
  否则它们缺 `#address-cells`，efifb 等遍历 "pci" 节点的代码会报 WARN。

### 给端点驱动的接口

`pcie_kport_enumerate`、`remove_ep`、`rescan_ep`、`pm_control`、`lp_ctrl`、`power_notifiy_register`、`register_event`、`deregister_event`、
`ep_link_ltssm_notify`、`refclk_device_vote`（函数名都带 `pcie_kport_` 前缀，拼写照厂商）。

锁的划分：`enum_lock` 串行 enumerate/rescan/remove，端点 probe/remove 期间只持这一把；电源互斥锁只在上下电时拿（DWC 的 init/deinit 回调自己拿），
从不跨 PCI 核心的 probe；端点回调和事件注册用自旋锁。所以端点驱动在 probe 里可以调 `register_event`、`pm_control`、`lp_ctrl`；
不能在 probe 里调 enumerate/rescan/remove，也不能在 poweron/poweroff 回调里调电源类接口。

最初 enumerate 持着电源锁跨过整个端点 probe，WiFi 驱动在 probe 里注册 link-down 事件又要拿这把锁，死锁，关机路径也卡在这把锁上。
修复是上面的锁划分（`PCI: dwc: kport: let endpoint probe call back into the API; skip L2 wait`）。

### 系统睡眠

两个问题，修好后 s2idle 可用，唤醒后网卡正常，WiFi 和蓝牙恢复：

- 等不到 L2：发 PME_Turn_Off 后能收到 PME_TO_Ack，但 LTSSM 停在 L1（0x14），不报 L2 idle。`kport_pcie_suspend_noirq` 返回 -110
  （`Timeout waiting for L2 entry! LTSSM: 0x14`），整个挂起中止。改成和厂商一样只等 PME_TO_Ack（`skip_l23_ready`，同一个提交）。
- RC 已被端点驱动关掉：WiFi 驱动在 PM notifier 里（设备挂起之前）就给芯片和 RC1 断电。PCI 核心在 noirq 阶段访问不到根端口 0001:00:00.0
  （"Unable to change power state from D0 to D3hot, device inaccessible"），唤醒时等链路超时，把下面的端点永久标成已断开，之后端点的配置读全被挡住返回 ~0，
  WiFi/蓝牙起不来。4.19 的 PCI 核心没有这套检查。改法：prepare 时如果桥起来了而 RC 已断电，把根端口及以下设成 syscore，让 PM 核心跳过它们，
  complete 时恢复（`PCI: dwc: kport: keep the PM core off a hierarchy whose RC is off during system sleep`）。RC0 带电，照常走正常路径。

### 根端口事件不走 MSI

DWC 根端口自己的事件（LBMS/bwctrl、PME、AER）在这颗 SoC 上不经 MSI 控制器上报：retrain 后 LBMS 置位，但没有中断。所以 pcieport 的 PME、AER、
bwctrl 服务收不到中断。厂商内核也一样（`PCIe PME`、`aerdrv` 的中断计数一直是 0）。

## 实测

- RC0：`PCIe Gen.1 x1 link up`，2.5 GT/s x1（RTL8168H 的最大值），`0000:01:00.0 [10ec:8168]`，r8169 识别为 RTL8168h/8111h（XID 541），
  接口 `enp1s0`，MAC 和厂商内核一致；MSI-X（`DW-PCI-MSIX-0000:01:00.0`）；打开接口时加载固件 `rtl8168h-2_0.0.2`；ethtool `-P`/`-d`/`-S` 正常；
  r8169 解绑重绑、根端口 retrain 后链路都能恢复；两次启动结果一致。
- RC1 带芯片：`PCIe Gen.2 x1 link up`，`0001:01:00.0 [19e5:1103]`，WiFi 驱动绑定。芯片没上电时（只做 RC 侧测试）共用的 FNPLL、PIPE 时钟、DBI/iATU 都正常，
  链路停在 detect.quiet（`Phy link never came up`，LTSSM 0x0），然后下电。
- s2idle：`rtcwake -m freeze` 进入和唤醒都通过，网卡正常。

## 怎么检查

```bash
sudo bash tests/pcie.sh
```

检查 RC 绑定、枚举、ID、r8169、链路速率和宽度、MAC（sysfs 和 `ethtool -P`）、ethtool 寄存器和统计、MSI 向量、固件、r8169 解绑重绑、
根端口 retrain 后链路恢复（看 LNKSTA，不看 bwctrl 计数）、RC1 端点（有就查）。需要装 ethtool。环境变量：

- `EXPECT_MAC`：期望的网卡 MAC，默认值是作者那台机器的，换成自己的。
- `PCIE_TEST_SUSPEND=1`：额外做一次 s2idle（`rtcwake -m freeze -s 10`）。

插了网线时还会 ping 网关并核对网卡 MSI-X 中断计数在涨，这是验证 MSI 投递的唯一办法（根端口事件不走 MSI）。

手工看：

```bash
lspci -nn
sudo lspci -vv -s 0000:01:00.0 | grep -E "LnkSta|MSI"
dmesg | grep -E "pcie-kport|PCIe Gen"
```

## 已知问题与没做的

- 测试机没插网线，RTL8168 的实际链路、吞吐和 MSI 投递都没验证。
- 没插网线时 RTL8168 停在 D0。r8169 的 runtime PM 默认没开；`system/perf` 在省电和平衡档把它的 `power/control` 设成 `auto`（D3hot），性能档保持 `on`。
- 没开 L1 子状态。厂商 RC0 开了 L1SS，参考时钟由 CLKREQ# 硬件门控；要省电时再加 `l1ss_support`，并验证 CLKREQ#。
- `pcie_kport_refclk_device_vote` 是空实现（厂商用它按投票关参考时钟）。
- RC1 枚举失败时根端口仍然注册着而 RC 已下电，pcieport 会打一条 "Unable to change power state ... inaccessible"，无害。
- RC1 一旦出现 completion timeout，不会自己恢复。
- systemd-networkd 的 `Name=enx*` 也会匹配 RTL8168：udev 给它起了 `enx<MAC>` 形式的备用名。给 USB 网卡写 .network 时按 MAC 匹配，
  否则插上网线后两块网卡会用同一份配置。

## 试过但没用

- 挂起时等 L2 idle：LTSSM 停在 L1，超时 -110，挂起中止；改为只等 PME_TO_Ack。
- 用 bwctrl 计数验证 retrain：根端口事件不走 MSI，计数不涨；改查 LNKSTA。
- 只拉 WiFi 芯片的两个电源 GPIO、当成 RC1 的 vpcie3v3 来起链路：链路停在 detect.quiet。芯片还要 PMU 的 32 kHz 时钟（clk_pmu32kb）和 WiFi 驱动的上电时序。
- 异步 probe：r8169 在异步 probe 里 request_module 报 WARN，改成同步。
