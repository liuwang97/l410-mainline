# 内核

源码：[linux-l410](https://github.com/liuwang97/linux-l410) 的 `l410-6.18` 分支，基于上游稳定版 v6.18.54
（gregkh/linux 的同名标签）。L410 的全部改动都在 `git log v6.18.54..l410-6.18` 里。当前标签是 `v6.18.54-l410.1`（86 个提交），
[发布页](https://github.com/liuwang97/linux-l410/releases/tag/v6.18.54-l410.1)有编好的整套文件。

v6.18.54-l410.1 的源码和作者在测试机上验证看门狗、睡眠修复时用的内核相同（只差几处注释）；它比第一版 `v6.18.54-l410` 多了
看门狗接管（修开机约 60 s panic）和 hi110x 的两个睡眠修复。第一版和测试机上跑过整套回归的内核相比，配置相同、设备树逐字节相同，
源码只多了 `drm/panfrost: poll the MMU status every microsecond`（MMU 状态轮询间隔从 10 µs 改成 1 µs）和几处注释。

## 提交是怎么组织的

提交按依赖顺序排，每个驱动是一个提交，后来的修复已经并进去了；本身有独立意义的修复和功能单独成提交。大致顺序：

1. 和 L410 无关、可以单独拿去上游的通用改动：swap 分配告警、`sched_cpu_util()` 计入 sched_ext 负载、i2c-hid 重试、
   UFS core 两处、tas2562 初始音量、DesignWare I2C 的 compatible、panfrost MMU 轮询间隔。
2. 板级基础：移植用的 deadman 看门狗，`l410/` 目录的基础配置片段和设备树修补。
3. SoC 核心：hwspinlock、IPC mailbox、硬件投票、时钟、64 位外设 DMA。
4. 电源：SPMI、PMIC、调压器、IP 电源域、RTC、电源键、温度传感器、cpufreq、外设调压投票。
5. UFS、USB、PCIe、笔记本外设（EC、电池、静音灯）。
6. 性能与睡眠：可切换的 PELT 半衰期、cpufreq 能耗模型、DDR 调频、l410-perf 模式与 boost、系统睡眠。
7. 显示与 GPU：Panfrost 支持 G76 和调频策略、背光 PWM、DSS 驱动及其实时提交、关屏断电、EDID。
8. WiFi/蓝牙（hi110x）和音频（hi6405）：先导入厂商源码，再逐项移植和修复。
9. 发行版配置：sched_ext、桌面/安全/内存相关选项、去掉只会报错的固件设备树内容。
10. 构建脚本、自带的固件设备树和 initramfs、README。

每个子系统的 `l410: ... build inputs` 提交放在该子系统的驱动之后，只含配置片段和设备树修补。

厂商驱动（Hi1103 WiFi/蓝牙、Hi6405 音频）先原样导入麒麟 4.19.71 内核源码包里的版本，再在后面的提交里移植到 6.18，
这样能看清改了什么。

## 构建

在 x86-64 的 Debian/Ubuntu（或 WSL 2）上：

```bash
sudo apt install gcc-aarch64-linux-gnu make bc bison flex libssl-dev libelf-dev \
    device-tree-compiler cpio kmod curl ccache
l410/build.sh -o ../l410-build          # -n NAME 给版本号加后缀，-f FRAG 追加配置片段
```

`l410/build.sh` 做的事：

1. `make defconfig`，再用 `scripts/kconfig/merge_config.sh` 按文件名顺序合并 `l410/configs/*.config`，`olddefconfig`。
2. 编 `Image` 和模块，模块装到临时目录后打包成 `modules.tar.gz`。
3. 把 `l410/dt/l410-firmware.dts` 和 `l410/dt/fixups.d/*.dtsi` 拼起来，用 dtc 编成 `l410.dtb`。
4. 用 Debian 的 busybox-static（从 snapshot.debian.org 按哈希下载）和 `l410/initramfs/init` 做 `initrd.img`。
5. 生成 `boot.cfg`。

内核版本号是 `6.18.54-l410`（`CONFIG_LOCALVERSION="-l410"`），`-n` 的后缀接在后面。

## l410/ 目录

| 路径 | 内容 |
|---|---|
| `l410/configs/00-base.config` 到 `98-memory.config` | 配置片段，按子系统分文件。说明见 [kernel-config.md](kernel-config.md) |
| `l410/dt/l410-firmware.dts` | 固件传给厂商内核的设备树（麒麟下 `/sys/firmware/fdt` 反编译）。沿用厂商的私有绑定 |
| `l410/dt/fixups.d/NN-*.dtsi` | 6.18 驱动需要的修补：PSCI 1.0、ramoops 移进 reserved-memory、各子系统的 compatible、时钟、供电、I2C 总线恢复等 |
| `l410/initramfs/init` | busybox 写的 initramfs |
| `l410/firmware/hisilicon/kirin990-usb31phy.bin` | USB 3.1 combo PHY 固件，`CONFIG_EXTRA_FIRMWARE` 编进内核 |
| `l410/build.sh` | 构建脚本 |

为什么用固件的设备树而不是写一份主线风格的：这台机器的 UEFI 和厂商内核用海思私有的绑定，时钟、调压器、电源域都按
节点名和私有属性描述，几百个节点。沿用它、只修补 6.18 驱动需要的地方，工作量小一个数量级。代价是这份设备树进不了上游。

## 启动

麒麟的 GRUB（2.04，arm64-efi）读 Debian 分区上的 `/boot/l410/boot.cfg`：

```
linux /boot/l410/Image root=UUID=<Debian 分区> ro rootwait l410.mode=root ignore_loglevel printk.devkmsg=on
      panic=10 nokaslr efi=noruntime log_buf_len=16M clk_ignore_unused pd_ignore_unused
      regulator_ignore_unused console=tty0
initrd /boot/l410/initrd.img
devicetree /boot/l410/l410.dtb
```

| 参数 | 原因 |
|---|---|
| `efi=noruntime` | 这台机器的 EFI 运行时服务 GetTime 会缺页，内核调用即崩 |
| `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` | 固件打开的时钟、电源域、电源还有一部分没有对应的 6.18 驱动来认领，不能让内核在启动末尾把它们关掉 |
| `nokaslr` | 固定内核地址，pstore 和崩溃日志里的地址可以直接对照 `System.map` |
| `log_buf_len=16M ignore_loglevel printk.devkmsg=on` | 日志全量保留，出问题时从 pstore 能拿到完整记录 |
| `panic=10` | panic 后 10 秒重启 |
| `l410.mode=root` | initramfs 正常挂根分区（`probe` 是移植期的诊断模式，见 [../dev/README.md](../dev/README.md)） |
| `l410_deadman=0` | 固件在进内核前已经启动了看门狗 WDT0（约 60 s 后到期）。v6.18.54-l410.1 起内核开机就接管并停掉它，这也是默认值；`l410_deadman=<秒>` 则把它当成移植用的 deadman 武装起来。第一版 v6.18.54-l410 在这个参数下不碰 WDT0，开机约 60 s 会 panic，所以 `boot/install-kernel.sh` 安装时去掉它、再由 `l410-watchdog-off.service` 停掉 WDT0，这对新内核也无害 |

GRUB 必须加载未压缩的 `Image`（GRUB 2.04 需要 arm64 Image 头，所以关了 `CONFIG_EFI_ZBOOT`）。

## 出问题时

- 机器没有串口。起不来时，在 GRUB 里选麒麟启动，6.18 最后一次的控制台日志在麒麟的 `/var/lib/systemd/pstore/`
  （ramoops 和厂商内核用同一块内存、同样的布局）。
- 早期启动卡住、连根分区都没挂上：把 `boot.cfg` 里的 `l410.mode=root` 改成 `l410.mode=probe`，initramfs 会把探测状态打进日志后重启，
  再到麒麟里读 pstore。
- 回到上一个内核：`/boot/l410.prev/` 和 `/boot/l410/` 两个目录对换。
- 设备驱动的调试接口大多在 debugfs：显示在 `/sys/kernel/debug/dri/0/`，另有 `asp-pcm`、`hi6405`、`hi6405-card`、
  `kirin-ipc`、`huawei-echub` 等目录，见各硬件文档。

## 跟进新的上游稳定版

L410 的提交和上游没有冲突的地方很少（几个通用改动碰到上游文件），一般可以直接 rebase：

```bash
git fetch https://github.com/gregkh/linux.git tag v6.18.N
git rebase --onto v6.18.N v6.18.54 l410-6.18
```

`l410/build.sh` 不用改。新内核装上以后先跑一遍 `tests/quick.sh`。
