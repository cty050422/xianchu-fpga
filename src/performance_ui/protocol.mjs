// Configuration-D UART telemetry. The 0x21 waveform is an 8-bit, decimated
// preview of FPGA PCM, not a full-rate audio capture or DAC analogue measurement.
export const SAMPLE_RATE = 48_000;
const SYNC = 0xA5;
const WAVE = 0x21;
const PERF = 0x22;
const LEVELS = 0x23;          // S10 voice-level meter: seq, flags, 4x16 LE, layer 16 LE
const WAVE_LEN = 51;
const PERF_LENS = new Set([27, 39, 53]);
const LEVELS_LEN = 13;

const u16 = (p, n) => p[n] | (p[n + 1] << 8);
const u32 = (p, n) => (p[n] | (p[n + 1] << 8) | (p[n + 2] << 16) | (p[n + 3] << 24)) >>> 0;

export function phaseToHz(phaseInc) {
  return phaseInc * SAMPLE_RATE / 4294967296;
}

export function decodeFrame(type, payload) {
  if (type === WAVE && payload.length === WAVE_LEN) {
    return {
      kind: 'wave', seq: u16(payload, 0), gates: payload[3] & 15,
      phaseInc: u32(payload, 4), mask: u32(payload, 8),
      peak: u16(payload, 17), clipping: Boolean(payload[2] & 4),
      // payload[19..50] is pcm[15:8], i.e. signed two's-complement int8.
      samples: Array.from(payload.slice(19, 51), value => value < 128 ? value : value - 256)
    };
  }
  if (type === LEVELS && payload.length === LEVELS_LEN) {
    return {
      kind: 'levels', seq: u16(payload, 0), flags: payload[2],
      // Post-gain window peaks per voice (the SAME window the 0x21/0x22 of
      // this seq describe) plus the additive-layer window peak.
      voiceLevels: [u16(payload, 3), u16(payload, 5), u16(payload, 7), u16(payload, 9)],
      layerLevel: u16(payload, 11)
    };
  }
  if (type === PERF && PERF_LENS.has(payload.length)) {
    const status = payload.length >= 39 ? payload[31] : null;
    const panel = payload.length === 53 && payload[39] === 1 ? {
      version: 1, group: payload[40] & 1, octave: (payload[40] >> 1) & 1,
      guide: Boolean(payload[40] & 4), panic: Boolean(payload[40] & 8),
      test: Boolean(payload[40] & 16), calibrated: Boolean(payload[40] & 32),
      step: payload[41], target: payload[42] & 15, expression: payload[43],
      leds: payload[44] & 15, hits: u16(payload,45), wrong: u16(payload,47),
      misses: u16(payload,49), partialTarget: payload[51], calRefused: Boolean(payload[52]&1), audition:Boolean(payload[52]&2)
    } : null;
    return {
      kind: 'performance', panel, seq: u16(payload, 0), gates: payload[3] & 15,
      // Four post-calibration FPGA expression values, used only for semantic motion evidence.
      zonePressure: [u16(payload, 4), u16(payload, 6), u16(payload, 8), u16(payload, 10)],
      owner: payload[12] & 3, partials: payload[13] & 63,
      effectMode: payload[14] & 3, mask: u32(payload, 15),
      phaseInc: u32(payload, 19), clipping: Boolean(payload[2] & 4),
      extended: status !== null,
      xCenterValid: status === null ? null : Boolean(status & 1),
      yCenterValid: status === null ? null : Boolean(status & 2),
      xStale: status === null ? null : Boolean(status & 4),
      yStale: status === null ? null : Boolean(status & 8),
      presetOverride: status === null ? null : Boolean(status & 16),
      fxReady: status === null ? null : Boolean(status & 32),
      z1Pressed: status === null ? null : Boolean(status & 64),
      z2Pressed: status === null ? null : Boolean(status & 128),
      // Internal motion diagnostics only; the UI never displays these ADC codes.
      axisXCode: status === null ? null : u16(payload, 27) & 0xfff,
      axisYCode: status === null ? null : u16(payload, 29) & 0xfff,
      nextPreset: status === null ? null : payload[32] & 3,
      harmonicAxisMode: status === null ? null : Boolean(payload[32] & 128),
      wetTarget: status === null ? null : payload[33],
      wetActual: status === null ? null : payload[34]
    };
  }
  return null;
}

export class TelemetryParser {
  constructor(onFrame) {
    this.onFrame = onFrame;
    this.bytes = [];
    this.receivedBytes = 0;
    this.waveFrames = 0;
    this.performanceFrames = 0;
    this.levelsFrames = 0;
    this.expectedHeaders = 0;
    this.legacyHeaders = 0;
    this.adcTextHeaders = 0;
    this.checksumFailures = 0;
    this.signature = [];
    this.valid = 0;
    this.rejected = 0;
    this.missing = 0;
    this.lastSeq = null;
  }

