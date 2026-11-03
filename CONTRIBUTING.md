# 参与开发

先读 [架构](docs/architecture.md)、[协议](docs/protocol.md) 与 [测试](docs/testing.md)。安装依赖后运行 `python tools/check_project.py` 和 `npm test`；修改 S3 共享头文件时追加原生 C++ 检查，修改 RTL 时运行受影响仿真及真实综合/PnR/STA。

改动请说明行为变化、复现方式、测试范围。通信协议需同步 FPGA、S3、JS 与冻结金样；不能只改一端。保留原始失败记录，不通过放宽断言伪造修复。不提交 API Key、AppID 私人配置、个人绝对路径、器件库、工具链、构建缓存和实测人员的私人信息。

提交新的硬件测量时，附位流哈希、测点、设备设置与事件判据；图中数字、状态文字和仿真 PASS 不能替代实体证据。不同镜像的实测数据分开记录。
