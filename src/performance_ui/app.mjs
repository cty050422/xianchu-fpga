import { WireCapture } from './wire_capture.mjs';
import { TelemetryParser, diagnoseTelemetry } from './protocol.mjs';
import { initialState, joystick2View, updatePerformance, zoneViews } from './music.mjs';
import { signalPath } from './evidence.mjs';

const $ = id => document.getElementById(id);
const refs = Object.fromEntries([
  'connectionBadge','demoButton','connectButton','notice','noteName','frequency','cents',
  'playingPill','pitchChart','vibratoChart','chartWatermark','vibratoBadge',
  'vibratoRate','vibratoDepth','presetName','presetDescription','presetGlyph',
  'presetStatus','harmonicBars','partialCount','z1State','z2State',
  'joy1XPitch','joy1YVibrato','joy2Badge','panelState','guideState',
  'joy2Availability','joy2UpdateAge','joy2XTarget','joy2XCenter','joy2XMotion',
  'joy2YTarget','joy2YCenter','joy2YMotion','joy2YStage','joy2Override',
  'wetGauge','wetPercent','wetTargetPercent','wetActualPercent',
  'wetTargetFill','wetActualFill','effectMode','effectReady','frameHealth',
  'streamStatus','frameStats','transportDiagnostics','rxSummary','protocolSummary',
  'overviewJoy1','overviewJoy1Detail','overviewJoy2','overviewJoy2Detail',
  'overviewZones','overviewZonesDetail',
  'pathSerial','pathCalibration','pathTrigger','pathPcm','pathHeadline','pathDetail',
  ...Array.from({ length: 4 }, (_, i) => `zoneGate${i}`),
  ...Array.from({ length: 4 }, (_, i) => `zoneMotion${i}`)
].map(id => [id, $(id)]));

let source = 'offline';
let wireCapture = null;
let state = initialState();
let parser = null;
let port = null;
let reader = null;
let connecting = false;
let connectionGeneration = 0;
let demoTimer = null;
let demoFrame = 0;
let connectionError = '';
let connectedAt = 0;
let lastByteAt = 0;
let renderPending = false;
let lastWaveAt = 0;

function scheduleRender() {
  if (renderPending) return;
  renderPending = true;
  requestAnimationFrame(() => {
    renderPending = false;
    render();
  });
}

for (let i = 0; i < 32; i++) {
  const bar = document.createElement('i');
  bar.style.setProperty('--height', `${Math.max(17, 89 - i * 1.7 + 6 * Math.sin(i))}%`);
  refs.harmonicBars.append(bar);
}

function setSource(next) {
  source = next;
  state = initialState();
  lastWaveAt = 0;
  connectionError = '';
  refs.chartWatermark.classList.toggle('hidden', next !== 'demo');
  refs.connectionBadge.className = `badge ${next === 'live' ? 'live' : next === 'demo' ? 'demo' : 'offline'}`;
  refs.connectionBadge.textContent = next === 'demo' ? '界面演示' :
    next === 'live' ? '正在连接' : '未连接';
  refs.notice.classList.toggle('live', next === 'live');
  refs.notice.textContent = next === 'demo' ?
    '界面演示中。连接 FPGA 后可观看实时演奏。' :
    next === 'live' ? '已连接串口，正在接收演奏状态。' :
    '连接 FPGA 串口，开始实时演奏。';
  refs.connectButton.textContent = next === 'live' ? '断开串口' : '连接 FPGA 串口';
  scheduleRender();
}

function stopDemo() {
  if (demoTimer !== null) clearInterval(demoTimer);
  demoTimer = null;
}

