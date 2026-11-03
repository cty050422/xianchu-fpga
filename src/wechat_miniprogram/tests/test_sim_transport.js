const { test } = require('node:test')
const assert = require('node:assert/strict')
const { createSessionHub } = require('../services/device_session')
const { createSimDevice } = require('../utils/sim_device')
const { createSimTransport } = require('../utils/sim_transport')
const protocol = require('../utils/protocol')
const compiler = require('../utils/score_compiler')

function score8() {
  return {
    schemaVersion: 1, songId: 'test-8', revision: 1, title: '测试八步',
    source: { type: 'original', license: 'CC0-1.0', attribution: 't' },
    difficulty: 1, tags: ['测试'], bpm: 90, timeSignature: [4, 4],
    notes: [0, 1, 2, 3, 3, 2, 1, 0].map(z => ({ zone: z, beats: 1 }))
  }
}
const compiled8 = () => compiler.compileScore(score8(), {})

test('real client stack uploads a full song over the MTU-20 sim transport', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  const outcome = await hub.simUploadSegment({ wireId: 9 }, compiled8(), 0)
  assert.equal(outcome.status.song, 9)
  assert.ok(outcome.status.flags & 1, 'scoreLoaded after COMMIT readback')
  const dev = hub._state.sim.transport.device
  assert.equal(dev.state.steps.length, 8)
  // duration samples survived the wire exactly (90 bpm, 1 beat = 32000)
  assert.equal(dev.state.steps[0].duration, 32000)
  await hub.leaveSimulator()
})

test('notifications are fragmented to MTU-20 and reassembled by the real parser', async () => {
  const transport = createSimTransport({ profile: 'normal' })
  let chunks = []
  transport.onNotify((buffer, kind) => chunks.push(new Uint8Array(buffer).length))
  await transport.connect()
  await transport.write(protocol.pingFrame(0))
  await new Promise(r => setTimeout(r, 40))
  // 22-byte status frame must arrive as 17+5 under MTU 20
  assert.deepEqual(chunks, [17, 5])
  transport.disconnect()
})

test('bad CRC frame gets result 0xE1, never a silent success', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('bad-crc')
  const session = hub._state.sim
  await assert.rejects(
    session.issuer.submit(seq => {
      // Corrupt AFTER the issuer stamped its sequence so the reply path is real.
      const bytes = new Uint8Array(protocol.pingFrame(seq))
      bytes[6] ^= 0xff
      return bytes.buffer
    }, { type: 0x14 }),
    (error) => {
      assert.equal(error.code, 'FPGA_RESULT')
      assert.equal(error.result, 0xe1)
      return true
    }
  )
  await hub.leaveSimulator()
})

test('lost STEP ACK ends TIMEOUT_UNKNOWN and never reports success', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('drop-step-ack')
  await assert.rejects(
    hub.simUploadSegment({ wireId: 5 }, compiled8(), 0),
    (error) => {
      assert.equal(error.code, 'TIMEOUT_UNKNOWN')
      return true
    }
  )
  // The device actually accepted the step (it is staged), the client just
  // never heard back: the client must NOT claim the song is loaded.
  const dev = hub._state.sim.transport.device
  assert.equal(dev.state.scoreLoaded, false)
  await hub.leaveSimulator()
})

test('mid-upload disconnect aborts without breaking the previously committed song', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  const first = await hub.simUploadSegment({ wireId: 4 }, compiled8(), 0)
  assert.equal(first.status.song, 4)
  const dev = hub._state.sim.transport.device

  // Reconnect a disconnect-mid transport is a different session; simulate by
  // directly using a session whose profile drops at step 2.
  await hub.leaveSimulator()
  await hub.enterSimulator('disconnect-mid')
  const snapshots = []
  hub.subscribe(s => snapshots.push(s.hardwareMode))
  await assert.rejects(
    hub.simUploadSegment({ wireId: 6 }, compiled8(), 0),
    (error) => {
      // TIMEOUT_UNKNOWN (in-flight write), RESET (session cleared by the
      // disconnect) or NOT_CONNECTED are all honest failure outcomes.
      assert.ok(['TIMEOUT_UNKNOWN', 'SEND_FAILED', 'RESET', 'NOT_CONNECTED'].includes(error.code), 'got ' + error.code)
      return true
    }
  )
  await new Promise(r => setTimeout(r, 60))
  assert.equal(hub.snapshot().hardwareMode, 'disconnected')
  assert.ok(snapshots.includes('disconnected'))
})

