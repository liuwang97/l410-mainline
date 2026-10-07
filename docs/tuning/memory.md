# 内存调优

L410 只有 8 GB 内存，存储是 UFS。Debian 默认既没有 swap 也没有 systemd-oomd，内存用满时只能等内核 OOM 杀进程。
这里的配置分几层：zswap 加 UFS 上的 swapfile 接住超出物理内存的部分；MGLRU、THP 和 sysctl 让回收更平稳；
systemd-oomd 在压力持续时杀掉占用最大的应用；cgroup 保护让桌面会话最后才被回收。

| 层 | 内容 | 文件 |
|---|---|---|
| 内核 | zswap 开机启用（zstd，shrinker 开）、MGLRU、THP 默认 madvise | 内核树 `l410/configs/98-memory.config` |
| 压缩交换 | 8 GB `/swapfile`，zswap 池上限 25% | `system/mem/install.sh swap`、`mem-tune` |
| 回收 | MGLRU `min_ttl_ms=1000`，THP defrag `defer`，vm sysctl | `mem-tune`、`systemd/mem-tune.service`、`90-l410-memory.conf` |
| OOM | systemd-oomd：用户会话内存压力 50% 持续 10 s，或 swap 用量超过 90% | `systemd/*-l410-oomd.conf`、`oomd.conf.d-l410.conf`、`l410-oomd-resync@.*` |
| 保护 | `user.slice`、`user@.service`：memory.low 75%、memory.min 25%；`session.slice`：memory.min 768M | `systemd/*-l410-mem.conf` |
| IO | UFS 各 LUN 用 mq-deadline | `60-l410-iosched.rules` |

所有文件都在 [system/mem](../../system/mem)。

和性能配置（[system/perf](../../system/perf)）不冲突：`l410-perfd` 只写 `cpu.uclamp.min`，不碰内存接口；tuned 的三个档位不改 vm sysctl。

## 内核部分

`l410/configs/98-memory.config`：

| 选项 | 作用 |
|---|---|
| `CONFIG_ZSWAP=y`、`ZSWAP_DEFAULT_ON`、`ZSWAP_SHRINKER_DEFAULT_ON`、`ZSWAP_COMPRESSOR_DEFAULT_ZSTD` | 压缩的 swap 缓存，开机即启用，用 zstd，冷页由 shrinker 自己写回 swapfile |
| `CONFIG_ZSMALLOC=y`、`CONFIG_CRYPTO_ZSTD=y` | zswap 的分配器和压缩算法，原来是模块，改成编进内核 |
| `CONFIG_LRU_GEN=y`、`LRU_GEN_ENABLED` | 多代 LRU（MGLRU），开机启用 |
| `CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y`（不选 `ALWAYS`） | 透明大页只给调用 `madvise()` 的程序，原来默认是 `always` |

原来的内核没开 zswap 和 MGLRU；PSI、MEMCG、UCLAMP_TASK_GROUP、能耗模型、PREEMPT 早就有。

内核里另有一个相关修复：极限内存压力下，6.18 新的 swap table 在 kswapd 里做睡眠分配必然失败（PF_MEMALLOC 下既不能回收，又因为
`__GFP_NOMEMALLOC` 用不了保留内存），失败已经被正确处理（簇放回空闲链表，页留在内存里等下一轮），但每次都打出整页 Mem-Info。
提交 `mm, swap: don't warn when the sleeping swap table allocation fails`（`mm/swapfile.c`）给它加了 `__GFP_NOWARN`。

## 压缩交换：zswap + swapfile

- `/swapfile` 默认 8 GB（`SWAP_SIZE` 可改）。ext4 上用 `fallocate` + `mkswap`，btrfs 上用 `btrfs filesystem mkswapfile`，写进 `/etc/fstab`。
  用 `rootfs/deploy.sh` 部署时它已经建好（`--swap 8G`，`0` 表示不建）；在镜像构建的 chroot 里这一层跳过。
