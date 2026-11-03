# 验证与测量

## 离线回归

```sh
python tools/check_project.py
npm ci --prefix src/assistant_gateway --ignore-scripts
npm test
python tools/test_cpp.py
python tools/run_rtl.py
```

`check_project.py` 检查必需文件、引脚工程闭包、占位 AppID 和私人路径/密钥泄漏。`test_host.mjs` 运行小程序、网关、诊断台、跨端集成及曲库测试，保存 TAP 日志和退出码；不会访问 BLE、串口或真实 API。CI 只跑可在通用主机执行的部分。

`test_cpp.py` 使用宿主 g++，核对 S3 的授权、协议、OLED 与 BLE 转发。`CXX` 可以指定编译器；Windows 需保证编译器依赖 DLL 可用。

RTL 测试需要 Icarus 与合法安装的 Gowin GW5A 原语库。可设置 `IVERILOG_BIN`、`GOWIN_SIMLIB` 或 `GOWIN_IDE_BIN`。默认 13 项覆盖顶层编译、包络、插值、合唱、整机合成、试听、显示采集/追踪/标签/缩放，其中**顶层项仅编译**，其余运行仿真。扩展台在 `tests/rtl` 与 `tests/integration`，未被默认入口执行的台不计入默认通过数。

所有原始日志在 `build/`，不纳入 Git。发行包只带本次测试摘要、构建清单和哈希，不复制历史工作日志。

## 四声部与分量

四个 FSR 依次按下、依次松开，核对四声部归属、独立电平及尾音生命周期。不能只拍“四灯亮”来替代声音与声部状态。

32 分量测试结合三类证据：RTL 的相位/权重/累加通路、GAO 有效运算记录、DAC 或数字音频的频谱。GAO 累加器事件不是等间隔 PCM，不能直接拿它做音频 FFT。测试模式的约 55 Hz 基频适合分辨低频谐波；普通音色和高音区可能有权重为零或因抗混叠屏蔽的分量。

吞吐量使用“有效活跃分量数 × 实际输出采样率”计算，注明是否谐波锁相关系、是否各自独立包络；不按物理乘法器数/过采样重复计数。本项目每声部谐波共享该声部包络，不能把四声部的分量数直接宣称为相同数量的独立可调复音。

## 延迟

1. **数字内部计时**：片内计数器观测接受 note-on 到匹配串行输出事件。HDMI 的数字段延迟不覆盖按压机械、ADC 前等待与 DAC/功放模拟部分。
2. **模拟端到端测量**：示波器 CH1 接 ADC 前压力调理输出、CH2 接 DAC 模拟输出，共参考地，固定探头倍率、时基、阈值与触发方向。两光标分别对齐预定输入事件与输出起音事件，记录 Δt。光标不能随意对准第一个载波峰。
3. **声学链路**：如包含音箱与空气传播，需要独立麦克风与同步参考，不把 DAC 模拟测量直接称为完整声学延迟。

四区分别重复测量，保留原始波形/照片、实际位流 SHA、测点、门槛和无效试次，汇总 min/median/P95/max。一次截图不等于整个系统在所有条件下达到相同上限。本次公开发行替换了开放字库并重新构建，**不把旧位流的实测数字自动绑定到新位流**。

离线工具位于 `tests/latency`；`scope_screenshots.py` 只登记人工光标读数，`analyze_scope.py` 依据预先冻结的 profile 处理真实 CSV。`tests/analysis/demo_analysis.py` 支持 GAO/WAV 分析，需 NumPy/Matplotlib/SciPy；`tests/matlab` 提供 MATLAB 数值分析。它们不自动读取硬件。

## 需要人工完成的验收

当前 Release 构建清单的 `hardware_validation=NOT_RUN` 指本次发行产物没有在整理过程中重新烧录。真实 BLE、手机原生环境、显示器兼容、耳听效果、模拟幅度与物理延迟需对本次配套镜像另行测试。不要通过编辑布尔标记把这些步骤改成已通过。