function startDemo() {
  connectionGeneration++;
  if (source === 'live') void disconnectSerial();
  stopDemo();
  setSource('demo');
  demoFrame = 0;
  demoTimer = setInterval(() => {
    const now = performance.now();
    const t = demoFrame * 0.04;
    const preset = Math.floor(t / 4) % 2;
    const noteBase = Math.floor(t / 8) % 2 ? 261.626 : 220;
    const bend = t % 8 < 5 ? 13 * Math.sin(2 * Math.PI * 5 * t) : 0;
    const hz = noteBase * 2 ** (bend / 1200);
    const phaseInc = Math.round(hz * 4294967296 / 48000) >>> 0;
    const active = t % 8 < 7.5;
    const axisXCode = 2048 + Math.round(1700 * Math.sin(t / 2));
    const targetPartials = Math.min(32, 2 + (axisXCode >>> 7));
    const mask = targetPartials === 32 ? 0xffffffff : (2 ** targetPartials - 1) >>> 0;
    const common = { seq: demoFrame, gates: active ? 1 : 0, phaseInc, mask,
      peak: active ? 12000 : 0,
      clipping: false };
    const frame = demoFrame % 5 === 4 ? { ...common, kind: 'performance', owner: 0,
      partials: active ? targetPartials : 0, effectMode: 2, extended: true,
      zonePressure: [active ? 9000 + Math.round(2500 * Math.sin(t * 4)) : 0, 0, 0, 0],
      nextPreset: preset, harmonicAxisMode: true,
      wetTarget: 32 + Math.round(32 * Math.sin(t / 2)),
      wetActual: 32 + Math.round(32 * Math.sin(t / 2)), xCenterValid: true,
      yCenterValid: true, xStale: false, yStale: false, presetOverride: false,
      fxReady: true, z1Pressed: false, z2Pressed: false,
      axisXCode,
      axisYCode: 2048 + Math.round(650 * Math.sin(t / 2)) } : { ...common, kind: 'wave',
      samples: Array.from({ length: 32 }, (_, i) => active ?
        Math.round(56 * Math.sin(2 * Math.PI * hz * (t + i / 1500))) : 0) };
    updatePerformance(state, frame, now);
    if (frame.kind === 'wave') lastWaveAt = now;
    demoFrame++;
    scheduleRender();
  }, 40);
}

async function connectSerial() {
  if (connecting || port) return;
  if (!('serial' in navigator)) {
    connectionError = '此浏览器不支持 Web Serial；请用桌面版 Edge / Chrome。'; render(); return;
  }
  connecting = true;
  const generation = ++connectionGeneration;
  let selected;
  try {
    selected = await navigator.serial.requestPort();
    await selected.open({ baudRate:115200, dataBits:8, stopBits:1, parity:'none' });
    if (generation !== connectionGeneration) { await selected.close(); return; }
  } catch (error) {
    if (selected) { try { await selected.close(); } catch {} }
    if (generation === connectionGeneration && error?.name !== 'NotFoundError')
      connectionError = `无法打开串口：${error.message}`;
    render(); return;
  } finally { connecting = false; }
  stopDemo();
  port = selected;
  const capture = new WireCapture();
  wireCapture = capture;
  const startedAt = performance.now();
  const session = { capture, startedAt, generation, parser:null };
  session.parser = new TelemetryParser(frame => {
    if (port !== selected || wireCapture !== capture || generation !== connectionGeneration) return;
    const now = performance.now();
    capture.recordFrame({ at_ms:Math.round(now-startedAt),kind:frame.kind,
      seq:frame.seq??null,type:frame.type??null });
    updatePerformance(state,frame,now);
    if(frame.kind==='wave') lastWaveAt=now;
    scheduleRender();
  });
  parser = session.parser;
  setSource('live'); connectedAt=startedAt; lastByteAt=0;
  void readSerial(selected,session);
}