- 如果系统里已经有 zram swap，`install.sh` 会停下来：zram 加上磁盘 swap 会让 LRU 倒置，先关掉 zram 的生成器。
- zswap 参数由 `mem-tune` 开机设置：压缩器 zstd，池上限 `max_pool_percent=25`（约 2 GB，满了以后新换出的页直接写 UFS），shrinker 开。
- 超出物理内存的部分先进 zswap（压缩后留在内存里），冷页由 shrinker 写回 UFS。

## 回收：MGLRU、THP、sysctl

`mem-tune`（`mem-tune.service` 开机运行一次）设内核没有 Kconfig 默认值的运行时参数，缺的文件只报告、跳过：

| 参数 | 值 | 原因 |
|---|---|---|
| `/sys/kernel/mm/lru_gen/min_ttl_ms` | 1000 | 最近 1 s 用过的页不回收；保不住时宁可 OOM，也不来回抖动 |
| `/sys/kernel/mm/transparent_hugepage/enabled` | `madvise` | 同内核默认值 |
| `/sys/kernel/mm/transparent_hugepage/defrag` | `defer` | 缺页时不做同步规整，改为唤醒 kswapd/kcompactd |
| `/sys/module/zswap/parameters/*` | 见上一节 | |

`/etc/sysctl.d/90-l410-memory.conf`：

| sysctl | 值 | 原因 |
|---|---|---|
| `vm.swappiness` | 100 | 匿名页和文件页同等对待，由 MGLRU 按 refault 平衡 |
| `vm.page-cluster` | 0 | 不做换入预读：从 zswap 读邻近页是同步解压 |
| `vm.watermark_scale_factor` | 100 | 水位间隔为内存的 1%（约 80 MB），kswapd 更早开始，分配时很少直接回收 |
| `vm.watermark_boost_factor` | 0 | 碎片事件不触发一阵集中回收 |
| `vm.dirty_background_bytes` | 67108864（64 MB） | 脏页到 64 MB 开始后台写回 |
| `vm.dirty_bytes` | 268435456（256 MB） | 到 256 MB 时写入方被限速 |

`mem-tune.service` 的顺序是 `After=local-fs.target`、`Before=sysinit.target`。**不要改成 `Before=swap.target`**：
`tmp.mount` 在 `swap.target` 之后，`local-fs.target` 又在 `tmp.mount` 之后，会形成顺序环。systemd 为了破环把 `tmp.mount` 从开机事务里删掉，
tmpfs 晚约 10 s 才挂上，盖住了 tmpfiles 已经建好的 `/tmp/.X11-unix`，于是 Xwayland 起不来，ksmserver、kaccess 崩溃。
zswap、LRU、THP 的参数随时可以改，不需要赶在 swap 之前。`tests/quick.sh` 的 `sys.ordering-cycles`、`sys.x11-socket-dir`、`sys.user-units` 检查这类问题。

## systemd-oomd

- `user@.service` 加 `ManagedOOMMemoryPressure=kill`、`ManagedOOMMemoryPressureLimit=50%`；`oomd.conf` 设 `DefaultMemoryPressureDurationSec=10s`。
  用户会话的内存压力超过 50% 并持续 10 s 时，oomd 杀掉这个用户下压力最大的 cgroup（某个 `app-*.scope` 或 `.service`）。
  systemd 262 给 `user@.service` 的默认值也是 50%/10 s。
- `-.slice` 加 `ManagedOOMSwap=kill`，`SwapUsedLimit=90%`：swap 用量（zswap 占的 swap 槽也算）超过 90% 时，杀 swap 用量最大的 cgroup。
- `session.slice` 设了 `ManagedOOMPreference=avoid`，oomd 挑对象时避开它。

systemd 262 上有两个坑，`install.sh` 和单元文件都处理了：

