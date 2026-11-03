// Host tests for the phone-side transaction layer and discovery rules.
// The FPGA is modelled independently here (frame parser + score state + status
// encoder) so the client is not validated against its own encoder only.
const assert = require('assert')
const protocol = require('../utils/protocol')
const discovery = require('../utils/discovery')
const { createIssuer, fingerprint } = require('../utils/transaction')

function crc8(bytes, begin, end) {
  let crc = 0
  for (let i = begin; i < end; i += 1) {
    crc ^= bytes[i]
    for (let bit = 0; bit < 8; bit += 1) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
  }
  return crc
}

// Minimal behaviour model of esp_score_link (result codes must match the RTL).
class FpgaSim {
  constructor(options) {
    this.song = 0
    this.loaded = false
    this.guide = false
    this.flagsExtra = 0x10 // calibrated
    this.txn = null
    this.mask = new Set()
    this.steps = {}
    this.seqEcho = 0
    this.result = 0
    this.deliver = (options && options.deliver) || (() => {})
  }

  statusFrame() {
    const payload = [
      this.song, (this.loaded ? 1 : 0) | (this.guide ? 2 : 0) | this.flagsExtra,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, this.seqEcho, this.result
    ]
    const data = [0xa5, 0x5a, 1, 0x80, payload.length, this.seqEcho].concat(payload)
    data.push(crc8(data, 2, data.length))
    return data
  }

  receive(buffer) {
    const bytes = Array.from(new Uint8Array(buffer))
    const seq = bytes[5]
    const type = bytes[3]
    const len = bytes[4]
    const payload = bytes.slice(6, 6 + len)
    this.seqEcho = seq
    this.result = 0
    if (type === 0x10) {
      if (payload[1] < 1 || payload[1] > 32) this.result = 0xe2
      else { this.txn = { song: payload[0], count: payload[1] }; this.mask = new Set() }
    } else if (type === 0x11) {
      if (!this.txn) this.result = 0xe6
      else if (payload[0] >= this.txn.count || (payload[1] & 0xf0) !== 0) this.result = 0xe2
      else this.mask.add(payload[0])
    } else if (type === 0x12) {
      if (!this.txn) this.result = 0xe6
      else if (payload[0] !== this.txn.song || this.mask.size !== this.txn.count) this.result = 0xe3
      else { this.song = this.txn.song; this.loaded = true; this.txn = null }
    } else if (type === 0x13) {
      if (payload[0] > 1 || (payload[0] === 1 && !this.loaded)) this.result = 0xe4
      else this.guide = payload[0] === 1
    } else if (type === 0x14) {
      if (len !== 0) this.result = 0xe2
    } else this.result = 0xe0
    this.deliver(this.statusFrame())
  }
}

// Delivers status bytes in MTU-23 sized chunks, like a real notification stream.
function wire(issuer, sim, chunkSize) {
  const feed = protocol.createStatusParser(status => issuer.onStatus(status))
  sim.deliver = frame => {
    const bytes = Uint8Array.from(frame)
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      feed(bytes.slice(offset, offset + chunkSize).buffer)
    }
  }
}

