# 触控板双指滚动

在 Chromium 里用双指滚动长页面，滚得非常快，而且感觉没有加速。原因有两个：Chromium 在 Wayland 下把触控板滚动量乘了 12；
libinput 对触控板滚动不做任何加速。处理办法是给 Chromium 加一个开关去掉 ×12，再给 libinput 打补丁，按手指速度乘一个增益。
`sudo system/install.sh input` 两样都装，文件在 [system/input/](../../system/input/)。

## 原因

滚动量从手指到页面经过三层，问题出在第一层和第三层：

| 层 | 做了什么 | 每 mm 手指行程 |
|---|---|---|
| libinput 1.31.3 | 双指滚动走 `touchpad_scroll_filter` → `touchpad_constant_filter`，常数 1000 / 25.4 × 0.9 × 0.2968，与速度无关 | 10.52 单位 |
| KWin 6.7.4 | 乘触控板的 `ScrollFactor`（系统设置 → 触摸板 → 滚动速度），原样作为 `wl_pointer.axis` 发给客户端 | ScrollFactor 0.5 时 5.26 |
| Chromium 154（Wayland） | `WaylandPointer::OnAxis` 把 axis 值当滚轮单位换算：÷10 × 120，等于再乘 12；开关 `WaylandUnscaledTouchpadScrolling` 默认关 | 63 逻辑像素 |

屏幕 2160×1440、缩放 150%、约 7.3 物理像素/mm，按上表：手指移动 1 mm，页面滚约 13 mm；手指滑 15 mm 就翻过一整屏（960 逻辑像素），
抬手后还有惯性。短页面一下就到底，看不出来，长页面才明显。Qt 和 GTK 程序把 axis 值直接当像素，不乘 12。

"没有加速"：libinput 故意不给触控板滚动加速。上游唯一的办法是 1.23 起的自定义加速曲线（custom profile，可以单设 scroll 曲线），
但它会同时取代指针的自适应加速，而且 KWin 6.7 不支持配置它（libkwin 里没有 `libinput_config_accel_*` 符号），GNOME 也不支持。
Chromium 只有抬手后的惯性（fling），没有随速度变化的倍率。光标移动有加速（adaptive），不受这些影响。

触控板本身没有问题：Goodix 27C6:01E0，分辨率 16/15 单位/mm，面板 119×71 mm，HID 描述符和厂商 4.19 内核下逐字节一致。

## Chromium：去掉 ×12

[chromium-touchpad-scroll](../../system/input/chromium-touchpad-scroll) 装成 `/etc/chromium.d/l410-touchpad-scroll`
（Debian 的 `/usr/bin/chromium` 会读这个目录下的每个文件），加上 `--enable-features=WaylandUnscaledTouchpadScrolling`。滚轮走另一条路径，不受影响。

- Chromium 154 没有调倍数的参数。上游 main 后来加了 `scroll_scaling_factor`，默认 2.5。
- 后出现的 `--enable-features` 会顶掉前面的。要开别的 feature，写进这个文件的同一个开关里。
- 装好后重启一次 Chromium（`chrome://restart` 会恢复标签页）。

## KDE 滚动速度保持 1.0

系统设置 → 触摸板 → 滚动速度（`ScrollFactor`）应该保持 1.0。为了压住 Chromium 把它调低没有用处，其他程序会一起变慢：
设成 0.5 时，Dolphin、Konsole、Firefox 的滚动都慢了一半。

除了在系统设置里改，也可以经 D-Bus 改（测试机上触控板是 `event3`），KWin 会自己写回 `~/.config/kcminputrc`：

```bash
busctl --user set-property org.kde.KWin /org/kde/KWin/InputDevice/event3 org.kde.KWin.InputDevice scrollFactor d 1.0
```

## libinput 补丁

[0001-touchpad-speed-dependent-two-finger-scroll-gain.patch](../../system/input/libinput/0001-touchpad-speed-dependent-two-finger-scroll-gain.patch)，
基于 Debian 的 libinput 1.31.3-1。

- 位置：`tp_filter_scroll()`（evdev-mt-touchpad.c）。双指滚动每帧的增量在这里换算，乘上增益 G(v) 后照常进入 `evdev_post_scroll()`。
  起步阈值、方向锁、抬手时的停止事件都不变。边缘滚动、滚轮、按键滚动和指针移动不经过这里。
- 速度 v：本帧手指行程（`raw` 是 x 轴设备单位，除以 x 分辨率得到 mm）加上最近 `window_ms`（默认 50 ms）内各帧的行程，
  除以这些帧的时间间隔之和。一次滑动的第一帧按估计的报告间隔算（libinput 只发本帧的增量，不补发起步前积累的量）。
  `tp_gesture_init_scroll()` 时清空，停顿超过 `gap_ms` 也算新的一次，手指反向时清空窗口。分辨率是 libinput 猜出来的触控板（`is_fake_resolution`）不加速。
