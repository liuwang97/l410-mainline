# 华为擎云 L410 运行主线 Linux 6.18 + Debian

华为擎云 L410（型号 KLVU-WDU0B，麒麟 990 + Mali-G76）出厂装的是麒麟 V10，内核是厂商的 4.19.71-kr990。
这个仓库和配套的内核仓库让它跑 Linux 6.18 LTS 和 Debian（forky，KDE Plasma 6.7 Wayland），
GPU 用开源的 Panfrost/Mesa，不再依赖厂商内核和闭源 libmali。

| 仓库 | 内容 |
|---|---|
| [linux-l410](https://github.com/liuwang97/linux-l410)（分支 `l410-6.18`） | 内核：上游 v6.18.54 之上的 L410 驱动、设备树修补、配置片段和构建脚本 |
| 本仓库 | 在一台新 L410 上装 Debian 的脚本、系统配置、测试脚本、各硬件的调试记录 |

## 硬件状态

| 部件 | 状态 | 说明 |
|---|---|---|
| CPU：4×A55 1.86 GHz + 2×A76 2.09 GHz + 2×A76 2.86 GHz | 可用 | 三簇调频、EAS、cpuidle、温控（90 °C 降频，105 °C 关机） |
| 存储：UFS 3.1 | 可用 | HS-G4 双通道，顺序读约 1.6 GB/s；固件分区所在的 LUN 只读 |
| USB 3.1、板载 hub、摄像头 | 可用 | |
| 有线网 RTL8168 | 可用 | PCIe |
| WiFi / 蓝牙 Hi1103 | 可用 | WPA2、WPA3；需要从机器自带的麒麟拷固件（部署脚本自动做） |
| 屏幕 2160×1440 eDP | 可用 | 60 Hz，关屏时整条显示链断电，硬件光标，背光 |
| GPU Mali-G76 MC16 | 可用 | Panfrost，OpenGL ES 3.1 / OpenGL 3.1（Mesa 26.1） |
| 声卡 Hi6405 + 2×TAS2562 | 可用 | 扬声器、耳机、内置麦克风 |
| 键盘、触控板、F 行热键、电池、合盖 | 可用 | |
| 睡眠 | s2idle 可用 | deep 唤醒会变成冷启动，默认不用 |
| 硬件视频解码 | 可用 | H.264、HEVC（含 10 bit）、VP9、VP8、MPEG-2；GStreamer 自动使用，Chromium 由 `system/install.sh video` 打开 |
| DP/HDMI 输出、指纹、硬件视频编码 | 不支持 | |

各部件的细节在 [docs/hardware/](docs/hardware/)，已知问题见 [docs/known-issues.md](docs/known-issues.md)。

## 在一台新的 L410 上安装

需要：

- 一台 L410（KLVU-WDU0B），保留出厂麒麟（GRUB、WiFi 固件都从它来）；
- UFS 上一个至少 32 GB 的空分区给 Debian（出厂分区表没有空闲空间，要先从 DATA 分区缩出来，见安装文档）；
- 一台 x86-64 的 Debian/Ubuntu 电脑或 Windows 的 WSL 2，用来编内核和生成根文件系统；
- U 盘或网络，把文件拷到 L410。

步骤概要（完整说明见 [docs/install.md](docs/install.md)）：

```bash
# 1. PC 上：编内核
git clone -b l410-6.18 https://github.com/liuwang97/linux-l410.git
linux-l410/l410/build.sh -o l410-build

# 2. PC 上：生成 Debian 根文件系统（arm64，用 qemu-user 跑软件包的安装脚本）
git clone https://github.com/liuwang97/l410-mainline.git
sudo l410-mainline/rootfs/mkrootfs.sh --user <用户名> l410-debian.tar.xz

# 3. L410 的麒麟里：写入分区、拷 WiFi 固件、装内核、加 GRUB 启动项
sudo l410-mainline/rootfs/deploy.sh --part /dev/sddN --format \
    --rootfs l410-debian.tar.xz --kernel l410-build/bundle

# 4. 重启进 Debian，补做需要真机的配置，然后注销重新登录
sudo /opt/l410/system/install.sh

# 5. 自检
sudo bash l410-mainline/tests/quick.sh
```

## 目录

| 目录 | 内容 |
|---|---|
| [boot/](boot/) | 装内核（`install-kernel.sh`）、在麒麟的 GRUB 里加启动项（`grub-entry.sh`） |
| [rootfs/](rootfs/) | 生成根文件系统（`mkrootfs.sh`）、软件包清单、在 L410 上部署（`deploy.sh`）、要从麒麟拷的固件清单 |
| [system/](system/) | Debian 的系统配置，`system/install.sh` 按阶段安装：基础、桌面、硬件、电源模式、调度器、内存、触控板、视频硬解、Mesa、启动速度、应用 |
| [tests/](tests/) | 在 L410 上跑的测试：`quick.sh` 一分钟自检，各子系统测试，`bench/` 性能测量工具 |
| [tools/](tools/) | 诊断信息收集 |
| [docs/](docs/) | 安装、内核、硬件、调优、测试文档 |
| [dev/](dev/) | 移植时用的无人值守测试工具（单次启动、看门狗、pstore、远程部署），普通安装用不到 |

## 文档

- [docs/install.md](docs/install.md)：安装和升级
- [docs/kernel.md](docs/kernel.md)：内核源码结构、构建、启动参数、出问题时怎么取日志
- [docs/kernel-config.md](docs/kernel-config.md)：内核配置片段
- [docs/hardware/](docs/hardware/)：SoC 时钟与核间通信、电源与温控、UFS、USB、PCIe、WiFi/蓝牙、音频、显示与 GPU、视频解码、笔记本外设、睡眠
- [docs/tuning/](docs/tuning/)：电源模式与性能、桌面帧延迟、sched_ext、内存、应用启动速度、触控板滚动、桌面
- [docs/testing/](docs/testing/)：自检套件、测试计划、最近一次回归结果

## 许可

本仓库的脚本和文档按 GPL-2.0 发布（见 [LICENSE](LICENSE)）。`system/` 里给 Mesa、libinput、scx、systemsettings 的补丁沿用各自项目的许可。
WiFi/蓝牙固件不在仓库里，部署时从同一台机器的麒麟系统复制。