async function main() {
  const results = []
  const record = (name, ok) => { results.push({ name, ok }); }

  // ---- 1. happy path: BEGIN, STEP, COMMIT with readback ----
  {
    const sim = new FpgaSim()
    let sent = []
    const issuer = createIssuer({ send: buffer => { sent.push(buffer); sim.receive(buffer) }, timeoutMs: 200 })
    wire(issuer, sim, 20)
    const song = protocol.SONGS[0]
    await issuer.submit(seq => protocol.beginFrame(song, seq), { type: 0x10 })
    for (let i = 0; i < song.steps.length; i += 1) {
      await issuer.submit(seq => protocol.stepFrame(song.steps[i], i, seq), { type: 0x11 })
    }
    const outcome = await issuer.submit(seq => protocol.commitFrame(song.id, seq), {
      type: 0x12,
      validate: status => (status.song === song.id && (status.flags & 1))
        ? true : `readback ${status.song}`
    })
    assert.strictEqual(outcome.ok, true)
    assert.strictEqual(sent.length, song.steps.length + 2)
    assert.strictEqual(sim.loaded, true)
    // sequence numbers must be consecutive per written frame
    for (let i = 0; i < sent.length; i += 1) {
      assert.strictEqual(new Uint8Array(sent[i])[5], i)
    }
    record('逐条应答提交：BEGIN+8 STEP+COMMIT 得到 FPGA 匹配应答', true)
  }

  // ---- 2. a notification with a different sequence must not settle ----
  {
    const sim = new FpgaSim()
    const issuer = createIssuer({ send: buffer => sim.receive(buffer), timeoutMs: 200 })
    wire(issuer, sim, 20)
    let settled = issuer.onStatus({
      song: 9, flags: 1, step: 0, target: 0, expression: 0, hits: 0, wrong: 0, misses: 0,
      layout: 0, partials: 0, wet: 0, commandSequence: 200, commandResult: 0
    })
    assert.strictEqual(settled, false)
    await issuer.submit(seq => protocol.pingFrame(seq), { type: 0x14 })
    record('无关序号的通知不会结算当前命令', true)
  }

  // ---- 3. timeout is UNKNOWN and does not auto-retry ----
  {
    let writes = 0
    const issuer = createIssuer({ send: () => { writes += 1 }, timeoutMs: 40 })
    let error = null
    try {
      await issuer.submit(seq => protocol.commitFrame(1, seq), { type: 0x12 })
    } catch (caught) { error = caught }
    assert.ok(error && error.code === 'TIMEOUT_UNKNOWN')
    assert.strictEqual(writes, 1, '超时后不得自动重发')
    assert.strictEqual(issuer.busy, false, '超时后必须释放发令器')
    record('超时返回未知结果且不自动重发', true)
  }

  // ---- 4. busy: only one command in flight ----
  {
    let release = null
    const issuer = createIssuer({ send: () => new Promise(resolve => { release = resolve }), timeoutMs: 500 })
    const first = issuer.submit(seq => protocol.pingFrame(seq), { type: 0x14 })
    let busy = null
    try { await issuer.submit(seq => protocol.pingFrame(seq), { type: 0x14 }) } catch (e) { busy = e }
    assert.ok(busy && busy.code === 'BUSY')
    release()
    issuer.onStatus({ commandSequence: 0, commandResult: 0, flags: 0, song: 0, step: 0, target: 0,
      expression: 0, hits: 0, wrong: 0, misses: 0, layout: 0, partials: 0, wet: 0 })
    await first
    record('单发令器：并发命令被拒绝', true)
  }

  // ---- 5. readback mismatch is rejected ----
  {
    const sim = new FpgaSim()
    const issuer = createIssuer({ send: buffer => sim.receive(buffer), timeoutMs: 200 })
    wire(issuer, sim, 20)
    const song = protocol.SONGS[0]
    await issuer.submit(seq => protocol.beginFrame(song, seq), { type: 0x10 })
    for (let i = 0; i < song.steps.length; i += 1) {
      await issuer.submit(seq => protocol.stepFrame(song.steps[i], i, seq), { type: 0x11 })
    }
    // Successful COMMIT of the staged song, but the caller expects a different
    // readback identity. Asking the FPGA to COMMIT song2 would instead be E3,
    // which must be reported as an FPGA rejection BEFORE readback validation.
    let error = null
    try {
      await issuer.submit(seq => protocol.commitFrame(song.id, seq), {
        type: 0x12, validate: status => (status.song === 2 && (status.flags & 1)) ? true : 'readback'
      })
    } catch (caught) { error = caught }
    assert.ok(error && error.code === 'READBACK_MISMATCH', '读回不一致必须拒绝')
    record('提交结果与读回不一致时不算成功', true)
  }

  // ---- 6. FPGA rejection carries the result code ----
  {
    const sim = new FpgaSim()
    const issuer = createIssuer({ send: buffer => sim.receive(buffer), timeoutMs: 200 })
    wire(issuer, sim, 20)
    let error = null
    try { await issuer.submit(seq => protocol.commitFrame(1, seq), { type: 0x12,
      validate:()=>{throw new Error('rejected ACK must not invoke success readback validator')}
    }) } catch (e) { error = e }
    assert.ok(error && error.code === 'FPGA_RESULT' && error.result === 0xe6, '没有事务的 COMMIT 应返回 E6')
    assert.strictEqual(protocol.describeResult(0xe6).indexOf('没有已开始'), 0)
    record('FPGA 拒绝码（E6 无事务）原样上报', true)
  }

  // ---- 7. Sequence wrap outside the bounded replay window is legal ----
  {
    let issuer
    issuer=createIssuer({send:buffer=>{let seq=new Uint8Array(buffer)[5];issuer.onStatus({commandSequence:seq,commandResult:0})}})
    for(let i=0;i<520;i++) await issuer.submit(seq=>protocol.frame(0x14,seq,[i&255]))
    assert.ok(issuer.history().length<=128)
    record('连续520条命令跨越两次序号回绕，历史有界',true)
  }

  // ---- 8. discovery rules ----
  {
    assert.deepStrictEqual(discovery.matchAdvertising({ advertisServiceUUIDs: [discovery.SERVICE_UUID] }),
      { matched: true, reason: 'service-uuid' })
    assert.deepStrictEqual(discovery.matchAdvertising({ name: 'XianChu-LINK-R1' }),
      { matched: true, reason: 'compat-name' })
    assert.deepStrictEqual(discovery.matchAdvertising({ name: 'FPGA-Instrument' }),
      { matched: true, reason: 'compat-name' })
    assert.strictEqual(discovery.matchAdvertising({ name: 'Mi Band 8' }).matched, false)
    assert.strictEqual(discovery.matchAdvertising({ advertisServiceUUIDs: ['0000180d-0000-1000-8000-00805f9b34fb'] }).matched, false)
    assert.strictEqual(discovery.hasService([{ uuid: discovery.SERVICE_UUID.toUpperCase() }]), true)
    assert.strictEqual(discovery.hasService([{ uuid: '0000180d-0000-1000-8000-00805f9b34fb' }]), false)
    const identity = discovery.parseIdentity('XC-LINK-R2-20261022 armed=false protocol=1')
    assert.strictEqual(identity.build, 'XC-LINK-R2-20261022')
    assert.strictEqual(identity.armed, false)
    assert.strictEqual(identity.protocolVersion, 1)
    record('发现规则：服务 UUID 优先、兼容名兜底、陌生设备拒绝', true)
  }

  // ---- 9. 22-byte status survives MTU-23 fragmentation ----
  {
    const sim = new FpgaSim()
    const issuer = createIssuer({ send: buffer => sim.receive(buffer), timeoutMs: 200 })
    wire(issuer, sim, 20)
    let seen = null
    const feed = protocol.createStatusParser(status => { seen = status })
    const frame = Uint8Array.from(sim.statusFrame())
    for (let offset = 0; offset < frame.length; offset += 7) feed(frame.slice(offset, offset + 7).buffer)
    assert.ok(seen && seen.flags === 0x10)
    record('22 字节状态在 7/20 字节分片下完整重组', true)
  }

  const failed = results.filter(r => !r.ok)
  for (const item of results) console.log(`${item.ok ? 'ok  ' : 'FAIL'} ${item.name}`)
  if (failed.length) {
    console.log(`FAIL test_transaction: ${failed.length}/${results.length} failed`)
    process.exitCode = 1
  } else {
    console.log(`PASS test_transaction (${results.length} groups: single issuer, timeout unknown, readback, seq reuse, discovery, fragmentation)`)
  }
}

main().catch(error => {
  console.error('FAIL test_transaction:', error && error.stack || error)
  process.exitCode = 1
})
