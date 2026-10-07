# USB

L410 的 USB 是一个 DWC_usb31 控制器，经 Synopsys USB 3.1/DP combo PHY 出来，后面接一颗板载 Realtek RTS5411 hub。
控制器的两个根端口都只接这颗 hub，内置摄像头和测试时插在机身 USB 口上的设备都在它下面。6.18 上只做了 host 模式。

代码在内核仓库 [linux-l410](https://github.com/liuwang97/linux-l410)（分支 `l410-6.18`）：

| 文件 | 内容 |
|---|---|
| `drivers/phy/hisilicon/phy-kirin990-usb3.c` | generic PHY，匹配 `hisilicon,apr-dwc3` |
| `drivers/usb/dwc3/dwc3-kirin990.c` | glue，匹配 `hisilicon,dwc3-usb`：取 PHY，`phy_init` + `phy_power_on`，再 `of_platform_populate` 出 dwc3 子节点（host） |
| `l410/firmware/hisilicon/kirin990-usb31phy.bin` | combo PHY 的 SRAM 固件，从厂商 `firmware.h` 的 APR 数组转出（小端 u16），用 `CONFIG_EXTRA_FIRMWARE` 编进内核 |
| `l410/configs/40-usb.config` | DWC3、PHY、xHCI platform、onboard_usb_dev、r8152、EXTRA_FIRMWARE |
| `l410/dt/fixups.d/40-usb.dtsi` | PHY 节点加 `#phy-cells` 和 syscon / dp-ctrl / dwc3 的 phandle；glue 加 `phys`；dwc3 改 `dr_mode = "host"`，删 `extcon`、`linux,sysdev_is_parent` |
| `l410/dt/fixups.d/42-usb-hub.dtsi` | hub 供电和复位，由 onboard_usb_dev 管 |

## 硬件

- 控制器：DWC_usb31 1.10a（GSNPSID 0x33313130），f8400000，xHCI 两个口（1 × USB2 + 1 × USB3），64 位寻址，SPI 159。
- 拓扑（`lsusb -t`）：

| 总线 | 路径 | 设备 |
|---|---|---|
| bus1（USB2） | 1-1 | RTS5411 的 USB2 部分 0bda:5411，4 口 |
| | 1-1.4 | 内置摄像头 3196:0203 "HD Camera"（UVC） |
| | 1-1.1 | 外接口（测试时接鼠标） |
| bus2（USB3） | 2-1 | RTS5411 的 USB3 部分 0bda:0411，2 口 |
| | 2-1.2 | 外接口（测试时接 RTL8153 USB 千兆网卡 0bda:8153） |

### 厂商驱动的分工

厂商代码在 4.19 的 `drivers/usb/dwc3/hisi/`：

| 节点 / 文件 | 做什么 |
|---|---|
| `usb_phy@f8480000`（`hisilicon,apr-dwc3`，dwc3-apr.c） | misc ctrl（usb3otg_bc）上的控制器/PHY 复位、USB2 PHY（HSDT sysctrl 0x600-0x618）、时钟、LDO |
| `hisi_usb_dp_ctrl@f8481000` + hisi_usb3_31phy_v2.c | combo PHY 的 CR 寄存器口；SRAM 固件（6144 个 u16）写到 CR 0xc000 起 |
| `combophy_regcfg` | misc ctrl 复位（mmc0crg 0x20/0x24 bit5/6）、PHY 复位、testpowerdown、power stable 等寄存器描述 |
| `pddevice`（`hisilicon,pd`，combophy.c） | Type-C Assist（TCA，misc+0x200）换道。L410 的 `init-mode = "usb_dp"`：开机按“USB3.1 + DP 2 lane、正插”切换，另外两条 lane 给 DP→PS176→HDMI；然后发 ID_FALL 让控制器起 host |
| `hw_usb_hub` | product_type 5（KUA）。GPIO 114（gpio14 bit2，fe010000）= hub 复位（高电平复位），GPIO 115（gpio14 bit3）= hub 供电，GPIO 48（gpio6 bit0）= 摄像头供电。开机先断电，USB_BUS_ADD 时上电 |

麒麟运行时读到的寄存器（USB 各部分都在工作）：

| 寄存器 | 值 | 含义 |
|---|---|---|
| misc 0xa0 | 0x106 | PHY、控制器已解复位 |
| TCA_TCPC | 0x3 | USB + DP 2 lane |
| TCA PSTATE | 0x33bb00 | |
| USB_DP_CTRL CFG0 | 0x191a | SSC、CDR legacy |
| USB_DP_CTRL CFG6 | SRAM bypass = 0，EXT_LD_DONE = 1 | 跑 SRAM 固件 |
| CTRL_CFG0 bit19 | 1 | 强制 Gen1 |
| HSDT 0x600 / 0x604 / 0x618 | 0x364 / 0x027cfee4 / 0x1 | USB2 PHY 配置，0x604 是眼图参数 |

DT 里 0.85 V / 1.8 V 两路 LDO（ldo6、ldo7，TCXO buffer）是 disabled，厂商日志里是 "maybe cs2"，这块板子不用。

## 6.18 实现

`phy_init` 的顺序：

1. misc ctrl 上电、解复位（含 NoC 退出 idle）。
2. combo PHY 上电，加载 SRAM 固件。
3. TCA 先切到 NC 再切到 USB + DP2。切换时控制器临时解复位、`GUSB3PIPECTL.SUSPHY = 1`，照厂商 `enable_u3`。
4. 控制器正式起来：USB2 PHY 出 IDDQ、解复位，UTMI 16 bit，SSC，强制 Gen1，控制器解复位，VBUS valid。
5. 眼图、vboost、终端电阻。

整个 `phy_init` 约 0.6 s，成功后日志里有 `fw loaded, mux 3, TCPC 0x3 PSTATE 0x33bb33`。

- 时钟全部走时钟框架：`clk_usb3phy_ref`（= clk_usb3otg_ref）、`aclk_usb3otg`、`hclk_usb3otg`、`clk_usb3_tcxo_en`（= clk_abb_usb ← clk_usb_tcxo_en）、
  `clk_usb2phy_ref`（set_rate 19.2 MHz）、`clk_mmc_usbdp`。
- 供电：ldo23 `usb_phy_ldo_33v`（3.2 V，UEFI 已打开，驱动不设电压）。ldo6、ldo7 不申请。
- syscon 用 `device_node_to_regmap()` 拿（目标节点大多没有 `"syscon"` compatible），不占用寄存器区，和时钟驱动共用不冲突。
- 固件走 `request_firmware`。缺固件时 PHY 保持 SRAM bypass，跑 ROM 里的代码，功能可能降级。
- hub：`42-usb-hub.dtsi` 用 regulator-fixed 管 GPIO 115（hub 供电，12 ms），在 dwc3 节点下加 `hub@1`（`usbbda,5411`，`reset-gpios` = GPIO 114，高电平复位），
  由 onboard_usb_dev 上电、解复位。USB3 那一半（0bda:0411）也解析到这个节点。
- TCA 固定 USB3.1 + DP 2 lane、正插（读 `pddevice` 的 `init-mode`）。

### 控制器重新初始化时的 SError

现象：glue 解绑再绑定（相当于控制器级插拔）时，第二次 `phy_init` 在 `kirin990_usb_phy_init+0x134` 读 USB_DP_CTRL 时同步外部中止。

原因：`phy_exit` 让 USB NoC 进了 power idle；重新 init 时 `misc_ctrl_on` 先做 CR end（读写 USB_DP_CTRL），这时 NoC 还在 idle。
第一次开机没事，是因为 UEFI 留下的 NoC 不在 idle。厂商驱动用 `is_phy_cr_start` 标志，CR 没启动时 cr_end 不碰寄存器。

改法（`phy: kirin990-usb3: no USB_DP_CTRL access while the USB NoC is idle`）：同样用标志，`misc_ctrl_on` 在 NoC 退出 idle 前不碰 USB_DP_CTRL；
`phy_exit` 不再额外拉 misc 复位（厂商也不拉）。验证：控制器插拔 3 次全过，每次 11-12 s 网络恢复，RTL8153 回到 5000M。

## 实测

- RTL8153 跑在 SuperSpeed（5000M），以太网链路 1000 Mb/s（有一次协商成 100 Mb/s，下一次启动又是 1000）；ping 300 次（20 ms 间隔）和 1400 字节 ping 1000 次都不丢包；
  rx/tx 0 错误。
- 经 ssh 双向各传 256 MiB 随机数据，SHA-256 校验一致；PC 到 L410 约 532 Mbit/s，L410 到 PC 约 342 Mbit/s。这条路径有 ssh 加密和一次转发，数值只是下限。
- 摄像头：uvcvideo、`/dev/video0`，能抓帧；经 hub 端口 4 disable/enable 模拟一次插拔，能重新枚举。
- s2idle：唤醒后 USB 设备都回来，唤醒约 2 s 里 USB 设备复位占约 1.2 s。

## 怎么检查

```bash
sudo bash tests/usb.sh
```

检查项：驱动绑定；PHY 起来的日志（固件已加载、TCA mux 3）；`clk_summary` 里的 USB 时钟；拓扑和速度（两个 root hub、RTS5411 两半）；
摄像头（uvcvideo、`/dev/video*`、`v4l2-ctl --list-devices`、抓 3 帧、经 hub 端口 4 做一次插拔）；内核日志里没有 xhci/dwc3/PHY/r8152 错误；USB 复位次数。
接了 RTL8153 时还查网卡：5000M 且在 2-1.x、链路 1000 Mb/s、地址、默认路由、ping 不丢包。脚本开头的网卡名和地址是作者环境的值，
用之前改成自己的；没接 RTL8153 且默认路由在 WLAN 上时，网卡项跳过（`USB_NIC_REQUIRED=1` 强制检查）。日志从 `journalctl -k -b` 读，
因为别的驱动刷屏会把开机时的 USB 日志挤出 dmesg 环形缓冲。

`tests/usb-host.sh` 在 PC 上跑，由移植用的测试工具在测试内核在线时调用（见 [../../dev/README.md](../../dev/README.md)）：
双向传随机数据并校验（`USB_BULK_MB`，默认 256），再在 L410 上用 `systemd-run` 脱离当前 ssh 连接做 3 次 glue 解绑/绑定，等网络回来后检查
RTL8153 回到 5000M、PHY init 计数加 1。

手工看：

```bash
lsusb -t
dmesg | grep -iE "kirin990|dwc3|xhci"
cat /sys/kernel/debug/clk/clk_summary | grep -i usb     # 需要 root
```

移植初期 UFS 根分区还挂不上时，`dev/bringup/usb-initramfs/` 给诊断 initramfs 加了 USB 网卡 DHCP 和一个小 HTTP 服务，可以从 PC 验证整条链路。

## 没做的

- OTG / gadget、BC1.2 充电检测、Type-C PD（`hisilicon,pd`、fusb、tusb 那些）、HiFi USB（音频子系统共用 USB2 PHY）、DP4 独占模式。
- 系统睡眠时 PHY 的 suspend/resume。s2idle 下不需要，deep 睡眠本身还不能用。
- DP 输出：TCA 固定在 USB3.1 + DP 2 lane、正插；DP 那两条 lane 的 HPD 和切换要等 DP/HDMI 驱动（见 [graphics.md](graphics.md)）。
  如果 DP 要用别的 mux 模式（DP4），切换时 USB 必须先断开，要和这个 PHY 驱动协调。
- `CONFIG_EXTRA_FIRMWARE` 是单个字符串，现在写在 `40-usb.config` 里。别的子系统也要内建固件时，要合并到同一个配置片段。

## 试过但没用

- 对路由器 flood ping 测丢包：丢 61%，是路由器对 ICMP 限速，和 USB 无关，测试里已不用。