async function readSerial(selected,session) {
  const owns = () => port===selected && wireCapture===session.capture &&
    connectionGeneration===session.generation;
  try {
    while(selected.readable && owns()) {
      const ownedReader=selected.readable.getReader(); reader=ownedReader;
      try {
        while(owns()) {
          const {value,done}=await ownedReader.read();
          // read() may finish after disconnect/demo/reconnect. Never route its
          // old bytes through the new session's global parser or capture.
          if(done || !owns()) break;
          if(value?.length) {
            lastByteAt=performance.now();
            session.capture.push(value,lastByteAt-session.startedAt);
            session.parser.push(value); scheduleRender();
          }
        }
      } finally {
        ownedReader.releaseLock();
        if(reader===ownedReader) reader=null;
      }
    }
  } catch(error) {
    if(owns()) connectionError=`串口读取中断：${error.message}`;
  } finally {
    // If an API reuses a port object, old cleanup still must not close the
    // newly established session using that object.
    if(port!==selected || owns()) { try { await selected.close(); } catch {} }
    if(owns()) {
      const lastError=connectionError;port=null;setSource('offline');
      if(lastError){connectionError=lastError;refs.notice.textContent=lastError;}
    }
  }
}

async function disconnectSerial() {
  ++connectionGeneration;
  const selected=port,ownedReader=reader; port=null;
  setSource('offline');
  try { await ownedReader?.cancel(); } catch {}
  // The owning read loop releases and closes only its own reader/port.
  if(!selected) return;
}

refs.connectButton.addEventListener('click', () => source === 'live' ? disconnectSerial() : connectSerial());
refs.demoButton.addEventListener('click', startDemo);
if ('serial' in navigator) {
  navigator.serial.addEventListener('disconnect', () => {
    if (source === 'live') void disconnectSerial();
  });
}

function fitCanvas(canvas) {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const width = Math.max(1, Math.floor(canvas.clientWidth * dpr));
  const height = Math.max(1, Math.floor(canvas.clientHeight * dpr));
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, width: canvas.clientWidth, height: canvas.clientHeight };
}

function drawGraph(canvas, points, now, windowMs, color, relative = false) {
  const { ctx, width, height } = fitCanvas(canvas);
  ctx.clearRect(0, 0, width, height);
  ctx.strokeStyle = '#2a3b39';
  ctx.lineWidth = 1;
  for (let y = 1; y <= 3; y++) {
    ctx.beginPath(); ctx.moveTo(0, height * y / 4); ctx.lineTo(width, height * y / 4); ctx.stroke();
  }
  for (let x = 1; x <= 6; x++) {
    ctx.beginPath(); ctx.moveTo(width * x / 7, 0); ctx.lineTo(width * x / 7, height); ctx.stroke();
  }
  const shown = points.filter(p => p.active && p.hz > 0 && now - p.t <= windowMs);
  if (shown.length < 2) return;
  const values = shown.map(p => 1200 * Math.log2(p.hz / 440));
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  const min = relative ? mean - 40 : Math.min(...values) - 30;
  const max = relative ? mean + 40 : Math.max(...values) + 30;
  const span = Math.max(80, max - min);
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.shadowColor = color;
  ctx.shadowBlur = 3;
  ctx.beginPath();
  shown.forEach((p, i) => {
    const x = width * (1 - (now - p.t) / windowMs);
    const y = height - 12 - (height - 24) * (values[i] - min) / span;
    if (i === 0 || p.t - shown[i - 1].t > 180) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  });
  ctx.stroke();
  ctx.shadowBlur = 0;
}

const axisHealth = {
  valid: '回中已确认 · 输入有效',
  uncalibrated: '回中校准未完成',
  stale: '通道数据超时 · 检查接线'
};
const motionLabel = observed => observed === null ? '等待两次状态采样' :
  observed ? '近 2.5 秒检测到明显移动' : '近 2.5 秒未检测到明显移动';
const motionBrief = observed => observed === null ? '待采样' : observed ? '曾有变化' : '无明显变化';
const barFill = percent => `${percent === null ? 0 : Math.max(0, Math.min(100, percent * 4))}%`;