  push(chunk) {
    if (!chunk?.length) return;
    this.receivedBytes += chunk.length;
    for (const byte of chunk) {
      this.bytes.push(byte);
      this.signature.push(byte);
      if (this.signature.length > 4) this.signature.shift();
      const s = this.signature;
      if (s.length >= 3) {
        const n = s.length;
        if (s[n - 3] === 0xA5 && s[n - 2] === 0x5A && (s[n - 1] === 0x11 || s[n - 1] === 0x12))
          this.legacyHeaders++;
        if (s[n - 3] === SYNC && ((s[n - 2] === WAVE && s[n - 1] === WAVE_LEN) ||
            (s[n - 2] === PERF && PERF_LENS.has(s[n - 1])) ||
            (s[n - 2] === LEVELS && s[n - 1] === LEVELS_LEN))) this.expectedHeaders++;
      }
      if (s.length === 4 && s[0] === 0x41 && s[1] === 0x44 && s[2] === 0x43 && s[3] === 0x20)
        this.adcTextHeaders++;
    }
    while (this.bytes.length >= 4) {
      if (this.bytes[0] !== SYNC) {
        this.bytes.shift();
        continue;
      }
      const type = this.bytes[1];
      const length = this.bytes[2];
      // A corrupt LEN must not hold the stream hostage waiting for 255 bytes.
      if (!((type === WAVE && length === WAVE_LEN) ||
            (type === PERF && PERF_LENS.has(length)) ||
            (type === LEVELS && length === LEVELS_LEN))) {
        this.rejected++;
        this.bytes.shift();
        continue;
      }
      const size = length + 4;
      if (this.bytes.length < size) break;
      const body = this.bytes.slice(0, size - 1);
      const sum = body.reduce((total, value) => (total + value) & 255, 0);
      if (sum !== this.bytes[size - 1]) {
        this.rejected++;
        this.checksumFailures++;
        this.bytes.shift();
        continue;
      }
      const frame = decodeFrame(type, this.bytes.slice(3, size - 1));
      this.bytes.splice(0, size);
      if (!frame) continue;
      if (this.lastSeq !== null) {
        const delta = (frame.seq - this.lastSeq + 65536) & 65535;
        if (delta > 1 && delta < 32768) this.missing += delta - 1;
      }
      this.lastSeq = frame.seq;
      this.valid++;
      if (frame.kind === 'wave') this.waveFrames++;
      else if (frame.kind === 'levels') this.levelsFrames = (this.levelsFrames || 0) + 1;
      else this.performanceFrames++;
      this.onFrame(frame);
    }
    // Bound memory if arbitrary serial noise is received.
    if (this.bytes.length > 512) this.bytes.splice(0, this.bytes.length - 512);
  }
}

// This reports transport/protocol health only; it never exposes ADC or PCM samples.
export function diagnoseTelemetry(parser, connectedMs, idleMs, validAgeMs = 0) {
  if (!parser || parser.receivedBytes === 0) {
    if (connectedMs < 1500) return '串口已打开，等待首字节…';
    if (connectedMs < 6000) return '目前 0 字节；旧 ADC 测试程序可能每 5 秒才回显一次，请至少等待 6 秒。';
    return '已等待 6 秒仍为 0 字节：核对数据串口、配置 D 位流和 UART_TX 接线。';
  }
  if (parser.valid > 0) {
    if (validAgeMs > 1500) return idleMs > 1500 ?
      '曾收到配置 D 遥测，但已超过 1.5 秒没有新字节；检查板卡供电或串口连接。' :
      '仍收到字节，但已超过 1.5 秒没有有效配置 D 帧；检查位流版本或串口质量。';
    if (parser.performanceFrames === 0 && connectedMs > 1500)
      return '已收到 0x21 波形帧，暂未收到 0x22 状态帧；部分演奏状态仍不可用。';
    return '配置 D 遥测已通过校验；演奏数据正在更新。';
  }
  if (parser.legacyHeaders > 0)
    return '疑似旧配置 B/C 的 A5 5A 11/12 诊断帧；此界面需要配置 D 的 0x21/0x22 位流。';
  if (parser.adcTextHeaders > 0)
    return '疑似 ADC 测试程序的文字回显；此界面需要配置 D 的 0x21/0x22 位流。';
  if (parser.expectedHeaders > 0 && parser.checksumFailures > 0)
    return '见到配置 D 帧头但校验失败；核对 115200 8N1、时钟和串口信号完整性。';
  if (parser.expectedHeaders > 0)
    return '见到配置 D 帧头，尚未收到完整有效帧；等待下一帧或检查串口连接。';
  return '收到字节，但不是可识别的配置 D 遥测；可能选错端口或烧入了其他程序。';
}
