// Score schema + four-zone compiler. SINGLE canonical implementation shared by
// the miniprogram, the catalog service and the tests (the gateway loads this
// same file via createRequire). Grounded in rtl/esp_score_link.sv:
//   * MAX_STEPS = 32 per uploaded bank;
//   * STEP payload = index, zone(2b) | expression/hint(2b) << 2, duration_samples(24b, != 0);
//   * there is NO silence/rest step type on the wire — a rest cannot be encoded;
//   * expression 3 is a reserved code, not a documented gesture.
// The compiler therefore REJECTS rests (REST_NOT_ENCODABLE) instead of silently
// re-labelling them, and rejects reserved/unknown expressions.

var STEP_SAMPLES_PER_BEAT_NUM = 2880000 // 60 s * 48000 Hz
var MAX_STEPS = 32
var V2_MAX_STEPS = 64 // 7-bit count, 6-bit step index
var MAX_DURATION_SAMPLES = 0xffffff
var BPM_MIN = 30
var BPM_MAX = 180
var BEATS_DEN = 16 // authored beats must be integer multiples of 1/16

var PRESET_GROUPS = {
  A: { label: '组A', notes: [60, 62, 64, 67], names: ['C4', 'D4', 'E4', 'G4'] },
  B: { label: '组B', notes: [67, 69, 71, 72], names: ['G4', 'A4', 'B4', 'C5'] }
}

function noteName(midi) {
  var names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
  return names[midi % 12] + (Math.floor(midi / 12) - 1)
}

// ---------------------------------------------------------------------------
// Canonical JSON + SHA-256 content hash.
// Both sides run ECMAScript Number::toString, so float literals stringify
// identically; beats are still restricted to exact 1/16 multiples (see below)
// so no 0.1-style representation can sneak into a hashed document.
// ---------------------------------------------------------------------------
function canonicalize(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return '[' + value.map(canonicalize).join(',') + ']'
  var keys = Object.keys(value).sort()
  return '{' + keys.map(function (k) { return JSON.stringify(k) + ':' + canonicalize(value[k]) }).join(',') + '}'
}

// Compact, dependency-free SHA-256 (FIPS 180-4). Pure JS so the exact same code
// runs inside the miniprogram (no node:crypto there) and in Node; the gateway
// tests cross-check it against node:crypto.
var K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

function sha256Hex(input) {
  var bytes = []
  var text = typeof input === 'string' ? input : JSON.stringify(input)
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x80) bytes.push(code)
    else if (code < 0x800) { bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63)) }
    else { bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63)) }
  }
  var bitLen = bytes.length * 8
  bytes.push(0x80)
  while (bytes.length % 64 !== 56) bytes.push(0)
  for (var j = 7; j >= 0; j--) bytes.push((bitLen / Math.pow(2, j * 8)) & 0xff)

  var h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
  var w = new Array(64)
  function rotr(x, n) { return (x >>> n) | (x << (32 - n)) }

  for (var block = 0; block < bytes.length; block += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = (bytes[block + t * 4] << 24) | (bytes[block + t * 4 + 1] << 16) |
             (bytes[block + t * 4 + 2] << 8) | bytes[block + t * 4 + 3]
    }
    for (var t2 = 16; t2 < 64; t2++) {
      var s0 = rotr(w[t2 - 15], 7) ^ rotr(w[t2 - 15], 18) ^ (w[t2 - 15] >>> 3)
      var s1 = rotr(w[t2 - 2], 17) ^ rotr(w[t2 - 2], 19) ^ (w[t2 - 2] >>> 10)
      w[t2] = (w[t2 - 16] + s0 + w[t2 - 7] + s1) | 0
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
    for (var t3 = 0; t3 < 64; t3++) {
      var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
      var ch = (e & f) ^ (~e & g)
      var temp1 = (hh + S1 + ch + K[t3] + w[t3]) | 0
      var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
      var maj = (a & b) ^ (a & c) ^ (b & c)
      var temp2 = (S0 + maj) | 0
      hh = g; g = f; f = e; e = (d + temp1) | 0
      d = c; c = b; b = a; a = (temp1 + temp2) | 0
    }
    h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0; h[3] = (h[3] + d) | 0
    h[4] = (h[4] + e) | 0; h[5] = (h[5] + f) | 0; h[6] = (h[6] + g) | 0; h[7] = (h[7] + hh) | 0
  }
  var out = ''
  for (var m = 0; m < 8; m++) {
    var hex = (h[m] >>> 0).toString(16)
    while (hex.length < 8) hex = '0' + hex
    out += hex
  }
  return out
}

