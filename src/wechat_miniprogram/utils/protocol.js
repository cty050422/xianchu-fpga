const SERVICE_UUID = '7a330001-4b62-4f70-9f60-66706761736d'
const COMMAND_UUID = '7a330002-4b62-4f70-9f60-66706761736d'
const STATUS_UUID = '7a330003-4b62-4f70-9f60-66706761736d'

const SONGS = [
  { id: 1, name: '四区节奏示例A（8步）', steps: [
    [0, 0, 500], [0, 0, 500], [2, 0, 500], [2, 0, 500],
    [3, 1, 500], [3, 0, 500], [2, 2, 800], [1, 0, 700]
  ]},
  { id: 2, name: '四区节奏示例B（8步）', steps: [
    [1, 0, 400], [1, 0, 400], [2, 0, 400], [3, 0, 400],
    [3, 1, 400], [2, 0, 400], [1, 2, 400], [0, 0, 800]
  ]},
  { id: 3, name: '四区音阶练习', steps: [
    [0, 0, 350], [1, 0, 350], [2, 0, 350], [3, 0, 350],
    [3, 2, 500], [2, 1, 500], [1, 0, 350], [0, 0, 700]
  ]},
  // Zone notes must be A/standard = C4 D4 E4 G4. Selecting a score does
  // not change the FPGA note group or octave; the player sets them first.
  { id: 4, name: '玛丽有只小羊羔（26步，A组标准八度）', steps: [
    [2,0,500],[1,0,500],[0,0,500],[1,0,500],[2,0,500],[2,0,500],[2,0,1000],
    [1,0,500],[1,0,500],[1,0,1000],[2,0,500],[3,0,500],[3,0,1000],
    [2,0,500],[1,0,500],[0,0,500],[1,0,500],[2,0,500],[2,0,500],[2,0,500],[2,0,500],
    [1,0,500],[1,0,500],[2,0,500],[1,0,500],[0,0,1000]
  ]}
]

function crc8(bytes, begin, end) {
  let crc = 0
  for (let i = begin; i < end; i += 1) {
    crc ^= bytes[i]
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
    }
  }
  return crc
}

function frame(type, sequence, payload) {
  const data = [0xa5, 0x5a, 1, type & 0xff, payload.length & 0xff, sequence & 0xff].concat(payload)
  data.push(crc8(data, 2, data.length))
  return Uint8Array.from(data).buffer
}

function songFrames(song, firstSequence) {
  let sequence = firstSequence & 0xff
  const frames = [beginFrame(song, sequence++)]
  song.steps.forEach((step, index) => {
    frames.push(stepFrame(step, index, sequence++))
  })
  frames.push(commitFrame(song.id, sequence++))
  return { frames, nextSequence: sequence & 0xff }
}

// Individual builders so the transaction queue can stamp one sequence number
// per written frame instead of pre-computing a whole batch.
function beginFrame(song, sequence) {
  return frame(0x10, sequence, [song.id, song.steps.length])
}

function stepFrame(step, index, sequence) {
  const samples = Math.max(1, Math.min(0xffffff, Math.round(step[2] * 48)))
  return stepFrameSamples(step, index, sequence, samples)
}

// Variant for pre-compiled steps: the score compiler already resolved exact
// 48 kHz sample counts (rational BPM conversion); do not round-trip via ms.
function stepFrameSamples(step, index, sequence, samples) {
  const clamped = Math.max(1, Math.min(0xffffff, samples | 0))
  const flags = (step[0] & 3) | ((step[1] & 3) << 2)
  return frame(0x11, sequence, [index & 0xff, flags, clamped & 0xff,
    (clamped >>> 8) & 0xff, (clamped >>> 16) & 0xff])
}

function commitFrame(songId, sequence) {
  return frame(0x12, sequence, [songId & 0xff])
}

function pingFrame(sequence) {
  return frame(0x14, sequence, [])
}

