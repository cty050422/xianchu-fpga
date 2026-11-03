// Real-HTTP catalog acceptance: start the actual gateway on an ephemeral
// loopback port and exercise list/search/pagination/detail/version/hash/
// compile endpoints with real fetch calls. This is the localhost closure the
// acceptance plan requires (it is NOT a public deployment).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createGateway } from './server.mjs'
import { createCatalog } from './catalog.mjs'
import { SEEDS } from './catalog_seed.mjs'

const require = (await import('node:module')).createRequire(import.meta.url)
const compiler = require('../wechat_miniprogram/utils/score_compiler.js')

let base = ''
let gateway

test.before(async () => {
  const ledgerFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'catalog-ledger-')), 'ledger.json')
  gateway = createGateway({ ledgerFile })
  await new Promise(resolve => gateway.server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${gateway.server.address().port}`
})

test.after(() => { gateway.server.close() })

test('healthz reports catalog + provider modes', async () => {
  const res = await fetch(base + '/assistant/v1/healthz')
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.equal(body.catalog.songs, SEEDS.length)
  assert.equal(body.asr.mode, 'mock')
  assert.equal(body.asr.paid, false)
})

test('catalog list: pagination, totals, summaries with adaptation', async () => {
  const res = await fetch(base + '/catalog/v1/songs?page=1&pageSize=5')
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.equal(body.schemaVersion, 1)
  assert.equal(body.songs.length, 5)
  assert.equal(body.page, 1)
  assert.ok(body.total >= 10)
  assert.equal(body.totalPages, Math.ceil(body.total / 5))
  for (const song of body.songs) {
    assert.ok(song.contentHash && song.contentHash.length === 64)
    assert.ok(song.adaptation)
    if (!song.adaptation.playable) assert.ok(song.adaptation.reasonText)
  }
  const page2 = await (await fetch(base + '/catalog/v1/songs?page=2&pageSize=5')).json()
  assert.equal(page2.page, 2)
  // No overlap between pages
  const ids1 = body.songs.map(s => s.songId), ids2 = page2.songs.map(s => s.songId)
  assert.equal(ids1.filter(id => ids2.includes(id)).length, 0)
  // Out-of-range page is empty, not an error
  const page99 = await (await fetch(base + '/catalog/v1/songs?page=99&pageSize=5')).json()
  assert.deepEqual(page99.songs, [])
})

test('search by title and tag; speed filter matches intent params', async () => {
  const q = await (await fetch(base + '/catalog/v1/songs?q=' + encodeURIComponent('小羊羔'))).json()
  assert.equal(q.total, 1)
  assert.equal(q.songs[0].songId, 'mary-lamb-preset-a')
  const slow = await (await fetch(base + '/catalog/v1/songs?bpmMax=90')).json()
  assert.ok(slow.songs.every(s => s.bpm <= 90))
  const tag = await (await fetch(base + '/catalog/v1/songs?tag=' + encodeURIComponent('琶音'))).json()
  assert.equal(tag.total, 1)
  assert.equal(tag.songs[0].songId, 'arpeggio-flow')
})

test('detail returns full score whose hash verifies with the shared compiler', async () => {
  const res = await fetch(base + '/catalog/v1/songs/mary-lamb-preset-a')
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.equal(compiler.scoreContentHash(body.score), body.contentHash)
  assert.equal(body.score.notes.length, 26)
  assert.equal(body.adaptation.mapping.group, 'A')
})

test('detail 404 for unknown song; ETag 304 revalidation', async () => {
  const missing = await fetch(base + '/catalog/v1/songs/no-such-song')
  assert.equal(missing.status, 404)
  const first = await fetch(base + '/catalog/v1/songs/rhythm-basic-a')
  const etag = first.headers.get('etag')
  assert.ok(etag)
  const revalidated = await fetch(base + '/catalog/v1/songs/rhythm-basic-a', {
    headers: { 'if-none-match': etag }
  })
  assert.equal(revalidated.status, 304)
})

test('compile endpoint: BPM override recomputes samples exactly', async () => {
  const res = await fetch(base + '/catalog/v1/songs/rhythm-basic-a/compile?bpm=60')
  const body = await res.json()
  assert.equal(body.compiled.ok, true)
  assert.equal(body.compiled.bpm, 60)
  assert.equal(body.compiled.steps[0].durationSamples, 48000)
  const driftAt90 = body.compiled.roundingDriftSamples
  // 48-step marathon: two segments with honest labels
  const m = await (await fetch(base + '/catalog/v1/songs/endurance-marathon-48/compile')).json()
  assert.equal(m.compiled.segments.length, 2)
  assert.deepEqual(m.compiled.segments.map(s => s.steps.length), [32, 16])
  assert.equal(m.compiled.segments[1].label, '第2段/共2段')
  assert.ok(driftAt90 === 0 || typeof driftAt90 === 'number')
})

test('compile endpoint: custom-mapping song refused without device support', async () => {
  const refused = await (await fetch(base + '/catalog/v1/songs/ode-phrase-custom/compile')).json()
  assert.equal(refused.compiled.ok, false)
  assert.equal(refused.compiled.errors[0].code, 'MAPPING_REQUIRES_CONFIG')
  const allowed = await (await fetch(base + '/catalog/v1/songs/ode-phrase-custom/compile?customNotes=1')).json()
  assert.equal(allowed.compiled.ok, true)
  assert.deepEqual(allowed.compiled.requiredMapping.notes, [62, 64, 65, 67])
})

test('six-pitch song is served with an explicit not-adaptable reason', async () => {
  const body = await (await fetch(base + '/catalog/v1/songs/twinkle-six-pitches')).json()
  assert.equal(body.adaptation.playable, false)
  assert.equal(body.adaptation.reason, 'TOO_MANY_PITCHES')
  assert.match(body.adaptation.reasonText, /6 个不同音高/)
})

test('unknown /catalog route returns structured 404, not a crash', async () => {
  const res = await fetch(base + '/catalog/v1/whatever')
  assert.equal(res.status, 404)
  assert.equal((await res.json()).error, 'NOT_FOUND')
})

test('a structurally broken seed fails service construction (no silent serving)', () => {
  const broken = [{ ...SEEDS[0], songId: 'broken', schemaVersion: 9 }]
  assert.throws(() => createCatalog({ seeds: broken }), /SEED_INVALID/)
  const duplicate = [SEEDS[0], { ...SEEDS[0] }]
  assert.throws(() => createCatalog({ seeds: duplicate }), /SEED_DUPLICATE/)
})

test('seed catalog: at least 10 playable entries with real variety', () => {
  const catalog = createCatalog()
  const list = catalog.list({ pageSize: 50 })
  const playable = list.songs.filter(s => s.adaptation.playable)
  assert.ok(playable.length >= 10, `expected ≥10 playable, got ${playable.length}`)
  const byPattern = new Set(playable.map(s => JSON.stringify(s.tags)))
  assert.ok(byPattern.size >= 6, 'seed drills must not be one copied array')
  const bpmValues = new Set(playable.map(s => s.bpm))
  assert.ok(bpmValues.size >= 5)
  const stepCounts = playable.map(s => s.stepCount)
  assert.ok(stepCounts.some(n => n > 32), 'at least one multi-segment drill')
})