// Hash covers the whole document EXCEPT its own contentHash field.
function scoreContentHash(score) {
  var copy = {}
  for (var key in score) if (key !== 'contentHash' && Object.prototype.hasOwnProperty.call(score, key)) copy[key] = score[key]
  return sha256Hex(canonicalize(copy))
}

// ---------------------------------------------------------------------------
// Structural validation (schema-level, device independent).
// ---------------------------------------------------------------------------
function validateSchema(score) {
  var errors = []
  if (!score || typeof score !== 'object') return [{ code: 'SCHEMA_NOT_OBJECT', message: '曲谱必须是对象' }]
  if (score.schemaVersion !== 1 && score.schemaVersion !== 2)
    errors.push({ code: 'SCHEMA_VERSION', message: 'schemaVersion 必须为 1 或 2（2 支持和弦 zones 与休止）' })
  if (typeof score.songId !== 'string' || !/^[a-z0-9-]{2,64}$/.test(score.songId))
    errors.push({ code: 'SONG_ID', message: 'songId 必须是 2–64 位小写字母/数字/连字符' })
  if (!Number.isInteger(score.revision) || score.revision < 1 || score.revision > 9999)
    errors.push({ code: 'REVISION', message: 'revision 必须是 1–9999 整数' })
  if (typeof score.title !== 'string' || !score.title.trim() || score.title.length > 60)
    errors.push({ code: 'TITLE', message: 'title 必须是 1–60 字符' })
  if (!Number.isInteger(score.difficulty) || score.difficulty < 1 || score.difficulty > 5)
    errors.push({ code: 'DIFFICULTY', message: 'difficulty 必须是 1–5' })
  if (!Array.isArray(score.tags) || score.tags.length > 8 || score.tags.some(function (t) { return typeof t !== 'string' || !t }))
    errors.push({ code: 'TAGS', message: 'tags 必须是至多 8 个非空字符串' })
  if (!Number.isFinite(score.bpm) || score.bpm < BPM_MIN || score.bpm > BPM_MAX)
    errors.push({ code: 'BPM_RANGE', message: 'bpm 必须在 ' + BPM_MIN + '–' + BPM_MAX + '（收到 ' + score.bpm + '）' })
  var ts = score.timeSignature
  if (!Array.isArray(ts) || ts.length !== 2 || ![2, 3, 4, 6, 8].includes(ts[0]) || ![2, 4, 8].includes(ts[1]))
    errors.push({ code: 'TIME_SIGNATURE', message: 'timeSignature 必须形如 [4,4]' })
  if (!score.source || typeof score.source !== 'object' || !score.source.type ||
      !['original', 'public-domain', 'licensed'].includes(score.source.type) ||
      typeof score.source.license !== 'string' || typeof score.source.attribution !== 'string')
    errors.push({ code: 'SOURCE', message: 'source 需含 type(original/public-domain/licensed)、license、attribution' })
  if (!Array.isArray(score.notes) || score.notes.length < 1 || score.notes.length > 512)
    errors.push({ code: 'NOTES_LENGTH', message: 'notes 必须是 1–512 步' })
  if (errors.length) return errors

  for (var i = 0; i < score.notes.length; i++) {
    var note = score.notes[i]
    if (!note || typeof note !== 'object') { errors.push({ code: 'NOTE_SHAPE', index: i, message: '第' + (i + 1) + '步不是对象' }); continue }
    if (note.zone !== null && note.zone !== undefined && (!Number.isInteger(note.zone) || note.zone < 0 || note.zone > 3))
      errors.push({ code: 'ZONE_RANGE', index: i, message: '第' + (i + 1) + '步 zone 必须是 0–3 或 null(休止)' })
    if (note.zones !== undefined) {
      if (score.schemaVersion !== 2) {
        errors.push({ code: 'ZONES_V1', index: i, message: '第' + (i + 1) + '步 zones 和弦数组需要 schemaVersion 2' })
      } else if (!Array.isArray(note.zones) || note.zones.length < 1 || note.zones.length > 4 ||
                 note.zones.some(function (z) { return !Number.isInteger(z) || z < 0 || z > 3 })) {
        errors.push({ code: 'ZONES_RANGE', index: i, message: '第' + (i + 1) + '步 zones 必须是 1–4 个 0–3 的整数' })
      }
    }
    if (note.midi !== undefined && (!Number.isInteger(note.midi) || note.midi < 36 || note.midi > 96))
      errors.push({ code: 'MIDI_RANGE', index: i, message: '第' + (i + 1) + '步 midi 超出 36–96 设备音域' })
    if (note.zone === undefined && note.midi === undefined && note.zones === undefined)
      errors.push({ code: 'NOTE_EMPTY', index: i, message: '第' + (i + 1) + '步缺 zone、midi 或 zones' })
    if (!Number.isFinite(note.beats) || note.beats <= 0 || Math.round(note.beats * BEATS_DEN) !== note.beats * BEATS_DEN || note.beats * BEATS_DEN > 256)
      errors.push({ code: 'BEATS', index: i, message: '第' + (i + 1) + '步 beats 必须是 1/16 的正整数倍且 ≤16 拍' })
    var expr = note.expression || 0
    if (!Number.isInteger(expr) || expr < 0 || expr > 3)
      errors.push({ code: 'EXPRESSION_RANGE', index: i, message: '第' + (i + 1) + '步 expression 必须是 0–3' })
  }
  return errors
}

