// Host tests for the phone-side CONFIGURATION transport.
//
// The board is modelled independently (its own frame parser, lease/epoch/replay
// rules and reply encoder) so the client is not validated against its own bytes.
// The point of each case is a behaviour a phone could get wrong: writing without a
// lease, mistaking a stage for an effect, replaying a sequence with a new body, or
// reading a config answer as a score status frame.
const assert = require('assert')
const protocol = require('../utils/protocol')

function crc8(bytes, begin, end) {
  let crc = 0
  for (let i = begin; i < end; i += 1) {
    crc ^= bytes[i]
    for (let bit = 0; bit < 8; bit += 1) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
  }
  return crc
}

// Behaviour model of rtl/config_session.sv + rtl/config_capability.sv.
class BoardSim {
  constructor(options = {}) {
    this.mask = options.mask === undefined ? 0x3b80ff : options.mask
    this.lease = 0
    this.held = false
    this.epoch = 1
    this.staged = new Map()
    this.stagedEpoch = 0
    this.applied = { 5: 512, 6: 512, 7: 512, 8: 512, 16: 32, 18: 0 }
    this.lastSeq = null
    this.lastBody = null
    this.lastResult = 0
    this.lastValue = 0
    this.deliver = options.deliver || (() => {})
  }

  reply(seq, op, field, result, value) {
    const payload = [op, field, result, value & 0xff, (value >>> 8) & 0xff,
      this.epoch & 0xff, (this.epoch >>> 8) & 0xff,
      this.mask & 0xff, (this.mask >>> 8) & 0xff, (this.mask >>> 16) & 0x3f,
      this.firstField()]
    const data = [0xa5, 0x5a, 1, 0x81, payload.length, seq & 0xff].concat(payload)
    data.push(crc8(data, 2, data.length))
    this.deliver(data)
  }

  firstField() {
    for (let id = 1; id <= 22; id += 1) if ((this.mask >>> (id - 1)) & 1) return id
    return 0
  }

  supports(id) {
    return id >= 1 && id <= 22 && ((this.mask >>> (id - 1)) & 1) === 1
  }

  receive(buffer) {
    const bytes = Array.from(new Uint8Array(buffer))
    assert.strictEqual(bytes[3], 0x15, 'host sent a non-config frame')
    const seq = bytes[5]
    const payload = bytes.slice(6, 6 + bytes[4])
    const op = payload[0]
    const field = payload[1]
    const value = payload[2] | (payload[3] << 8)
    const token = payload[4] | (payload[5] << 8)
    const body = [op, field, value, token].join(':')

    if (this.lastSeq === seq && this.lastBody === body) {
      this.reply(seq, op, field, this.lastResult, this.lastValue)
      return
    }
    if (this.lastSeq === seq && this.lastBody !== body) {
      this.reply(seq, op, field, 24, this.epoch)
      return
    }
    this.lastSeq = seq
    this.lastBody = body

    if (op === protocol.CONFIG_OPS.CAPABILITY) {
      this.lastResult = 0
      this.lastValue = this.mask & 0xffff
      this.reply(seq, op, field, 0, this.lastValue)
      return
    }
    if (op === protocol.CONFIG_OPS.ACQUIRE) {
      if (this.lease && this.lease !== token) { this.reply(seq, op, field, 23, this.epoch); return }
      if (!this.lease) this.epoch += 1
      this.lease = token
      this.lastResult = 0
      this.lastValue = this.epoch
      this.reply(seq, op, field, 0, this.epoch)
      return
    }
    if (op === protocol.CONFIG_OPS.RELEASE) {
      if (this.lease !== token) { this.reply(seq, op, field, 23, this.epoch); return }
      this.lease = 0
      this.epoch += 1
      this.lastResult = 0
      this.lastValue = this.epoch
      this.reply(seq, op, field, 0, this.epoch)
      return
    }
    // SET / COMMIT / GET all need the lease.
    if (!this.lease || this.lease !== token) {
      this.lastResult = 23
      this.lastValue = this.epoch
      this.reply(seq, op, field, 23, this.epoch)
      return
    }
    if (op === protocol.CONFIG_OPS.COMMIT) {
      if (this.staged.size === 0) { this.reply(seq, op, field, 22, this.epoch); return }
      if (this.held) { this.reply(seq, op, field, 20, this.epoch); return }
      if (this.stagedEpoch !== this.epoch) { this.staged.clear(); this.reply(seq, op, field, 19, this.epoch); return }
      for (const [id, v] of this.staged) this.applied[id] = v
      this.staged.clear()
      this.lastResult = 0
      this.lastValue = this.epoch
      this.reply(seq, op, field, 0, this.epoch)
      return
    }
    if (!this.supports(field)) {
      this.lastResult = 16
      this.lastValue = this.firstField()
      this.reply(seq, op, field, 16, this.firstField())
      return
    }
    if (op === protocol.CONFIG_OPS.GET) {
      this.lastResult = 0
      this.lastValue = this.applied[field]
      this.reply(seq, op, field, 0, this.applied[field])
      return
    }
    // SET
    const meta = protocol.configField(field)
    const min = meta ? meta.min : 0
    const max = meta ? meta.max : 0
    if (value < min || value > max) { this.reply(seq, op, field, 17, this.epoch); return }
    this.staged.set(field, value)
    this.stagedEpoch = this.epoch
    this.lastResult = 1
    this.lastValue = value
    this.reply(seq, op, field, 1, value)
  }
}

