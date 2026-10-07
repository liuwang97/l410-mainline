# 应用启动延迟

这份文档记录开始菜单、系统设置、Chromium、Firefox、WPS 和 QQ 的启动时间怎么测、慢在哪里、改了什么。
改之前开始菜单打开要 0.5-1 s，系统设置启动要 2-3 s，目标是这几项都快一倍。

改动由 `system/install.sh` 的 `mesa`、`launch`、`apps` 三个阶段安装（`sudo system/install.sh mesa launch apps`），
大核优先属于 `sched-ext` 阶段。每一项的撤销方法写在各小节里，文末有汇总表。

测量环境：L410，6.18 内核，Debian forky，Plasma/KWin 6.7.4，Mesa 26.1.6，scx_lavd，插电、性能档。
测试机的动画时长系数是 1.5（`AnimationDurationFactor=1.5`，个人习惯，不是调优项）；下面的指标都只算到窗口映射。

## 怎么测

- 指标：从发起启动到 KWin 映射出这个程序的第一个窗口（`windowAdded`）。WPS 先出启动画面，取主窗口（KWin 窗口类型 0）。
- 计时探针是 KWin 脚本 [watch.js](../../tests/bench/launch/watch.js)，窗口映射时往 KWin 日志写一行毫秒时间戳。
- 启动方式和开始菜单一样：每次起一个临时 systemd 单元 `app-<id>@<uuid>.service`，放在 `app.slice` 里。
- 关闭方式和人一样：用 KWin 脚本 `closeWindow` 关窗口（[launch2.sh](../../tests/bench/launch/launch2.sh)），不用信号杀进程。
- A/B：同一时段交替跑，每项 3-5 次。[compare.sh](../../tests/bench/launch/compare.sh) 依次测五个程序；
  [to-original.sh](../../tests/bench/launch/to-original.sh) 和 [to-current.sh](../../tests/bench/launch/to-current.sh)
  在改动前后两种状态之间切换（大核优先、字体、常驻服务）。脚本在 [tests/bench/launch/](../../tests/bench/launch/)，用法见各脚本开头。
- 只在插电性能档下比较。拔掉电源后 PowerDevil 会切到平衡档，那时测的数作废。

测量时容易踩的坑：

- 用 SIGTERM 关 Firefox，它会当成崩溃，下次启动走会话恢复，慢 0.4-0.5 s。
- QQ 停在登录窗口时不进托盘，关掉窗口进程就退出了。
- 强制重新登录（[relogin.sh](../../tests/bench/launch/relogin.sh)：停掉 `graphical-session.target`，再由 sddm 自动登录）之后，
  systemd 用户实例的环境里没有 `DISPLAY` 和 `XAUTHORITY`。Wayland 程序会退回默认的 `wayland-0`，照常工作；
  X11 程序（WPS、QQ）经 systemd 单元启动时会崩溃或明显变慢。修法：从 plasmashell 的 `/proc/<pid>/environ` 取出这几个变量，
  再执行 `systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY`。
  正常登录不受影响；从开始菜单启动的程序也不受影响，因为 plasmashell 会把自己的环境传给它们。
- bpftrace 挂上探针要约 1 s。抓启动阶段的事件，要先挂好、等它输出 ready，再启动程序。
- ssh 里用 `pkill -f <模式>` 会把执行命令的那个 shell 自己也杀掉，要用 `pkill -x`。
- 换了 Mesa 要重新登录，见下面 Mesa 一节。

## 结果

插电性能档，正常关窗口：

| 程序 | 改之前 | 现在，冷启动 | 现在，常驻 | 倍数 |
|---|---|---|---|---|
| 开始菜单，第二次起 | 337 ms | 45 ms | | 7.5× |
| 开始菜单，首次 | 535 ms | 161 ms | | 3.3× |
| WPS 主窗口 | 1116 ms | 422 ms | | 2.6× |
| QQ（到登录窗口） | 1238 ms（中位 1171） | 740 ms | | 1.6-1.7× |
| Chromium | 1489 ms（中位 1295） | 922 ms | 370-400 ms（常驻后第一次 489） | 冷 1.4-1.6×，常驻 3-4× |
| Firefox | 1663 ms（中位 1618） | 1196 ms（中位 1113） | | 1.4-1.45× |
| 系统设置 | 1527 ms | 1356 ms | 180 ms（常驻后第一次 633） | 冷 1.1×，常驻 8× |

