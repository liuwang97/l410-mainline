# 键盘、触控板、EC 与电池

这一篇讲 L410 上笔记本特有的外设：嵌入式控制器（EC，华为叫 echub）和它管的电池、充电器、静音灯，I2C-HID 键盘和触控板，F 行热键，合盖开关，以及 I2C 总线卡死后的恢复。

6.18 上的做法：EC 是新写的驱动 `drivers/mfd/huawei-echub.c`，电池/充电器 `drivers/power/supply/huawei-echub-battery.c`，静音灯 `drivers/leds/leds-huawei-echub.c`；键盘和触控板用主线 i2c-hid-of，合盖用主线 gpio-keys，都只靠设备树改动（`l410/dt/fixups.d/09-laptop.dtsi`）和配置片段（`l410/configs/09-laptop.config`）。键盘、触控板的 HID 报告描述符和厂商内核逐字节一致，电池读数和厂商内核一致。指纹不支持。

## 设备一览

| 设备 | 连接 | 厂商 4.19 | 6.18 |
|---|---|---|---|
| 键盘 | I2C7 0x3a，HID 14F3:1400，中断 gpio29 线 0（厂商编号 232），下降沿 | `huawei-keyboard`，i2c_hid + hid-generic | i2c-hid-of |
| 触控板 | I2C6 0x5d，HID 27C6:01E0（Goodix），中断 gpio29 线 4（236），低电平 | `huawei,goodix-clickpad`，i2c_hid + hid-multitouch | i2c-hid-of |
| 触控板（别的批次） | I2C6 0x15，同一中断 | `huawei,elan-clickpad`，这台机器上不存在（-121） | 同上，探测失败不报错 |
| EC | I2C7 0x38 | `huawei,echub_i2c`，mfd 子设备 echub-power / echub-battery / echub-keyboard | `huawei-echub` |
| 电池、充电器 | EC 寄存器；AC 在位是 GPIO 23（gpio2 线 7），厂商 1 s 轮询一次 | `echub_battery` | `huawei-echub-battery`，绑 EC 子节点 `huawei,echub-battery` |
| 静音灯 | EC 寄存器 0x0277 | `echub-keyboard`，`/dev/muteled` | `platform::mute` |
| EC 调压器 | EC 命令 0x02B2，7 路开关 LDO0-6 | `echub-power` | 不做，见已知问题 |
| 状态同步 | GPIO 240（gpio30 线 0），运行时高，挂起时拉低至少 10 ms | `huawei,ec_state_sync` | EC mfd 模块里的平台驱动，syscore 挂起/恢复 |
| 合盖 | GPIO 195（gpio24 线 3），低 = 合上 | `hw_gpio_key`，900 ms 去抖 | gpio-keys，`SW_LID` |
| 指纹 | SPI1，由 TEE 读；内核只管中断（gpio29 线 2）、复位 GPIO 和 sysfs 通知 | `fpc,fingerprint` | 不支持 |
| 摄像头 | 板载 USB hub 端口 1.4，USB 3196:0203，uvcvideo | | 见 [usb.md](usb.md) |

厂商内核的 GPIO 编号换算：pl061 每组 8 根，组号就是设备树别名 `gpioN`，所以 232 = gpio29 线 0。这些都在 Kylin 的 `/sys/kernel/debug/gpio` 和 `/proc/interrupts` 上核对过。

## EC 协议

整理自厂商 4.19 的 `drivers/echub`。每次访问是一个 I2C 传输：先写 4 字节，再读回。

```
写：reg[15:8] reg[7:0] 0x01 arg
读：status count data[count] pec     读寄存器
    status pec                       写寄存器 / 命令
```

status 为 0 表示成功。PEC 是 SMBus CRC-8（多项式 0x07），覆盖 `addr<<1`、写的 4 字节、`addr<<1|1` 和读回的内容，和内核的 `i2c_smbus_pec()` 一致。EC 是单片机，请求挨得太近会丢，厂商驱动两次读之间睡 10 ms；这里统一保证 10 ms 间隔，失败重试 3 次。