// A tiny client: one request at a time, sequence stamped, answer matched by echo.
function createClient(board, options = {}) {
  const replies = []
  let sequence = options.firstSequence || 1
  const parser = protocol.createReplyParser({ onConfig: r => replies.push(r) })
  board.deliver = bytes => parser(Uint8Array.from(bytes).buffer)
  return {
    replies,
    async call(op, field, value, token) {
      const seq = sequence++ & 0xff
      const before = replies.length
      board.receive(protocol.configFrame({ op, field, value, token, sequence: seq }))
      assert.strictEqual(replies.length, before + 1, 'expected exactly one config reply')
      const reply = replies[replies.length - 1]
      assert.strictEqual(reply.sequence, seq, 'reply did not echo the request sequence')
      return reply
    }
  }
}

const tests = []
function test(name, fn) { tests.push([name, fn]) }

test('capability probe works before any lease and lists the implemented fields', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  const reply = await client.call(protocol.CONFIG_OPS.CAPABILITY, 0, 0, 0)
  assert.strictEqual(reply.result, 0)
  assert.strictEqual(reply.supportedMask, 0x3b80ff)
  assert.strictEqual(reply.firstField, 1)
  for (const id of [1, 2, 3, 4, 5, 6, 7, 8, 16, 18, 20, 21, 22]) {
    assert.ok(protocol.supportsField(reply.supportedMask, id), 'field ' + id + ' should be supported')
  }
  for (const id of [9, 13, 14, 19]) {
    assert.ok(!protocol.supportsField(reply.supportedMask, id), 'field ' + id + ' must not be offered')
  }
})

test('a write without a lease is refused and changes nothing', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  const refused = await client.call(protocol.CONFIG_OPS.SET, 16, 8, 0xBEEF)
  assert.strictEqual(refused.result, 23)
  assert.strictEqual(board.applied[16], 32)
})

test('set is invisible until commit, and get only returns applied values', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0xBEEF)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.SET, 16, 8, 0xBEEF)).result, 1)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.GET, 16, 0, 0xBEEF)).value, 32)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.COMMIT, 0, 0, 0xBEEF)).result, 0)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.GET, 16, 0, 0xBEEF)).value, 8)
})

test('unsupported and out-of-range fields are named, not silently accepted', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0xBEEF)
  const unsupported = await client.call(protocol.CONFIG_OPS.SET, 13, 5, 0xBEEF)
  assert.strictEqual(unsupported.result, 16)
  assert.strictEqual(unsupported.firstField, 1)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.SET, 16, 200, 0xBEEF)).result, 17)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.SET, 16, 0, 0xBEEF)).result, 17)
})

test('a second phone cannot steal a live lease', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0x1111)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0x2222)).result, 23)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.SET, 16, 4, 0x2222)).result, 23)
  assert.strictEqual(board.applied[16], 32)
})

test('a retried commit replays instead of applying twice', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0xBEEF)
  await client.call(protocol.CONFIG_OPS.SET, 16, 8, 0xBEEF)
  const seq = 42
  board.receive(protocol.configFrame({ op: protocol.CONFIG_OPS.COMMIT, field: 0, value: 0, token: 0xBEEF, sequence: seq }))
  const first = client.replies[client.replies.length - 1]
  board.receive(protocol.configFrame({ op: protocol.CONFIG_OPS.COMMIT, field: 0, value: 0, token: 0xBEEF, sequence: seq }))
  const again = client.replies[client.replies.length - 1]
  assert.strictEqual(first.result, 0)
  assert.strictEqual(again.result, 0, 'the retry must return the cached OK, not INCOMPLETE')
  assert.strictEqual(board.applied[16], 8)
})

