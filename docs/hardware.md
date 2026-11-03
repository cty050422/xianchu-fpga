# 硬件与接线

适用目标：**Tang Mega 60K / GW5AT-LV60PG484AC1/I0 + NEO Dock**。换开发板、Dock 修订版或插针方向时必须对照其原理图；本表不适用于其他 Tang 系列板。

## 所需硬件

| 器件 | 数量与说明 |
|---|---|
| FPGA 与 Dock | Tang Mega 60K，带板载 PT8211 与 HDMI 接口的 NEO Dock |
| 压力输入 | 4 片 FSR，调理输出不得超过 ADC/FPGA 所用 3.3 V 量程 |
| 双轴摇杆 | 2 个，X/Y 模拟量及低有效 Z 按键 |
| ADC | MCP3208，8 通道、12 位、3.3 V；H10/H11 是本项目原调理板的排针标号 |
| 指引灯 | 4 LED，各串 1 kΩ 电阻，共地；H1 是五针 LED 板接口 |
| 蓝牙与 OLED | ESP32-S3 N16R8，SSD1306 128×64 I²C OLED，地址 0x3C 或 0x3D |
| 输出 | HDMI 显示器与线；3.5 mm 有源音箱或兼容耳机 |

## ADC 与模拟通道

| FPGA / 模块 | 接到 | 信号 |
|---|---|---|
| J9.1 | 调理板 H11.1 | 3.3 V |
| J9.3 | 调理板 H11.2 | GND |
| J9.5 / R18 | H10.3 DIN | SPI MOSI |
| J9.6 / T18 | H10.2 DOUT | SPI MISO |
| J9.7 / P16 | H10.4 CS | SPI CS_N |
| J9.8 / R17 | H10.1 CLK | SPI SCK |
| FSR 1、2、3、4 调理输出 | MCP3208 CH0、CH1、CH2、CH3 | 压力 |
| 摇杆 1 X、Y | MCP3208 CH4、CH5 | 滑音、颤音 |
| 摇杆 2 X、Y | MCP3208 CH6、CH7 | 明暗/分量、效果湿度 |

若自制调理板，不照抄 H10/H11 序号：按表中的**信号名**核对连接。模块电源与模拟地接入共同的 3.3 V/GND；三针模块上的 S 是模拟输出，不接电源。

## 两个 Z 按键

| FPGA | 接到 |
|---|---|
| J8.1 / J8.3 / J8.7 | 摇杆 1 Z 接口 VCC / GND / D |
| J8.2 / J8.4 / J8.8 | 摇杆 2 Z 接口 VCC / GND / D |

Z1 对应 FPGA AA20，Z2 对应 AA21，空闲为高、按下为低。按模块丝印核对 D、VCC、GND，不能仅靠线色判断。两摇杆物理正方向均为 **+X↓，+Y→**。

## S3 与 OLED

| 起点 | 终点 | 说明 |
|---|---|---|
| FPGA J8.5 / AA19 / ESP_UART_TX | S3 GPIO17 | FPGA TX → S3 RX |
| S3 GPIO18 | FPGA J8.6 / AB20 / ESP_UART_RX | S3 TX → FPGA RX |
| FPGA J9.4 | S3 GND | 共参考地 |
| S3 3V3 | OLED VCC | 按模块额定电压使用 |
| S3 GND | OLED GND | 地 |
| S3 GPIO8 | OLED SDA | I²C 数据 |
| S3 GPIO9 | OLED SCL | I²C 时钟 |

串口为 **115200、8N1、3.3 V TTL**，不是 RS-232。OLED 是 I²C 四线屏，不是 I²S 音频设备。当前发行版由 **S3 单独驱动 OLED**，不要再把 OLED 总线接到 FPGA 的预留管脚。

推荐 FPGA 使用自己的合规电源，S3 使用 USB；只连接串口与共地。S3 已由 USB 供电时，不并接 J14.11 的 5 V。J9.2 是额外 3.3 V 电源针，不是 GPIO，也不用于给整块 S3 供电。

## LED 板

| FPGA | LED 板 H1 | 对应区域 |
|---|---|---|
| J14.12 GND | 1 GND | 四灯共地，仅需一根地线 |
| J8.11 / Y21 | 2 LED1 | FSR1 |
| J8.12 / Y22 | 3 LED2 | FSR2 |
| J8.9 / AB21 | 4 LED3 | FSR3 |
| J8.10 / AB22 | 5 LED4 | FSR4 |

每支路：FPGA GPIO → LED → 1 kΩ → GND，电阻串在 LED 前后均可。为高电平点亮，无需另外给 LED 板接 VCC。LED 极性按二极管阴阳极核对。所有引脚均以针 1 标记定位；不要按照片左右方向数针。

## 输出与复用

FPGA 的 HDMI **输出**接显示器 **输入**，普通电脑 HDMI 口通常也是输出，不能拿它充当采集输入。3.5 mm 音频口使用板载 PT8211 右对齐串行 DAC 通路。HDMI 当前只提供图像，不承载本项目音频。

PMOD 管脚与 SDRAM/摄像头等功能有复用；使用本接线时不要同时驱动这些共享功能。IO 电压与功能绑定以 `src/gowin/narrative/narrative.cst` 为准；KEY2/Y12 是板内 1.5 V 输入，不能外接 3.3 V 摇杆输出。

参考：[Sipeed 官方 60K 示例与板卡资料入口](https://github.com/sipeed/TangMega-60K-example)。所有改线均在断电时进行。
