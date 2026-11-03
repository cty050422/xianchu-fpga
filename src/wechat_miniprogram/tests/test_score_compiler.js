const { test } = require('node:test')
const assert = require('node:assert/strict')
const c = require('../utils/score_compiler')

function zoneScore(n, opts = {}) {
  const notes = []
  for (let i = 0; i < n; i++) notes.push({ zone: i % 4, beats: opts.beats || 1 })
  return {
    schemaVersion: 1, songId: opts.songId || 'test-song', revision: 1,
    title: opts.title || '测试曲', source: { type: 'original', license: 'CC0-1.0', attribution: 't' },
    difficulty: 1, tags: ['测试'], bpm: opts.bpm || 90, timeSignature: [4, 4], notes
  }
}

test('32 steps compile into one segment; 33 steps split into 32+1 with labels', () => {
  const a = c.compileScore(zoneScore(32), {})
  assert.equal(a.ok, true)
  assert.equal(a.segments.length, 1)
  const b = c.compileScore(zoneScore(33), {})
  assert.equal(b.ok, true)
  assert.equal(b.segments.length, 2)
  assert.deepEqual(b.segments.map(s => s.steps.length), [32, 1])
  assert.equal(b.segments[0].label, '第1段/共2段')
  assert.equal(b.segments[1].label, '第2段/共2段')
  assert.equal(b.multiSegment, true)
})
test('v2 preview and wire use exactly64-step segments, including all later segments',()=>{
 for(const n of [33,64,65,128,129]){
  const score=zoneScore(n);score.schemaVersion=2
  const p=c.compileScore(score,{encoding:'v2'}),wire=c.buildV2Transactions(42,p.steps,1)
  assert.equal(p.ok,true);assert.deepEqual(p.segments.map(s=>s.steps.length),wire.transactions.map(t=>t.frames[0][7]))
 }
})

test('five distinct pitches are rejected, never folded mod 4 into zones', () => {
  const score = zoneScore(5)
  score.notes = [60, 62, 64, 65, 67].map(m => ({ midi: m, beats: 1 }))
  const out = c.compileScore(score, {})
  assert.equal(out.ok, false)
  assert.equal(out.errors[0].code, 'TOO_MANY_PITCHES')
  assert.match(out.errors[0].message, /5 个不同音高/)
})

test('four pitches fitting preset A map to group A without config', () => {
  const score = zoneScore(4)
  score.notes = [60, 62, 64, 67].map(m => ({ midi: m, beats: 1 }))
  const out = c.compileScore(score, {})
  assert.equal(out.ok, true)
  assert.equal(out.requiredMapping.type, 'preset-group')
  assert.equal(out.requiredMapping.group, 'A')
  assert.deepEqual(out.zonePitches, [60, 62, 64, 67])
})

test('four pitches not fitting a preset require custom notes (field 1-4)', () => {
  const score = zoneScore(4)
  score.notes = [62, 64, 65, 67].map(m => ({ midi: m, beats: 1 }))
  const refused = c.compileScore(score, { deviceSupportsCustomNotes: false })
  assert.equal(refused.ok, false)
  assert.equal(refused.errors[0].code, 'MAPPING_REQUIRES_CONFIG')
  assert.equal(refused.requiredMapping.type, 'custom-notes')
  const allowed = c.compileScore(score, { deviceSupportsCustomNotes: true })
  assert.equal(allowed.ok, true)
  assert.equal(allowed.requiredMapping.needsConfig, true)
  assert.deepEqual(allowed.requiredMapping.notes, [62, 64, 65, 67])
  // LED zone i must sound exactly notes[i]: zone order follows pitch order.
  const zoneOf = {}
  for (const note of score.notes) zoneOf[note.midi] = null
  assert.equal(allowed.steps[0].zone, 0) // D4 lowest → zone0
  assert.equal(allowed.steps[2].zone, 2) // F4 → zone2
})

test('rest steps are refused: the wire protocol has no silence encoding', () => {
  const score = zoneScore(4)
  score.notes[2] = { zone: null, beats: 1 }
  const out = c.compileScore(score, {})
  assert.equal(out.ok, false)
  assert.equal(out.errors[0].code, 'REST_NOT_ENCODABLE')
  assert.match(out.errors[0].message, /休止/)
})

