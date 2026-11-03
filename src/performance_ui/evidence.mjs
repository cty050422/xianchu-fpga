// Browser-only view of FPGA-reported status; no physical audio measurements.
export function signalPath({ source, state, parser, now, waveAt = 0 }) {
  const unavailable = (label, detail) => ({ tone: 'unknown', label, detail });
  if (source === 'demo') return {
    steps: [
      unavailable('演示', '非实板'),
      unavailable('演示', '非实板'),
      unavailable('演示', '非实板'),
      unavailable('演示', '非实板')
    ],
    headline: '界面演示',
    detail: '连接 FPGA 后显示实时状态。'
  };
  if (source !== 'live') return {
    steps: Array.from({ length: 4 }, () => unavailable('未连接', '等待数据')),
    headline: '等待连接',
    detail: '请选择 FPGA 数据串口。'
  };

  const fresh = state.validFrames > 0 && now - state.lastFrameAt <= 1500;
  if (!fresh) return {
    steps: [
      { tone: parser?.receivedBytes ? 'warn' : 'unknown',
        label: parser?.receivedBytes ? '字节待识别' : '等待字节',
        detail: `${parser?.valid ?? 0} 个有效帧` },
      unavailable('未知', '无新状态帧'),
      unavailable('未知', '无新门控帧'),
      unavailable('未知', '无新合成帧')
    ],
    headline: '等待实时数据',
    detail: '请检查连接状态。'
  };

  const panelFresh = !!state.panel && now - state.lastPerformanceAt <= 1800;
  const panel = panelFresh ? state.panel : null;
  const gates = state.gates & 15;
  const gateCount = [0, 1, 2, 3].filter(i => gates & (1 << i)).length;
  const waveFresh = (parser?.waveFrames ?? 0) > 0 && state.outputKnown &&
    waveAt > 0 && now - waveAt <= 1500;
  const steps = [
    { tone: 'good', label: '数据正常', detail: `已收 ${state.validFrames} 帧` },
    panel ? panel.test ? { tone: 'good', label: '测试模式', detail: '校准状态不适用' } :
      panel.calibrated ? { tone: 'good', label: '已校准', detail: '可以演奏' } :
        { tone: 'warn', label: panel.calRefused ? '校准未完成' : '待校准', detail: '查看操作说明' } :
      unavailable('校准未知', '等待状态'),
    panel?.test ? { tone: 'good', label: '内置测试音', detail: '无需按压力键' } :
      { tone: gateCount ? 'good' : 'idle', label: `${gateCount}/4 区触发`,
        detail: gateCount ? '正在演奏' : '轻压演奏区' },
    waveFresh ? { tone: state.outputActive ? 'good' : 'idle',
      label: state.outputActive ? '数字合成中' : '数字静音',
      detail: 'FPGA 状态' } : unavailable('输出未知', '等待状态')
  ];

  if (panel?.panic) {
    steps[3]={tone:'warn',label:'保护静音',detail:'FPGA报告紧急停止状态'};
    return {steps,headline:'紧急停止 · FPGA保护静音',detail:'旧PCM预览不能覆盖新的保护状态；按操作手册恢复。'};
  }
  if (!panel) return { steps, headline: '串口已连接',
    detail: '等待演奏状态。' };
  if (!panel.test && !panel.calibrated) return { steps,
    headline: '请先完成摇杆校准',
    detail: '松开演奏区、摇杆回中；按住 Z2 后点按 FPGA KEY2（逻辑复位），约 1 秒后松开 Z2。' };
  if (!waveFresh) return { steps, headline: '演奏状态已更新',
    detail: '等待数字合成状态。' };
  if (panel.test) return { steps,
    headline: state.outputActive ? '测试音数字合成中' : '测试模式 · 数字静音',
    detail: state.outputActive ?
      '正在输出测试音数据。' : '检查测试模式状态。' };
  if (!gateCount) return { steps, headline: '等待按压演奏区',
    detail: '按下后，这里会显示触发状态。' };
  if (!state.outputActive) return { steps, headline: '已触发 · 数字静音',
    detail: '请查看合成状态。' };
  return { steps, headline: '正在演奏',
    detail: '四区触发与数字合成正在更新。' };
}