- 曲线从 `/etc/l410/scroll-accel.conf` 读。每次开始滑动时 `stat()` 一次，文件变了就重读，调曲线不用重新登录。没有这个文件时用编译进去的默认曲线。
  测试时可以用环境变量 `L410_SCROLL_ACCEL_CONFIG` 指定别的文件；它用 `secure_getenv()` 读，所以在带文件能力的 kwin_wayland 里无效。
- 调试：libinput 的调试日志每帧打印一行 `scroll accel: dt, mm, mm/s, gain`（`libinput debug-events --verbose`）。

### 安装和升级

[system/input/libinput/install.sh](../../system/input/libinput/install.sh)（`system/install.sh input` 会调用它）：

- 按已装 libinput10 的确切版本从 Debian 源下载源码（md5 校验），打上 Debian 自己的补丁和本补丁，用与 debian/rules 相同的选项编译
  （libwacom，无 Lua 插件，依赖和原版逐个比对过）。发布文件里有对应版本的预编译库时直接用它（`install.sh --so <文件>`）。
- 装到 `/usr/local/lib/aarch64-linux-gnu/`。ld.so.conf 先搜这个目录，安全执行模式下 ld.so.cache 依然有效，所以 KWin 也会用它；Debian 的文件一个都不动。
- KWin 下次启动（重新登录）才加载新库。确认已经加载：`sudo grep libinput /proc/$(pgrep -x kwin_wayland)/maps`。
- apt 钩子 `/etc/apt/apt.conf.d/80-l410-libinput` 调 [l410-libinput-check](../../system/input/libinput/l410-libinput-check)：
  libinput10 一换版本，就把本地库挪到 `/usr/local/lib/aarch64-linux-gnu/l410-disabled/`，免得新 KWin 要的新符号在旧库里找不到、桌面起不来。
  之后滚动回到线性，重跑 install.sh 即可。
- 卸载：`sudo system/input/libinput/install.sh remove`，下次登录起用回 Debian 的 libinput（`/etc/l410/scroll-accel.conf` 保留）。

### 不要用 LD_PRELOAD

kwin_wayland 带文件能力 `cap_sys_nice=ep`，glibc 对它处于安全执行模式：只会预加载系统库目录里、按裸名字给出、带 set-user-ID 位的库。
这样的库任何用户都能预加载进 sudo 之类的程序，以 root 身份运行，是本地提权漏洞。往 KWin 里预加载补丁库的实验试过，已经删除，不要这样做。
改 libinput 本身不需要任何特权。

## 加速曲线

### 参考来源

| 系统 | 速度怎么量 | 慢速 | 形状 | 峰值 | 可信度 |
|---|---|---|---|---|---|
| ChromeOS（gestures 库 `accel_filter_interpreter.cc`，默认 Scroll Sensitivity 3） | 手指 mm/s，逐帧 `hypot(dx,dy)/dt`，dt 限 3-50 ms | 增益 1；输出 2.5 × 133/25.4 = 13.1 DIP/mm，按 133 DIP/英寸约 2.5 mm 页面 / mm 手指 | 75 mm/s 以下 1，之后 v/75（输出速度 ∝ v²），600 mm/s 以上 1 + 4200/v | 8 倍 @ 600 mm/s，1000 mm/s 回到 5.2 | 常数、单位、默认档全在开源代码里；git 历史显示是按手感调的（2012 年"feels better on device"，2013 年因为"一划到底"降低高档位） |
| macOS（IOHIDFamily `IOHIDParametricAcceleration`，M1 Pro 真机 ioreg：`HIDTrackpadScrollAcceleration` 0.3125，`HIDScrollAccelCurves`） | 每轴最近 ≤9 个事件 / 500 ms 的平均量，换向即重置 | | `0.925x + (0.75x)²` 到 x=6.3，然后切线、平方根；按 120 Hz 推算约 1 + 0.0185·v 到 207 mm/s | 约 6.7-6.8 倍 @ 400-600 mm/s | 公式和出厂参数已核实；x 与手指 mm/s 的换算、绝对输出单位是推算的 |
| Windows Precision Touchpad | 未公开 | | Win8 指南只说"随手指速度加减速" | | 无数据 |
| libinput 1.31（未打补丁） | 不量 | 10.52 单位/mm，本机 2.16 mm 页面 / mm 手指 | 平 | 1 | 已核实 |

两条可用的生产曲线有三点一致：慢速增益 1；过了拐点，增益随速度近似线性上升（输出速度近似 v²）；
峰值 7-8 倍在 400-600 mm/s，之后缓慢回落，但输出速度仍随手指加快而增加。差别只在拐点：macOS 几乎从 0 开始升，ChromeOS 到 75 mm/s 才升。

研究文献：Quinn 等（UIST 2012）只测了滚轮（OS X 峰值约 14 倍，低速时小于 1），没测触控板；Cockburn 等（CHI 2012）表明增益按文档长度缩放效果最好，
但这需要知道文档长度，libinput 这一层做不到（libinput 维护者也因此主张滚动加速放在 GTK/Qt 里做）。

