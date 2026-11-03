# 设备字形

本项目使用 Noto Sans CJK SC Regular 的少量 16×16 字形，以及 RTL 的 8×8 ASCII 子集。派生字形统一命名为 **XianChu UI glyph subset**，采用 [SIL OFL 1.1](OFL.txt)。它们位于 `dashboard_zh_font.sv`、`oled_glyph_rom.sv`、`vga_font8x8.sv` 和固件的三个 `*glyphs.h` / `oled_status.h` 文件中。手绘方向箭头不依赖系统字体。

上游：[notofonts/noto-cjk](https://github.com/notofonts/noto-cjk)。Copyright 2014–2021 Adobe，保留原字体的版权与 OFL 条款。下载使用的 [字体文件](https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf) 的 SHA-256：

```text
2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b
```

不必安装字体就能编译已有源码。若需重新生成，安装 `Pillow==13.0.0`，下载以上字体，执行：

```sh
python tools/generate_fonts.py /path/to/NotoSansCJKsc-Regular.otf
```

脚本校验字体哈希，保留界面字形 ID 和行顺序，输出预览至 `build/fonts/glyphs.png`。修改字形后必须重新构建 FPGA 和 S3 固件；不要把旧位流与新源码混为同一产物。
