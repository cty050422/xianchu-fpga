import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { TelemetryParser, diagnoseTelemetry, phaseToHz } from './protocol.mjs';
import { describePitch, estimateVibrato, initialState, joystick2View,
  updatePerformance, zoneViews } from './music.mjs';
import { signalPath } from './evidence.mjs';

function frame(type, payload) {
  const body = [0xA5, type, payload.length, ...payload];
  return Uint8Array.from([...body, body.reduce((a, b) => (a + b) & 255, 0)]);
}
function put16(p, n, v) { p[n] = v & 255; p[n + 1] = (v >> 8) & 255; }
function put32(p, n, v) { for (let i = 0; i < 4; i++) p[n + i] = (v >>> (8 * i)) & 255; }
function wave(seq, hz = 440) {
  const p = new Uint8Array(51);
  put16(p, 0, seq); p[3] = 1;
  put32(p, 4, Math.round(hz * 4294967296 / 48000));
  put32(p, 8, 0x0000ffff);
  p.set([0x80, 0xff, 0x00, 0x7f], 19);
  return frame(0x21, p);
}
function performance(seq, { extended = true, x = 2050, y = 2800,
  pressures = [0, 0, 0, 0], wetTarget = 64, wetActual = 48,
  harmonicAxisMode = false, mask = 0x0000ffff, panel = false } = {}) {
  const p = new Uint8Array(panel ? 53 : extended ? 39 : 27);
  put16(p, 0, seq); p[3] = 1; p[12] = 2; p[13] = 16; p[14] = 2;
  pressures.forEach((value, index) => put16(p, 4 + 2 * index, value));
  put32(p, 15, mask); put32(p, 19, Math.round(440 * 4294967296 / 48000));
  if (extended) {
    put16(p, 27, x); put16(p, 29, y);
    p[31] = 1 | 2 | 16 | 32 | 128;
    p[32] = 1 | (harmonicAxisMode ? 128 : 0); p[33] = wetTarget; p[34] = wetActual;
    if (panel) {
      p[39] = 1; p[40] = 1 | 2 | 4 | 32; p[41] = 5; p[42] = 4;
      p[43] = 1; p[44] = 5; put16(p,45,12); put16(p,47,2); put16(p,49,3);
      p[51] = 29;
    }
  }
  return frame(0x22, p);
}