### 采用的曲线

以 ChromeOS 默认曲线为主体：它就是给 Chromium 加 Linux 触控板调的，单位是 mm，而且慢速比例（2.5）和本机未加速时（2.16）几乎一样，可以 1:1 移植。改了两个角：

- 起步：从 45 mm/s 开始，用 1 + (v-45)²/9000 平滑接到 v/75（在 105 mm/s 处值和斜率都连续）。比 ChromeOS 75 mm/s 的硬拐点早、也软，取的是 macOS 起步早的特点。
- 峰值：500-700 mm/s 之间，让输出速度的斜率从 2v/75 线性降到 1，峰值 7.26 倍 @ 600 mm/s；ChromeOS 在 600 处斜率从 16 突降到 1。之后和 ChromeOS 一样：1 + 4066.7/v。
- 采样成 23 个点，逐段检查输出速度（v × 增益）不下降。

另有一个柔和预设 `scroll-accel-gentle.conf`：增益 = 1 + (默认 - 1)/2，峰值 4.1 倍。

### 配置文件

[scroll-accel.conf](../../system/input/libinput/scroll-accel.conf) 装成 `/etc/l410/scroll-accel.conf`：

| 行 | 含义 |
|---|---|
| `enabled 1` | 写 0 关掉加速 |
| `window_ms 50` | 速度按最近 50 ms 的手指行程算 |
| `gap_ms 100` | 停顿超过 100 ms 算新的一次滑动 |
| `point <mm/s> <增益>` | 分段线性，最后一个点之后增益保持不变 |

增益乘的是 libinput 的滚动值（每 mm 手指 10.52）。KDE 滚动速度 1.0、Chromium 已去掉 ×12 时，增益 1.0 = 每 mm 手指 10.5 逻辑像素，
在 150% 缩放的 L410 面板上是 2.16 mm 页面 / mm 手指。

改完文件再滑一次就生效。换成柔和预设：

```bash
sudo cp /usr/local/share/l410/scroll-accel-gentle.conf /etc/l410/scroll-accel.conf
```

看实际的速度和增益（一边滑一边看）：

```bash
sudo libinput debug-events --verbose --device /dev/input/event3 | grep 'scroll accel'
```

### 离线测试结果

虚拟触控板，30 mm 双指滑动。输出单位是 Chromium/Qt 的逻辑像素（KDE 滚动速度 1.0，Chromium 已去掉 ×12）；本机一屏高约 960 逻辑像素。
括号里是相对不加速的倍数。

| 手指 | 不加速 | ChromeOS s3 原版 | 本机曲线 |
|---|---|---|---|
| 匀速 20 / 50 mm/s | 299 px（1.00） | 299（1.00） | 299 / 301（1.00 / 1.01） |
| 匀速 80 mm/s | 296（1.00） | 314（1.06） | 336（1.14） |
| 匀速 120 / 200 mm/s | 296 / 283 | 464 / 746 | 463 / 745（1.56 / 2.64） |
| 匀速 300 / 400 mm/s | 267 / 253 | 1030 / 1263 | 1030 / 1262（3.85 / 5.00） |
| 快划 峰值 150 / 300 mm/s | 300 / 296 | 474 / 900 | 478 / 900（1.60 / 3.05） |
| 快划 峰值 500 / 700 / 900 mm/s | 298 / 275 / 283 | 1409 / 1971 / 1944 | 1409 / 1912 / 1880（4.74 / 6.96 / 6.65） |

对照：未修之前（Chromium ×12，ScrollFactor 0.5），30 mm 不论快慢都是约 1790 px，接近两屏。现在慢滑 30 mm 约 1/3 屏，快划约 1.5-2 屏，
抬手后 Chromium 再按最后几帧（已加速）的速度惯性滚动。

- 报告间隔 6 / 12 / 16 ms 下增益一致：速度按真实时间算，和报告率无关。
- 最快的"快划"只有 4-7 帧，libinput 的起步判定会吃掉一两帧。
- 从静止瞬间以 1000 mm/s 匀速起步会被 libinput 当作跳点丢弃，真手指不会这样。

## 测试

[tests/scroll-accel-test.sh](../../tests/scroll-accel-test.sh)（在 L410 上以 root 运行）：

```bash
sudo tests/scroll-accel-test.sh [-l 库目录] [-c 曲线文件] -- const|flick <mm/s>...
```

它用 uinput 造一个和 Goodix 触控板参数相同的设备，用临时 udev 规则把它放进单独的 seat（KWin 看不到，不会滚动桌面），
按真实时间做双指滑动（`const` 匀速，`flick` 是最小加加速度的钟形速度曲线），经真实的 libinput 处理，从调试日志收集每帧的速度和增益。
不给 `-l` 时用已装的 libinput，不给 `-c` 时用库自己会读的曲线。编译测试程序需要 libinput-dev。
