# 移植用的测试工具

这里是把内核移植到 L410 时用的工具。机器没有串口，测试时也没人守在旁边，所以每次试新内核都要保证：
起不来能自己回到能用的系统，崩溃日志能取回来。普通安装用不到这些，装好的系统里默认也都是关着的。

## 思路

```
PC (WSL)                                   L410
build ──► bundle ──scp──► Debian 分区 /boot/l410/
                      grubenv next_entry=l410-test（只这一次）
                      reboot ──► GRUB l410-test 项 ──► 6.18 内核
                                   │ 正常：ssh 回来，跑测试脚本，取日志
                                   └ 挂死：deadman 看门狗复位 ──► 默认项（麒麟）
                                                         ──► 从麒麟取 pstore 里的上一次控制台日志
```

| 机制 | 在哪 | 作用 |
|---|---|---|
| 单次启动 | `grub-custom.cfg`（装到 SYSBOOT 的 `grub/custom.cfg`）的 `l410-test` 项，`grubenv` 的 `next_entry` | 试新内核只启动一次，下次重启自动回默认项 |
| 回退目标 | `grubenv` 的 `l410_fallback` | 测试启动之后的那次重启改去指定项（例如另一个能连 WiFi 的系统），而不是默认项 |
| deadman 看门狗 | 内核 `drivers/soc/hisilicon/l410-deadman.c`（`CONFIG_L410_DEADMAN`） | early_initcall 里启动 SP805 WDT0（0xfe026000，32.768 kHz，复位已接通），`l410_deadman=<秒>`，默认 600；`/sys/kernel/l410_deadman/timeout` 续期或写 0 停掉。中断在这台机器上走 FIQ，实际在设定值一半时 panic，到点硬复位兜底 |
| 自动回退 | Debian 上的 `l410-revert.service`（`prep-test-debian.sh` 生成） | 开机 15 分钟内没人 `touch /run/l410-keep` 就重启回默认项 |
| 崩溃日志 | ramoops（0x26e00000，1 MiB，`reserved-memory/pstore-mem`，布局和厂商内核相同） | 6.18 的控制台日志留在内存里，复位后由麒麟的 systemd-pstore 归档到 `/var/lib/systemd/pstore/` |
| 诊断 initramfs | 内核树 `l410/initramfs/init` 的 `l410.mode=probe` | 不挂根分区，把 CPU、中断、未完成的设备探测、块设备、网卡、USB 设备打进内核日志后重启，配合 pstore 看早期启动 |

正式安装的 `boot.cfg` 带 `l410_deadman=0`，看门狗不会启动，也没有 `l410-revert.service`。

## 脚本

脚本里的机器地址、ssh 用户、Debian 分区 UUID 是作者环境的值，用之前按自己的环境改（都在脚本开头）。

| 脚本 | 用途 |
|---|---|
| `l410-harness.sh` | 在 WSL 里跑：部署 bundle、单次启动、等 ssh、跑测试脚本、收日志、回默认项；起不来时从麒麟取 pstore。一次只跑一个（flock） |
| `wifi-deploy.sh` | 只有 WiFi 时用：从 Windows 的 Git Bash 把 bundle 传到 L410（Debian 或麒麟上都行），设 `next_entry` 后重启 |
| `grub-custom.cfg` | `l410-test` 菜单项，带 `l410_fallback` 逻辑 |
| `prep-test-debian.sh` | 一次性准备测试用 Debian：USB 网卡固定地址、ssh 密钥、免密 sudo、`l410-revert.service` |
| `deb-install.sh` | 机器不通外网时，在 PC 下载 deb 再到 Debian 上装 |
| `quick-remote.sh`、`suite-remote.sh`、`mk-suite.sh` | 远程跑 `tests/quick.sh`，或把几个子系统测试拼成一个套件交给 harness |
| `t2-run.sh` | 一键集成回归：quick、桌面配置、内存、性能、各子系统、诊断包，可选烤机和重启循环 |
| `testrig-nosleep.sh` | 测试期间关掉 PowerDevil 空闲自动睡眠（`restore` 恢复） |
| `forky-upgrade.sh` | 把已有的 Debian 13 trixie 原地升级到 forky（带备份、检查）。新装的系统直接就是 forky，用不到 |
| `compat-index.sh`、`compat-summary.py` | 移植前统计厂商 4.19 源码里新内核已删除的接口用法 |
| `bringup/` | 各子系统起步阶段的探测脚本和 initramfs 附加脚本（`*-repack-initrd.sh` 把探测脚本塞进 initramfs） |
| `wifi-diag/` | WiFi/蓝牙诊断：开机自测服务、HCI 压力测试、BFGX 调试开关补丁 |

## 经验

- 在麒麟上用 `/dev/mem` 读没上电或时钟关着的模块会把机器读死。只读厂商内核正在用的模块的寄存器。
- Debian 的 systemd-pstore 删 pstore 记录时会清掉当前控制台缓冲，调试期间把它屏蔽了；内核日志缓冲开到 16 MB（`log_buf_len=16M`）。
- 要用 pstore 追挂死，就让复位后仍回到同一个 6.18 内核（`next_entry` 和 `l410_fallback` 都设成 `l410-test`），
  因为麒麟启动时会覆盖 ramoops 区域。追睡眠挂死时加 `no_console_suspend`，否则日志停在 "Suspending console(s)"。
- s2idle 睡着时 deadman 的半程 FIQ 不会触发（中断被关），只有到点的 SP805 硬复位。
- 机器在麒麟 2403 下运行过以后，DDR 里的保留区和 ASP 子系统会带着它留下的状态经过热复位；6.18 的驱动不能假定没写过的内存或寄存器是干净的（麦克风录音的 LLI 问题就是这样来的，见 [../docs/hardware/audio.md](../docs/hardware/audio.md)）。
