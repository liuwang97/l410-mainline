# system/

把 Debian forky 配成 L410 用的样子。总入口是 `install.sh`，按阶段执行，每个阶段一个目录：

```bash
sudo system/install.sh                 # 全部阶段
sudo system/install.sh perf mem        # 只跑这两个
sudo system/install.sh --user alice    # 指定桌面用户（默认是调用 sudo 的用户）
```

| 目录 | 装了什么 |
|---|---|
| `base/` | 中文 locale、Asia/Shanghai、RTC 本地时间、主机名、桌面用户、ssh、fcitx5 |
| `desktop/` | SDDM（Wayland，可选自动登录）、timesyncd、AppArmor，关掉 smartd 和 networkd-wait-online |
| `hardware/` | UFS 固件 LUN 只读规则、F 行热键 hwdb、regulatory.db 与国家码 CN、Hi6405 的 UCM、fq_codel |
| `perf/` | tuned profile `l410-powersave/balanced/performance`、`profile.sh`、`l410-perfd`、KWin 脚本、systemd 片段 |
| `sched-ext/` | `scx-lavd.service`、`scx-run`、scx 的两个补丁和构建脚本 |
| `mem/` | `mem-tune`、sysctl、systemd-oomd 配置、cgroup 内存保护、IO 调度器规则 |
| `input/` | 打补丁的 libinput（触控板滚动加速）、Chromium 的触控板参数 |
| `mesa/` | panfrost 的 AFBC 补丁、构建脚本、安装脚本、apt 提示钩子 |
| `launch/` | RCU 加速、字体精简、hostnamectl 缓存、常驻 Chromium 和系统设置 |
| `apps/` | WPS 的 RSA 加速垫片、QQ 的桌面文件 |

`lib.sh` 是各阶段共用的函数。`assets.sha256` 是发布页上预编译二进制的校验值，`input`、`mesa`、`sched-ext`、
`launch`、`apps` 在 Debian 包版本匹配时下载它们，否则提示用同目录的构建脚本自己编。

`--chroot` 给 `rootfs/mkrootfs.sh` 用：在还没启动过的镜像里只装文件、启用服务，不碰硬件和运行中的服务。
所以第一次开机后要再跑一次 `sudo /opt/l410/system/install.sh`。

每个阶段做什么、为什么这么做，见 [../docs/install.md](../docs/install.md) 第 6 节和 `docs/tuning/` 下的文档。
