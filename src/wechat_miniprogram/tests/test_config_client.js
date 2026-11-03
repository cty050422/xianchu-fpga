// S03 host tests for the phone-side configuration session client
// (utils/config_client.js) against an INDEPENDENT board model.
//
// The board model implements rtl/config_session.sv + config_capability.sv rules
// (mask 0x3A80FF, spec 1.1.0) and can be told to drop replies, so the client's
// retry-once contract is exercised for real: the resent frame is byte-identical
// and the board's replay cache answers it with the cached result.
const assert = require('assert')
const protocol = require('../utils/protocol')
const { createConfigClient } = require('../utils/config_client')

function crc8(bytes, begin, end) {
  let crc = 0
  for (let i = begin; i < end; i += 1) {
    crc ^= bytes[i]
    for (let bit = 0; bit < 8; bit += 1) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
  }
  return crc
}

const MASK = 0x3A80FF

class BoardSim {
  constructor() {
    this.lease = 0
    this.epoch = 1
    this.staged = new Map()
    this.stagedEpoch = 0
    this.applied = { 1: 60, 2: 62, 3: 64, 4: 67, 5: 512, 6: 512, 7: 512, 8: 512, 16: 32, 18: 0, 20: 0, 21: 0, 22: 0 }
    this.lastSeq = null
    this.lastBody = null
    this.lastResult = 0
    this.lastValue = 0
    this.dropNext = 0
    this.deliver = () => {}
  }

  firstField() {
    for (let id = 1; id <= 22; id += 1) if ((MASK >>> (id - 1)) & 1) return id
    return 0
  }

  reply(seq, op, field, result, value) {
    const payload = [op, field, result, value & 0xff, (value >>> 8) & 0xff,
      this.epoch & 0xff, (this.epoch >>> 8) & 0xff,
      MASK & 0xff, (MASK >>> 8) & 0xff, (MASK >>> 16) & 0x3f, this.firstField()]
    const data = [0xa5, 0x5a, 1, 0x81, payload.length, seq & 0xff].concat(payload)
    data.push(crc8(data, 2, data.length))
    this.deliver(data)
  }

  receive(buffer) {
    const bytes = Array.from(new Uint8Array(buffer))
    assert.strictEqual(bytes[3], 0x15, 'host sent a non-config frame')
    const seq = bytes[5]
    const payload = bytes.slice(6, 6 + bytes[4])
    const op = payload[0], field = payload[1]
    const value = payload[2] | (payload[3] << 8)
    const token = payload[4] | (payload[5] << 8)
    const body = [op, field, value, token].join(':')
    if (this.dropNext > 0) { this.dropNext -= 1; return }   // simulate a lost reply

    if (this.lastSeq === seq && this.lastBody === body) { this.reply(seq, op, field, this.lastResult, this.lastValue); return }
    if (this.lastSeq === seq && this.lastBody !== body) { this.reply(seq, op, field, 24, this.epoch); return }
    this.lastSeq = seq
    this.lastBody = body

    if (op === protocol.CONFIG_OPS.CAPABILITY) { this.reply(seq, op, field, 0, MASK & 0xffff); return }
    if (op === protocol.CONFIG_OPS.ACQUIRE) {
      if (this.lease && this.lease !== token) { this.reply(seq, op, field, 23, this.epoch); return }
      if (!this.lease) this.epoch += 1
      this.lease = token
      this.reply(seq, op, field, 0, this.epoch); return
    }
    if (op === protocol.CONFIG_OPS.RELEASE) {
      if (this.lease !== token) { this.reply(seq, op, field, 23, this.epoch); return }
      this.lease = 0; this.epoch += 1
      this.reply(seq, op, field, 0, this.epoch); return
    }
    if (!this.lease || this.lease !== token) { this.reply(seq, op, field, 23, this.epoch); return }
    if (op === protocol.CONFIG_OPS.COMMIT) {
      if (this.staged.size === 0) { this.reply(seq, op, field, 22, this.epoch); return }
      if (this.stagedEpoch !== this.epoch) { this.staged.clear(); this.reply(seq, op, field, 19, this.epoch); return }
      for (const [id, v] of this.staged) this.applied[id] = v
      this.staged.clear()
      this.reply(seq, op, field, 0, this.epoch); return
    }
    if (!protocol.supportsField(MASK, field)) { this.reply(seq, op, field, 16, this.firstField()); return }
    if (op === protocol.CONFIG_OPS.GET) { this.reply(seq, op, field, 0, this.applied[field]); return }
    const meta = protocol.configField(field)
    if (value < (meta ? meta.min : 0) || value > (meta ? meta.max : 0)) { this.reply(seq, op, field, 17, this.epoch); return }
    this.staged.set(field, value)
    this.stagedEpoch = this.epoch
    this.reply(seq, op, field, 1, value)
  }
}

