# 安装

在一台出厂状态的华为擎云 L410（KLVU-WDU0B）上装 Debian + Linux 6.18，和麒麟并存。
GRUB、UEFI 都用机器原有的，Debian 只是麒麟 GRUB 菜单里多出的一项。

整个过程分三处做：

| 在哪 | 做什么 |
|---|---|
| PC（x86-64 Debian/Ubuntu，或 Windows 的 WSL 2） | 编内核，生成 Debian 根文件系统 |
| L410 的麒麟 | 腾出分区，写入根文件系统，拷固件，装内核，加 GRUB 启动项 |
| L410 的 Debian | 第一次启动后补完需要真机的配置 |

## 1. 机器上的分区

L410 的存储是一颗 UFS，系统看到四个 LUN：`sda`、`sdb`、`sdc` 是固件分区（引导、TEE、LPM3 固件、设备树等），
不能动；`sdd` 是用户盘。出厂时 `sdd` 大致是：

| 分区 | 卷标 | 用途 |
|---|---|---|
| sdd1 | ESP | UEFI 系统分区，`grubaa64.efi` |
| sdd2 | SYSBOOT | GRUB 配置（`grub/grub.cfg`、`grubenv`）和麒麟内核 |
| sdd3 | SYSROOT | 麒麟根分区 |
| sdd4 | KYLIN-BACKUP | 麒麟备份还原 |
| sdd5 | DATA | 麒麟的 `/data` |

Debian 需要一个新分区，至少 32 GB，建议 50 GB 以上。出厂时没有空闲空间，一般从 DATA 缩出来。
DATA 不是麒麟的根分区，可以在麒麟里卸载后离线缩小。**先备份 DATA 里的东西**，然后（以缩到 150 GB 为例）：

```bash
sudo umount /data                      # 有程序占用就先退出它们，或者从麒麟的恢复模式操作
sudo e2fsck -f /dev/sdd5
sudo resize2fs /dev/sdd5 150G
sudo parted /dev/sdd unit GiB print    # 记下 sdd5 的起点
sudo parted /dev/sdd resizepart 5 <起点+150>GiB
sudo parted /dev/sdd mkpart DEBIAN ext4 <起点+150>GiB 100%
sudo partprobe /dev/sdd
sudo mount /data
```

`resizepart` 的终点必须不小于 `resize2fs` 之后的文件系统大小，算不准就多留几 GB。新分区通常是 `/dev/sdd6`，
下文写作 `/dev/sddN`。

## 2. PC 上编内核

```bash
sudo apt install gcc-aarch64-linux-gnu make bc bison flex libssl-dev libelf-dev \
    device-tree-compiler cpio kmod curl ccache
git clone -b l410-6.18 https://github.com/liuwang97/linux-l410.git
linux-l410/l410/build.sh -o l410-build
```

16 线程的 PC 上第一次完整编译二三十分钟，装了 ccache 之后再编只要几分钟。产物在 `l410-build/bundle/`：

| 文件 | 内容 |
|---|---|
| `Image` | 内核 |
| `l410.dtb` | 固件设备树加 6.18 需要的修补 |
| `initrd.img` | busybox 小 initramfs，按 `root=` 挂根分区 |
| `modules.tar.gz` | 模块 |
| `boot.cfg` | GRUB 片段：内核命令行，`@ROOT_UUID@` 在安装时换成真实值 |