function render() {
  const now = performance.now();
  const path = signalPath({ source, state, parser, now, waveAt: lastWaveAt });
  ['pathSerial', 'pathCalibration', 'pathTrigger', 'pathPcm'].forEach((id, index) => {
    const step = path.steps[index];
    refs[id].dataset.tone = step.tone;
    refs[id].querySelector('strong').textContent = step.label;
    refs[id].querySelector('small').textContent = step.detail;
  });
  refs.pathHeadline.textContent = path.headline;
  refs.pathDetail.textContent = path.detail;
  const fresh = source === 'demo' || (source === 'live' && now - state.lastFrameAt < 1500);
  const perfFresh = fresh && now - state.lastPerformanceAt < 1800;
  const soundActive = fresh && (state.outputKnown ? state.outputActive : Boolean(state.pitch));
  const pitch = soundActive ? state.pitch : null;
  refs.noteName.textContent = pitch?.note ?? '—';
  refs.frequency.innerHTML = pitch ? `${pitch.hz.toFixed(1)} <small>Hz</small>` : '— <small>Hz</small>';
  refs.cents.innerHTML = pitch ? `${pitch.cents >= 0 ? '+' : ''}${pitch.cents.toFixed(1)} <small>cent</small>` : '— <small>cent</small>';
  refs.playingPill.textContent = pitch ? '正在演奏' : fresh ? '当前静音' : '等待数据';
  refs.playingPill.classList.toggle('active', Boolean(pitch));
  const vib = pitch && fresh ? state.vibrato : null;
  refs.vibratoBadge.textContent = vib ? '观察到颤音' : '等待稳定音';
  refs.vibratoRate.innerHTML = vib ? `${vib.rate.toFixed(1)} <small>Hz</small>` : '— <small>Hz</small>';
  refs.vibratoDepth.innerHTML = vib ? `±${vib.depth.toFixed(0)} <small>cent</small>` : '— <small>cent</small>';
  refs.joy1XPitch.textContent = pitch ? `${pitch.note} · ${pitch.hz.toFixed(1)} Hz` :
    fresh ? '当前静音' : '等待演奏';
  refs.joy1YVibrato.textContent = vib ? `${vib.rate.toFixed(1)} Hz · ±${vib.depth.toFixed(0)} cent` :
    pitch ? '等待稳定颤音' : '当前静音';
  const soundingHistory = soundActive ? state.pitchHistory : [];
  drawGraph(refs.pitchChart, soundingHistory, now, 6000, '#99e5ca');
  drawGraph(refs.vibratoChart, soundingHistory, now, 1600, '#eac09a', true);

  const joy2 = source === 'offline' ? { status: 'offline' } : joystick2View(state, now);
  const joy2Ready = joy2.status === 'ready';
  const panel = joy2Ready ? state.panel : null;
  refs.panelState.textContent = panel?.audition ? '曲谱试听中 · FPGA 实时合成' : panel ?
    `音组 ${panel.group ? 'B' : 'A'} · ${panel.octave ? '高八度' : '标准八度'} · ${panel.panic ? '紧急停止' : panel.test ? '32 分量测试音' : panel.calibrated ? '准备演奏' : '待校准'}` :
    '等待演奏设置';
  const guideZone=panel?.target ? '按区 '+[0,1,2,3].filter(i=>panel.target&(1<<i)).map(i=>i+1).join('+') : '休止 / 等待目标区';
  refs.guideState.textContent = panel?.audition ? '曲谱试听 · 在手机选择曲谱、修订与停止' : panel ? panel.guide ?
    `曲目引导 · 第 ${panel.step+1} 步 · ${guideZone} · ${['正常按音','滑音：摇杆1 X','颤音：摇杆1 Y'][panel.expression] ?? '等待提示'} · 命中 ${panel.hits} / 错按 ${panel.wrong} / 漏拍 ${panel.misses}` :
    '自由演奏 · Z2 双击开启 LED 曲目引导' : '曲目模式：等待数据';
  const presetKnown = joy2Ready && joy2.nextPreset !== null;
  refs.presetName.textContent = presetKnown ? ['拨弦 · PLUCK','吹管 · WIND','钟声 · BELL','合成贝斯 · BASS'][state.nextPreset] ?? '未知音色' : '—';
  refs.presetDescription.textContent = presetKnown ?
    '松开后重新按下，就会使用这一音色。' :
    joy2.status === 'unsupported' ? '当前程序未上报音色。' : '等待音色状态。';
  refs.presetGlyph.textContent = presetKnown ? ['♪','≈','♧','∿'][state.nextPreset] : '—';
  refs.presetGlyph.classList.toggle('wind', Boolean(presetKnown && state.nextPreset));
  refs.presetStatus.textContent = presetKnown ? state.harmonicAxisMode ? 'Z2 切换音色' :
    state.presetOverride ? '旧版控制' : 'Z 切换音色' : '等待音色';
  [...refs.harmonicBars.children].forEach((bar, index) =>
    bar.classList.toggle('on', Boolean(soundActive && perfFresh && ((state.mask >>> index) & 1))));
  const partialTarget = panel?.partialTarget ?? (joy2Ready ? joy2.partialTarget : null);
  refs.partialCount.textContent = soundActive && perfFresh ?
    `${state.partials} / ${partialTarget ?? '—'}` : '— / —';

  const zones = zoneViews(state, now);
  for (const [index, element] of [...document.querySelectorAll('.zone')].entries()) {
    const zone = zones[index];
    element.classList.toggle('active', zone.gate === true);
    refs[`zoneGate${index}`].textContent = zone.gate === null ? '等待状态' :
      zone.gate ? '按下 · 已触发' : '未按下';
    refs[`zoneMotion${index}`].textContent = zone.expressionMotion === null ? '力度待观察' :
      zone.expressionMotion ? '力度有变化' : '力度稳定';
  }
  refs.overviewJoy1.textContent = pitch ? `${pitch.note} · ${pitch.hz.toFixed(1)} Hz` :
    fresh ? '当前静音' : '等待演奏';
  refs.overviewJoy1Detail.textContent = vib ? `颤音约 ${vib.rate.toFixed(1)} Hz` :
    'X 滑音 · Y 颤音';
  refs.overviewJoy2.textContent = joy2Ready ?
    `${['拨弦','吹管','钟声','合成贝斯'][joy2.nextPreset] ?? '未知音色'} · ${joy2.harmonicAxisMode ? `${joy2.partialTarget} 分量` : '旧版控制'} · 合唱 ${joy2.wetTargetPct}%` :
    joy2.status === 'unsupported' ? '当前程序未上报' :
      joy2.status === 'stale' ? '状态暂时中断' : '等待摇杆状态';
  refs.overviewJoy2Detail.textContent = joy2Ready ?
    `近 2.5 秒：X ${motionBrief(joy2.xMotion)} · Y ${motionBrief(joy2.yMotion)}` :
    'X 分量 · Y 合唱 · Z 音色';
  const gateCount = zones.filter(zone => zone.gate === true).length;
  const gateKnown = zones.some(zone => zone.gate !== null);
  refs.overviewZones.textContent = gateKnown ? `${gateCount} / 4 区已触发` : '等待门控数据';
  refs.overviewZonesDetail.textContent = gateKnown ?
    gateCount ? `有效区：${zones.flatMap((zone, index) => zone.gate ? [`CH${index}`] : []).join('、')}` :
      '轻压任一区开始演奏' : '四个独立演奏区';
  refs.z1State.textContent = joy2Ready ? state.z1Pressed ? '采样时 Z 按下' : '采样时 Z 松开' : 'Z 状态未知';
  refs.z2State.textContent = joy2Ready ? joy2.z2Pressed ? '采样时 Z 按下' : '采样时 Z 松开' : 'Z 状态未知';
  refs.z1State.classList.toggle('down', Boolean(joy2Ready && state.z1Pressed));
  refs.z2State.classList.toggle('down', Boolean(joy2Ready && joy2.z2Pressed));
  const joy2Messages = {
    offline: '等待连接。',
    waiting: '等待摇杆状态。',
    stale: '摇杆状态暂时中断。',
    unsupported: '当前程序未上报摇杆状态。',
    ready: '摇杆状态实时更新。'
  };
  refs.joy2Availability.textContent = joy2Messages[joy2.status];
  refs.joy2Badge.textContent = joy2Ready ?
    joy2.xHealth === 'valid' && joy2.yHealth === 'valid' ? '双轴就绪' : '检查摇杆 2' :
    joy2.status === 'unsupported' ? '当前程序未上报' : joy2.status === 'stale' ? '状态超时' : '等待状态';
  refs.joy2Badge.classList.toggle('good', joy2Ready && joy2.xHealth === 'valid' && joy2.yHealth === 'valid');
  refs.joy2Badge.classList.toggle('warn', joy2.status === 'unsupported' || joy2.status === 'stale' ||
    (joy2Ready && (joy2.xHealth !== 'valid' || joy2.yHealth !== 'valid')));
  refs.joy2UpdateAge.textContent = joy2Ready ? `更新于 ${Math.round(joy2.ageMs)} ms 前` : '等待更新';
  refs.joy2XTarget.textContent = joy2Ready && joy2.harmonicAxisMode ?
    `${joy2.partialTarget} / 32` : joy2Ready ? '旧版控制' : '—';
  refs.joy2XCenter.textContent = `X 回中 / 数据：${joy2Ready ? axisHealth[joy2.xHealth] : '—'}`;
  refs.joy2YCenter.textContent = `Y 回中 / 数据：${joy2Ready ? axisHealth[joy2.yHealth] : '—'}`;
  refs.joy2XMotion.textContent = `X ${joy2Ready ? motionLabel(joy2.xMotion) : '近 2.5 秒移动：—'}`;
  refs.joy2YMotion.textContent = `Y ${joy2Ready ? motionLabel(joy2.yMotion) : '近 2.5 秒移动：—'}`;
  refs.joy2Override.textContent = joy2Ready ?
    joy2.harmonicAxisMode ? 'X 控分量 · Z2 控音色' :
      '当前程序使用旧版控制' : '控制模式：—';
  refs.joy2YTarget.textContent = joy2Ready ? `目标 ${joy2.wetTargetPct}%` : '—';
  refs.joy2YStage.textContent = joy2Ready ? `Y 档位：${joy2.wetStage}` : 'Y 档位：—';

  refs.wetPercent.textContent = joy2Ready ? `${joy2.wetActualPct}%` : '—';
  refs.wetTargetPercent.textContent = joy2Ready ? `${joy2.wetTargetPct}%` : '—';
  refs.wetActualPercent.textContent = joy2Ready ? `${joy2.wetActualPct}%` : '—';
  refs.wetGauge.style.setProperty('--value', barFill(joy2Ready ? joy2.wetActualPct : null));
  refs.wetTargetFill.style.setProperty('--fill', barFill(joy2Ready ? joy2.wetTargetPct : null));
  refs.wetActualFill.style.setProperty('--fill', barFill(joy2Ready ? joy2.wetActualPct : null));
  refs.effectMode.textContent = !perfFresh ? '—' : ['旁路','固定延迟','合唱','反馈合唱'][state.effectMode] ?? '—';
  refs.effectReady.textContent = !joy2Ready ? '状态未知' :
    state.fxReady ? '效果器就绪' : '缓冲填充中';
  refs.frameHealth.textContent = source === 'demo' ? '界面演示' :
    fresh ? state.clipping ? '数字削波' : '状态正常' : '等待数据';
  refs.streamStatus.textContent = connectionError || (source === 'demo' ? '界面演示' :
    source === 'live' ? fresh ? 'FPGA 实时状态' : '等待状态' : '尚未连接');
  refs.frameStats.textContent = source === 'live' && parser ?
    `有效 ${parser.valid} · 丢帧 ${parser.missing} · 错帧 ${parser.rejected}` :
    source === 'demo' ? `演示帧 ${demoFrame}` : '有效 0 · 丢帧 0';
  if (source === 'live' && parser) {
    refs.rxSummary.textContent = `已收 ${parser.receivedBytes} 字节 · 有效 ${parser.valid} 帧（0x21 ${parser.waveFrames} / 0x22 ${parser.performanceFrames}）· 校验失败 ${parser.checksumFailures}`;
    refs.protocolSummary.textContent = diagnoseTelemetry(parser, now - connectedAt,
      lastByteAt ? now - lastByteAt : Infinity, now - state.lastFrameAt);
    refs.transportDiagnostics.className = `transport-diagnostics ${fresh ? 'ok' : parser.receivedBytes ? 'warn' : 'idle'}`;
  } else {
    refs.rxSummary.textContent = source === 'demo' ? '演示模式' : '未连接';
    refs.protocolSummary.textContent = connectionError || (source === 'demo' ?
      '连接 FPGA 可看实时演奏。' : '连接 FPGA 数据串口。');
    refs.transportDiagnostics.className = 'transport-diagnostics idle';
  }
  if (source === 'live') {
    refs.connectionBadge.className = `badge ${fresh ? 'live' : 'pending'}`;
    refs.connectionBadge.textContent = fresh ? 'FPGA 实时演奏' :
      parser?.valid ? '数据暂时中断' : parser?.receivedBytes ? '正在识别数据' : '等待数据';
  }
}