// FPGA result codes (esp_score_link RESULT_*). E5/E6 are new in this round and
// are reported distinctly so the UI can explain "busy" and "no transaction".
const RESULTS = {
  0x00: '成功', 0xe0: '未知命令', 0xe1: 'CRC 错误', 0xe2: '参数越界',
  0xe3: '曲谱不完整或身份不符', 0xe4: '引导控制被拒绝', 0xe5: 'FPGA 忙（引导中或故障锁存）',
  0xe6: '没有已开始的曲谱事务'
}

function describeResult(code) {
  if (RESULTS[code]) return RESULTS[code]
  return '未定义结果 0x' + Number(code).toString(16)
}

function decodeFlags(flags) {
  return {
    scoreLoaded: !!(flags & 1), guideActive: !!(flags & 2), testMode: !!(flags & 4),
    panicMute: !!(flags & 8), calibrated: !!(flags & 16)
  }
}

function guideControl(start, sequence) {
  return frame(0x13, sequence, [typeof start==='number'?start:(start?1:0)])
}

function decodeStatus(bytes) {
  // Version byte must be 0x01 (PROTOCOL_SPEC_V1.json): a future v2 frame with
  // the same type/length must be dropped, never decoded with v1 assumptions.
  if (bytes.length !== 22 || bytes[2] !== 1 || bytes[3] !== 0x80 || bytes[4] !== 15) return null
  if (crc8(bytes, 2, bytes.length - 1) !== bytes[bytes.length - 1]) return null
  const p = bytes.slice(6, 21)
  return {
    song: p[0], flags: p[1], step: p[2], target: p[3] & 3,
    expression: (p[3] >>> 2) & 3, targetMask:p[3]>>>4,
    extended:!!(p[1]&128), mode:(p[1]&128)?((p[1]>>>5)&3):null,
    preset:(p[1]&128)?((p[10]>>>4)&3):null,
    effectMode:(p[1]&128)?((p[10]>>>2)&3):null,
    mappingReady:(p[1]&128)?!!(p[10]&64):null,
    hits: p[4] | (p[5] << 8), wrong: p[6] | (p[7] << 8),
    misses: p[8] | (p[9] << 8), layout: p[10] & 3,
    partials: p[11] & 63, wet: p[12], commandSequence: p[13], commandResult: p[14]
  }
}


// ---------------------------------------------------------------------------
// Configuration transport (frame 0x15 out, 0x81 back).
//
// The FPGA only accepts a field whose value reaches a real consumer; everything
// else answers UNSUPPORTED with the id of the first field it does accept. This
// table mirrors rtl/config_capability.sv, including which ids are implemented in
// the current image, so the UI can grey out the rest instead of offering a
// control that would be refused.
// ---------------------------------------------------------------------------
const CONFIG_OPS = { SET: 0, COMMIT: 1, GET: 2, ACQUIRE: 3, RELEASE: 4, CAPABILITY: 5 }

const CONFIG_RESULTS = {
  0: '成功', 1: '已暂存，等待提交', 16: '该字段在当前固件没有消费者',
  17: '数值超出范围', 19: '会话已过期，请重新获取授权',
  20: '乐器忙于引导或故障锁存', 22: '没有待提交的参数',
  23: '未取得配置授权或授权属于其他设备', 24: '请求序号重复但内容不同'
}

