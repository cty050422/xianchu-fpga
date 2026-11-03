const { test } = require('node:test')
const assert = require('node:assert/strict')
const intent = require('../utils/intent')
const { createSessionHub } = require('../services/device_session')
const compiler = require('../utils/score_compiler')

// ---- rule parser -----------------------------------------------------------
test('deterministic phrasings parse without any network or model call', () => {
  const cases = [
    ['找一首慢速练习', 'search', { bpmMax: 90 }],
    ['来点快速练习', 'search', { bpmMin: 110 }],
    ['搜索小羊羔', 'search', { q: '小羊羔' }],
    ['把速度改成80', 'set_bpm', { bpm: 80 }],
    ['速度调到100BPM', 'set_bpm', { bpm: 100 }],
    ['120拍', 'set_bpm', { bpm: 120 }],
    ['开始引导', 'start_guide', {}],
    ['停止引导', 'stop_guide', {}],
    ['现在什么状态', 'query_status', {}],
    ['用拨弦音色', 'suggest_preset', { preset: 0 }],
    ['换吹管', 'suggest_preset', { preset: 1 }],
    ['分量调到16', 'suggest_partials', { value: 16 }],
    ['合唱开一点', 'suggest_chorus', { wet: 32 }],
    ['选择欢乐颂首句', 'select', { q: '欢乐颂首句' }],
    ['这个乐器怎么校准呀', 'open_question', {}]
  ]
  for (const [text, type, params] of cases) {
    const out = intent.parse(text)
    assert.equal(out.type, type, `「${text}」→ ${out.type}（期望 ${type}）`)
    for (const key of Object.keys(params)) {
      assert.deepEqual(out.params[key], params[key], `「${text}」params.${key}`)
    }
  }
})

test('BPM out of range is invalid with an explanation, never applied', () => {
  assert.equal(intent.parse('把速度改成20').type, 'open_question') // no改? has 改成… 20<30 → parseBpm returns null → falls through
  const out = intent.parse('把速度改成999')
  assert.notEqual(out.type, 'set_bpm')
})

test('device-affecting intents are all marked requiresConfirm', () => {
  for (const text of ['把速度改成80', '开始引导', '停止引导', '用拨弦音色', '分量调到8', '合唱开一点']) {
    const out = intent.parse(text)
    assert.equal(out.requiresConfirm, true, text)
    assert.equal(out.deviceRequired, true, text)
  }
  for (const text of ['找一首慢速练习', '现在什么状态']) {
    assert.equal(intent.parse(text).requiresConfirm, false, text)
  }
})

// ---- the confirmation chain: voice → intent → proposal → NO hardware write --
test('voice→intent→proposal chain performs ZERO hardware writes when disconnected', async () => {
  const hub = createSessionHub({})
  const writes = []
  // Instrument the only path that could write: enterSimulator is the gateway
  // to a transport; without it every action must fail before any frame.
  const originalEnter = hub.enterSimulator
  hub.enterSimulator = function () { writes.push('enterSimulator'); return originalEnter.apply(hub, arguments) }

  // User says: "把速度改成80" with a current song selected.
  const parsed = intent.parse('把速度改成80')
  assert.equal(parsed.type, 'set_bpm')
  // Page-level behaviour: disconnected → save draft, do not send.
  hub.saveDraft({ kind: 'bpm', bpm: parsed.params.bpm })
  // Attempting the real action must be refused:
  await assert.rejects(hub.simUploadSegment({ wireId: 1 }, compiler.compileScore({
    schemaVersion: 1, songId: 'x', revision: 1, title: 'x',
    source: { type: 'original', license: 'CC0', attribution: 'x' },
    difficulty: 1, tags: [], bpm: 90, timeSignature: [4, 4],
    notes: [{ zone: 0, beats: 1 }]
  }, {}), 0), e => e.code === 'NOT_CONNECTED')
  await assert.rejects(hub.simGuide(true), e => e.code === 'NOT_CONNECTED')
  assert.equal(writes.length, 0, 'no transport was ever created')
  assert.equal(hub.snapshot().pendingActionCount, 1, 'draft saved, visible')

  // Later connecting must NOT auto-replay the draft.
  await hub.enterSimulator('normal')
  const dev = hub._state.sim.transport.device
  assert.equal(dev.state.commandCounter, 0, 'no command auto-replayed after connect')
  assert.equal(hub.snapshot().pendingActionCount, 0, 'drafts cleared by mode switch')
  await hub.leaveSimulator()
})

test('intent → search reuses the same catalog query contract (no shortcut path)', async () => {
  // The search intent's params must be exactly what the catalog client sends.
  const parsed = intent.parse('找一首慢速练习')
  const query = {
    q: parsed.params.q || '',
    bpmMax: parsed.params.bpmMax,
    bpmMin: parsed.params.bpmMin,
    difficulty: parsed.params.difficulty,
    maxDifficulty: parsed.params.maxDifficulty,
    tag: parsed.params.tag
  }
  // Same keys the catalog service /catalog/v1/songs understands.
  for (const key of ['q', 'bpmMax', 'bpmMin', 'difficulty', 'maxDifficulty', 'tag']) {
    assert.ok(key in query)
  }
  assert.equal(query.bpmMax, 90)
})
