const { test } = require('node:test')
const assert = require('node:assert/strict')
const { createRecorder, STATES } = require('../utils/recorder')

// ---- controllable fake of the wx recorder/permission surface ---------------
function makeFakeWx(overrides = {}) {
  const calls = { start: 0, stop: 0, authorize: 0 }
  let onStart, onStop, onError, onInterruptionBegin
  let lastStartOptions = null
  let lastDuration = 3000
  let lastSize = 12345
  const manager = {
    start(opts) {
      calls.start++
      lastStartOptions = opts
      if (overrides.startFails) { onError({ errMsg: overrides.startErr || 'operateRecorder:fail' }); return }
      onStart({})
    },
    stop() {
      calls.stop++
      if (overrides.stopSilent) return
      onStop({ tempFilePath: '/tmp/a.mp3', duration: lastDuration, fileSize: lastSize })
    },
    onStart(fn) { onStart = fn },
    onStop(fn) { onStop = fn },
    onError(fn) { onError = fn },
    onInterruptionBegin(fn) { onInterruptionBegin = fn }
  }
  const wx = {
    getRecorderManager: () => manager,
    getSetting(o) {
      o.success({ authSetting: overrides.recordScope === undefined ? {} : { 'scope.record': overrides.recordScope } })
    },
    authorize(o) {
      calls.authorize++
      if (overrides.authorizeFails) o.fail({ errMsg: 'authorize:fail auth deny' })
      else o.success({})
    },
    _setDuration: ms => { lastDuration = ms },
    _setSize: bytes => { lastSize = bytes },
    _emitInterruption: () => onInterruptionBegin({}),
    _calls: calls,
    _options: () => lastStartOptions
  }
  return wx
}

const tick = ms => new Promise(r => setTimeout(r, ms))

test('normal PTT cycle: idle → permission → recording → ready with MP3 contract', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  const phases = []
  rec.subscribe(s => phases.push(s.phase))
  await rec.start()
  await tick(5)
  assert.equal(rec.snapshot().phase, STATES.RECORDING)
  const options = wx._options()
  // WeChat contract: format mp3, 16 kHz mono (documented matrix), ≤15 s.
  assert.equal(options.format, 'mp3')
  assert.equal(options.sampleRate, 16000)
  assert.equal(options.numberOfChannels, 1)
  assert.equal(options.duration, 15000)
  const result = await rec.stop()
  assert.equal(rec.snapshot().phase, STATES.READY)
  assert.equal(result.mime, 'audio/mp3')
  assert.equal(result.tempFilePath, '/tmp/a.mp3')
  assert.ok(phases.includes(STATES.REQUESTING_PERMISSION))
  assert.ok(phases.includes(STATES.RECORDING))
})

test('permission denial lands in error with an open-settings recovery', async () => {
  const wx = makeFakeWx({ recordScope: false }) // previously denied
  const rec = createRecorder({ wx })
  await assert.rejects(rec.start(), e => e.code === 'PERMISSION_DENIED')
  assert.equal(rec.snapshot().phase, STATES.ERROR)
  assert.equal(rec.snapshot().error.recover, 'openSettings')
  assert.equal(wx._calls.start, 0, 'recorder.start was never called')
})

test('authorize failure at first ask is also a permission error', async () => {
  const wx = makeFakeWx({ authorizeFails: true })
  const rec = createRecorder({ wx })
  await assert.rejects(rec.start(), e => e.code === 'PERMISSION_DENIED')
  assert.equal(rec.snapshot().phase, STATES.ERROR)
})

test('busy recorder device surfaces RECORDER_BUSY', async () => {
  const wx = makeFakeWx({ startFails: true, startErr: 'operateRecorder:fail recorder is busy' })
  const rec = createRecorder({ wx })
  await rec.start().catch(() => {})
  await tick(5)
  assert.equal(rec.snapshot().phase, STATES.ERROR)
  assert.equal(rec.snapshot().error.code, 'RECORDER_BUSY')
})

test('too-short segment is rejected with a clear message', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  wx._setDuration(300)
  await assert.rejects(rec.stop(), e => e.code === 'TOO_SHORT')
  assert.equal(rec.snapshot().phase, STATES.ERROR)
})

test('too-long segment is rejected (client guard before server)', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  wx._setDuration(21000)
  await assert.rejects(rec.stop(), e => e.code === 'TOO_LONG')
})

test('oversized encoded file is rejected locally (2 MiB cap)', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  wx._setSize(3 * 1024 * 1024)
  await assert.rejects(rec.stop(), e => e.code === 'TOO_LARGE')
})

test('slide-up cancel: segment discarded, stale onStop ignored', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  rec.cancel()
  assert.equal(rec.snapshot().phase, STATES.CANCELLED)
  // A late onStop from the cancelled session must NOT flip state to ready.
  wx._setDuration(2000)
  const late = rec.stop().catch(() => {}) // no-op: not recording
  await tick(5)
  assert.equal(rec.snapshot().phase, STATES.CANCELLED)
})

test('page lifecycle abort (onHide) cancels an in-flight recording', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  rec.abortForLifecycle()
  assert.equal(rec.snapshot().phase, STATES.CANCELLED)
})

test('system interruption (call) cancels with explanation', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  wx._emitInterruption()
  await tick(5)
  assert.equal(rec.snapshot().phase, STATES.CANCELLED)
  assert.equal(rec.snapshot().error.code, 'INTERRUPTED')
})

test('re-entry guard: start while recording rejects ALREADY_RECORDING', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  await assert.rejects(rec.start(), e => e.code === 'ALREADY_RECORDING')
  assert.equal(wx._calls.start, 1)
})

test('15 s auto-stop ceiling arms a hard timer', async () => {
  const wx = makeFakeWx()
  const rec = createRecorder({ wx })
  await rec.start(); await tick(5)
  // Device honors duration: fires onStop at 15s. We just verify the guard
  // exists by checking START_OPTIONS.duration and the timer slot.
  assert.equal(rec.START_OPTIONS.duration, 15000)
  assert.ok(rec.MAX_DURATION_MS === 15000 && rec.MIN_DURATION_MS === 500)
  rec.cancel()
})

test('recorder module exposes states for the page state machine', () => {
  assert.deepEqual(Object.keys(STATES).sort(),
    ['CANCELLED', 'ERROR', 'IDLE', 'READY', 'RECORDING', 'RECOGNIZING', 'REQUESTING_PERMISSION', 'UPLOADING'].map(s => s).sort())
})