不想自己编，可以下载内核发布页的
[l410-kernel-6.18.54-l410.2.tar.gz](https://github.com/liuwang97/linux-l410/releases/tag/v6.18.54-l410.2)，解开就是同样的 `bundle/`。
内核构建的细节见 [kernel.md](kernel.md)。

## 3. PC 上生成根文件系统

```bash
sudo apt install mmdebstrap qemu-user-static arch-test
arch-test arm64                         # 要输出 "arm64: ok"
git clone https://github.com/liuwang97/l410-mainline.git
sudo l410-mainline/rootfs/mkrootfs.sh --user alice --hostname l410 \
    --snapshot 20261001T120000Z l410-debian.tar.xz
```

常用选项：

| 选项 | 说明 |
|---|---|
| `--user NAME` | 桌面用户，加入 sudo 组；密码用 `--password` 给或运行时输入 |
| `--ssh-key FILE` | 写进该用户的 `authorized_keys`（openssh-server 默认装好） |
| `--autologin` | SDDM 开机直接登录这个用户 |
| `--snapshot STAMP` | 从 snapshot.debian.org 取指定时刻的 forky，软件版本和作者测试时完全一致；不加就用当前的 forky |
| `--mirror URL` | Debian 镜像，例如 `https://mirrors.ustc.edu.cn/debian` |
| `--base` | 只装基础系统，不装桌面 |

软件包清单是 [rootfs/packages-base.txt](../rootfs/packages-base.txt) 和 [rootfs/packages-desktop.txt](../rootfs/packages-desktop.txt)。
生成过程中 `system/install.sh --chroot` 会把系统配置装进镜像（见第 6 节）。
arm64 的安装脚本在 qemu 下运行，完整桌面大约要 30 到 60 分钟，结果是 2 GB 左右的 `.tar.xz`。
生成过程要约 10 GB 磁盘空间，临时目录默认放在输出文件旁边（WSL 的 /tmp 是内存盘，放不下），也可以用 `--tmpdir` 指定。
ssh 主机密钥在生成镜像时产生，一个镜像装多台机器时，在每台上执行
`sudo rm /etc/ssh/ssh_host_* && sudo dpkg-reconfigure openssh-server` 换成各自的密钥。

## 4. 在 L410 的麒麟里部署

把 `l410-mainline` 目录、`l410-debian.tar.xz` 和 `l410-build/bundle` 拷到 L410（U 盘或 scp），在麒麟的终端里：

```bash
sudo l410-mainline/rootfs/deploy.sh --part /dev/sddN --format \
    --rootfs l410-debian.tar.xz --kernel l410-build/bundle
```

`deploy.sh` 依次做这些事：

1. 检查分区：拒绝 sdd1 到 sdd3 和固件 LUN，拒绝已挂载或小于 30 GiB 的分区；`--format` 时格式化成 ext4（卷标 DEBIAN）。
2. 解包根文件系统，写 `/etc/fstab`。
3. 按 [rootfs/firmware.list](../rootfs/firmware.list) 从正在运行的麒麟复制 WiFi/蓝牙固件（厂商固件，不在仓库里）。
   麒麟不在 `/` 时用 `--firmware-from <麒麟根目录>`。
4. 建 8 GB 的 `/swapfile`（`--swap 0` 不建）。
5. 调用 `boot/install-kernel.sh` 把内核装到 Debian 分区的 `/boot/l410/`。
6. 调用 `boot/grub-entry.sh` 在 SYSBOOT 的 `grub/custom.cfg` 里加一项 `Debian (Linux 6.18, L410)`，
   并让下一次启动进 Debian（只这一次，默认项还是麒麟）。加 `--default` 则直接设为默认。

麒麟的 `grub.cfg` 末尾有标准的 `41_custom`，会读同目录的 `custom.cfg`，所以麒麟自己更新 GRUB 配置也不会把这一项冲掉。
麒麟把 SYSBOOT 只读挂在 `/boot`，脚本写之前临时改成可写，写完改回去。

## 5. 第一次启动

重启后 GRUB 直接进 Debian。第一次进入桌面后：

1. 连上网络。网线（板载 RTL8168 或 USB 网卡）插上就自动用 DHCP 连接；WiFi 在 Plasma 右下角连，或者在终端里
   `nmcli dev wifi connect <SSID> password <密码>`。WPA2/WPA3 混合模式的路由器按 WPA2（`wpa-psk`）连接即可。
   有线和 WiFi 都由 NetworkManager 管理，systemd-networkd 不启用。
2. 补完需要真机的配置：

   ```bash
   sudo /opt/l410/system/install.sh
   ```

   这一步会刷新 udev 硬件库、设置 WiFi 国家码、启动电源模式服务、编译或下载 libinput 等（第 6 节）。
3. 注销再登录一次，让 KWin 和 plasmashell 加载新的 Mesa、libinput。
4. 显示缩放：作者的机器用 150%（系统设置 → 显示）。
5. 一切正常后，把 Debian 设成默认启动项：

   ```bash
   sudo /opt/l410/boot/grub-entry.sh "$(findmnt -n -o UUID /)" --default
   ```

   GRUB 菜单里随时可以选回麒麟。

自检：

```bash
sudo bash /opt/l410/tests/quick.sh        # 约 1 分钟，不改动系统；--fast 约 20 秒
```

结果里 FAIL 为 0 即正常，XFAIL 是已知问题（列在脚本开头的 KNOWN 表里）。说明见 [testing/quick-suite.md](testing/quick-suite.md)。

## 6. 系统配置（system/install.sh）

`system/install.sh` 分阶段，可以只跑某几个，例如 `sudo system/install.sh perf mem`。每个阶段可重复执行。

| 阶段 | 内容 | 文档 |
|---|---|---|
| base | 中文 locale、上海时区、RTC 用本地时间（和麒麟共用）、主机名、桌面用户、ssh、NetworkManager 管有线和 WiFi、fcitx5 | |
| desktop | SDDM（Wayland，可选自动登录）、NTP、AppArmor、关掉这台机器上只会报错的服务 | [tuning/desktop.md](tuning/desktop.md) |
| hardware | 停掉固件留下的看门狗 WDT0、UFS 固件分区只读、F 行热键（hwdb）、WiFi 国家码 CN、Hi6405 的 UCM、fq_codel | [hardware/](hardware/) |
| perf | tuned-ppd 三档电源模式、l410-perfd、KWin 脚本、按电源切换模式 | [tuning/perf-power.md](tuning/perf-power.md) |
| sched-ext | 开机启动 scx_lavd | [tuning/sched-ext.md](tuning/sched-ext.md) |
| mem | zswap + swapfile、sysctl、systemd-oomd、会话内存保护、IO 调度器 | [tuning/memory.md](tuning/memory.md) |
| input | 触控板滚动加速（打过补丁的 libinput）、Chromium 触控板滚动倍数 | [tuning/touchpad-scroll.md](tuning/touchpad-scroll.md) |
| video | 视频硬解：Chromium 的 V4L2 解码器参数、GStreamer 的 v4l2codecs | [hardware/vcodec.md](hardware/vcodec.md) |
| mesa | panfrost AFBC 上传修复（打过补丁的 libgallium） | [tuning/launch-latency.md](tuning/launch-latency.md) |
| launch | RCU 加速、精简字体、hostnamectl 缓存、常驻 Chromium 和系统设置 | [tuning/launch-latency.md](tuning/launch-latency.md) |
| apps | WPS、QQ 的启动加速（只处理已安装的） | [tuning/launch-latency.md](tuning/launch-latency.md) |

input、mesa、sched-ext、launch、apps 用到几个本地编译的二进制（libinput、libgallium、scx_lavd、systemsettings、
WPS 的 RSA 垫片）。Debian 的对应软件版本和发布页上预编译文件一致时直接下载（有 sha256 校验，见
[system/assets.sha256](../system/assets.sha256)），否则提示用同目录的构建脚本重新编译。用 `--snapshot` 生成的系统版本总是一致的。

WPS 和 QQ 要自己从官网下载 arm64 的 deb 安装，装好后再跑一次 `sudo /opt/l410/system/install.sh apps`。

## 7. 更新内核

在 PC 上更新 `linux-l410` 并重新 `l410/build.sh`，把 `bundle` 拷到 L410：

```bash
sudo /opt/l410/boot/install-kernel.sh bundle
sudo reboot
```

旧内核保留在 `/boot/l410.prev/`。新内核起不来时，在 GRUB 里选麒麟启动，挂上 Debian 分区，把
`/boot/l410` 和 `/boot/l410.prev` 两个目录换回来即可。

## 8. 卸载

在麒麟里：`sudo l410-mainline/boot/grub-entry.sh --remove` 删掉启动项，再删除或格式化 Debian 分区。
`grub-entry.sh` 第一次修改 `custom.cfg` 时留了一份 `custom.cfg.orig-l410`。

## 和作者的机器有什么不同

作者的测试机还装着另一套麒麟（2403）和一些移植期间的调试服务（单次启动测试、看门狗、自动回退，见
[../dev/README.md](../dev/README.md)），这些普通安装用不到。除此之外，按上面步骤加 `--snapshot 20261001T120000Z`
和 `--autologin` 得到的系统，软件版本和配置与测试机一致。
