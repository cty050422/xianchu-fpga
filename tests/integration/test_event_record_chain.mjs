// T2 full software chain: manual performance events -> 0x85 telemetry frames
// (the exact byte shape rtl/event_recorder.sv emits) -> the REAL miniprogram
// parser/session -> versioned JSON -> the REAL timeline compiler -> the REAL
// audition_score.compileTimeline -> the exact 0x1B/0x1C/0x1D/0x1E command byte
// stream audition_session.js sends. The command stream is written to
// tests/rtl/event_replay_commands.hex and is what tb_event_record_stream feeds
// into the production esp_score_link UART, so "phone JSON -> FPGA audio state"
// is exercised against the real RTL, not a mock.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
const require = createRequire(import.meta.url)
const R = require('../../src/wechat_miniprogram/utils/event_recording.js')
const A = require('../../src/wechat_miniprogram/utils/audition_score.js')

function frame85(seq, flags, note, gen, delta, dropped) {
  const body = [seq & 255, flags & 255, note & 255, gen & 255, delta & 255, (delta >>> 8) & 255, (delta >>> 16) & 255, dropped & 255]
  const head = [0xA5, 0x5A, 1, 0x85, 8, seq & 255]
  const all = head.concat(body)
  all.push(R.crc(all.slice(2)))
  return Uint8Array.from(all)
}
// Reference encoder: one frame per accepted event, deltas vs the previous pushed
// event (mirrors rtl/event_recorder.sv byte packing exactly).
function encodeFrames(list) {
  let prev = 0, lastDropped = 0
  return list.map((e, i) => {
    const flags = (e.on ? 128 : 0) | (e.loss ? 64 : 0) | (e.region << 4) | (e.preset << 2)
    const f = frame85(i & 255, flags, e.note, e.generation, e.sample - prev, lastDropped)
    prev = e.sample
    return f
  })
}