QQ 和 Firefox 还没有快到一倍，见"还差的"一节。

## 开始菜单：一次打开约 2500 次 GPU 提交（Mesa panfrost）

开始菜单（Kickoff）第一帧的关键路径是 plasmashell 的 `QSGRenderThread`，每次打开都要连续跑 160-330 ms。
bpftrace 统计，每次打开的约 250 ms 里有约 2500 次 `SUBMIT`、约 680 次 `CREATE_BO`。
系统设置启动时也一样：2626 次提交、约 1150 个缓冲区、约 5000 次 `WAIT_BO`。

原因在 Mesa panfrost。它把大于 16×16 的纹理都建成 AFBC 压缩格式（`panfrost_should_afbc`）。
CPU 每往 AFBC 纹理里写一次，`panfrost_ptr_map/unmap` 都要建一个临时缓冲区、用 GPU blit 过去、再立即 flush
（`"AFBC write staging blit"`），整张图覆写 8 次以上才会转成线性格式。Qt Quick 的每个图标、每个字形都是一次上传，
所以每次上传都是一个新批次：新缓冲区、GPU MMU 映射、mmap、提交。

改法是 [0001-panfrost-convert-private-AFBC-resources-on-CPU-write.patch](../../system/mesa/0001-panfrost-convert-private-AFBC-resources-on-CPU-write.patch)
（构建时由 [mesa-patch.py](../../system/mesa/mesa-patch.py) 打进源码）：私有的 AFBC 资源（非共享、非扫描输出、非深度模板）
第一次被 CPU 写时，用现成的 `pan_resource_modifier_convert` 转成 u-interleaved，有内容就拷一次，没内容就不拷，之后 CPU 直接按 tile 写。
设环境变量 `PAN_AFBC_CPU_WRITE=staging` 可以退回上游行为，方便 A/B。

效果：

- 系统设置启动时的提交从 2626 次降到 64 次。
- 开始菜单第二次起打开从约 300 ms 降到 43-48 ms，首次打开 161 ms。
- 随机间隔连续开关开始菜单 40 次，没有出问题。

不要用全局的 `PAN_MESA_DEBUG=noafbc` 代替这个补丁：Chromium 和 QQ 的渲染目标靠 AFBC 省带宽，关掉后它们反而变慢。

### 构建和安装

文件在 [system/mesa/](../../system/mesa/)。

- [build.sh](../../system/mesa/build.sh) 在 L410 上用已装版本的 Debian Mesa 源码编译（apt 源里要有 deb-src），
  沿用 Debian 的前端选项，版本串不变（例如 `26.1.6-1`）。只编 libgallium，gallium 驱动只留 panfrost、softpipe、llvmpipe。
  和 Debian 的库对比导出符号，只少 AMD/Radeon winsys 和 VA 入口，这台机器都用不到。
- [install.sh](../../system/mesa/install.sh) 把库装到 `/usr/local/lib/l410-mesa/`，再写 `/etc/ld.so.conf.d/00-l410-mesa.conf`。
  这个文件排在多架构目录之前，所以优先加载；Debian 的包不动。`system/install.sh mesa` 在发布文件里有对应 Mesa 版本的预编译库时直接用它，
  没有时提示用 build.sh 编，再 `install.sh --so <文件>`。
- Mesa 升级后：库名带完整的包版本（`libgallium-26.1.6-1.so`），新的 libEGL_mesa 链接的是新名字，旧的覆盖就不再被加载。
  不会出现加载器和库版本对不上的情况，只是补丁失效。apt 钩子 [99l410-mesa-check](../../system/mesa/99l410-mesa-check)
  在每次 dpkg 运行后检查，覆盖失效时提示重编。