// `supported: true` means the DEFAULT image really reads this field. The ids are
// the wire ids, so they can be sent unchanged. This table mirrors
// rtl/config_capability.sv (spec 1.1.0, mask 0x3A80FF): fields 1-4 (custom
// per-zone pitch), 5-8 (thresholds), 16 (partial target), 18 (attenuation) and
// 20-22 (next preset/group/octave) have consumers; the rest is refused 16.
const CONFIG_FIELDS = [
  { id: 5, key: 'on_threshold_zone0', label: '1区触发门限', min: 16, max: 4095, supported: true },
  { id: 6, key: 'on_threshold_zone1', label: '2区触发门限', min: 16, max: 4095, supported: true },
  { id: 7, key: 'on_threshold_zone2', label: '3区触发门限', min: 16, max: 4095, supported: true },
  { id: 8, key: 'on_threshold_zone3', label: '4区触发门限', min: 16, max: 4095, supported: true },
  { id: 16, key: 'partial_target', label: '加法分量上限', min: 2, max: 32, supported: true },
  { id: 18, key: 'user_attenuation', label: '输出衰减（0=原音量, 64=静音）', min: 0, max: 64, supported: true },
  { id: 1, key: 'note_zone0', label: '1区自定义音高', min: 36, max: 96, supported: true },
  { id: 2, key: 'note_zone1', label: '2区自定义音高', min: 36, max: 96, supported: true },
  { id: 3, key: 'note_zone2', label: '3区自定义音高', min: 36, max: 96, supported: true },
  { id: 4, key: 'note_zone3', label: '4区自定义音高', min: 36, max: 96, supported: true },
  { id: 17, key: 'chorus_wet_max', label: '合唱湿度上限（64=不限制）', min: 0, max: 64, supported: true },
  { id: 20, key: 'next_preset', label: '下一音色（0拨弦 1吹管 2钟声 3合成贝斯）', min: 0, max: 3, supported: true },
  { id: 21, key: 'next_group', label: '下一音组（0=A组 1=B组）', min: 0, max: 1, supported: true },
  { id: 22, key: 'next_octave', label: '下一八度（0=标准 1=高八度）', min: 0, max: 1, supported: true },
  { id: 13, key: 'bend_range_semitones', label: '弯音范围', min: 1, max: 12, supported: false },
  { id: 14, key: 'vibrato_depth', label: '颤音深度', min: 0, max: 127, supported: false },
  { id: 19, key: 'effect_family', label: '效果族（0经典 1空间）', min: 0, max: 1, supported: true }
]

function configField(id) {
  return CONFIG_FIELDS.find(f => f.id === id) || null
}

function configFrame(options) {
  const op = options.op
  const field = options.field || 0
  const value = options.value || 0
  const token = options.token || 0
  const sequence = options.sequence & 0xff
  return frame(0x15, sequence, [
    op & 0xff, field & 0xff, value & 0xff, (value >>> 8) & 0xff,
    token & 0xff, (token >>> 8) & 0xff, sequence, (options.sequence >>> 8) & 0xff
  ])
}

// Reply payload: op, field, result, value LE, epoch LE, mask LE (22 bits), first field.
function decodeConfigReply(bytes) {
  if (bytes.length !== 18 || bytes[2] !== 1 || bytes[3] !== 0x81 || bytes[4] !== 11) return null
  if (crc8(bytes, 2, bytes.length - 1) !== bytes[bytes.length - 1]) return null
  const p = bytes.slice(6, 17)
  return {
    sequence: bytes[5], op: p[0], field: p[1], result: p[2],
    value: p[3] | (p[4] << 8), epoch: p[5] | (p[6] << 8),
    supportedMask: p[7] | (p[8] << 8) | ((p[9] & 0x3f) << 16),
    firstField: p[10]
  }
}

function describeConfigResult(code) {
  return CONFIG_RESULTS[code] || ('未定义结果 0x' + Number(code).toString(16))
}

function supportsField(mask, id) {
  if (id < 1 || id > 22) return false
  return ((mask >>> (id - 1)) & 1) === 1
}

// One feed function for both reply types. The score status frame (22 bytes) and
// the config reply (18 bytes) are told apart by the length byte, so a single
// notification stream can be demultiplexed without guessing.