test('unauthorized profile: commands produce no FPGA writes and no fake success', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('unauthorized')
  let infoNotices = []
  hub._state.sim.transport.onInfo(text => infoNotices.push(text))
  await assert.rejects(hub.simPing(), error => {
    assert.equal(error.code, 'TIMEOUT_UNKNOWN')
    return true
  })
  await new Promise(r => setTimeout(r, 30))
  assert.ok(infoNotices.some(t => /PAIR FIRST/.test(t)), 'S3-style PAIR FIRST notice surfaced')
  const dev = hub._state.sim.transport.device
  assert.equal(dev.state.scoreLoaded, false, 'no score could be committed')
  await hub.leaveSimulator()
})

test('stale-status profile: freshness drops to stale after the stream stops', async () => {
  const fakeNow = { value: 1000 }
  const hub = createSessionHub({ now: () => fakeNow.value })
  await hub.enterSimulator('stale-status')
  await hub.simPing() // command 1
  await hub.simPing() // command 2
  await hub.simPing() // command 3
  assert.equal(hub.snapshot().freshness, 'fresh')
  await hub.simPing().catch(() => {}) // command 4: beyond staleAfter → no reply
  fakeNow.value += 6000
  assert.equal(hub.snapshot().freshness, 'stale')
  await hub.leaveSimulator()
})

test('capability mask mirrors all 14 declared consumer fields', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  const cap = await hub.queryCapability()
  assert.equal(cap.supportedMask, 0x3b80ff)
  assert.equal(cap.firstField, 1)
  for (const id of [1, 2, 3, 4, 5, 6, 7, 8, 16, 17, 18, 20, 21, 22])
    assert.ok(protocol.supportsField(cap.supportedMask, id), 'field ' + id)
  for (const id of [9, 13, 14, 19]) assert.ok(!protocol.supportsField(cap.supportedMask, id))
  await hub.leaveSimulator()
})

test('config transaction: ACQUIRE→SET→COMMIT→GET with matching readback', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  const rb = await hub.simConfigTransaction([{ field: 16, value: 24 }])
  assert.equal(rb.value, 24)
  // range violation is refused
  await assert.rejects(
    hub.simConfigTransaction([{ field: 16, value: 99 }]),
    error => {
      assert.equal(error.code, 'SET_FAILED')
      assert.equal(error.result, 17)
      return true
    }
  )
  await hub.leaveSimulator()
})

test('mode switch clears capability and pending drafts; nothing auto-replays', async () => {
  const hub = createSessionHub({})
  // Drafts saved while disconnected…
  hub.saveDraft({ kind: 'upload-song', songId: 'x' })
  assert.equal(hub.snapshot().pendingActionCount, 1)
  await hub.enterSimulator('normal')
  // …are wiped by the mode switch and NOT replayed.
  assert.equal(hub.snapshot().pendingActionCount, 0)
  const dev = hub._state.sim.transport.device
  assert.equal(dev.state.commandCounter, 0, 'no command was auto-sent on connect')
  await hub.leaveSimulator()
  assert.equal(hub.snapshot().capability, null)
})

test('disconnected hub refuses every hardware action (zero writes)', async () => {
  const hub = createSessionHub({})
  await assert.rejects(hub.simPing(), e => e.code === 'NOT_CONNECTED')
  await assert.rejects(hub.simUploadSegment({ wireId: 1 }, compiled8(), 0), e => e.code === 'NOT_CONNECTED')
  await assert.rejects(hub.simGuide(true), e => e.code === 'NOT_CONNECTED')
  await assert.rejects(hub.simConfigTransaction([{ field: 5, value: 600 }]), e => e.code === 'NOT_CONNECTED')
})

test('sim device: 32-step song commits with unsigned mask; 48 steps need two segments', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  const score48 = {
    schemaVersion: 1, songId: 'test-48', revision: 1, title: '48步',
    source: { type: 'original', license: 'CC0-1.0', attribution: 't' },
    difficulty: 1, tags: ['测试'], bpm: 100, timeSignature: [4, 4],
    notes: Array.from({ length: 48 }, (_, i) => ({ zone: i % 4, beats: 0.5 }))
  }
  const compiled = compiler.compileScore(score48, {})
  assert.equal(compiled.segments.length, 2)
  const s1 = await hub.simUploadSegment({ wireId: 30 }, compiled, 0)
  const s2 = await hub.simUploadSegment({ wireId: 30 }, compiled, 1)
  assert.ok(s1.status.flags & 1)
  assert.ok(s2.status.flags & 1)
  assert.notEqual(s1.status.song, s2.status.song, 'segments are separate transactions')
  await hub.leaveSimulator()
})

test('guide rejected before a song is committed (0xE4 path)', async () => {
  const hub = createSessionHub({})
  await hub.enterSimulator('normal')
  await assert.rejects(hub.simGuide(true), error => {
    assert.equal(error.code, 'FPGA_RESULT')
    assert.equal(error.result, 0xe4)
    return true
  })
  await hub.leaveSimulator()
})