// ---------------------------------------------------------------------------
// Pitch analysis: how many distinct sounds does the piece really need, and can
// a preset group (or a custom 4-note mapping) cover them?
// ---------------------------------------------------------------------------
function analyzePitches(score) {
  var distinct = []
  var midiNotes = false
  for (var i = 0; i < score.notes.length; i++) {
    var note = score.notes[i]
    if (note.zone === null) continue // rest: contributes no pitch; rejected later
    if (note.midi !== undefined) {
      midiNotes = true
      if (distinct.indexOf(note.midi) < 0) distinct.push(note.midi)
    } else if (note.zone === undefined && note.zones === undefined) {
      return { error: { code: 'NOTE_EMPTY', index: i, message: '第' + (i + 1) + '步既无 midi 也无 zone' } }
    }
  }
  distinct.sort(function (a, b) { return a - b })
  if (distinct.length > 4) {
    return {
      error: {
        code: 'TOO_MANY_PITCHES',
        message: '曲目用到 ' + distinct.length + ' 个不同音高（' + distinct.map(noteName).join(' ') +
          '），超过四区物理上限 4 个；请选择片段或分段练习，不能按音高模 4 压缩'
      }
    }
  }
  var fitsPreset = null
  var names = Object.keys(PRESET_GROUPS)
  for (var g = 0; g < names.length; g++) {
    var preset = PRESET_GROUPS[names[g]]
    if (distinct.every(function (m) { return preset.notes.indexOf(m) >= 0 })) { fitsPreset = names[g]; break }
  }
  return { distinct: distinct, midiNotes: midiNotes, fitsPreset: fitsPreset, needsCustom: midiNotes && !fitsPreset }
}

// ---------------------------------------------------------------------------
// Compile a validated score into uploadable wire steps at a given BPM.
// ---------------------------------------------------------------------------
function beatsToSamples(beats, bpm) {
  // beats is an exact multiple of 1/16: use pure integer arithmetic.
  var sixteenths = Math.round(beats * BEATS_DEN)
  // samples = sixteenths/16 * 60 * 48000 / bpm = sixteenths * 180000 / bpm
  var num = sixteenths * 180000
  var den = bpm
  return Math.round(num / den)
}