- 刚重启的 systemd-oomd 要等 PID 1 下一次 `daemon-reload` 才拿到 ManagedOOM 的 cgroup 列表，之前 `oomctl` 显示为空。`install.sh oomd` 重启 oomd 后再 reload 一次。
- 开机后才启动的 `user@UID.service`（每次登录）进不了 oomd 的监视列表：单元的 `ManagedOOMMemoryPressure=kill` 是对的，
  但 `oomctl` 的 “Memory Pressure Monitored CGroups” 是空的。oomd 重新订阅时拿到的全量列表是对的，所以 `user@.service` 通过 `Wants=` 拉起
  `l410-oomd-resync@UID.timer`，用户管理器起来 30 s 后 `systemctl try-restart systemd-oomd`。紧跟在用户管理器之后重启
  （开机 16.5 s 时，晚 30 ms）仍然收不到，晚一些才行，30 s 留足了余量。

## 会话内存保护

| 单元 | 设置 |
|---|---|
| `user.slice`（系统级 drop-in） | `MemoryLow=75%`、`MemoryMin=25%` |
| `user@.service`（系统级 drop-in） | `MemoryLow=75%`、`MemoryMin=25%` |
| `session.slice`（用户级 drop-in，`/etc/systemd/user/session.slice.d/`） | `MemoryMin=768M`、`ManagedOOMPreference=avoid` |

内存紧张时先回收 `system.slice` 里的服务，桌面后被回收。保护只沿着每一级祖先都设了保护的路径向下生效（memory_recursiveprot），
所以 `user.slice` 和 `user@.service` 两级都要设。`session.slice` 里是 KWin、plasmashell、PipeWire，768M 是按实测工作集定的固定值。
`install.sh protect` 用 `systemctl set-property --runtime` 把值直接加到正在运行的用户管理器上，不用重新登录。

## IO 调度器

`/etc/udev/rules.d/60-l410-iosched.rules` 给所有 `sd[a-z]`（UFS 的各个 LUN）设 `mq-deadline`。

## 没有做的

- 没有按前台应用动态调整的守护进程，所以没有按焦点分配 memory.low、没有把后台缓存的应用整体压进 zswap、没有 oom_score_adj 分级。
  `session.slice` 用固定的 memory.min 代替按工作集计算的值。
- 应用侧的调整（浏览器标签休眠、`MALLOC_ARENA_MAX`、关掉 baloo）不在这里部署。
- 不用：zram、DAMON_RECLAIM、KSM、移植更新的 zstd、全局 `memory.zswap.writeback=0`。

## 安装与回退

```bash
sudo system/install.sh mem                                            # 全部装上
sudo L410_SYSTEM=$PWD/system bash system/mem/install.sh oomd          # 只装一层：swap | l2 | oomd | protect | iosched
sudo L410_SYSTEM=$PWD/system bash system/mem/install.sh revert        # 全部撤掉，删除 /swapfile
```

装上的文件：

| 层 | 路径 |
|---|---|
| swap | `/swapfile`，`/etc/fstab` 里的一行 |
| l2 | `/usr/local/sbin/mem-tune`、`/etc/systemd/system/mem-tune.service`、`/etc/sysctl.d/90-l410-memory.conf` |
| oomd | 包 `systemd-oomd`；`/etc/systemd/system/user@.service.d/l410-oomd.conf`、`/etc/systemd/system/-.slice.d/l410-oomd.conf`、`/etc/systemd/oomd.conf.d/l410.conf`、`/etc/systemd/system/l410-oomd-resync@.{service,timer}` |
| protect | `/etc/systemd/system/user.slice.d/l410-mem.conf`、`/etc/systemd/system/user@.service.d/l410-mem.conf`、`/etc/systemd/user/session.slice.d/l410-mem.conf` |
| iosched | `/etc/udev/rules.d/60-l410-iosched.rules` |