装上或撤掉以后都要重新登录一次，让 KWin 和 plasmashell 一起换库。只重启 plasmashell（新 Mesa）、KWin 还是旧 Mesa 时，
打开几次菜单后 plasmashell 的渲染线程会卡在 Mesa EGL 的 `get_back_bo → wl_display_roundtrip_queue` 循环里（等合成器归还缓冲区），
主线程不再响应 D-Bus。两边都换成新库以后，这个问题没有再出现。

撤销：`sudo rm -rf /usr/local/lib/l410-mesa /etc/ld.so.conf.d/00-l410-mesa.conf /etc/apt/apt.conf.d/99l410-mesa-check && sudo ldconfig`，然后重新登录。

### 内核侧：MMU 忙等

每建一个缓冲区，内核 `panfrost_mmu_map` 里的 `wait_ready` 都要忙等 MMU。上游按 10 µs 间隔轮询，而一次 LOCK 或 FLUSH_PT 只要几微秒，
每次等待都被凑到 10 µs 以上，映射或解除映射一个缓冲区还要等两次。打开两次开始菜单，光忙等就有约 47 ms；
每个程序启动时建缓冲区要 20-56 ms，其中约一半是忙等。
内核分支里的 `drm/panfrost: poll the MMU status every microsecond` 把轮询间隔改成 1 µs（超时仍是 100 ms），它对启动时间的效果还没有单独测。

## 交互程序优先用 A76（scx_lavd 补丁）

lavd 按 `perf_cri` 给任务分大小核，交互程序常被放到 A55 上：

- 开始菜单的渲染线程有 3/4 的时间在 A55 上（算力 283，A76 中核 767、大核 1024），耗时比在大核上多一倍。
- 系统设置的主线程有 0.3-0.45 s 在小核上。只用 A55 时系统设置启动超过 4 s，只用 A76 大核时 1.27 s。

补丁 [0002-scx_lavd-prefer-big-cores-for-user-tasks.patch](../../system/sched-ext/patches/0002-scx_lavd-prefer-big-cores-for-user-tasks.patch)
给 lavd 加了 `--prefer-big-uid N` 和 `--prefer-big-wait-pct`（默认 260）：

- 适用于 uid ≥ N、nice ≤ 0、不是 SCHED_IDLE 或 SCHED_BATCH、不是内核线程的任务。
- 上次所在的核如果是空闲的 A76 就用它；否则按大核 6/7、中核 4/5 的顺序找空闲的 A76。
- A76 全忙时，挑预计最先空出来的一颗。预计等待 = 正在运行的任务预计结束时间 + 该核自己的队列 + 大核域队列的均摊。
  预计等待不超过任务平均运行时间的 260%（限制在 1-8 ms）时，进这颗核的每核队列排队。用每核队列，是因为空闲的 A55 不会去偷每核队列里的任务，域队列里的会被偷走。
  超过这个预算才交回 lavd 原来的选核逻辑，这时才可能放到 A55。
- 260% 的依据：同样的活 A55 约慢 3.6 倍，等待超过运行时间的 2.6 倍时，放到 A55 反而先做完。

[scx-run](../../system/sched-ext/scx-run) 在平衡档和性能档自动加 `--prefer-big-uid 1000`，省电档不加；lavd 二进制不认识这个选项时也不加。
[build-cross.sh](../../system/sched-ext/build-cross.sh) 和 build-native.sh 编译前会打上 `system/sched-ext/patches/` 里的补丁。

电池供电、平衡档（lavd 开着核心收拢）下同样生效：QQ 主线程在 A55 上的时间是 0-20%，Firefox 0-1%，其余时间在 A76 大核和中核之间。
WPS 主线程仍有 8-37% 的时间在 A55 上：四颗 A76 都忙（WPS 自己、wpscloudsvr、Xwayland、KWin 的实时线程）时，按设计退回 A55。

撤销：换成不带这个补丁编译的 `/usr/local/bin/scx_lavd`（scx-run 发现它不认识这个选项就不加），再 `sudo systemctl restart scx-lavd`。
lavd 本身见 [sched-ext.md](sched-ext.md)。

## 字体：2540 个里有 2072 个是 noto-extra