// 0x84 four-voice status frame (schema 1): per-voice generation, preset+partials,
// layer PCM, gain and pitch word. Unknown schema versions return null.
function decodeVoices(body) {
  if (!body || !((body[0]===1 && body.length===37)||(body[0]===2 && body.length===45))) return null
  const schema=body[0], stride=schema===2?10:8, voices=[]
  for(let v=0;v<4;v++) {
    const o=5+v*stride, pcm=body[o+2]|(body[o+3]<<8), partials=body[o+1]&63
    if(partials>32 || (schema===2 && (body[o+6]>127 || body[o+7]>3))) return null
    voices.push({generation:body[o],preset:(body[o+1]>>6)&3,partials,
      pcm:pcm&0x8000?pcm-0x10000:pcm,gain:body[o+4],gate:(body[o+5]>>7)&1,
      active:(body[o+5]>>6)&1,effectFamily:(body[o+5]>>5)&1,
      note:schema===2?body[o+6]:null,region:schema===2?body[o+7]:null,
      envelope:schema===2?(body[o+8]|body[o+9]<<8):null,
      pitchHigh:schema===1?((body[o+6]<<8)|body[o+7]):null})
  }
  return {schema,anyActive:!!(body[1]&1),budgetViolation:!!(body[1]&(schema===2?2:64)),
    grants:body[3]|body[4]<<8,voices}
}

function createReplyParser(handlers) {
  let pending = []
  return function feed(arrayBuffer) {
    pending = pending.concat(Array.from(new Uint8Array(arrayBuffer)))
    while (pending.length >= 7) {
      while (pending.length && pending[0] !== 0xa5) pending.shift()
      if (pending.length < 7) return
      if (pending[1] !== 0x5a) { pending.shift(); continue }
      const total = 7 + pending[4]
      if (total > 64) { pending.shift(); continue }
      if (pending.length < total) return
      const candidate = pending.slice(0, total)
      pending = pending.slice(total)
      if(candidate[2]!==1||crc8(candidate,2,candidate.length-1)!==candidate[candidate.length-1])continue;
      if(candidate[3]===0x82){const c=require('./mobile_observer').decodeControl(candidate.slice(6,-1));if(c&&handlers.onControl)handlers.onControl(c);}
      else if(candidate[3]===0x84){const v=decodeVoices(candidate.slice(6,-1));if(v&&handlers.onVoices)handlers.onVoices(v);}
      else if(candidate[3]===0x83){if(handlers.onWaveChunk)handlers.onWaveChunk(candidate.slice(6,-1));}
      else if(candidate[3]===0x85){if(handlers.onEventFrame)handlers.onEventFrame(candidate);}
      else if (candidate[3] === 0x81) {
        const reply = decodeConfigReply(candidate)
        if (reply && handlers.onConfig) handlers.onConfig(reply)
      } else if (candidate[3] === 0x80) {
        const status = decodeStatus(candidate)
        if (status && handlers.onStatus) handlers.onStatus(status)
      }
      // Unknown frame types are dropped here and in decodeStatus above; they are
      // never decoded with v1 assumptions (PROTOCOL_SPEC_V1 version_policy).
    }
  }
}

function createStatusParser(onStatus) {
  let pending = []
  return function feed(arrayBuffer) {
    pending = pending.concat(Array.from(new Uint8Array(arrayBuffer)))
    while (pending.length >= 7) {
      while (pending.length && pending[0] !== 0xa5) pending.shift()
      if (pending.length < 7) return
      if (pending[1] !== 0x5a) { pending.shift(); continue }
      const total = 7 + pending[4]
      if (total > 64) { pending.shift(); continue }
      if (pending.length < total) return
      const candidate = pending.slice(0, total)
      pending = pending.slice(total)
      const status = decodeStatus(candidate)
      if (status) onStatus(status)
    }
  }
}

module.exports = {
  SERVICE_UUID, COMMAND_UUID, STATUS_UUID, SONGS, RESULTS, crc8, frame,
  songFrames, beginFrame, stepFrame, stepFrameSamples, commitFrame, pingFrame, guideControl,
  describeResult, decodeFlags, decodeStatus, createStatusParser,
  CONFIG_OPS, CONFIG_RESULTS, CONFIG_FIELDS, configField, configFrame,
  decodeConfigReply, describeConfigResult, supportsField, createReplyParser, decodeVoices
}