function compileScore(score, options) {
  var opts = options || {}
  var errors = validateSchema(score)
  if (errors.length) return { ok: false, errors: errors }

  var bpm = opts.bpm || score.bpm
  if (!Number.isFinite(bpm) || bpm < BPM_MIN || bpm > BPM_MAX)
    return { ok: false, errors: [{ code: 'BPM_RANGE', message: '练习速度必须在 ' + BPM_MIN + '–' + BPM_MAX + ' BPM（收到 ' + bpm + '）' }] }

  var analysis = analyzePitches(score)
  if (analysis.error) return { ok: false, errors: [analysis.error] }

  // Rest handling depends on the wire encoding. v1 STEP has no silence type,
  // so a rest is refused there; the v2 STEP2 encodes it as an empty mask.
  var encoding = opts.encoding === 'v2' ? 'v2' : 'v1'
  for (var r = 0; r < score.notes.length; r++) {
    if (score.notes[r].zone === null && encoding !== 'v2')
      return { ok: false, errors: [{ code: 'REST_NOT_ENCODABLE', index: r, message: '第' + (r + 1) + '步是休止：v1 线协议没有静音类型；请使用 v2 编码（encoding:"v2"，需要支持 0x16/0x17/0x18 的固件）' }] }
    if (score.notes[r].zones !== undefined && encoding !== 'v2')
      return { ok: false, errors: [{ code: 'CHORD_NOT_ENCODABLE', index: r, message: '第' + (r + 1) + '步是和弦：v1 线协议每步只能一个区；请使用 v2 编码' }] }
  }

  // Zone assignment.
  var zoneOfMidi = {}
  var requiredMapping = null
  if (analysis.midiNotes) {
    if (analysis.fitsPreset) {
      var preset = PRESET_GROUPS[analysis.fitsPreset]
      for (var z = 0; z < 4; z++) zoneOfMidi[preset.notes[z]] = z
      requiredMapping = { type: 'preset-group', group: analysis.fitsPreset, label: preset.label + '（' + preset.names.join(' ') + '）', needsConfig: false }
    } else {
      // Distinct pitches (≤4) do not fit a preset: needs custom note fields 1–4.
      var sorted = analysis.distinct.slice()
      for (var s = 0; s < sorted.length; s++) zoneOfMidi[sorted[s]] = s
      var customNotes = sorted.slice()
      while (customNotes.length < 4) customNotes.push(sorted[sorted.length - 1])
      requiredMapping = {
        type: 'custom-notes', notes: customNotes, needsConfig: true,
        label: '自定义四音 ' + customNotes.map(noteName).join(' ') + '（需配置字段1–4）'
      }
    }
  } else {
    requiredMapping = { type: 'panel-group', label: '面板当前组（A/B/八度由演奏者选择）', needsConfig: false }
  }

  // Device capability check for custom mappings.
  var deviceSupportsCustomNotes = opts.deviceSupportsCustomNotes === true
  if (requiredMapping.needsConfig && !deviceSupportsCustomNotes) {
    return {
      ok: false,
      errors: [{
        code: 'MAPPING_REQUIRES_CONFIG',
        message: '该曲目需要自定义四音映射（' + requiredMapping.label + '），但当前设备未协商字段1–4能力；' +
          '请在面板改用组A/B加八度演奏其他曲目，或连接支持字段1–4的固件后配置映射再上传'
      }],
      requiredMapping: requiredMapping
    }
  }

  // Build steps with exact BPM conversion, tracking rounding drift.
  var steps = []
  var exactTotalSixteenths = 0
  var roundedSamples = 0
  for (var i = 0; i < score.notes.length; i++) {
    var note = score.notes[i]
    var zone = note.zone !== undefined ? note.zone : zoneOfMidi[note.midi]
    var expression = note.expression || 0
    if (expression === 3)
      return { ok: false, errors: [{ code: 'EXPRESSION_RESERVED', index: i, message: '第' + (i + 1) + '步 expression=3 是保留编码，当前固件未定义手势，拒绝编码' }] }
    var samples = beatsToSamples(note.beats, bpm)
    if (samples < 1 || samples > MAX_DURATION_SAMPLES)
      return { ok: false, errors: [{ code: 'DURATION_RANGE', index: i, message: '第' + (i + 1) + '步换算 ' + samples + ' 采样，超出 1–' + MAX_DURATION_SAMPLES + '（24位）范围' }] }
    var mask = null
    if (note.zone === null && encoding === 'v2') {
      mask = 0 // rest
    } else if (note.zones !== undefined && encoding === 'v2') {
      mask = 0
      for (var zi = 0; zi < note.zones.length; zi++) mask |= (1 << note.zones[zi])
    } else if (zone !== null && zone !== undefined) {
      mask = 1 << zone
    } else if (encoding === 'v2') {
      mask = 0
    }
    steps.push({ zone: zone, mask: mask, expression: expression, durationSamples: samples, beats: note.beats })
    exactTotalSixteenths += Math.round(note.beats * BEATS_DEN)
    roundedSamples += samples
  }
  var exactSamples = Math.round(exactTotalSixteenths * 180000 / bpm)
  var driftSamples = roundedSamples - exactSamples

  // 32-step segmentation. A segment is uploaded as its own BEGIN/STEP/COMMIT
  // transaction; the next segment needs a fresh upload (the FPGA cannot glue
  // banks into one seamless song).
  var segments = []
  var segmentSize=encoding==='v2'?V2_MAX_STEPS:MAX_STEPS
  for (var start = 0; start < steps.length; start += segmentSize) {
    var chunk = steps.slice(start, start + segmentSize)
    segments.push({
      index: segments.length, startIndex: start,
      steps: chunk,
      label: '第' + (segments.length + 1) + '段/共' + Math.ceil(steps.length / segmentSize) + '段'
    })
  }
  var multiSegment = segments.length > 1

  return {
    ok: true,
    bpm: bpm,
    steps: steps,
    stepCount: steps.length,
    segments: segments,
    multiSegment: multiSegment,
    requiredMapping: requiredMapping,
    durationSeconds: Math.round(roundedSamples / 48000 * 100) / 100,
    roundingDriftSamples: driftSamples,
    // Sounding pitch per zone under the resolved mapping (for UI honesty: the
    // LED zone and the heard pitch must agree).
    zonePitches: analysis.midiNotes
      ? (requiredMapping.type === 'preset-group'
        ? PRESET_GROUPS[requiredMapping.group].notes
        : requiredMapping.notes)
      : null,
    zonePitchNames: analysis.midiNotes
      ? (requiredMapping.type === 'preset-group'
        ? PRESET_GROUPS[requiredMapping.group].names
        : requiredMapping.notes.map(noteName))
      : null,
    contentHash: scoreContentHash(score)
  }
}