| 寄存器 | arg | 含义 |
|---|---|---|
| 0x0280（1 字节，带 PEC） | 0x81 | bit1 电池在位 |
| | 0x82 | bit4 故障，bit5 过热，bit6 过压 |
| | 0x90 | 电量 % |
| | 0xa2/0xa3 | 设计容量 mAh（低/高字节） |
| | 0xa4/0xa5 | 标称电压 mV |
| | 0xaa/0xab | 循环次数 |
| 0x0451（2 字节，小端） | 0x01 | 电流 mA（有符号） |
| | 0x06 | 电压 mV |
| | 0x07 | 剩余容量 mAh |
| | 0x08 | 满充容量 mAh |
| | 0x09 | 温度，单位 0.1 K |
| 0x02B2（命令） | 0x16 | OS 已启动（驱动开机时发，和厂商内核一样） |
| | 0x50-0x5D | EC 电源开关，偶数关、奇数开 |
| 0x0277 | 0x5A / 0x55 | 静音灯亮 / 灭 |

命令 0x17（重启）、0x23（挂起）、0x25（关机）在厂商代码里有定义，但没有人调用，这里也不发。

厂商代码对 2 字节读不校验 PEC。实测 EC 对字读同样给出正确的 PEC，所以现在所有读都严格校验（`mfd: huawei-echub: check the PEC of word reads too`）。

debugfs：`/sys/kernel/debug/huawei-echub/stats` 是传输数、失败、重试、状态错、PEC 错的计数；`read` 可以读任意寄存器（只读，不能写 EC）：

```sh
echo "0x0280 0x90 1" | sudo tee /sys/kernel/debug/huawei-echub/read
sudo cat /sys/kernel/debug/huawei-echub/read
```

## 电池和充电器

`huawei-echub-battery` 注册两个 power_supply：`echub-battery` 和 `echub-ac`。电池每 10 s 轮询一次，低电量时 5 s 一次。AC 在位 GPIO 带中断（200 ms 去抖）；拿不到中断时跟着电池轮询一起查。

轮询工作放在可冻结的工作队列上（`power: supply: huawei-echub-battery: poll on a freezable workqueue`）。原来挂起过程中它还在读 EC，会报 `i2c-7: Transfer while suspended`。

同一台机器上和厂商内核的读数对比：

| 项 | 厂商 4.19 | 6.18 |
|---|---|---|
| 电量 / 状态 | 100%，Full | 100%，Full |
| 电压 | 8.692 V | 8.688-8.691 V |
| 满充容量 | 6947 mAh | 6950-6957 mAh |
| 设计容量 | 7230 mAh，标称 7640 mV（2S） | 相同 |
| 循环次数 | 51 | 51 |
| 温度 | 30.0 °C | 30.1-32.8 °C |
| AC | 在线 | 在线 |

首次测试里 EC 共 66 次传输（含 60 s 内连续轮询 50 次）0 错误，字读的 PEC 全对。

## 静音灯

`leds-huawei-echub` 注册 `platform::mute`，写 EC 寄存器 0x0277，默认触发器是 `audio-mute`。这个触发器要靠 ALSA 的 `SND_CTL_LED` 驱动，目前内核没开，Hi6405 的控件也没有标 LED 属性，所以灯不会随静音自动亮灭。可以手动控制：

```sh
echo 1 | sudo tee /sys/class/leds/platform::mute/brightness
```

键盘背光由 EC 固件自己处理，内核里没有对应驱动（厂商内核也没有）。

## 键盘和触控板（I2C-HID）

对照原版 4.19.71，厂商改过 i2c-hid-core，6.18 上的处理：

- 键盘中断用下降沿并加 `IRQF_NO_SUSPEND`，其他设备默认低电平：设备树里写 `interrupts-extended`，键盘 `IRQ_TYPE_EDGE_FALLING`，触控板 `IRQ_TYPE_LEVEL_LOW`。
- 探测和取报告描述符前各 `msleep(1)`，键盘取 HID 描述符失败时再试一次（厂商注释：键盘由 EC 模拟，处理不了紧挨着的两次请求）：6.18 上取 HID 描述符失败后等 1-2 ms 重试一次（`HID: i2c-hid: retry fetching the HID descriptor once`）。取报告描述符前主线已经有复位和上电后 60 ms 的等待，不用再加。
- 触控板备用描述符地址 0x0020（XINSI 触控板）、恢复后等 60 ms、S3 期间保持键盘中断：这台机器用不到，或者只和挂起有关，没有做。
- hid-multitouch 的一处改动（`hid_map_usage` 后 `*bit` 为空时返回）：主线已有等价处理。
- 两个设备都没有复位/供电 GPIO，也没有调压器；触控板设备树里原有的 `post-power-on-delay-ms = 2` 主线 i2c-hid-of 直接支持。