`revert` 删除上表的配置文件和 swapfile，sysctl 和 sysfs 的值在下次开机时回到内核默认值。它不卸载 systemd-oomd，oomd 之后按 systemd
自带的默认值继续监视用户会话，不需要的话 `sudo systemctl disable --now systemd-oomd`。内核侧的默认值（zswap 开、MGLRU 开、THP madvise）留在内核里；
没有 swap 设备时 zswap 不起作用。

## 验证

```bash
sudo bash tests/mem.sh --no-load                # 只查配置
sudo bash tests/mem.sh --load over --secs 60    # 130% 超量压力 + 受保护的前台探针
```

判定：各项配置正确，swapfile ≥ 7 GiB 且没有 zram，oomd 在监视 `user@<uid>.service`，保护值非零；压力运行中前台探针的 p99 < 250 ms，
超出部分进了 zswap，KWin 和 plasmashell 存活，内核日志干净。直接回收、规整、refault、zswap、PSI 的增量只记录，用于前后对比。
结果写在 `/var/tmp/l410-mem/`，最后一行是 `RESULT: PASS` 或 `RESULT: FAIL (n)`。

另有 `tests/mem-scenario.sh`：Chromium 开 N 个真实网站标签，后台一个占用程序顶住内存，再把每个标签切到前台，用 DevTools 协议测重新渲染的时间。

## 测试结果

`tests/mem.sh --load over --secs 60`，Debian forky，性能档，逐层加上去测。

- 压力源：`system.slice` 里一个 Python 程序，占用 130% 的可用内存；每页 1 KiB 随机数据加 3 KiB 零（压缩比约 3:1），写满后每秒随机访问全部页面。
  这比真实桌面恶劣得多。没用 stress-ng，因为它会把 `--vm-bytes` 自动压到可用内存以内，根本不会超量。
- 前台探针：`app.slice` 里 256 MiB 的工作集，每 100 ms 全部访问一遍。

| 配置 | 占用程序 | OOM | 直接回收次数 / 最长 | 规整停顿 | 文件页 refault | zswap 压出 / 写回 UFS | PSI full 峰值 | 探针 p99 / max |
|---|---|---|---|---|---|---|---|---|
| 基线（无 swap，默认 sysctl；已有 MGLRU） | 涨到约 6 GB 被内核 OOM 杀掉 | 1 | 908 / 9.2 ms | 2414 | 11748 | 无 | 4.3% | 19.5 / 23.9 ms |
| + 8 GB swapfile、zswap | 拿到 7.96 GB | 0 | 8399 / 79.8 ms | 2605 | 18893 | 379 万页 / 13.5 万页 | 49% | 22.2 / 33.6 ms |
| + sysctl、zswap 池 25%、min_ttl 1 s、THP defer | 8.6 GB | 0 | 7602 / 22.9 ms | 0 | 27555 | 361 万 / 21.7 万 | 45% | 22.8 / 48.7 ms |
| + oomd、cgroup 保护、mq-deadline | 8.6 GB | 0 | 8189 / 19.4 ms | 2 | 11720 | 389 万 / 18.2 万 | 46% | 22.2 / 33.9 ms |

- 基线不抖，但会死：超出物理内存的部分没有去处，内核 OOM 只能杀进程。加上 swapfile 和 zswap 后同样的负载全部活下来。
- THP `defer` 消掉了缺页路径上的同步规整（2605 → 0），最长的一次直接回收从 80 ms 降到 23 ms。
- cgroup 保护让压力先落在 `system.slice` 上，桌面的文件页 refault 从 27555 回到 11720，接近没有压力时的水平。
- 最终配置（本文的全部设置）复测时，前台探针 p99 是 21.6 ms。

oomd 功能测试：在用户的 `app.slice` 里起一个 14 GB 的占用程序，19 s 后 swap 用量超过 90%，systemd-oomd 只杀掉了这个应用的 scope
（`Failed with result 'oom-kill'`），KWin、plasmashell 不受影响。