// ---------------------------------------------------------------------------
// v2 wire encoder (S04): BEGIN2 0x16 / STEP2 0x17 / COMMIT2 0x18.
// BEGIN2 payload: song_id, count(1..63), segment_index, segment_count.
// STEP2 payload:  index, mask_byte {2'b0, expr[1:0], zone_mask[3:0]}, duration LE24.
// COMMIT2 payload: song_id, steps_crc8 accumulated over every staged payload
// (crc8 of 0x17, index, mask, duration bytes) exactly like esp_score_link.
function crc8Bytes(bytes, begin, end) {
  var crc = 0
  for (var i = begin; i < end; i++) {
    crc ^= bytes[i]
    for (var b = 0; b < 8; b++) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
  }
  return crc
}

function v2Frame(type, sequence, payload) {
  var data = [0xa5, 0x5a, 1, type & 0xff, payload.length & 0xff, sequence & 0xff].concat(payload)
  data.push(crc8Bytes(data, 2, data.length))
  return data
}

// One staged step's contribution to the COMMIT2 CRC: opcode 0x17 then the
// payload bytes, matching rtl/esp_score_link.sv crc8_step2.
function stepsCrcStep(crc, payload) {
  var feed = [0x17].concat(payload)
  for (var i = 0; i < feed.length; i++) {
    crc ^= feed[i]
    for (var b = 0; b < 8; b++) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
  }
  return crc
}

// steps: the compileScore output (each has mask or zone, expression, durationSamples).
function buildV2Transactions(songNumericId, steps, firstSequence) {
  var sequence = (firstSequence || 1) & 0xffff
  var segCount = Math.ceil(steps.length / V2_MAX_STEPS)
  var transactions = []
  for (var seg = 0; seg < segCount; seg++) {
    var chunk = steps.slice(seg * V2_MAX_STEPS, (seg + 1) * V2_MAX_STEPS)
    var frames = [v2Frame(0x16, sequence & 0xff, [songNumericId & 0xff, chunk.length, seg, segCount])]
    sequence = (sequence + 1) & 0xffff
    var crc = 0
    for (var i = 0; i < chunk.length; i++) {
      var st = chunk[i]
      var mask = (st.mask === undefined) ? (st.zone === null || st.zone === undefined ? 0 : (1 << st.zone)) : st.mask
      var dur = st.durationSamples
      var payload = [i & 0xff, (((st.expression || 0) & 3) << 4) | (mask & 0xf),
        dur & 0xff, (dur >>> 8) & 0xff, (dur >>> 16) & 0xff]
      frames.push(v2Frame(0x17, sequence & 0xff, payload))
      sequence = (sequence + 1) & 0xffff
      crc = stepsCrcStep(crc, payload)
    }
    frames.push(v2Frame(0x18, sequence & 0xff, [songNumericId & 0xff, crc]))
    sequence = (sequence + 1) & 0xffff
    transactions.push({
      segmentIndex: seg, segmentCount: segCount,
      stepCount: chunk.length, frames: frames,
      begin: frames[0], commit: frames[frames.length - 1]
    })
  }
  return { transactions: transactions, nextSequence: sequence }
}

module.exports = {
  MAX_STEPS: MAX_STEPS,
  V2_MAX_STEPS: V2_MAX_STEPS,
  buildV2Transactions: buildV2Transactions,
  MAX_DURATION_SAMPLES: MAX_DURATION_SAMPLES,
  BPM_MIN: BPM_MIN,
  BPM_MAX: BPM_MAX,
  PRESET_GROUPS: PRESET_GROUPS,
  canonicalize: canonicalize,
  sha256Hex: sha256Hex,
  scoreContentHash: scoreContentHash,
  validateSchema: validateSchema,
  analyzePitches: analyzePitches,
  beatsToSamples: beatsToSamples,
  compileScore: compileScore,
  noteName: noteName
}