compatible 写成 `"huawei-keyboard", "hid-over-i2c"` 和 `"goodix-clickpad", "hid-over-i2c"`：I2C 客户端名取第一个 compatible，所以 HID 设备名和厂商内核一样（`huawei-keyboard 14F3:1400` 等），驱动匹配走 `hid-over-i2c`。下面的热键 hwdb 就是按这个名字匹配的。

## F 行热键

键盘 HID 描述符里声明了 Consumer（亮度、音量等）、Wireless Radio（飞行模式）、System Control（电源/睡眠）三个集合。厂商 4.19 给每个集合单独建一个 input 设备；主线 hid-input 把 Consumer 和 System Control 并进键盘那个 input 设备（`hidinput_match_application`），只有 Wireless Radio Control 单独一个。

但 EC 实际上不走 Consumer 集合：F 行热键是作为键盘页（0x07）的保留用法 0xA5-0xAF 放在普通键盘报告（ID 1）里发出来的。主线 `hid_keyboard[]` 这些位置是空的，于是全部变成 `KEY_UNKNOWN`（扫描码 0x700a5 起）。厂商 4.19 是直接改了 `drivers/hid/hid-input.c` 的 `hid_keyboard[]` 表 0xA0 那一行，这个改动不在任何 huawei 驱动里，只有和原版 diff 才看得到。

| 用法 | 按键 | 厂商键码 | 6.18 |
|---|---|---|---|
| 0xA5 / 0xA6 | F1 / F2 亮度 -/+ | BRIGHTNESSDOWN / UP | 相同 |
| 0xAF | F3 键盘背光 | 不映射（EC 自己调背光，这只是通知） | 相同 |
| 0xA7 / 0xA8 / 0xA9 | F4 静音，F5/F6 音量 -/+ | MUTE / VOLUMEDOWN / VOLUMEUP | 相同 |
| 0xAA | F7 麦克风静音 | F20 | MICMUTE（XKB 里两者都是 XF86AudioMicMute，MICMUTE 是主线的正规键码） |
| 0xAD | F8 投屏 | SWITCHVIDEOMODE | 相同 |
| 0xAB | F9 无线 | WLAN | 相同 |
| 0xAC | F10 电脑管家 | CONFIG | 相同 |
| 0xAE | 推测是单按 Fn（切换 Fn 锁定，之后 F 行发 F1-F12 的 0x3A 起） | 不映射 | 相同 |

F11 是 PrtSc（0x46），F12 是 Ins（0x49），都是标准用法。摄像头键没有 HID 报告。

6.18 不改内核，用 udev hwdb 做同样的映射：`system/hardware/61-l410-keyboard.hwdb`，由 `system/hardware/install.sh` 装好。手动安装：

```sh
sudo install -m 644 system/hardware/61-l410-keyboard.hwdb /etc/udev/hwdb.d/
sudo systemd-hwdb update
sudo udevadm trigger --action=change --subsystem-match=input
```

已经在运行的 KWin 会立刻拿到亮度、音量、静音（这些键码描述符里本来就有，设备的键位图里也有）。MICMUTE、WLAN、SWITCHVIDEOMODE 的位图是 hwdb 生效后才补上的，libinput 要重新打开设备才认，所以要重新登录或重启。

## 合盖

设备树把 `echub_lid` 改成主线 `gpio-keys`，加 `lid-switch` 子节点：`SW_LID`，低有效，900 ms 去抖（和厂商一样），`wakeup-source`。厂商的"工厂模式下关合盖中断"（EC 寄存器 0x0408/0x0489/0x04e9）没有移植。

## I2C 总线卡死后的恢复

现象：一次长时间烤机中，触控板所在的 i2c-6 先报了 5 次 "lost arbitration"，之后每次传输都 "controller timed out"（i2c-hid 返回 -110），触控板一直到重启都不能用。

原因：一次传输被打断后，从设备把 SDA 拉低不放。重新探测控制器没用，要用 GPIO 打 SCL 时钟，直到从设备放开 SDA。厂商内核用设备树里的 `cs-gpios` 做这件事；6.18 原来没有任何总线恢复。i2c-designware 本身支持：节点有 `scl-gpios`/`sda-gpios` 和一个 `gpio` pinctrl 状态时，超时或总线忙会调 `i2c_generic_scl_recovery`。I2C 核心在 probe 拿 GPIO 时把引脚切到 `gpio` 状态，拿完再切回 `default`（pl061 的各组有 gpio-ranges，拿 GPIO 线时也会改引脚复用），所以两个状态都得有。