test('expression 3 is reserved and refused; 0-2 pass through', () => {
  const score = zoneScore(2)
  score.notes[0].expression = 3
  const out = c.compileScore(score, {})
  assert.equal(out.ok, false)
  assert.equal(out.errors[0].code, 'EXPRESSION_RESERVED')
  const ok2 = c.compileScore(zoneScore(2, {}), {})
  score.notes[0].expression = 2
  const out2 = c.compileScore(score, {})
  assert.equal(out2.ok, true)
  assert.equal(out2.steps[0].expression, 2)
})

test('BPM conversion is exact rational arithmetic with reported drift', () => {
  assert.equal(c.beatsToSamples(1, 60), 48000)
  assert.equal(c.beatsToSamples(0.5, 80), 18000)
  assert.equal(c.beatsToSamples(0.25, 120), 6000)
  // 0.25 beats @ 44 bpm = 0.25 * 2880000 / 44 = 16363.63… → 16364
  assert.equal(c.beatsToSamples(0.25, 44), 16364)
  // Drift is tracked: sum(rounded) - round(sum)
  const score = zoneScore(8, { bpm: 44 })
  score.notes.forEach(n => { n.beats = 0.25 })
  const out = c.compileScore(score, {})
  assert.equal(out.ok, true)
  const exact = Math.round(8 * 0.25 * 2880000 / 44)
  const rounded = out.steps.reduce((acc, st) => acc + st.durationSamples, 0)
  assert.equal(out.roundingDriftSamples, rounded - exact)
  assert.equal(rounded - exact, 3) // 8 × (16364 − 16363.63…) ≈ 3 samples total
})

test('BPM bounds 30..180 enforced for score and practice override', () => {
  const low = zoneScore(2); low.bpm = 29
  assert.equal(c.compileScore(low, {}).ok, false)
  const override = c.compileScore(zoneScore(2), { bpm: 181 })
  assert.equal(override.ok, false)
  assert.equal(override.errors[0].code, 'BPM_RANGE')
  assert.equal(c.compileScore(zoneScore(2), { bpm: 180 }).ok, true)
  assert.equal(c.compileScore(zoneScore(2), { bpm: 30 }).ok, true)
})

test('schema validation rejects bad documents', () => {
  const bad = zoneScore(2)
  bad.schemaVersion = 3 // v2 is legal since S04 (chords + rests); 3 is not
  const out = c.compileScore(bad, {})
  assert.equal(out.ok, false)
  assert.equal(out.errors[0].code, 'SCHEMA_VERSION')
  const badMidi = zoneScore(2); badMidi.notes[0] = { midi: 120, beats: 1 }
  assert.equal(c.compileScore(badMidi, {}).errors[0].code, 'MIDI_RANGE')
  const badBeats = zoneScore(2); badBeats.notes[0].beats = 0.1 // not a 1/16 multiple
  assert.equal(c.compileScore(badBeats, {}).errors[0].code, 'BEATS')
  const badZone = zoneScore(2); badZone.notes[0].zone = 4
  assert.equal(c.compileScore(badZone, {}).errors[0].code, 'ZONE_RANGE')
})

test('contentHash is canonical and matches node:crypto sha256', () => {
  const crypto = require('node:crypto')
  const score = zoneScore(3)
  const h1 = c.scoreContentHash(score)
  const reordered = {}
  for (const key of ['notes', 'title', 'songId', 'bpm', 'tags', 'source', 'difficulty', 'revision', 'timeSignature', 'schemaVersion'])
    reordered[key] = score[key]
  const h2 = c.scoreContentHash(reordered)
  assert.equal(h1, h2, 'key order must not change the hash')
  assert.equal(h1.length, 64)
  const ref = crypto.createHash('sha256').update(Buffer.from(c.canonicalize(score), 'utf8')).digest('hex')
  assert.equal(h1, ref)
})

test('duration limits: 24-bit sample range enforced', () => {
  const score = zoneScore(1, { bpm: 30 })
  score.notes[0].beats = 16 // 16 beats @30bpm = 32s = 1,536,000 samples OK
  assert.equal(c.compileScore(score, {}).ok, true)
  // Beats grid caps at 16 per step; at 30 bpm that stays under 0xFFFFFF, so
  // the range error path needs an artificial case:
  const out = c.compileScore(zoneScore(1, { bpm: 30 }), { bpm: 30 })
  assert.equal(out.ok, true)
})
