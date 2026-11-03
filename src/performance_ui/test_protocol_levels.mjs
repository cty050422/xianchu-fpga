// S14 conformance: the PC status panel decodes the new 0x23 voice-level record
// (post-gain window peaks from the S10 chain) and keeps the existing 0x21/0x22
// contract intact.
import assert from 'node:assert'
import { decodeFrame, TelemetryParser } from './protocol.mjs'

const sum = bytes => bytes.reduce((t, v) => (t + v) & 255, 0)

function frame(type, payload) {
  const data = [0xA5, type, payload.length, ...payload]
  data.push(sum(data))
  return Uint8Array.from(data)
}

// ---- 1. a 0x23 record decodes to the pinned values -------------------------
const levels = frame(0x23, [0x34, 0x12, 0x03,
  0x10, 0x27, 0x00, 0x00, 0x88, 0x13, 0x00, 0x00, 0x40, 0x1F])
const dec = decodeFrame(0x23, Array.from(levels).slice(3, levels.length - 1))
assert.strictEqual(dec.kind, 'levels')
assert.strictEqual(dec.seq, 0x1234)
assert.strictEqual(dec.flags, 3)
assert.deepStrictEqual(dec.voiceLevels, [10000, 0, 5000, 0])
assert.strictEqual(dec.layerLevel, 8000)

// ---- 2. the parser routes it and counts it ---------------------------------
const parser = new TelemetryParser(() => {})
parser.push(levels)
assert.strictEqual(parser.levelsFrames, 1)
assert.strictEqual(parser.valid, 1)
assert.strictEqual(parser.lastSeq, 0x1234)

// ---- 3. a corrupted 0x23 is rejected by checksum ---------------------------
const bad = Uint8Array.from(levels)
bad[bad.length - 1] ^= 0xFF
const p2 = new TelemetryParser(() => {})
p2.push(bad)
assert.strictEqual(p2.levelsFrames, 0)
assert.strictEqual(p2.checksumFailures, 1)

// ---- 4. seq gap accounting still works across a 0x23 ----------------------
const p3 = new TelemetryParser(() => {})
p3.push(levels)                                    // seq 0x1234
p3.push(frame(0x23, [0x38, 0x12, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))  // seq 0x1238: gap of 3
assert.strictEqual(p3.missing, 3)

// ---- 5. the existing 0x21 wave contract is untouched -----------------------
const wave = frame(0x21, new Array(51).fill(0))
const w = decodeFrame(0x21, new Array(51).fill(0))
assert.strictEqual(w.kind, 'wave')
assert.strictEqual(w.samples.length, 32)

console.log('PASS S14 PC panel 0x23 levels decoding (5 checks)')