`fonts-noto` 元包会拉进 `fonts-noto-extra`（1540 个文件）和 `fonts-noto-ui-extra`（532 个），都是稀有文字和额外的字重、字宽。
每次字体匹配、每个 Qt 程序启动时枚举字体库，都要把全部字体扫一遍；Chromium 的浏览器进程光 fontconfig 就花 200 ms。

用只剩 468 个字体的配置做 A/B：Chromium 快 20%，Firefox 快 15%，WPS 快 24%，系统设置快 6%。

`launch` 阶段卸掉 `fonts-noto fonts-noto-extra fonts-noto-ui-extra fonts-noto-unhinted`，保留 core、ui-core、cjk、cjk-extra、color-emoji、mono，
并把它们标成手动安装。默认、中文、serif、monospace 的匹配结果不变；Plasma 只依赖 core 和 ui-core。

撤销：`sudo apt install fonts-noto`。

## RCU 宽限期加速

QQ 启动时，主线程一开始就在 D 状态等了 19 ms，唤醒它的是 `rcu_preempt`，也就是在等 RCU 宽限期。
来源是 Chromium/Electron 沙箱建命名空间、进程迁移 cgroup 时调用的 `synchronize_rcu`。

[l410-rcu-expedited.conf](../../system/launch/l410-rcu-expedited.conf)（tmpfiles.d）在开机时把 `/sys/kernel/rcu_expedited` 写成 1。
A/B：WPS 快 14%，QQ 快 8%，系统设置快 4%，Chromium 和 Firefox 各快 3%。

功耗：加速的宽限期要靠 IPI 唤醒各个 CPU，但只在有人调 `synchronize_rcu` 时才发生。电池供电、平衡档、桌面空闲时交替测了两轮，每轮 60 s：
写 0 时平均 846 和 844 mA，写 1 时 843 和 857 mA，差别在 EC 电流读数的误差（约 1%）以内。
如果以后在轻载场景下测出差别，可以改成只在性能档打开。

撤销：删掉 `/etc/tmpfiles.d/l410-rcu-expedited.conf`；当场生效用 `echo 0 | sudo tee /sys/kernel/rcu_expedited`。

## WPS：启动时同步调用 hostnamectl

WPS 主线程会 `popen("hostnamectl")`，这会经 D-Bus 激活 systemd-hostnamed，主线程要等约 60 ms。

[/usr/local/bin/hostnamectl](../../system/launch/hostnamectl) 是一个带缓存的包装，在 PATH 里排在 `/usr/bin` 前面：

- 带参数的调用原样交给 `/usr/bin/hostnamectl`。
- 不带参数的状态查询从按 boot_id 区分的缓存里返回（缓存放在调用者的 `$XDG_RUNTIME_DIR`），
  `/etc/hostname`、`/etc/os-release`、`/etc/machine-info` 有变化时重建。
- 输出和原工具逐字节相同。

5 轮交替：808 ms → 683 ms。撤销：删掉 `/usr/local/bin/hostnamectl`。

## WPS：每次启动做两次 RSA-4096 私钥解密

WPS 自带的 libcrypto 是定制的 OpenSSL 1.1.1zb：带 SM2 和一组 ENGINE 钩子，按 `linux-generic32` 编译（纯 C，32 位）。
它的 `libkccservice` 每次启动都用自带的私钥做两次 `RSA_private_decrypt`（PKCS#1 v1.5，输出 178 和 314 字节），
都在主线程上，落在大核要 38-65 ms，落在小核要 116 ms。

这个 libcrypto 不能整个换掉：WPS 要用它独有的 7 个符号（`sm2_do_sign`、`ENGINE_ssl_generate_master_secret` 等）。
所以做了一个 LD_PRELOAD 垫片（[system/apps/wps/](../../system/apps/wps/)）：

- 只接管 `RSA_private_decrypt`。静态链入按 linux-aarch64 编译的 OpenSSL 1.1.1w（符号全部本地化），通过 WPS 自己的 `RSA_get0_*` 读密钥。
  [build.sh](../../system/apps/wps/build.sh) 在 PC 上交叉编译。