test('all dashboard element references exist in the HTML', () => {
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
  const app = readFileSync(new URL('./app.mjs', import.meta.url), 'utf8');
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  const refList = app.match(/const refs = Object\.fromEntries\(\[([\s\S]*?)\]\.map/);
  assert.ok(refList, 'the static element-reference list should exist');
  for (const [, id] of refList[1].matchAll(/'([^']+)'/g))
    assert.ok(ids.has(id), `missing #${id}`);
  for (let zone = 0; zone < 4; zone++) {
    assert.ok(ids.has(`zoneGate${zone}`));
    assert.ok(ids.has(`zoneMotion${zone}`));
  }
});

test('the local server serves every linked stylesheet and module', () => {
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
  const app = readFileSync(new URL('./app.mjs', import.meta.url), 'utf8');
  const server = readFileSync(new URL('./server.mjs', import.meta.url), 'utf8');
  const linked = [...html.matchAll(/(?:href|src)="\.\/([^\"]+)"/g)].map(match => match[1]);
  const imports = [...app.matchAll(/from '\.\/([^']+)'/g)].map(match => match[1]);
  for (const filename of [...linked, ...imports])
    assert.ok(server.includes(`['/${filename}', '${filename}']`) ||
      server.includes(`['/${filename}', '${filename}'],`), `not served: ${filename}`);
});

test('53-byte panel status reports the new gesture and LED guide state', () => {
  const got=[];
  new TelemetryParser(item=>got.push(item)).push(performance(4,{panel:true,harmonicAxisMode:true}));
  assert.equal(got.length,1);
  assert.deepEqual(got[0].panel, {version:1,group:1,octave:1,guide:true,panic:false,
    test:false,calibrated:true,step:5,target:4,expression:1,leds:5,
    hits:12,wrong:2,misses:3,partialTarget:29,calRefused:false,audition:false});
  const state=initialState();updatePerformance(state,got[0],1000);
  assert.equal(joystick2View(state,1000).partialTarget,29);
});

test('phase increment reports musical A4 at 440 Hz', () => {
  const inc = Math.round(440 * 4294967296 / 48000);
  assert.ok(Math.abs(phaseToHz(inc) - 440) < 0.001);
  assert.equal(describePitch(phaseToHz(inc)).note, 'A4');
});

test('split frames, 0x22 extended status and sequence decode', () => {
  const got = [];
  const parser = new TelemetryParser(item => got.push(item));
  const bytes = Uint8Array.from([...wave(65535), ...performance(0)]);
  parser.push(bytes.slice(0, 6));
  parser.push(bytes.slice(6, 57));
  parser.push(bytes.slice(57));
  assert.equal(parser.valid, 2);
  assert.equal(parser.missing, 0);
  assert.equal(got[0].kind, 'wave');
  assert.equal(got[0].samples.length, 32);
  assert.deepEqual(got[0].samples.slice(0, 4), [-128, -1, 0, 127]);
  assert.equal(got[1].kind, 'performance');
  assert.equal(got[1].owner, 2);
  assert.equal(got[1].partials, 16);
  assert.equal(got[1].nextPreset, 1);
  assert.equal(got[1].harmonicAxisMode, false);
  assert.equal(got[1].wetActual, 48);
  assert.equal(got[1].axisXCode, 2050);
  assert.equal(got[1].axisYCode, 2800);
  assert.equal(got[1].presetOverride, true);
  assert.equal(got[1].z2Pressed, true);
});

test('new mapping marker separates CH6 partial count from old preset override', () => {
  const got = [];
  new TelemetryParser(item => got.push(item)).push(performance(3, {
    harmonicAxisMode: true, mask: 0x00ffffff
  }));
  const state = initialState();
  updatePerformance(state, got[0], 1000);
  const view = joystick2View(state, 1000);
  assert.equal(view.harmonicAxisMode, true);
  assert.equal(view.partialTarget, 24);
  assert.equal(view.nextPreset, 1);
});

test('corrupt checksum is rejected and parser resynchronises', () => {
  const got = [];
  const parser = new TelemetryParser(item => got.push(item));
  const broken = wave(1);
  broken[20] ^= 0x80;
  parser.push(Uint8Array.from([0, 12, ...broken, ...wave(2)]));
  assert.equal(parser.rejected, 1);
  assert.equal(parser.valid, 1);
  assert.equal(got[0].seq, 2);
  assert.equal(parser.checksumFailures, 1);
  assert.equal(parser.receivedBytes, broken.length + wave(2).length + 2);
});

test('diagnostics distinguish no bytes, old binary protocol, ADC text and bad checksum', () => {
  const noBytes = new TelemetryParser(() => {});
  assert.match(diagnoseTelemetry(noBytes, 2000, Infinity), /0 字节/);
  assert.match(diagnoseTelemetry(noBytes, 7000, Infinity), /已等待 6 秒/);
  const legacy = new TelemetryParser(() => {});
  legacy.push(Uint8Array.from([0xA5, 0x5A]));
  legacy.push(Uint8Array.from([0x11, 0x00]));
  assert.equal(legacy.legacyHeaders, 1);
  assert.match(diagnoseTelemetry(legacy, 2000, 0), /配置 B\/C/);
  const ascii = new TelemetryParser(() => {});
  ascii.push(new TextEncoder().encode('ADC CH0=3090 (2.490V)\r\n'));
  assert.equal(ascii.adcTextHeaders, 1);
  assert.match(diagnoseTelemetry(ascii, 2000, 0), /ADC 测试/);
  const bad = new TelemetryParser(() => {});
  const broken = wave(1);
  broken[20] ^= 0x80;
  bad.push(broken);
  assert.match(diagnoseTelemetry(bad, 2000, 0), /校验失败/);
  const valid = new TelemetryParser(() => {});
  valid.push(wave(2));
  assert.match(diagnoseTelemetry(valid, 2000, 0), /暂未收到 0x22/);
  assert.match(diagnoseTelemetry(valid, 2000, 2500, 2500), /没有新字节/);
  assert.match(diagnoseTelemetry(valid, 2000, 0, 2500), /没有有效配置 D 帧/);
});

test('state distinguishes next-note preset and active-zone pitch', () => {
  const got = [];
  new TelemetryParser(item => got.push(item)).push(performance(4));
  const state = initialState();
  updatePerformance(state, got[0], 1000);
  assert.equal(state.nextPreset, 1);
  assert.equal(state.pitch.note, 'A4');
  assert.equal(state.gates, 1);
});

test('quiet DAC windows clear audio results without erasing joystick controls', () => {
  const state = initialState();
  const phaseInc = Math.round(440 * 4294967296 / 48000);
  const wave = peak => ({ kind: 'wave', seq: 1, gates: 1, mask: 0xffffffff,
    phaseInc, peak, clipping: false });
  state.nextPreset = 1;
  state.wetActual = 32;
  updatePerformance(state, wave(12000), 1000);
  assert.equal(state.outputActive, true);
  assert.equal(state.pitch.note, 'A4');
  updatePerformance(state, wave(0), 1021);
  assert.equal(state.outputActive, true);
  updatePerformance(state, wave(0), 1042);
  assert.equal(state.outputActive, false);
  assert.equal(state.pitch, null);
  assert.equal(state.pitchHistory.length, 0);
  assert.equal(state.vibrato, null);
  assert.equal(state.nextPreset, 1);
  assert.equal(state.wetActual, 32);
  updatePerformance(state, wave(12000), 1063);
  assert.equal(state.pitch.note, 'A4');
});

test('joystick 2 motion and four-zone expression evidence use a bounded window', () => {
  const state = initialState();
  const got = [];
  const parser = new TelemetryParser(item => got.push(item));
  parser.push(performance(0, { pressures: [100, 0, 0, 0] }));
  updatePerformance(state, got.pop(), 1000);
  assert.equal(joystick2View(state, 1000).xMotion, null);
  parser.push(performance(1, { x: 2170, y: 2820, pressures: [700, 100, 0, 0] }));
  updatePerformance(state, got.pop(), 1100);
  const view = joystick2View(state, 1100);
  assert.equal(view.status, 'ready');
  assert.equal(view.xMotion, true); // 120-code threshold
  assert.equal(view.yMotion, false);
  assert.equal(view.nextPreset, 1);
  assert.equal(view.wetTargetPct, 25);
  assert.equal(view.wetActualPct, 19);
  assert.equal(view.wetStage, '右端');
  assert.deepEqual(zoneViews(state, 1100).map(zone => zone.expressionMotion),
    [true, false, false, false]); // 512-expression threshold
  assert.equal(zoneViews(state, 1100)[0].gate, true);
  assert.equal(joystick2View(state, 4000).status, 'stale');
  assert.equal(zoneViews(state, 4000)[0].gate, null);
  parser.push(performance(2, { x: 2170, y: 2820, pressures: [700, 100, 0, 0] }));
  updatePerformance(state, got.pop(), 4000);
  assert.equal(joystick2View(state, 4000).xMotion, null);
  assert.equal(zoneViews(state, 4000)[0].expressionMotion, null);
});

test('27-byte status explicitly replaces, rather than inherits, extended joystick data', () => {
  const state = initialState();
  const got = [];
  const parser = new TelemetryParser(item => got.push(item));
  assert.equal(joystick2View(state, 1000).status, 'waiting');
  parser.push(performance(1));
  updatePerformance(state, got.pop(), 1000);
  assert.equal(joystick2View(state, 1000).status, 'ready');
  parser.push(performance(2, { extended: false }));
  updatePerformance(state, got.pop(), 1100);
  assert.equal(joystick2View(state, 1100).status, 'unsupported');
  assert.equal(state.nextPreset, null);
  assert.equal(state.axisXHistory.length, 0);
});

test('vibrato estimator accepts stable 5 Hz pitch movement but not flat notes', () => {
  const history = [];
  for (let t = 0; t <= 1600; t += 21.333) {
    const hz = 440 * 2 ** (12 * Math.sin(2 * Math.PI * 5 * t / 1000) / 1200);
    history.push({ t, hz, active: true });
  }
  const estimate = estimateVibrato(history, 1600);
  assert.ok(estimate && estimate.rate > 4 && estimate.rate < 6);
  assert.ok(estimate.depth > 5 && estimate.depth < 20);
  assert.equal(estimateVibrato(history.map(p => ({ ...p, hz: 440 })), 1600), null);
});

test('signal path keeps demo and disconnected values distinct from live FPGA data', () => {
  const state = initialState();
  const parser = { receivedBytes: 0, valid: 0, waveFrames: 0 };
  const demo = signalPath({ source: 'demo', state, parser, now: 1000 });
  assert.match(demo.headline, /界面演示/);
  assert.ok(demo.steps.every(step => step.tone === 'unknown'));
  const offline = signalPath({ source: 'offline', state, parser, now: 1000 });
  assert.ok(offline.steps.every(step => step.tone === 'unknown'));
  const waiting = signalPath({ source: 'live', state, parser, now: 2000 });
  assert.match(waiting.headline, /等待实时数据/);
});

test('signal path separates calibration, gate and FPGA-reported digital output', () => {
  const state = initialState();
  state.validFrames = 2;
  state.lastFrameAt = 1000;
  state.lastPerformanceAt = 1000;
  state.panel = { calibrated: false, calRefused: true, test: false };
  const parser = { receivedBytes: 200, valid: 2, waveFrames: 1 };
  let view = signalPath({ source: 'live', state, parser, now: 1100, waveAt: 1000 });
  assert.equal(view.steps[1].tone, 'warn');
  assert.match(view.headline, /请先完成摇杆校准/);
  state.panel.calibrated = true;
  state.panel.calRefused = false;
  state.gates = 1;
  state.outputKnown = true;
  state.outputActive = false;
  view = signalPath({ source: 'live', state, parser, now: 1100, waveAt: 1000 });
  assert.match(view.headline, /已触发 · 数字静音/);
  assert.equal(view.steps[2].tone, 'good');
  assert.equal(view.steps[3].tone, 'idle');
  state.outputActive = true;
  view = signalPath({ source: 'live', state, parser, now: 1100, waveAt: 1000 });
  assert.match(view.headline, /正在演奏/);
  view = signalPath({ source: 'live', state, parser, now: 2600, waveAt: 1000 });
  assert.match(view.headline, /等待实时数据/);
  state.lastFrameAt = 2600;
  state.lastPerformanceAt = 2600;
  view = signalPath({ source: 'live', state, parser, now: 2600, waveAt: 1000 });
  assert.match(view.headline, /演奏状态已更新/);
});

test('test tone bypasses FSR gate without claiming analogue output', () => {
  const state = initialState();
  Object.assign(state, {
    validFrames: 2, lastFrameAt: 1000, lastPerformanceAt: 1000,
    panel: { calibrated: false, test: true }, gates: 0,
    outputKnown: true, outputActive: true
  });
  const view = signalPath({ source: 'live', state,
    parser: { receivedBytes: 200, valid: 2, waveFrames: 1 }, now: 1100, waveAt: 1000 });
  assert.equal(view.steps[1].label, '测试模式');
  assert.equal(view.steps[2].label, '内置测试音');
  assert.match(view.headline, /测试音数字合成中/);
});

test('dashboard omits low-rate PCM graph and instrument checklist', () => {
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
  assert.doesNotMatch(html, /pcmChart|proof-board|外部仪器待验/);
  assert.match(html, /设备调试|实时演奏画面/);
});

test('fresh panic status takes precedence over a still-fresh nonzero PCM preview',()=>{
 const state=initialState();Object.assign(state,{validFrames:2,lastFrameAt:1000,lastPerformanceAt:1000,
  panel:{calibrated:true,panic:true,test:false},gates:1,outputKnown:true,outputActive:true});
 const view=signalPath({source:'live',state,parser:{waveFrames:1},now:1100,waveAt:1000});
 assert.match(view.headline,/静音|紧急停止/);assert.doesNotMatch(view.headline,/正在演奏/);
});
