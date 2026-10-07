# UFS 存储

L410 的存储只有一颗 UFS 盘（WDC SDINFDO4-512G），没有 SATA、NVMe 或独立 SSD。主控是 Kirin 990 的 UFS 控制器加 Synopsys M-PHY。

6.18 的驱动是主线 ufshcd 的平台 variant：`drivers/ufs/host/ufs-kirin.c`（`CONFIG_SCSI_UFS_KIRIN`，配置片段 `l410/configs/30-ufs.config`），
移植自厂商 4.19 的 `ufs-kirin.c`、`ufs-taurus.c`（Kirin 990 部分）和 `ufs_mphy_firmware.c`（变成 `drivers/ufs/host/ufs-kirin-mphy-fw.h`）。
代码在内核仓库 [linux-l410](https://github.com/liuwang97/linux-l410)（分支 `l410-6.18`）。不需要 DT 修补。

## 硬件

| 项 | 实况 |
|---|---|
| 主控 | `ufs@F8200000`（`hisilicon,kirin-ufs`），Synopsys UFSHCI 3.0，CAP 0x1187071f：32 槽、64 位 DMA、自动 hibern8、带 inline crypto |
| 子系统控制块 | 第二段寄存器 0xf81ff000：上电开关、隔离、参考时钟、复位、PHY SRAM 控制 |
| PHY | Synopsys M-PHY，固件在 SRAM 里。每次 PHY 复位后，主机都要经 UIC 把 6144 个 16 位字写到 PHY 地址 0xc000 起（一个字 5 条 DME_SET，约 3 万条 UIC 命令），实测 74 ms |
| 盘 | WDC SDINFDO4-512G，UFS 3.1，4 KiB 逻辑块 |
| 厂商内核协商结果 | HS-G4、2 lane、FAST 模式、rate B；自动 hibern8 5 ms（AHIT 0xc05） |
| 时钟 | DT 里只有 `clk_ufsio_ref`（clkin_sys 38.4 MHz 的 fixed-factor，没有门控）。UFS 子系统总线时钟（SCTRL SCPEREN4 bit14 + SCCLKDIV9，即 0x1b0 bit14 / 0x274）和器件参考时钟（PMIC `CLK_UFS_EN` 0x43）DT 里都没有，UEFI 开着，厂商驱动也只在初始化和系统休眠时直接写寄存器 |
| 供电 | `vcc-supply = ldo15`（2.55 V，always-on），由 PMIC 调压器驱动注册，见 [power.md](power.md) |

四个 LUN：

| LUN | 设备 | 大小 | 内容 |
|---|---|---|---|
| 0 | sda | 4 MiB | 固件，写保护 |
| 1 | sdb | 64 MiB | 固件，写保护 |
| 2 | sdc | 1.25 GiB，19 个分区 | 固件，写保护 |
| 3 | sdd | 476 GiB | 用户盘（ESP、GRUB、麒麟、Debian 都在这里，见 [../install.md](../install.md)） |

## 驱动

| 钩子 | 做什么 |
|---|---|
| `init` | 映射子系统控制块；取可选时钟 `clk_ufsio_ref`、`ufs_subsys`、`dev_ref`；解析 `ufs-kirin-*` DT 标志；读 SCTRL efuse 的 RX Rhold 位；rpm_lvl = 1，spm_lvl = 3 |
| `hce_enable_notify` PRE | 整个 UFS 子系统复位重上电（厂商 `ufs_soc_init`，去掉 SCTRL 时钟配置）：主控复位、电源开关、SRAM 出低功耗、38.4 MHz 参考时钟、去隔离、器件复位脉冲 |
| `link_startup_notify` PRE | M-PHY 属性、CR 口、加载 PHY SRAM 固件（轮询 UIC，期间关 UCCS 中断）、rate B、TX 均衡、关 TX LCC 等 |
| `link_startup_notify` POST | DL 阈值、恢复时钟门控、关 AH8 下的 power gating |
| `pwr_change_notify` PRE | 协商 HS-G4 / rate B / 2 lane / FAST；G4 用 0 dB 均衡，其他档 3.5 dB；同步长度、PA_TActivate、关 TX adapt（WDC） |
| `apply_dev_quirks` | 每次器件初始化（含各种复位之后）置 fPowerOnWPEn 并回读，见下 |
| `fixup_dev_quirks` | WDC/SanDisk 盘加 `UFSHCD_CAP_KEEP_AUTO_BKOPS_ENABLED_EXCEPT_SUSPEND`（厂商对 SanDisk 从不关 auto-BKOPS） |
| `device_reset` | 子系统控制块里的 RST_n 脉冲 |
| `suspend`/`resume`（只在系统睡眠时） | 关/开 PHY 参考时钟和（可选的）器件参考时钟 |
| `set_dma_mask` | 64 位 |

模块参数（内建，写在命令行上）：

| 参数 | 默认 | 作用 |
|---|---|---|
| `ufs_kirin.full_init` | 1 | 0 = 不复位子系统、不加载 PHY 固件，只做 HCE，沿用 UEFI 留下的 PHY 状态（调试用） |
| `ufs_kirin.protect_fw_luns` | 1 | 0 = 不给固件 LU 上电写保护 |

UFS 核心（`drivers/ufs/core`）改了两处：

- `scsi: ufs: core: export ufshcd_query_flag()`：把 `ufshcd_query_flag()` 导出到 `include/ufs/ufshcd.h`，主线没有给 host 驱动用的 query 接口。
- `scsi: ufs: core: detect auto-hibern8 errors without an active UIC command`：6.18 的 `ufshcd_uic_cmd_compl()` 在没有正在执行的 UIC 命令时
  直接 `goto unlock`，而自动 hibern8 进出失败（UHES/UHXS）恰好发生在没有 UIC 命令的时候。中断被当成 "Unhandled interrupt" 丢掉，错误处理不启动，
  链路一直坏着，直到 SCSI 超时（实测卡 60 s，abort 失败后才复位）。现在先检查 AH8 错误再看有没有命令，出错后 170-230 ms 内恢复，读写不报错。

运行时电源管理和厂商一样：rpm_lvl 1（器件 active + 链路 hibern8），spm_lvl 3（器件 sleep + 链路 hibern8）。驱动不改自动 hibern8 定时器；
装了 `system/perf` 后，三档分别设成 5、20、150 ms（省电、平衡、性能），LU 空闲 2 s 后 runtime suspend。s2idle 睡眠唤醒后 UFS 正常。

没有移植：inline crypto / FBE（要安全世界写密钥）、RPMB、HPB、厂商 mas_blk IO 调度、DFX 计数器和黑匣子、FPGA 上的 "HISI MPHY TC" 路径、
Hi1861 的 VCC 断电重启。

## 固件 LU 写保护

厂商内核用 `CONFIG_SCSI_UFS_LUN_PROTECT` 保护 LUN0-2。6.18 刚移植时没有这层，sda-sdc 报 `Write Protect is off`。这三个 LUN 绝对不要写。现在有两层：

1. 驱动：每次器件初始化后置 fPowerOnWPEn 并回读。LUN0-2 的 bLUWriteProtect 是“上电写保护”，置了这个 flag 后器件自己拒绝写命令，
   内核日志里 sda-sdc 报 `Write Protect is on`。和厂商做法一样，只置易失 flag，不写描述符。
2. udev 规则 [system/hardware/60-l410-ufs-fw-ro.rules](../../system/hardware/60-l410-ufs-fw-ro.rules)（`system/install.sh` 的 hardware 阶段装到 `/etc/udev/rules.d/`）：按 UFS 主机路径和 SCSI LUN 匹配，不依赖 sdX 名字
   （`DEVPATH=="*/f8200000.ufs/host*/target*/*:0:0:[012]/block/*"`），对盘和所有分区执行 `blockdev --setro`，并设 `UDISKS_IGNORE=1`、
   `UDISKS_AUTO=0`，桌面不显示也不自动挂载。

## 怎么检查

```bash
sudo bash tests/ufs.sh
```

脚本只在 `/var/tmp` 下写普通文件（结束删掉），从不直接写块设备，也不碰 sda-sdc。复位用 `SG_SCSI_RESET`（host reset），
运行时 PM 用 `rpm_lvl` 和 `power/control`。检查项：协商结果（`FAST-G4 x2, rate B, 0 dB`）、sda-sdc 写保护、数据校验（顺序 2 GiB、4 路并发、
3000 次随机 O_DIRECT）、host reset 后回到 HS-G4、rpm_lvl 1 挂起恢复、自动 hibern8 压力、错误计数。环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `UFS_TEST_MB` | 2048 | 顺序数据测试的大小（MiB） |
| `UFS_TEST_QUICK=1` | | 跳过数据测试 |
| `UFS_TEST_AH8` | 300 | 每轮自动 hibern8 压力的次数 |
| `UFS_TEST_RPM5=1` | | 也测 rpm_lvl 5（会碰到下面的已知问题） |

实测：M-PHY 固件加载 74 ms，0.31 s 出现 `scsi host0`；O_DIRECT 顺序读 1.6 GB/s；数据校验一致；AH8 压力 300 次 0 错；
从 UFS 启动 Debian 到 multi-user.target 约 6.4 s（内核 0.44 s + 用户态 6.0 s）。

手工看：

```bash
dmesg | grep -E "ufshcd-kirin|Write Protect"
cat /sys/bus/platform/devices/f8200000.ufs/auto_hibern8
cat /sys/bus/platform/devices/f8200000.ufs/rpm_lvl /sys/bus/platform/devices/f8200000.ufs/spm_lvl
```

## 已知问题：器件断电恢复后第一次自动 hibern8 退出失败

只在 rpm_lvl 或 spm_lvl 为 5、6（器件断电 + 链路关）时出现，默认级别碰不到。每种重新初始化路径各 6 轮，每轮之后做 20 次“读一下、空闲 0.2 s”，
迫使链路反复进出 AH8：

| 路径 | AH8 退出失败 |
|---|---|
| 空闲（不重新初始化） | 0/6 |
| host reset（错误处理，整套重新初始化，含 RST_n） | 0/6 |
| rpm_lvl 1（器件 active + 链路 H8） | 0/6 |
| rpm_lvl 3（器件 sleep + 链路 H8） | 0/6 |
| rpm_lvl 4（器件 powerdown + 链路 H8，不复位） | 0/6 |
| rpm_lvl 5（器件 powerdown + 链路 off，恢复时整套重新初始化） | 6/6，每次恢复后恰好一次 |
| rpm_lvl 5，恢复后先空闲 5 s | 6/6 |

时间很固定：恢复（固件加载）后约 2.04 s 内的 H8 退出都正常，之后的第一次 H8 退出必然失败（HCS.UPMCRS = 5，host 侧两条 RX lane 停在 HIBERN8，
也就是器件没回应）；错误处理整套复位之后不再出现。只有“从 PowerDown 经复位回来”这一条路径触发，推测是 WDC 器件固件在这种复位后约 2 s 做的某个内部动作。
厂商内核运行时从不让器件断电，所以碰不到。有了上面的核心修复，这次失败 170-230 ms 内自动恢复，读写不报错。

## 没做的

- 子系统总线时钟和器件参考时钟没有建模。驱动留了可选时钟 `ufs_subsys`、`dev_ref`：将来给 SCTRL 的 gate/div 或 PMIC 的门控建节点后，
  在 UFS 节点加 `clock-names` 即可。目前刻意不加：`dev_ref` 的 PMIC 门控在 probe 时要经 PMIC regmap 写寄存器，出错会让整个系统丢根文件系统，
  收益只是休眠时省一点电。
- inline crypto、RPMB、HPB 等（见上）。

## 试过但没用

- rpm_lvl 5 恢复后先空闲 5 s 再访问：AH8 退出照样失败一次，等待不能绕过。