- 4096 位私钥运算在大核上的下限约 21 ms（`openssl speed`），光换实现收益有限，所以再按 SHA-256（填充方式、模数、密文）缓存结果，
  放在 `$XDG_RUNTIME_DIR/l410-fastrsa/`（tmpfs，权限 0700，每次开机清空）。WPS 每次启动解的都是同样两段数据，
  从第二次启动起两次解密都直接命中缓存。
- 校验：`L410_FASTRSA_CHECK=1` 时同时跑 WPS 原来的实现并逐字节比较，8 次全部相同。
  `L410_FASTRSA_NOCACHE=1` 关掉缓存，`L410_FASTRSA_OFF=1` 全部交回 WPS 自己的函数。

[install.sh](../../system/apps/wps/install.sh) 装好垫片库，在 `/usr/local/bin` 放 wps、et、wpp、wpspdf 四个包装脚本，
并把 WPS 的桌面文件复制到 `/usr/local/share/applications`、Exec 改指向包装脚本，这样菜单和文件关联启动都带上垫片。
用 LD_PRELOAD 启动 WPS 本身没有问题。测试中见过的 WPS 启动崩溃是环境里缺 `DISPLAY` 引起的，和垫片无关，见"怎么测"。

撤销：`sudo bash system/apps/wps/install.sh --remove`。

## QQ：GTK 主题解析

Electron 启动时会初始化 GTK 并解析当前 GTK 主题，Breeze 的 `gtk.css` 有 212 KB。QQ 的界面是网页渲染的，用到 GTK 的只有少数原生对话框。
A/B（平衡档）：默认 807 ms，`GTK_THEME=Adwaita` 729 ms，快 10%。

[qq-desktop.sh](../../system/apps/qq-desktop.sh) 在 `/usr/local/share/applications/qq.desktop` 放一个覆盖的桌面文件，只对 QQ 生效。
Firefox 的控件跟随 GTK 主题，换主题外观会变，所以不对它做。

撤销：`sudo bash system/apps/qq-desktop.sh --remove`。

## 常驻：Chromium 和系统设置

这两个程序的冷启动主要花在自身初始化的 CPU 工作上：系统设置要加载 480 个库、QML 和 KCM；Chromium 要初始化浏览器、GPU 和渲染进程。
上面几项加起来也只快 1.1-1.6 倍，所以另外做了常驻。

- Chromium：[l410-chromium-warm.service](../../system/launch/l410-chromium-warm.service) 在登录 20 s 后启动
  `chromium --no-startup-window --keep-alive-for-test`：没有窗口，进程常驻，托盘里有图标，窗口里也不会出现"不支持的命令行参数"提示。
  点 Chromium 时只是在常驻进程里开一个窗口，370-400 ms。从菜单"退出"会结束进程，10 s 后服务重新拉起。
- 系统设置：给 systemsettings 加了 `--resident` 模式（[systemsettings-resident.py](../../system/launch/systemsettings-resident.py)，
  在 L410 上用 [systemsettings-build.sh](../../system/launch/systemsettings-build.sh) 编译，需要 deb-src）。
  常驻实例启动时不显示窗口，关窗口只是隐藏；再次启动 systemsettings 时经 KDBusService 交给常驻实例，回到首页后显示。
  编好的程序装在 `/usr/local/bin/systemsettings`，在 PATH 里排在 `/usr/bin` 前面；不带 `--resident` 时行为和原版一样。
  服务是 [l410-systemsettings-resident.service](../../system/launch/l410-systemsettings-resident.service)。

代价（空闲时实测）：常驻 Chromium 占 288 MB（PSS），常驻系统设置占 94 MB；两者 60 s 内的 CPU 时间都不到 1 s，没有可见的后台唤醒。

两个服务用 `systemctl --global enable` 挂在 `plasma-workspace.target` 下，对所有用户生效。撤销：

```bash
sudo systemctl --global disable l410-chromium-warm l410-systemsettings-resident
systemctl --user stop l410-chromium-warm l410-systemsettings-resident
sudo rm /usr/local/bin/systemsettings      # 只撤系统设置时
```

## 试过但没用