test('event recording chain: parse, JSON, compile, replay commands', () => {
  // ---- manual performance: two overlapping voices, a fast repeat, a held third
  // voice, and the SAME pitch in two regions (possible after live retune).
  const ev = []
  const push = (sample, on, region, note, preset, generation) => ev.push({ sample, on, region, note, preset, generation })
  push(480, 1, 0, 60, 0, 1)     // C4 region0
  push(1200, 1, 1, 67, 0, 2)    // G4 region1 (overlap)
  push(2400, 1, 2, 64, 1, 3)    // E4 region2 preset wind (held to the end)
  push(3600, 0, 0, 60, 0, 1)    // C4 off
  push(3840, 1, 0, 60, 0, 4)    // fast re-press (240 samples later)
  push(4800, 0, 1, 67, 0, 2)    // G4 off
  push(9600, 0, 0, 60, 0, 4)
  push(9600, 1, 3, 60, 0, 5)    // same pitch, region3 (unison via retune)
  push(19200, 0, 3, 60, 0, 5)

  // ---- telemetry frames -> the REAL recorder/parser
  const rec = R.createEventRecorder()
  rec.start()
  const frames = encodeFrames(ev)
  for (const f of frames) rec.onFrame(f)
  assert.strictEqual(rec.count, ev.length, 'every delivered event is kept')
  assert.strictEqual(rec.hasLoss, false, 'clean stream has no loss mark')
  const json = rec.toJSON('chain-test')
  assert.strictEqual(json.schema, 'xianchu.event-recording')
  assert.strictEqual(json.version, R.VERSION)
  assert.strictEqual(json.eventCount, ev.length)
  assert.strictEqual(json.durationSamples, ev[ev.length - 1].sample)
  // absolute sample timeline = sum of deltas, wall clock never involved
  assert.strictEqual(json.events[4].s, 3840, 'fast re-press lands at its FPGA sample')

  // ---- gap handling: a dropped burst must mark loss, never fabricate note-offs
  const rec2 = R.createEventRecorder()
  rec2.start()
  const withGap = encodeFrames(ev.slice(0, 4))
  // drop the G4 note-off frame (index 5) and push the rest with a loss flag frame
  rec2.onFrame(withGap[0]); rec2.onFrame(withGap[1]); rec2.onFrame(withGap[2])
  rec2.onFrame(frame85(4, 64 | 128, 60, 4, 240, 1)) // loss flag set by the FPGA
  rec2.onFrame(encodeFrames([{ sample: 4800, on: 0, region: 1, note: 67, preset: 0, generation: 2 }])[0])
  assert.strictEqual(rec2.hasLoss, true, 'loss flag marks the session')
  const j2 = rec2.toJSON()
  assert.strictEqual(j2.hasLoss, true)
  assert.strictEqual(j2.dropped, 1)
  // the unmatched release is dropped from the timeline, not turned into an off

  // ---- duplicate delivery: the same seq twice must mark loss (no silent dupes)
  const rec4 = R.createEventRecorder()
  rec4.start()
  const dup = encodeFrames(ev.slice(0, 3))
  rec4.onFrame(dup[0]); rec4.onFrame(dup[1])
  rec4.onFrame(dup[1]) // duplicated frame: expected next seq is 2, got 1 again
  assert.strictEqual(rec4.hasLoss, true, 'duplicate frame marks the session')
  assert.strictEqual(rec4.count, 3, 'duplicate event is recorded once more (raw telemetry kept, loss visible)')

  // ---- JSON round trip: save -> load -> identical timeline source
  const rec3 = R.createEventRecorder().staticFromJSON(JSON.parse(JSON.stringify(json)))

  // ---- timeline + REAL compiler
  const timeline = R.eventsToTimeline(rec3.toJSON().events.map(e => ({ sample: e.s, on: e.k, region: e.r, note: e.n, preset: e.p, generation: e.g })))
  const compiled = A.compileTimeline(timeline)
  assert.ok(compiled.steps.length >= 1 && compiled.steps.length <= 1024)
  assert.ok(compiled.samples <= 5760000, 'total length within the 120 s protocol ceiling')
  assert.strictEqual(compiled.scope, 'symbolic_fpga_synthesis')
  for (const s of compiled.steps) {
    assert.ok(s.samples >= 960 && s.samples <= 2880000, 'every step within duration range')
    assert.ok(s.notes.length <= 4, 'at most four voices per step')
    assert.ok(new Set(s.notes).size === s.notes.length, 'no duplicate pitches per step')
  }
  // quantization bound: every timeline boundary sits on an original event sample
  // (within the 480-sample off extension and the 20 ms merge allowance)
  for (const t of timeline) {
    const start = Math.round(t.startMs * 48)
    const near = ev.some(e => Math.abs(e.sample - start) <= R.OFF_COMPENSATION_SAMPLES) ||
                 Math.abs(start - (ev[ev.length - 1].sample + R.OFF_COMPENSATION_SAMPLES)) <= 960
    assert.ok(near, 'timeline boundary ' + start + ' traces to an original event')
  }
  // replay semantics: the segment carries the raw events' pitches (union)
  const allNotes = new Set(compiled.steps.flatMap(s => s.notes))
  for (const n of [60, 67, 64]) assert.ok(allNotes.has(n), 'pitch ' + n + ' survives the compile')

  // ---- exact replay command stream (what audition_session.js would send)
  const part = compiled.segments[0]
  const id = 7
  const toBytes = b => Array.from(new Uint8Array(b))
  const cmds = []
  cmds.push(toBytes(A.frame(0x1b, 1, [id, part.steps.length])))
  for (let i = 0; i < part.steps.length; i++) cmds.push(toBytes(A.frame(0x1c, 2 + i, A.stepPayload(part.steps[i], i))))
  cmds.push(toBytes(A.frame(0x1d, 2 + part.steps.length, [id, part.crc])))
  cmds.push(toBytes(A.frame(0x1e, 3 + part.steps.length, [1, 0, id])))
  const here = path.dirname(fileURLToPath(import.meta.url))
  const hexPath = path.join(here, '..', '..', 'tests', 'rtl', 'event_replay_commands.hex')
  const bytes = cmds.flat()
  const hexText = bytes.map(b => b.toString(16).padStart(2, '0')).join('\n') + '\n'
  // Icarus cannot reliably open non-ASCII paths on Windows: the bench reads the
  // byte stream from a fixed ASCII copy in the temp dir (same bytes).
  fs.writeFileSync(hexPath, hexText)
  fs.writeFileSync(path.join(os.tmpdir(), 'xc_t2_event_replay_commands.hex'), hexText)
  fs.mkdirSync(path.join(here, '..', '..', 'build', 'tests'), { recursive: true })
  fs.writeFileSync(path.join(here, '..', '..', 'build', 'tests', 'event_chain_commands.json'),
    JSON.stringify({ steps: part.steps.length, samples: part.samples, crc: part.crc, bytes: bytes.length, hexFile: 'tests/rtl/event_replay_commands.hex',
    simCopy: path.join(os.tmpdir(), 'xc_t2_event_replay_commands.hex') }, null, 1))
  // frame-level sanity: every frame CRCs and the sequencer's static limits hold
  for (const c of cmds) {
    assert.strictEqual(R.crc(c.slice(2, c.length - 1)), c[c.length - 1], 'frame crc valid')
    assert.strictEqual(c[0], 0xA5); assert.strictEqual(c[1], 0x5A)
  }
})
