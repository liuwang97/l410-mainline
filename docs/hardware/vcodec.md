# 视频硬件解码

麒麟 990 的视频编解码子系统（VCodec V500）里有一个解码器 VDH、两个编码器 VENC 和一个 JPEG 单元。
厂商 4.19 用 `hi_vcodec` 驱动，走私有的 OMX 接口。6.18 上新写了 V4L2 无状态（request API）解码驱动 `hisi-vdec`
（`drivers/media/platform/hisilicon/vdec/`），只做解码，内核从 v6.18.54-l410.2 起带它。

配置片段 `l410/configs/85-vcodec.config`：`CONFIG_VIDEO_HISI_VDEC=m`，连带选上 v4l2-mem2mem、videobuf2-dma-sg、v4l2-h264、v4l2-vp9。
不需要设备树修补：驱动匹配固件设备树里现成的 `hisilicon,HiVCodecV500-vdec` 节点，按 OF 别名自动加载。
用户态的设置在 [system/video/](../../system/video/)（`system/install.sh video`）。

## 支持的格式

| 格式 | 一致性测试 |
|---|---|
| H.264（CBP、Main、High；帧、场、MBAFF、PAFF） | JVT-AVC_V1 128/135。没过的：FMO 3 个，SP/SI 2 个，CVFC1（裁剪，GStreamer 的限制），MR8_BT_B |
| HEVC Main、Main10（10 bit 输出 P010） | JCT-VC-HEVC_V1 142/147。没过的：PICSIZE_A 到 D（高度超过 4096），TSUNEQBD_A（亮度、色度位深不同） |
| VP9 profile 0、profile 2 | VP9-TEST-VECTORS 276/305。没过的：帧间改分辨率 26 个（GStreamer 会丢帧），SVC 1 个，profile 1 两个。10 bit 向量通过 |
| VP8 | VP8-TEST-VECTORS 61/61 |
| MPEG-2 主档次 | ISO 13818-4 的 38 个 MPEG-2 流和 ffmpeg 比，37 个在 IDCT 误差内一致；teracom_vlc4 最后一帧有 4 行宏块不同。另外 5 个 MPEG-1 流不在 V4L2 接口的范围内 |

VC-1、MPEG-4、AVS、AV1 没做，编码也没做。

Chromium 播 4K30 时，CPU 占用和软解相比：H.264 约 1/3，VP9 约 1/5。Chromium 没有 HEVC 软解，HEVC 只能靠硬解。
解码器时钟默认 332 MHz，模块参数 `hisi_vdec.clk_level`：0 = 480 MHz，1 = 332 MHz，2 = 277 MHz，3 = 185 MHz。

## 用户态

| 程序 | 怎么接上 | 状态 |
|---|---|---|
| GStreamer（playbin、decodebin） | `gstreamer1.0-plugins-bad` 里的 v4l2codecs（`v4l2slh264dec` 等），rank 比软解高，自动选用 | 全部格式可用，10 bit 输出 P010 |
| Chromium | Chromium 自带的 V4L2 无状态解码器：[system/video/chromium-video-decode](../../system/video/chromium-video-decode) 装到 `/etc/chromium.d/`，打开 `PreferV4L2VideoAcceleration`、`AcceleratedVideoDecodeLinuxGL`，并进已有的 `--enable-features` 列表 | H.264、HEVC Main、VP8、VP9 profile 0 硬解，零拷贝，画面和软解一致。HEVC Main10、VP9 profile 2 不走硬件（见下） |
| ffmpeg、mpv（VA-API） | megi 维护的 libva-v4l2-request，自己编，`LIBVA_DRIVER_NAME=v4l2_request`；vainfo 能列出全部档次 | `ffmpeg -hwaccel vaapi` 解 H.264、HEVC 8/10 bit、VP8、VP9，和软解逐帧一致 |
| Firefox | VA-API | 没做：RDD 沙箱打不开 VA 驱动 |

Chromium 不走 VA-API：它把自己分配的帧导入 VA 表面，libva-v4l2-request 不支持导入，结果是绿屏。所以用 Chromium 自己的 V4L2 路径。