- 关掉 `QT_ACCESSIBILITY=1`（Debian 的 at-spi2-core 设的）：没有改善。
- 64 KB 匿名 mTHP：没有改善，略差。
- Chromium 加 `--password-store=basic`（不经 KWallet）：没有差别。
- QQ 改走原生 Wayland（`--ozone-platform=wayland`）：更慢，1031 ms 对 717 ms。
- Firefox `-silent` 常驻：常驻进程不接受远程开窗口的命令，再启动要 5.8 s。
- WPS `-quickstart`：这个版本直接退出，返回码 255。
- 全局 `PAN_MESA_DEBUG=noafbc`：Chromium 和 QQ 变慢。
- 不带 LLVM 的 libgallium（`NOLLVM=1 system/mesa/build.sh`）：能正常工作，但最小 QML 窗口只快约 8 ms（210 对 218 ms），
  软件渲染的后备还会从 llvmpipe 退成慢得多的 softpipe。没有部署。
- 内核加固选项、CPU 实际频率（PMU 实测 1.86、2.09、2.86 GHz）：查过，没有问题。

## 还差的

- Firefox（1.4-1.45×）：没有单一热点。主线程上 `XRE_main` 自身约 350 ms，其余是 JS、DOM、样式。
  它的 GL 探测进程和主进程各加载一次 libLLVM，每次约 15 ms。`-silent` 常驻不行，常驻只能靠藏起一个窗口，没有做。
- QQ（1.6-1.7×）：Electron 主进程约 550 ms CPU，其中 GTK 和 glib 约 120 ms。走 X11 比原生 Wayland 快。
  QQ 要常驻，得先登录并在 QQ 里设开机自启，没有做。
- 系统设置冷启动：9 个硬件 KCM 的 `KCModuleData` 是同步加载的（`X-KDE-System-Settings-Uses-ModuleData`），挪到首帧之后，实测上限约 10%。
- L3/DSU：实测约 1.4 GHz，档位表最高 1556 MHz，只有约 11% 余量。6.18 上没有驱动给 L3 投票（`hisi,l3-devbw`、`l3c_devfreq` 等节点都没绑定）。
  想在性能档投最高档，要写 PMCTRL 的投票寄存器，必须先对照厂商驱动核实格式。
- WPS：RSA 垫片和缓存装好后，还没有在插电性能档、环境变量正确的条件下和原始状态单独对照过。

## 文件与撤销

| 改动 | 装到哪里 | 仓库里的来源 | 撤销 |
|---|---|---|---|
| Mesa AFBC 补丁 | `/usr/local/lib/l410-mesa/`，`/etc/ld.so.conf.d/00-l410-mesa.conf`，`/etc/apt/apt.conf.d/99l410-mesa-check` | `system/mesa/` | 删掉这三处，`ldconfig`，重新登录 |
| lavd 大核优先 | `/usr/local/bin/scx_lavd`，`/usr/local/lib/l410-perf/scx-run` | `system/sched-ext/` | 换成不带补丁的 scx_lavd，`systemctl restart scx-lavd` |
| 字体 | 卸了 4 个包 | `system/launch/install.sh` | `apt install fonts-noto` |
| RCU | `/etc/tmpfiles.d/l410-rcu-expedited.conf` | `system/launch/` | 删掉这个文件，或往 sysfs 写 0 |
| hostnamectl 缓存 | `/usr/local/bin/hostnamectl` | `system/launch/` | 删除 |
| WPS RSA 垫片 | `/usr/local/lib/l410-wps/`，`/usr/local/bin/{wps,et,wpp,wpspdf}`，`/usr/local/share/applications/wps-office-*.desktop` | `system/apps/wps/` | `install.sh --remove` |
| QQ 桌面文件 | `/usr/local/share/applications/qq.desktop` | `system/apps/qq-desktop.sh` | `qq-desktop.sh --remove` |
| 系统设置常驻 | `/usr/local/bin/systemsettings`，`/etc/systemd/user/l410-systemsettings-resident.service` | `system/launch/` | `systemctl --global disable`，删二进制 |
| Chromium 常驻 | `/etc/systemd/user/l410-chromium-warm.service` | `system/launch/` | `systemctl --global disable` |

在 L410 上编译 Mesa 和 systemsettings 时要在 apt 源里加 deb-src，并装上它们的编译依赖；不再编译时可以删掉。
