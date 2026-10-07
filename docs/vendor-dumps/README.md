# 厂商系统里的原始数据

在麒麟（厂商内核 4.19.71-23-kr990）下采集的原始信息，移植时拿来对照。都是只读命令的输出。

| 文件 | 内容 |
|---|---|
| `config-4.19.71-23-kr990` | 厂商内核配置 |
| `dmesg-4.19.71-23.txt` | 厂商内核一次正常开机的日志 |
| `bound-drivers.txt` | 平台设备和绑定的驱动 |
| `clk_summary-4.19.71-23.txt` | `/sys/kernel/debug/clk/clk_summary`：时钟树和频率 |
| `hid-rdesc-6-005d-clickpad.hex`、`hid-rdesc-7-003a-keyboard.hex` | 触控板、键盘的 HID 报告描述符 |
| `misc.txt` | GRUB 模块列表、`/proc/iomem` 等 |
| `audio/` | Hi6405 空闲时的寄存器、DAPM 状态、寄存器写入历史，以及音频相关的 GPIO、时钟、中断 |

固件交给厂商内核的设备树在内核仓库的 `l410/dt/l410-firmware.dts`。