setSource('offline');
// Valid serial frames request the next browser paint directly; the slow timer only ages timeouts.
setInterval(scheduleRender, 250);
render();

// Software-service status panel: bounded 30 s polling of the gateway health
// endpoint through the UI server's same-origin proxy. Never shows keys; a
// stopped gateway is a valid displayed state, not an error to hide.
async function refreshServicePanel() {
  const panel = document.getElementById('servicePanel');
  const summary = document.getElementById('serviceSummary');
  const detail = document.getElementById('serviceDetail');
  if (!panel || !summary || !detail) return;
  try {
    const res = await fetch('/services/status');
    const status = await res.json();
    if (status.gateway?.reachable) {
      const g = status.gateway.body;
      summary.textContent = `网关已启动（${g.build}）`;
      detail.textContent = `曲库 ${g.catalog?.songs ?? '?'} 首 · ASR ${g.asr?.mode ?? '?'}（${g.asr?.name ?? ''}）· ` +
        `TTS ${g.tts?.mode ?? '?'} · 今日配额 ${g.limits?.turns_used ?? '?'}/${g.limits?.daily_turns ?? '?'}。` +
        (g.asr?.mode === 'live' ? 'LIVE 供应商已启用（消费真实额度）。' : '默认 Mock，未接真实付费 ASR。');
      panel.className = 'transport-diagnostics ok';
    } else {
      summary.textContent = '网关未运行';
      detail.textContent = `曲库/语音后端（${status.gateway_url}）不可达：${status.gateway?.error ?? ''}。` +
        '可用 assistant_gateway 目录启动（见 START_HERE）。小程序曲库页将显示离线缓存。';
      panel.className = 'transport-diagnostics warn';
    }
  } catch (error) {
    summary.textContent = '状态不可用';
    detail.textContent = '无法读取 /services/status（UI 服务器未提供代理？）。';
    panel.className = 'transport-diagnostics warn';
  }
}
refreshServicePanel();
setInterval(refreshServicePanel, 30000);

document.getElementById('exportCapture').addEventListener('click', () => {
  if (!wireCapture) { window.alert('没有实板串口采集。演示数据不能导出为硬件证据。'); return; }
  const report = { ...wireCapture.snapshot(), exported_at: new Date().toISOString(), exported_while_source: source };
  const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)], { type: 'application/json' }));
  const a = document.createElement('a'); a.href = url;
  a.download = `fpga_live_capture_${new Date().toISOString().replace(/[:.]/g, '-')}.json`;
  a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