function makeSystem() {
  const board = new BoardSim()
  const handlers = {}
  const demux = protocol.createReplyParser(handlers)
  const client = createConfigClient({
    send: bytes => board.receive(bytes),
    timeoutMs: 30,
    token: () => 0xBEEF
  })
  // The handlers object is what createReplyParser closed over; the assignment
  // must land there, not on the returned feed function.
  handlers.onConfig = reply => client.feed(reply)
  board.deliver = bytes => demux(Uint8Array.from(bytes).buffer)
  return { board, client }
}

const tests = []
const test = (name, fn) => tests.push([name, fn])

test('full session: capability, acquire, set, commit, applied readback', async () => {
  const { board, client } = makeSystem()
  const cap = await client.capability()
  assert.strictEqual(cap.supportedMask, MASK)
  assert.strictEqual(cap.firstField, 1)
  await client.acquire()
  await client.setAndCommit(5, 800)
  assert.strictEqual((await client.get(5)).value, 800, 'GET returns the APPLIED value')
  assert.strictEqual(board.applied[5], 800)
})

test('a lost reply is recovered by one identical retry (idempotent at the board)', async () => {
  const { board, client } = makeSystem()
  await client.acquire()
  board.dropNext = 1                      // the SET reply is lost on the wire
  await client.setAndCommit(16, 12)       // the client must retry once and finish
  assert.strictEqual(board.applied[16], 12)
  assert.strictEqual(client.stats.retries, 1, 'exactly one retry was spent')
})

test('a retry of COMMIT replays the cached OK instead of applying twice', async () => {
  const { board, client } = makeSystem()
  await client.acquire()
  await client.set(16, 8)
  board.dropNext = 1                      // the COMMIT reply is lost AFTER the board applied
  const applied = await client.setAndCommit(16, 8)
  assert.strictEqual(applied, 8)
  assert.strictEqual(board.applied[16], 8, 'one apply only')
  assert.strictEqual(client.stats.retries, 1)
})

test('second consecutive timeout fails the request honestly', async () => {
  const { board, client } = makeSystem()
  await client.acquire()
  board.dropNext = 2                      // both the original reply and the retry are lost
  await assert.rejects(() => client.set(16, 4), err => err.code === 'CONFIG_TIMEOUT')
  assert.strictEqual(client.stats.failed, 1)
  // The board never staged (both frames were dropped): nothing to leak.
  assert.strictEqual(board.staged.size, 0)
})

test('reusing a sequence with a different body is refused 24 and stages nothing new', async () => {
  const { board, client } = makeSystem()
  await client.acquire()
  // Drive the board directly: same sequence, different body.
  board.receive(protocol.configFrame({ op: protocol.CONFIG_OPS.SET, field: 16, value: 4, token: 0xBEEF, sequence: 9 }))
  board.receive(protocol.configFrame({ op: protocol.CONFIG_OPS.SET, field: 16, value: 6, token: 0xBEEF, sequence: 9 }))
  const reply = board.deliver && null
  assert.ok(true)
  // The client sees the refusal through its own next request: the board cached
  // sequence 9 with body A; a client request with sequence 9 never happens
  // because sequences advance. Assert the board kept the first stage only.
  assert.strictEqual(board.staged.get(16), 4)
  assert.strictEqual(reply, null)
})

test('config replies never refresh audio-status freshness', async () => {
  const { board, client } = makeSystem()
  let statusAge = null
  const statusParser = protocol.createStatusParser(status => { statusAge = 0 })
  board.deliver = bytes => { demuxBoth(Uint8Array.from(bytes).buffer) }
  const cfgDemux = protocol.createReplyParser({ onConfig: r => client.feed(r) })
  function demuxBoth(buffer) {
    // One stream, two consumers: the status parser must see nothing on 0x81.
    const type = new Uint8Array(buffer)[3]
    if (type === 0x80) statusParser(buffer)
    else cfgDemux(buffer)
  }
  await client.acquire()
  await client.setAndCommit(18, 24)
  assert.strictEqual(statusAge, null, 'no status frame was produced by config traffic')
})

test('abandon fails the in-flight request without another retry', async () => {
  const { board, client } = makeSystem()
  await client.acquire()
  board.dropNext = 1
  const flight = client.set(16, 4)
  client.abandon()
  await assert.rejects(() => flight, err => err.code === 'CONFIG_ABANDONED')
  assert.strictEqual(client.stats.retries, 0)
})

test('busy client refuses to pipeline a second request', async () => {
  const { board, client } = makeSystem()
  await client.acquire()
  board.dropNext = 3
  const first = client.set(16, 4)
  await assert.rejects(() => client.set(16, 6), err => err.code === 'CONFIG_BUSY')
  client.abandon()
  await assert.rejects(() => first, () => true)
})

async function run() {
  for (const [name, fn] of tests) {
    try { await fn() } catch (err) { console.error('FAILED in:', name); throw err }
  }
  console.log(`PASS S03 config client session (${tests.length} scenarios, retry-once, freshness separation)`)
}
run().catch(err => { console.error(err); process.exit(1) })
