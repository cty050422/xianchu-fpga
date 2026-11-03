# 串口与 BLE 协议

本页是协议导航；逐字节实现与冻结金样才是编码依据。

| 端 | 源码入口 |
|---|---|
| FPGA | `src/rtl/esp_score_link.sv`、`config_session.sv`、`config_capability.sv` |
| S3 | `src/firmware/arduino/XianChu_Link_R3/link_protocol.h`、`mobile_view.h` |
| 小程序 | `src/wechat_miniprogram/utils/protocol.js`、`mobile_observer.js`，`services/` 会话层 |
| 主机观察 | `src/performance_ui/protocol.mjs` |
| 金样 | `src/docs/protocol/GOLDEN_SAMPLES_V1.json` |

## 帧与链路

UART 为 115200、8N1。帧头 A5 5A，后接版本、类型、正文长度、序号、正文及 CRC-8，poly=0x07、init=0。CRC 从版本字节覆盖到正文最后一字节；长度与 CRC 通过前不发布状态。

BLE MTU 可能只有 20 字节，不能把每次通知当作完整 UART 帧。S3 做有界转发，小程序先重组，再验证 CRC；状态、四声部、手势和波形各有独立的完整性/新鲜度。通知订阅和命令应答分开，不以“写特征成功”认定 FPGA 已执行。

主要上行：0x80 总状态、0x81 配置应答、0x82 手势/控制、0x83 波形分片、0x84 四声部状态、0x85 事件记录。总状态正文为 15 字节，完整帧 22 字节；其他类型依其长度字段解析，不沿用旧版固定长度猜测。

## 曲谱与播放

- 0x10 BEGIN、0x11 STEP、0x12 COMMIT：兼容练习曲谱事务；曲谱 v2 和能力协商由 `protocol.js` 封装，不手工拼接旧帧代替新格式。
- 0x13 练习控制；0x14 PING；0x15 配置通道。
- 0x1B–0x1E：符号曲谱示范试听的加载、提交与播放控制，具体字段见客户端 `audition_score.js` / `audition_session.js`。

计数、步数、表达提示、和弦区域掩码、休止与时值都有边界校验。手机“下载完成”必须意味着设备完成提交；断线/失鲜后不得重放旧会话待办。

## 配置字段

当前默认图支持 **15/22** 个字段，能力掩码 `0x3F80FF`。范围检查与真正消费者均在 FPGA 内；表内范围不能替代实时查询。

| 字段 | 含义 | 当前状态 |
|---|---|---|
| 1–4 | 四区域音高，MIDI 36–96 | 支持 |
| 5–8 | 四区域触发门槛，ADC 16–4095 | 支持 |
| 9–12 | 四区域曲线选择 | UNSUPPORTED |
| 13 | 可配置弯音范围 | UNSUPPORTED；面板既有滑音仍可用 |
| 14 | 可配置颤音深度上限 | UNSUPPORTED；摇杆既有颤音仍可用 |
| 15 | 可配置轴死区 | UNSUPPORTED |
| 16 | 分量目标 2–32 | 支持 |
| 17 | 效果湿度上限 0–64（64=不额外限制） | 支持；作为摇杆湿度的上限 |
| 18 | 用户衰减量 0–64（0=直通，64=静音） | 支持 |
| 19 | 效果家族：0 合唱/延迟，1 空间混响 | 支持 |
| 20–22 | 下一次音色、音组、八度选择 | 支持；实时改调见音组/八度事件通路 |

GET 返回已应用值，SET 只暂存，COMMIT 原子生效。过期 lease、旧 epoch、重复/陈旧请求和不支持字段不得假成功。手机 BLE 授权、电脑曲库访问权限和 USB 调试授权是不同来源，不互相冒充。
