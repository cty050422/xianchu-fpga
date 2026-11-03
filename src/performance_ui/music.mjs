import { phaseToHz } from './protocol.mjs';

const NAMES = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
export const JOYSTICK_MOTION_WINDOW_MS = 2500;
export const JOYSTICK_MOTION_DELTA = 120;
export const EXPRESSION_MOTION_DELTA = 512;
// 32/32768 is about -60 dBFS. Two quiet 0x21 windows avoid blanking on a
// single low-level window while still clearing the display after ~43 ms.
export const SILENCE_PEAK_LIMIT = 32;
export const SILENCE_WAVE_WINDOWS = 2;
const WET_STAGES = new Map([[0, '左端 · 干声'], [16, '偏左'], [32, '回中'],
                            [48, '偏右'], [64, '右端']]);

function observedMotion(history, threshold = JOYSTICK_MOTION_DELTA) {
  if (history.length < 2) return null;
  const codes = history.map(point => point.code);
  return Math.max(...codes) - Math.min(...codes) >= threshold;
}

function rememberMotion(history, code, now) {
  if (Number.isInteger(code)) history.push({ t: now, code });
  while (history.length && now - history[0].t > JOYSTICK_MOTION_WINDOW_MS)
    history.shift();
}

// Semantic diagnostics from the extended 0x22 record. Raw axis codes never leave this module.
export function joystick2View(state, now) {
  if (!state.lastPerformanceAt) return { status: 'waiting' };
  if (now - state.lastPerformanceAt > 1800) return { status: 'stale' };
  if (!state.extended) return { status: 'unsupported' };
  return {
    status: 'ready',
    ageMs: Math.max(0, now - state.lastPerformanceAt),
    xHealth: !state.xCenterValid ? 'uncalibrated' : state.xStale ? 'stale' : 'valid',
    yHealth: !state.yCenterValid ? 'uncalibrated' : state.yStale ? 'stale' : 'valid',
    xMotion: observedMotion(state.axisXHistory),
    yMotion: observedMotion(state.axisYHistory),
    presetOverride: state.presetOverride,
    nextPreset: state.nextPreset,
    harmonicAxisMode: state.harmonicAxisMode,
    partialTarget: state.panel?.partialTarget ?? (state.harmonicAxisMode ? 32 - Math.clz32(state.mask) : null),
    z2Pressed: state.z2Pressed,
    wetTargetPct: state.wetTarget === null ? null : Math.round(state.wetTarget / 256 * 100),
    wetActualPct: state.wetActual === null ? null : Math.round(state.wetActual / 256 * 100),
    wetStage: WET_STAGES.get(state.wetTarget) ?? '档位切换中'
  };
}

// Gate is the effective FPGA trigger; expression motion is not raw FSR voltage.
export function zoneViews(state, now) {
  const gateFresh = state.validFrames > 0 && now - state.lastFrameAt <= 1500;
  const pressureFresh = state.lastPerformanceAt > 0 && now - state.lastPerformanceAt <= 1800;
  return state.zonePressureHistory.map((history, index) => ({
    gate: gateFresh ? Boolean(state.gates & (1 << index)) : null,
    expressionMotion: pressureFresh ? observedMotion(history, EXPRESSION_MOTION_DELTA) : null
  }));
}

export function describePitch(hz) {
  if (!Number.isFinite(hz) || hz < 20 || hz > 5000) return null;
  const midiFloat = 69 + 12 * Math.log2(hz / 440);
  const midi = Math.round(midiFloat);
  return { hz, note: `${NAMES[(midi % 12 + 12) % 12]}${Math.floor(midi / 12) - 1}`,
    cents: (midiFloat - midi) * 100, midi };
}

// This is an estimate from the transmitted selected voice, not a microphone measurement.
// Slow manual slides can otherwise look like vibrato: require a 3–8 Hz oscillation and
// enough crossings in a 1.6 s window before showing a rate.
export function estimateVibrato(history, now) {
  const items = history.filter(point => point.active && now - point.t <= 1600 && point.hz > 0);
  if (items.length < 28 || items.at(-1).t - items[0].t < 900) return null;
  const times = items.map(point => (point.t - items[0].t) / 1000);
  const cents = items.map(point => 1200 * Math.log2(point.hz / items[0].hz));
  const span = times.at(-1) - times[0];
  const slope = (cents.at(-1) - cents[0]) / span;
  const residual = cents.map((value, i) => value - cents[0] - slope * times[i]);
  const sorted = [...residual].sort((a, b) => a - b);
  const center = sorted[Math.floor(sorted.length / 2)];
  const deviations = residual.map(value => value - center);
  const depth = (sorted[Math.floor(sorted.length * 0.9)] -
                 sorted[Math.floor(sorted.length * 0.1)]) / 2;
  if (depth < 3 || depth > 90) return null;
  const crossings = [];
  for (let i = 1; i < deviations.length; i++) {
    if (deviations[i - 1] <= 0 && deviations[i] > 0) crossings.push(times[i]);
  }
  if (crossings.length < 4) return null;
  const intervals = crossings.slice(1).map((time, i) => time - crossings[i]);
  const mean = intervals.reduce((a, b) => a + b, 0) / intervals.length;
  const rate = 1 / mean;
  if (rate < 3 || rate > 8) return null;
  return { rate, depth };
}

