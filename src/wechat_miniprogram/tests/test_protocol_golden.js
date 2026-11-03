// S01 conformance: the mini-program implementation must reproduce the frozen
// golden samples in docs/protocol/GOLDEN_SAMPLES_V1.json byte for byte.
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const protocol = require('../utils/protocol')

const goldens = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', '..', 'docs', 'protocol', 'GOLDEN_SAMPLES_V1.json'), 'utf8'))

function toBuf(a) { return Uint8Array.from(a).buffer }
function eq(actual, expected, what) {
  assert.deepStrictEqual(Array.from(actual), expected, what)
}

// 1. CRC anchors, including the industry-standard CRC-8/SMBUS check value.
goldens.crc_vectors.forEach(v => {
  const bytes = Array.from(Buffer.from(v.input_hex, 'hex'))
  assert.strictEqual(protocol.crc8(bytes, 0, bytes.length), v.crc,
    `crc8(${v.input_hex || 'empty'})`)
})

// 2. Frame builders reproduce the golden wire bytes.
eq(Array.from(new Uint8Array(protocol.pingFrame(1))), goldens.ping_frame, 'PING')
eq(Array.from(new Uint8Array(protocol.beginFrame({ id: 4, steps: new Array(8).fill(0) }, 0x10))), goldens.begin_frame, 'BEGIN')
eq(Array.from(new Uint8Array(protocol.stepFrameSamples([0, 0, 0], 0, 0x11, 24000))), goldens.step_frame_0, 'STEP 0')
eq(Array.from(new Uint8Array(protocol.stepFrameSamples([1, 1, 0], 1, 0x12, 48000))), goldens.step_frame_1, 'STEP 1')
eq(Array.from(new Uint8Array(protocol.commitFrame(4, 0x13))), goldens.commit_frame, 'COMMIT')

// 3. The golden status frame decodes to the pinned values (first status frame
//    after reset, triggered by the golden PING).
const st = protocol.decodeStatus(goldens.status_frame)
assert.ok(st, 'golden status frame must decode')
assert.strictEqual(goldens.status_frame.length, 22, 'status frame total length')
assert.strictEqual(goldens.status_frame[5], 0x00, 'status frame counter lives in the header sequence byte')
assert.strictEqual(st.song, 0)
assert.strictEqual(st.flags, 0x10)
assert.strictEqual(st.step, 0)
assert.strictEqual(st.target, 0)
assert.strictEqual(st.expression, 0)
assert.strictEqual(st.hits, 0x1234)
assert.strictEqual(st.wrong, 5)
assert.strictEqual(st.misses, 0)
assert.strictEqual(st.layout, 1)
assert.strictEqual(st.partials, 32)
assert.strictEqual(st.wet, 10)
assert.strictEqual(st.commandSequence, 1)
assert.strictEqual(st.commandResult, 0)

// 4. Golden config requests/replies round-trip through the parser.
Object.entries(goldens.config_requests).forEach(([name, bytes]) => {
  const built = protocol.configFrame({
    op: bytes[6], field: bytes[7],
    value: bytes[8] | (bytes[9] << 8),
    token: bytes[10] | (bytes[11] << 8),
    sequence: bytes[12] | (bytes[13] << 8)
  })
  eq(Array.from(new Uint8Array(built)), bytes, `config request ${name}`)
})
Object.entries(goldens.config_replies).forEach(([name, bytes]) => {
  const r = protocol.decodeConfigReply(bytes)
  assert.ok(r, `config reply ${name} must decode`)
  assert.strictEqual(r.result, bytes[8], `${name} result`)
  assert.strictEqual(r.value, bytes[9] | (bytes[10] << 8), `${name} value`)
  assert.strictEqual(r.epoch, bytes[11] | (bytes[12] << 8), `${name} epoch`)
  assert.strictEqual(r.supportedMask, 0x3B80FF, `${name} mask`)
  assert.strictEqual(r.firstField, 1, `${name} first field`)
  assert.strictEqual(r.sequence, bytes[5], `${name} echoed sequence`)
})

// 5. Negative frames are rejected, never misdecoded (version policy included).
Object.entries(goldens.negative_frames).forEach(([name, bytes]) => {
  assert.strictEqual(protocol.decodeStatus(bytes), null, `${name} must not decode as status`)
  assert.strictEqual(protocol.decodeConfigReply(bytes), null, `${name} must not decode as config reply`)
  let seen = null
  const feed = protocol.createReplyParser({
    onStatus: v => { seen = ['status', v] },
    onConfig: v => { seen = ['config', v] }
  })
  feed(toBuf(bytes))
  assert.strictEqual(seen, null, `${name} must be dropped by the demux`)
})

// 6. Demux routing: golden status -> onStatus, golden config -> onConfig,
//    and a fragmented status frame still reassembles.
let routed = null
const feed2 = protocol.createReplyParser({
  onStatus: v => { routed = ['status', v.song] },
  onConfig: v => { routed = ['config', v.result] }
})
feed2(toBuf(goldens.status_frame))
assert.deepStrictEqual(routed, ['status', 0])
routed = null
feed2(toBuf(goldens.config_replies.commit))
assert.deepStrictEqual(routed, ['config', 0])
routed = null
const stBytes = goldens.status_frame
feed2(toBuf(stBytes.slice(0, 9)))
feed2(toBuf(stBytes.slice(9)))
assert.deepStrictEqual(routed, ['status', 0])

console.log('PASS protocol golden conformance (mini-program, 32 frozen vectors)')
