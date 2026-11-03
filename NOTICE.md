# 来源与许可

本仓库的原创 RTL、固件、客户端及工具采用 [MIT](LICENSE)。下列资源保留各自许可，不能因仓库根目录的 MIT 声明而改用其他许可。

| 资源 | 来源与许可 |
|---|---|
| `src/rtl/vendor_display/` 显示 PLL 包装与参数 | [Sipeed TangMega-60K-example](https://github.com/sipeed/TangMega-60K-example)，保留同目录 `SIPEED_LICENSE` 中的 Sipeed 版权及 Apache-2.0 声明；完整许可见 [third_party/Apache-2.0.txt](third_party/Apache-2.0.txt)；Gowin 生成文件中的原始声明保留 |
| 设备中文与 RTL ASCII 字形 | [Noto Sans CJK SC](https://github.com/notofonts/noto-cjk)，SIL Open Font License 1.1；本项目裁剪字库称为 **XianChu UI glyph subset**，许可及可复现生成方法见 [third_party/fonts](third_party/fonts/README.md) |
| S3 的经典 5×7 ASCII 字形 | Adafruit GFX `glcdfont.c`，BSD 许可见固件目录 `Adafruit_GFX_LICENSE.txt` |
| Arduino 库 | Adafruit GFX、SSD1306、BusIO、Espressif Arduino core 为外部依赖，不在本仓库重新分发安装目录；按各上游许可使用 |
| 可选 MP3 解码 | `mpg123-decoder@1.0.3` 与其 WebAssembly/依赖由 npm 锁定安装；按各包随附许可使用，不把依赖重新标为 MIT |
| 曲谱练习 | 原创练习的 CC0 声明、旋律来源和改编说明逐首保存在 `src/assistant_gateway/catalog_seed.mjs`；不提供商业录音或商业曲谱下载 |

FPGA 正弦表、相位增量表是运算系数，不是预录乐音。Gowin EDA、器件库、仿真原语和 Arduino 工具链不随源码包分发，需要按上游条款自行安装。设备实拍图片为本项目装配记录；使用这些图片时请保留项目出处。

引脚方案参考 Sipeed 官方原理图与示例；本仓库只针对文档所列硬件。`narrative` 等内部工程名是构建路径，不代表另一套发布版本。