export function updatePerformance(state, frame, now) {
  state.lastFrameAt = now;
  state.validFrames++;
  state.gates = frame.gates;
  state.clipping = frame.clipping;
  state.phaseInc = frame.phaseInc;
  if (frame.kind === 'levels') {
    // S10/S14: post-gain per-voice window peaks + the additive layer peak.
    // The panel bars read these instead of fabricating levels from gates.
    state.voiceLevels = frame.voiceLevels;
    state.layerLevel = frame.layerLevel;
    state.lastLevelsAt = now;
    return;
  }
  if (frame.kind === 'performance') {
    state.lastPerformanceAt = now;
    state.panel = frame.panel ?? null;
    state.partials = frame.partials;
    state.mask = frame.mask;
    state.effectMode = frame.effectMode;
    state.owner = frame.owner;
    state.extended = Boolean(frame.extended);
    frame.zonePressure?.forEach((code, index) =>
      rememberMotion(state.zonePressureHistory[index], code, now));
    if (frame.extended) {
      state.nextPreset = frame.nextPreset;
      state.harmonicAxisMode = frame.harmonicAxisMode;
      state.wetTarget = frame.wetTarget;
      state.wetActual = frame.wetActual;
      state.xCenterValid = frame.xCenterValid;
      state.yCenterValid = frame.yCenterValid;
      state.xStale = frame.xStale;
      state.yStale = frame.yStale;
      state.presetOverride = frame.presetOverride;
      state.fxReady = frame.fxReady;
      state.z1Pressed = frame.z1Pressed;
      state.z2Pressed = frame.z2Pressed;
      rememberMotion(state.axisXHistory, frame.axisXCode, now);
      rememberMotion(state.axisYHistory, frame.axisYCode, now);
    } else {
      // An older 27-byte record must not leave a previous extended status visible.
      state.nextPreset = null;
      state.harmonicAxisMode = null;
      state.wetTarget = null;
      state.wetActual = null;
      state.xCenterValid = null;
      state.yCenterValid = null;
      state.xStale = null;
      state.yStale = null;
      state.presetOverride = null;
      state.fxReady = null;
      state.z1Pressed = null;
      state.z2Pressed = null;
      state.axisXHistory.length = 0;
      state.axisYHistory.length = 0;
    }
  } else {
    state.mask = frame.mask;
    if (Number.isInteger(frame.peak)) {
      state.outputKnown = true;
      if (frame.peak > SILENCE_PEAK_LIMIT) {
        state.outputActive = true;
        state.quietWaveWindows = 0;
      } else {
        state.quietWaveWindows++;
        if (state.quietWaveWindows >= SILENCE_WAVE_WINDOWS)
          state.outputActive = false;
      }
    }
  }
  // A note gate or a harmonic mask can remain set while the actual DAC PCM is
  // silent. Once a wave peak is available, use that output evidence instead.
  const active = state.outputKnown ? state.outputActive : Boolean(frame.gates || frame.mask);
  const hz = active ? phaseToHz(frame.phaseInc) : 0;
  state.pitch = active ? describePitch(hz) : null;
  if (!active) {
    state.pitchHistory.length = 0;
    state.vibrato = null;
    return state;
  }
  state.pitchHistory.push({ t: now, hz, active });
  while (state.pitchHistory.length && now - state.pitchHistory[0].t > 6500)
    state.pitchHistory.shift();
  state.vibrato = estimateVibrato(state.pitchHistory, now);
  return state;
}

export function initialState() {
  return {
    lastFrameAt: 0, lastPerformanceAt: 0, validFrames: 0, gates: 0, panel: null,
    outputKnown: false, outputActive: false, quietWaveWindows: 0,
    pitch: null, pitchHistory: [], vibrato: null, nextPreset: null, harmonicAxisMode: null,
    wetTarget: null, wetActual: null, partials: 0, mask: 0,
    effectMode: null, owner: null, clipping: false, extended: false,
    xCenterValid: null, yCenterValid: null, xStale: null, yStale: null,
    presetOverride: null, fxReady: null, z1Pressed: null, z2Pressed: null,
    axisXHistory: [], axisYHistory: [],
    zonePressureHistory: Array.from({ length: 4 }, () => [])
  };
}