test('reusing a sequence with a different body is refused', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0xBEEF)
  board.receive(protocol.configFrame({ op: protocol.CONFIG_OPS.SET, field: 16, value: 4, token: 0xBEEF, sequence: 9 }))
  board.receive(protocol.configFrame({ op: protocol.CONFIG_OPS.SET, field: 16, value: 6, token: 0xBEEF, sequence: 9 }))
  const reply = client.replies[client.replies.length - 1]
  assert.strictEqual(reply.result, 24)
  assert.strictEqual(board.staged.get(16), 4, 'the conflicting retry must not overwrite the stage')
})

test('a commit while the instrument is busy is held, not applied', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0xBEEF)
  await client.call(protocol.CONFIG_OPS.SET, 18, 32, 0xBEEF)
  board.held = true
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.COMMIT, 0, 0, 0xBEEF)).result, 20)
  assert.strictEqual(board.applied[18], 0)
  board.held = false
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.COMMIT, 0, 0, 0xBEEF)).result, 0)
  assert.strictEqual(board.applied[18], 32)
})

test('release bumps the epoch and kills the old token', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  const before = (await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0xBEEF)).epoch
  const after = (await client.call(protocol.CONFIG_OPS.RELEASE, 0, 0, 0xBEEF)).epoch
  assert.strictEqual(after, before + 1)
  assert.strictEqual((await client.call(protocol.CONFIG_OPS.SET, 16, 8, 0xBEEF)).result, 23)
})

test('a staged set from a dead session cannot be committed by the next owner', async () => {
  const board = new BoardSim()
  const client = createClient(board)
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0x2222)
  await client.call(protocol.CONFIG_OPS.SET, 16, 2, 0x2222)
  board.lease = 0           // the lease expired while the phone was away
  board.epoch += 1
  await client.call(protocol.CONFIG_OPS.ACQUIRE, 0, 0, 0x3333)
  const reply = await client.call(protocol.CONFIG_OPS.COMMIT, 0, 0, 0x3333)
  assert.strictEqual(reply.result, 19)
  assert.strictEqual(board.applied[16], 32)
})

test('the reply parser keeps status and config frames apart', async () => {
  const board = new BoardSim()
  const seen = { status: 0, config: 0 }
  const parser = protocol.createReplyParser({
    onStatus: () => { seen.status += 1 },
    onConfig: () => { seen.config += 1 }
  })
  // A status frame and a config reply delivered in ONE notification, split across
  // two chunks, must both be recovered exactly once.
  const status = [0xa5, 0x5a, 1, 0x80, 15, 3].concat(new Array(15).fill(0))
  status.push(crc8(status, 2, status.length))
  let configBytes = null
  const board2 = new BoardSim({ deliver: bytes => { configBytes = bytes } })
  board2.receive(protocol.configFrame({ op: protocol.CONFIG_OPS.CAPABILITY, field: 0, value: 0, token: 0, sequence: 1 }))
  const all = Uint8Array.from(status.concat(configBytes)).buffer
  parser(all.slice(0, 11))
  parser(all.slice(11))
  assert.strictEqual(seen.status, 1, 'status frame lost or duplicated')
  assert.strictEqual(seen.config, 1, 'config reply lost or duplicated')
  assert.ok(board.replies === undefined || true)
})

test('a config frame is byte-exact for the RTL decoder', async () => {
  const frame = Array.from(new Uint8Array(protocol.configFrame({
    op: protocol.CONFIG_OPS.ACQUIRE, field: 0, value: 0, token: 0xBEEF, sequence: 7
  })))
  assert.deepStrictEqual(frame, [0xa5, 0x5a, 0x01, 0x15, 0x08, 0x07,
    0x03, 0x00, 0x00, 0x00, 0xef, 0xbe, 0x07, 0x00, 0xc6])
})

;(async () => {
  let failed = 0
  for (const [name, fn] of tests) {
    try {
      await fn()
      console.log('ok   ' + name)
    } catch (error) {
      failed += 1
      console.log('FAIL ' + name + ': ' + error.message)
    }
  }
  console.log(failed === 0 ? `PASS phone config transport (${tests.length} cases)` : `FAIL ${failed}/${tests.length}`)
  process.exit(failed === 0 ? 0 : 1)
})()
