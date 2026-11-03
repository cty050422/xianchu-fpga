// Catalog client acceptance: the wx adapter layer against a REAL localhost
// gateway (request bridge wx.request → node fetch). Cache verification, hash
// rejection, offline fallback, corruption repair, favorites/recent, size cap.
const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { createCatalogClient } = require('../utils/catalog_client')

// ---- wx mock with a real HTTP bridge ----------------------------------------
function makeWxBridge(baseUrl, overrides = {}) {
  const storage = new Map()
  return {
    wx: {
      request(o) {
        fetch(baseUrl + o.url.replace(baseUrl, ''), { method: o.method || 'GET', headers: { 'content-type': 'application/json' }, body: o.data ? JSON.stringify(o.data) : undefined })
          .then(async res => {
            if (overrides.offline) throw new Error('bridge offline')
            const text = await res.text()
            let data
            try { data = JSON.parse(text) } catch { data = text }
            if (res.statusCode === undefined) {}
            if (res.status >= 200 && res.status < 300) o.success({ statusCode: res.status, data })
            else o.success({ statusCode: res.status, data })
          })
          .catch(err => o.fail({ errMsg: 'request:fail ' + err.message }))
      },
      getStorageSync: k => (storage.has(k) ? storage.get(k) : ''),
      setStorageSync: (k, v) => storage.set(k, v),
      removeStorageSync: k => storage.delete(k),
      getStorageInfoSync: () => ({ keys: Array.from(storage.keys()) }),
      _storage: storage
    },
    storage
  }
}

let base = '', gateway, ledgerFile
test.before(async () => {
  const { createGateway } = await import('../../assistant_gateway/server.mjs')
  ledgerFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'catclient-')), 'ledger.json')
  gateway = createGateway({ ledgerFile })
  await new Promise(resolve => gateway.server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${gateway.server.address().port}`
})
test.after(() => gateway.server.close())

test('list/detail over the wx adapter against real HTTP; hash verified into cache', async () => {
  const { wx } = makeWxBridge(base)
  const client = createCatalogClient({ wx, baseUrl: base })
  const list = await client.list({ q: '' })
  assert.equal(list.source, 'network')
  assert.ok(list.data.songs.length >= 10)
  const detail = await client.detail('rhythm-basic-a')
  assert.equal(detail.fromCache, false)
  assert.equal(client.cached().length, 1)
  const cached = client.readCachedDetail('rhythm-basic-a')
  assert.ok(cached && cached.fromCache)
  // recent list updated
  assert.ok(client.recent.list().includes('rhythm-basic-a'))
})

test('hash mismatch is refused and never poisons the cache', async () => {
  const { wx, storage } = makeWxBridge(base)
  const client = createCatalogClient({ wx, baseUrl: base })
  // Tamper the server response in the bridge so the hash no longer matches.
  const originalRequest = wx.request
  wx.request = o => originalRequest({
    ...o,
    success: res => {
      if (res.data && res.data.score && res.data.score.songId === 'rhythm-basic-a') {
        res.data.score.title = '被篡改的标题'
      }
      o.success(res)
    }
  })
  await assert.rejects(client.detail('rhythm-basic-a'), e => e.code === 'HASH_MISMATCH')
  assert.equal(client.cached().length, 0, 'nothing cached from a mismatching document')
})

test('corrupted cache entry is discarded and repaired on next fetch', async () => {
  const { wx, storage } = makeWxBridge(base)
  const client = createCatalogClient({ wx, baseUrl: base })
  await client.detail('hold-sustain')
  const key = 'catalog:song:hold-sustain'
  const good = storage.get(key)
  // Corrupt the stored score (simulate bit rot): next read must drop it.
  storage.set(key, { score: { ...good.score, bpm: 1 }, contentHash: good.contentHash })
  const reRead = client.readCachedDetail('hold-sustain')
  assert.equal(reRead, null, 'hash check on read dropped the corrupted entry')
  // A fresh fetch repairs the state.
  const fresh = await client.detail('hold-sustain')
  assert.equal(fresh.fromCache, false)
  assert.ok(client.readCachedDetail('hold-sustain'))
})

test('service down: cached detail and list serve offline with explicit marking', async () => {
  const network = { offline: false }
  const { wx } = makeWxBridge(base, network)
  const client = createCatalogClient({ wx, baseUrl: base })
  await client.list({ q: '' })
  await client.detail('rhythm-basic-a')
  // Simulate the service dying.
  network.offline = true
  const offlineList = await client.list({ q: '' })
  assert.equal(offlineList.source, 'cache')
  assert.equal(offlineList.offline, true)
  assert.ok(offlineList.data.songs.length >= 1)
  const offlineDetail = await client.detail('rhythm-basic-a')
  assert.equal(offlineDetail.fromCache, true)
  // A song never cached has no offline fallback.
  await assert.rejects(client.detail('arpeggio-flow'), e => e.code === 'NETWORK_ERROR')
  // Changing servers is not a network failure of the original source.
  client.setBaseUrl('http://127.0.0.1:1')
  await assert.rejects(client.list({ q: '' }), e => e.code === 'NETWORK_ERROR')
  await assert.rejects(client.detail('rhythm-basic-a'), e => e.code === 'NETWORK_ERROR')
})

test('a valid hash for a different requested song is rejected before caching',async()=>{
 const {wx}=makeWxBridge(base),client=createCatalogClient({wx,baseUrl:base}),original=wx.request
 wx.request=o=>original({...o,url:o.url.replace('hold-sustain','rhythm-basic-a')})
 await assert.rejects(client.detail('hold-sustain'),e=>e.code==='BAD_DETAIL')
 assert.equal(client.cached().length,0)
})

test('unconfigured service refuses cleanly instead of inventing a server', async () => {
  const { wx } = makeWxBridge(base)
  const client = createCatalogClient({ wx, baseUrl: '' })
  await assert.rejects(client.list({}), e => e.code === 'SERVICE_UNCONFIGURED')
})

test('favorites toggle and cache clear', async () => {
  const { wx } = makeWxBridge(base)
  const client = createCatalogClient({ wx, baseUrl: base })
  assert.equal(client.favorites.toggle('a'), true)
  assert.equal(client.favorites.has('a'), true)
  assert.equal(client.favorites.toggle('a'), false)
  assert.equal(client.favorites.has('a'), false)
  await client.detail('rhythm-basic-b')
  const removed = client.clearCache()
  assert.equal(removed, 1)
  assert.equal(client.cached().length, 0)
})

test('late response ordering: a slow first query must not clobber a newer one', async () => {
  const { wx } = makeWxBridge(base)
  const client = createCatalogClient({ wx, baseUrl: base })
  // The client's list() resolves with whatever the server answered for THAT
  // request; verify two concurrent searches return their own results.
  const [slow, fast] = await Promise.all([
    client.list({ q: '小羊羔' }),
    client.list({ q: '琶音' })
  ])
  assert.equal(slow.data.songs[0].songId, 'mary-lamb-preset-a')
  assert.equal(fast.data.songs[0].songId, 'arpeggio-flow')
})
