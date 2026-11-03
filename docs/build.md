# 安装、构建与烧录

## 工具版本

| 工具 | 本发行使用 |
|---|---|
| Gowin EDA | Education V1.9.11.03，GW5AT-60B 器件库 |
| Arduino IDE / ESP32 core | Arduino IDE 2.x；`esp32:esp32@3.3.12` |
| Arduino 外部库 | Adafruit GFX Library 1.13.0、Adafruit SSD1306 2.5.17、Adafruit BusIO 1.17.4 |
| Node.js | 24 LTS；主机代码最低要求 22 |
| Python | 3.12；构建入口仅需标准库 |
| 可选验证工具 | Icarus Verilog 13、Gowin GW5A 仿真原语、g++（C++17） |
| 可选分析 | NumPy、Matplotlib；MATLAB 脚本另行安装 MATLAB |

不要安装整个开发工作区。Node 的完整实验网关测试需要 `npm ci --prefix src/assistant_gateway --ignore-scripts`；**仅使用当前曲库服务时不需要安装 npm 依赖或 API Key**。

## FPGA

图形界面打开 `src/gowin/narrative/narrative.gprj`，顶层必须是 `instrument_display_top`，目标器件 `GW5AT-LV60PG484AC1/I0`。不要替换 CST/SDC，不要用其他目录的旧工程生成位流。

可重复命令行构建：

```powershell
# 按实际安装路径填写；不要原样抄一个不存在的目录。
$env:GOWIN_IDE_BIN = 'D:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin'
python tools/build_fpga.py
```

脚本在独立 ASCII 路径构建，检查输入是否改变、产物是否新生成、Setup/Hold 是否均为 0，结果放在 `build/fpga/<日期时间>/`。`XIANCHU_BUILD_ROOT` 可指定 ASCII 缓存目录。GAO 启用的原始 EDA 输出名可能是 `ao_0.fs`，脚本统一输出为 **XianChu.fs** 并配对 **XianChu.rao**。

打开 Gowin Programmer，选择真实板卡与正确器件，添加同一发行版 `fpga/XianChu.fs`。首次优先使用 SRAM 编程验证，确认效果后再按板卡手册决定是否写 Flash。GAO 使用该包同目录的 `.rao`，不能混用历史探针文件。本文不把工具“下载成功”等同于演奏与模拟音频已验收。

## ESP32-S3：Arduino IDE

打开 `src/firmware/arduino/XianChu_Link_R3/XianChu_Link_R3.ino`，保持该文件夹内所有头文件一起存在。

1. 安装 Espressif ESP32 开发板包 **3.3.12**，选择 **ESP32S3 Dev Module**。
2. 库管理器安装 **Adafruit GFX Library**、**Adafruit SSD1306**、**Adafruit BusIO**。
3. Flash Size 选 **16MB**；Partition Scheme 选 **16M Flash (3MB APP/9.9MB FATFS)**，对应 `app3M_fat9M_16MB`。编译输出应显示应用容量上限 **3145728 bytes**，只改 Flash Size 不够。
4. PSRAM 选 **OPI PSRAM**；USB Mode 选 **Hardware CDC and JTAG**；USB CDC On Boot 选 **Enabled**。
5. 选择本机实际 S3 端口，点击上传。串口监视器 115200，按复位可看启动状态。不要把历史机器上的 COM 编号当作自己的端口。

CLI 构建使用同一参数，不自动烧录：

```sh
arduino-cli core update-index --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core install esp32:esp32@3.3.12 --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli lib install "Adafruit GFX Library@1.13.0" "Adafruit SSD1306@2.5.17" "Adafruit BusIO@1.17.4"
python tools/build_s3.py
```

`arduino-cli` 放入 PATH，或设置 `ARDUINO_CLI`；非默认工具目录可设置 `ARDUINO_CLI_CONFIG`。完整 FQBN：

```text
esp32:esp32:esp32s3:FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,PSRAM=opi,USBMode=hwcdc,CDCOnBoot=cdc
```

输出在 `build/s3/<日期时间>/`。**普通 `.ino.bin` 只有应用，不能写到地址 0。** 若选择使用二进制烧录工具，只把 `*.merged.bin` 作为完整镜像写到 `0x0`，目标芯片选 `esp32s3`；会替换对应 Flash 内容。初次使用推荐 Arduino IDE，以免手工地址错误。

## 小程序

导入目录 `src/wechat_miniprogram`，填写自己的微信小程序 AppID（公开配置使用 `touristappid` 占位，不包含私人配置）。真机需要蓝牙权限；开发者工具模拟器不能证明 BLE 已正常。更换源码目录后重新编译、预览扫码，不能继续使用旧二维码缓存。

## 版本配套

统一使用同一个 Release 的 FPGA、S3 和小程序源码。Release 包中的 `manifest.json` 逐文件记录 SHA-256；修改源码后重新构建，不沿用旧位流标签。BLE “已连接”只是无线连接成功，需要确认有效 FPGA 状态帧持续更新、PING 得到 FPGA 应答后再下载曲谱。