Chromium 的 V4L2 代码不会排单平面的 P010 帧，遇到 10 bit 流会卡住。驱动因此不在 profile 菜单里报 HEVC Main10 和 VP9 profile 2，
Chromium 遇到 VP9 profile 2 就回退软解，HEVC 10 bit 在 Chromium 里放不了。GStreamer 和 VA-API 不看这些菜单，照样硬解 10 bit。

libva-v4l2-request 那边的已知问题：销毁解码上下文时还没取走的帧会丢（VP9 结尾段错误，MPEG-2 少最后一两帧）；
PAFF + MBAFF 的场对测试流 CAPAMA3 有 4 帧不对。

## 驱动要点

这些是在硬件上实测出来的：

- 消息池的格式来自 HiSTB VFMW v5.0（Hi3796MV200 的 VDH V5R6C1）的 HAL 和头文件，再用麒麟用户态的 libOMX 交叉核对。
  麒麟上所有地址都按 `addr >> 4` 存。图像消息在 slot 5，压缩头信息消息在 slot 4，slice/tile 消息从 slot 6 起。
- 输出是线性 NV12，行距 64 字节对齐，YSTRIDE 寄存器 = 行距 × 8，UV_ORDER=1（默认的色度顺序是 CrCb）。10 bit 写 16 位样本，值在高 10 位，即 P010。
- VDH 不会跳过防竞争字节（厂商的 VFMW 是在拷码流时用起始码检测器剥掉的）：驱动把 slice 拷成 RBSP，再在 RBSP 上解析 slice 头。
- HEVC：给 VDH 的有效位数必须包含 rbsp 停止位，否则最后一个 CTB 的 CABAC 读不到停止位，误差落在画面右下角。
  `data_byte_offset` 是 RBSP 坐标，GStreamer 从每个 slice 自己的起始码算，libva-v4l2-request 从缓冲区开头算，驱动看偏移落在哪个 slice 里来判断。
  `chroma_offset` 按最终的 ChromaOffset 处理。
- VP9：运动补偿会读出参考帧右边、下边约 6 个像素而不钳位。驱动给每帧留 16 像素的边，解完一帧后复制边缘像素（按行做小范围缓存同步）。
  概率的前向更新用 v4l2-vp9 在软件里做，后向适应由硬件做，从计数缓冲区读回。
- MPEG-2：硬件不解析 slice 头，驱动自己扫起始码，读 quantiser_scale_code、intra_slice 和第一个宏块地址增量。
  场图像的 top_field_first 恒为 0，第二场按提交顺序认。一个宏块一个 slice 的流要 1350 条以上的 slice 消息，消息池按 1920×1088 每宏块一条分配。
  libva-v4l2-request 按 slice 逐个提交（带 HOLD_CAPTURE_BUF），GStreamer 整帧提交，驱动把请求攒到不再持有 CAPTURE 缓冲区为止再解。
- 帧模式：Chromium 的 V4L2 路径整帧提交、不给 slice 参数（它按能自己解析 slice 头的硬件设计）。VDH 不会，所以驱动自己解析
  H.264 的 slice 头（包括参考列表修改，初始列表用 v4l2-h264 建）和 HEVC 的 slice 段头（RPS 用 `num_delta_pocs_of_ref_rps_idx`、列表修改、加权预测、入口点）。
  Chromium 按 bus_info 把 video 设备和 media 设备配对，两者都由 V4L2 核心按设备名填。
- 电源：ldo_media、vdec 的 IP 电源域、clk_vdec 调频；运行时 PM，空闲 200 ms 后自动挂起。
- SMMU 是 vdec 自己的，页表是 ARM LPAE 格式（io-pgtable），没找到 TLB 失效寄存器，释放的 IOVA 要等下一次断电之后才复用。

## 怎么确认在硬解

- `/proc/interrupts` 里 `e9200000.vdec` 的计数在涨，就是在用硬件。
- debugfs 的 `hisi_vdec/debug` 写 1 打每帧的日志，写 2 打每个 slice 的日志；`hisi_vdec/regs` 是寄存器快照。
- Chromium 的软解对照：加 `--disable-accelerated-video-decode` 启动。

## 测试方法

- 一致性：[fluster](https://github.com/fluendo/fluster)，例如 `python3 fluster.py run -d GStreamer-H.264-V4L2SL -ts JVT-AVC_V1`，
  HEVC、VP9、VP8 换成对应的解码器和测试集。MPEG-2 把硬解结果和 ffmpeg 软解比 PSNR。
