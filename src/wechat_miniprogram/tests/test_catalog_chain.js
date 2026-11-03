// S16 conformance: the ONLINE CATALOG TO DEVICE chain, board-less but on the
// REAL client code path:
//   catalog entry (schemaVersion 2 JSON, chord + rest) -> score_compiler
//   (encoding v2) -> buildV2Transactions (0x16/0x17/0x18 + steps CRC) ->
//   sim transport (MTU fragmentation, real S3 relay shape) -> sim device
//   (spec-1.5.0 contract) -> published score -> guide starts -> status shows
//   the right step/target. The catalog layer itself (HTTP/cache/ETag) keeps
//   its own test file; this one proves the DIRECTION catalog -> device.
const assert = require('assert')
const protocol = require('../utils/protocol')
const compiler = require('../utils/score_compiler')
const { createSessionHub } = require('../services/device_session')

function crc8(bytes, begin, end) {
  let crc = 0
  for (let i = begin; i < end; i += 1) {
    crc ^= bytes[i]
    for (let bit = 0; bit < 8; bit += 1) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
  }
  return crc
}

// A minimal catalog entry: schemaVersion 2 with a chord, a rest and steps.
const catalogEntry = {
  schemaVersion: 2, songId: 'chain-demo', revision: 1,
  title: '整链演示', difficulty: 1, tags: ['demo'], bpm: 120,
  timeSignature: [4, 4],
  source: { type: 'original', license: 'CC0', attribution: 'S16 chain test' },
  notes: [
    { zones: [0, 2], beats: 1 },   // chord: zones 0+2
    { zone: null, beats: 1 },      // rest
    { zone: 1, beats: 2 },         // single
    { zone: 3, beats: 1 }
  ]
}

const tests = []
const test = (name, fn) => tests.push([name, fn])

test('catalog entry compiles to v2 transactions with chord/rest masks', () => {
  const compiled = compiler.compileScore(catalogEntry, { encoding: 'v2', deviceSupportsCustomNotes: true })
  assert.strictEqual(compiled.ok, true, JSON.stringify(compiled.errors || ''))
  assert.strictEqual(compiled.steps[0].mask, 0b0101, 'chord mask zones 0+2')
  assert.strictEqual(compiled.steps[1].mask, 0, 'rest mask 0')
  const tx = compiler.buildV2Transactions(9, compiled.steps, 1)
  assert.strictEqual(tx.transactions.length, 1, '4 steps fit one segment')
  const frames = tx.transactions[0].frames
  assert.strictEqual(frames[0][3], 0x16, 'BEGIN2')
  assert.strictEqual(frames[frames.length - 1][3], 0x18, 'COMMIT2')
  // every frame passes the frozen CRC chain
  frames.forEach(f => assert.strictEqual(crc8(f, 2, f.length - 1), f[f.length - 1]))
  return { compiled, tx }
})

test('catalog -> v2 compile -> service upload -> device publishes the score', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  const compiled = compiler.compileScore(catalogEntry, { encoding: 'v2', deviceSupportsCustomNotes: true })
  assert.strictEqual(compiled.ok, true)
  await hub.simUploadSegmentV2(compiled, 9, 0)
  const device = hub._state.sim.transport.device
  assert.strictEqual(device.state.scoreLoaded, true)
  assert.strictEqual(device.state.songId, 9)
  assert.strictEqual(device.state.stepCount, 4)
  assert.strictEqual(device.state.steps[0].mask, 0b0101, 'chord mask zones 0+2')
  assert.strictEqual(device.state.steps[1].rest, true, 'rest step published')
  // FX_CONTROL through the same service path latches the runtime mode
  await hub.simFxControl(3)
  assert.strictEqual(device.state.fxMode, 3, 'echo mode latched')
  await hub.leaveSimulator()
})

test('guide starts on the published v2 score and the snapshot reflects it', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  const compiled = compiler.compileScore(catalogEntry, { encoding: 'v2', deviceSupportsCustomNotes: true })
  await hub.simUploadSegmentV2(compiled, 9, 0)
  await hub.simGuide(true)
  const snap = hub.snapshot()
  // The authoritative state arrives in the status frame: flags bit1 = guide.
  assert.strictEqual(snap.lastStatus.flags & 2, 2, 'guide active on the published v2 score')
  assert.strictEqual(snap.lastStatus.song, 9, 'status still reports song 9')
  await hub.simGuide(false)
  await hub.leaveSimulator()
})

async function run() {
  for (const [name, fn] of tests) await fn()
  console.log(`PASS S16 catalog->v2-compile->transaction->device chain (${tests.length} stages)`)
}
run().catch(err => { console.error(err); process.exit(1) })