`l410/dt/fixups.d/08-i2c-recovery.dtsi` 按厂商 `cs-gpios` 给四条 DesignWare I2C 补上恢复（`l410: dt: GPIO bus recovery for the four DesignWare I2C buses`）。引脚是开漏，复用功能 0 在两个 IOMG 块上都是 GPIO：

| 总线 | 设备 | SCL / SDA |
|---|---|---|
| i2c-3（fa04c000） | 功放 | gpio005 / gpio006 |
| i2c-4（fa04d000） | eDP 桥 SN65DSI86、WiFi 校准 EEPROM | gpio029 / gpio030 |
| i2c-6（fa04e000） | 触控板 | gpio237 / gpio238 |
| i2c-7（fa04f000） | 键盘、EC | gpio177 / gpio178 |

开机日志里每条总线一行 `using pinctrl states for GPIO recovery`，共 4 行。键盘、触控板或功放失灵并伴随 designware 超时时，先确认这 4 行在。`tests/quick.sh` 和 `tests/soak-mix.sh` 的内核日志检查会把这类 I2C 错误判为失败。

## 系统睡眠

s2idle 睡眠唤醒后 8 个输入节点和睡前一致，EC 电池轮询在挂起期间停住（见上文）。唤醒源是电源键、合盖和 RTC；键盘还不能唤醒（i2c-hid 节点要加 `wakeup-source`）。厂商和挂起有关的 i2c-hid 改动（S3 期间保持键盘中断、恢复后触控板等 60 ms）没有加。

## 检查方法

```sh
sudo dmesg | grep 'GPIO recovery'                      # 4 行
cat /sys/class/power_supply/echub-battery/uevent
cat /sys/class/power_supply/echub-ac/online
sudo cat /sys/kernel/debug/huawei-echub/stats          # 错误、重试、PEC 错都应是 0
sudo evtest                                            # 选 huawei-keyboard，按 F1 应得 KEY_BRIGHTNESSDOWN
sudo evtest --query /dev/input/eventN EV_SW SW_LID     # N 换成合盖设备；开着返回 0，合着返回 10
```

`tests/laptop.sh`（root，只用 POSIX sh 和 busybox 工具，所以也能放进 initramfs 跑）：HID 设备绑到正确驱动，报告描述符的 md5 和厂商内核一致；键盘、Wireless Radio、触控板、合盖各 input 设备都在；热键的扫描码映射（EVIOCGKEYCODE 读 0x700a5-0x700ad）；EC 绑定、debugfs 无错误；电池各项在合理范围并和厂商内核的读数比对；AC 在线；60 s 连续轮询 EC 无错误；静音灯开关 EC 接受；合盖和状态同步 GPIO 的状态；dmesg 无相关报错。它无人值守，只查枚举、映射和当前状态，不能代替真的按键、合盖。

`tests/quick.sh --only input,ec` 还查电池健康度（满充/设计 ≥ 80%）、AC 状态与电流方向是否一致、电池温区和 power_supply 温度、UPower 百分比。

## 已知问题

- 键盘不能唤醒系统；合盖、电源键唤醒没有实测。
- 静音灯不跟随静音状态，见上文。
- EC 调压器（echub-power）没有移植：设备树里没有节点引用它。面板和 eDP 桥的供电是 SoC GPIO，不走 EC LDO，`EC_1V2_EN`、`EC_DSI_VCCIO_ON` 在这台机器上用不到。以后真要用，命令寄存器 0x02B2，开 = 基址 + 1。
- 热键、合盖的实际动作只能人工测：热键用 evtest 手按验证过一次。
- EC 的 mfd 子设备启动时有 "DMA mask not set" 提示，无害。
- 指纹不支持：传感器在 TEE（iTrustee）后面，6.18 没有 tzdriver，也没有厂商 HAL。

## 试过但没用

- 触控板总线卡死后重新绑定 i2c_hid 或 i2c_designware：不恢复，要靠 GPIO 总线恢复。
- 只看键盘 input 设备的键位图来判断热键：MUTE、VOLUME±、BRIGHTNESS± 等全在位图里，但那只说明描述符声明了这些用法，实际按键全是 `KEY_UNKNOWN`。要查扫描码映射或真按。
