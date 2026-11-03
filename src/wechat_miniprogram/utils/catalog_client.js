// Catalog HTTP client with verified cache. Every downloaded score is hashed
// (same canonical SHA-256 as the service) BEFORE it enters the cache; a
// corrupted or mismatched document is discarded, and a failed update keeps the
// previous good revision. Offline reads are explicitly marked as cache.
var compiler = require('./score_compiler')

var CACHE_PREFIX = 'catalog:'
var MAX_CACHED_SONGS = 60

function createCatalogClient(options) {
  var opts = options || {}
  var wxApi = opts.wx
  var baseUrl = opts.baseUrl || ''
  var storage = opts.storage || {
    get: function (k) { return wxApi.getStorageSync(k) },
    set: function (k, v) { wxApi.setStorageSync(k, v) },
    remove: function (k) { wxApi.removeStorageSync(k) },
    info: function () { return wxApi.getStorageInfoSync() }
  }

  function request(method, path, body) {
    return new Promise(function (resolve, reject) {
      if (!baseUrl) {
        return reject({ code: 'SERVICE_UNCONFIGURED', message: '尚未配置曲库服务地址（设置页可配置）' })
      }
      wxApi.request({
        url: baseUrl + path,
        method: method,
        data: body || undefined,
        timeout: 8000,
        success: function (res) {
          if (res.statusCode >= 200 && res.statusCode < 300) resolve(res.data)
          else reject({ code: 'HTTP_' + res.statusCode, statusCode: res.statusCode, body: res.data })
        },
        fail: function (err) {
          reject({ code: 'NETWORK_ERROR', message: (err && err.errMsg) || '网络请求失败' })
        }
      })
    })
  }

  function cachedSongs() {
    var index = storage.get(CACHE_PREFIX + 'index')
    if (!Array.isArray(index)) return []
    return index.filter(function (entry) { return entry && entry.songId && entry.contentHash && entry.baseUrl === baseUrl })
  }

  function writeCacheIndex(songs) {
    storage.set(CACHE_PREFIX + 'index', songs.slice(0, MAX_CACHED_SONGS))
  }

  function rememberCached(songId, entry) {
    var songs = cachedSongs().filter(function (s) { return s.songId !== songId })
    songs.unshift({ songId: entry.score.songId, revision: entry.score.revision, title: entry.score.title,
      contentHash: entry.contentHash, cachedAt: Date.now(), baseUrl: baseUrl })
    // Size cap: evict oldest cached song documents first.
    var keep = songs.slice(0, MAX_CACHED_SONGS)
    for (var i = 0; i < songs.length; i++) {
      if (keep.indexOf(songs[i]) < 0) storage.remove(CACHE_PREFIX + 'song:' + songs[i].songId)
    }
    writeCacheIndex(keep)
    storage.set(CACHE_PREFIX + 'song:' + songId, entry)
  }

  function readCachedDetail(songId) {
    var raw = storage.get(CACHE_PREFIX + 'song:' + songId)
    if (!raw || !raw.score || !raw.contentHash || raw.baseUrl !== baseUrl || raw.score.songId !== songId) {
      // Corrupt cache entry: remove it so the next fetch repairs the state.
      storage.remove(CACHE_PREFIX + 'song:' + songId)
      return null
    }
    // Re-verify the hash on read: storage corruption must surface, not serve.
    if (compiler.scoreContentHash(raw.score) !== raw.contentHash) {
      storage.remove(CACHE_PREFIX + 'song:' + songId)
      return null
    }
    raw.fromCache = true
    return raw
  }

  return {
    setBaseUrl: function (url) { baseUrl = String(url || '').replace(/\/+$/, '') },
    getBaseUrl: function () { return baseUrl },

    list: function (params) {
      var query = []
      var p = params || {}
      if (p.page) query.push('page=' + p.page)
      if (p.pageSize) query.push('pageSize=' + p.pageSize)
      if (p.q) query.push('q=' + encodeURIComponent(p.q))
      if (p.difficulty) query.push('difficulty=' + p.difficulty)
      if (p.maxDifficulty) query.push('maxDifficulty=' + p.maxDifficulty)
      if (p.tag) query.push('tag=' + encodeURIComponent(p.tag))
      if (p.bpmMin) query.push('bpmMin=' + p.bpmMin)
      if (p.bpmMax) query.push('bpmMax=' + p.bpmMax)
      var suffix = query.length ? '?' + query.join('&') : ''
      var origin = baseUrl, cacheKey = origin + suffix
      return request('GET', '/catalog/v1/songs' + suffix).then(function (data) {
        if (origin !== baseUrl) throw { code: 'SOURCE_CHANGED', message: '曲库服务已变化，请重新搜索' }
        storage.set(CACHE_PREFIX + 'list-cache', { key: cacheKey, data: data, cachedAt: Date.now() })
        return { source: 'network', data: data }
      }).catch(function (error) {
        if (origin !== baseUrl) throw error
        var cached = storage.get(CACHE_PREFIX + 'list-cache')
        if (cached && cached.key === cacheKey && cached.data) {
          return { source: 'cache', data: cached.data, offline: true, error: error }
        }
        throw error
      })
    },

    // Detail with hash verification and cache repair. `offline` results carry
    // the cached document and never pretend to be a live fetch.
    detail: function (songId) {
      var origin = baseUrl
      return request('GET', '/catalog/v1/songs/' + songId).then(function (entry) {
        if (origin !== baseUrl) throw { code: 'SOURCE_CHANGED', message: '曲库服务已变化，请重新选择' }
        if (!entry || !entry.score || entry.score.songId !== songId) throw { code: 'BAD_DETAIL', message: '服务返回的曲目数据不完整或编号不匹配' }
        var actual = compiler.scoreContentHash(entry.score)
        if (actual !== entry.contentHash) {
          throw { code: 'HASH_MISMATCH', message: '内容hash不符（服务=' + entry.contentHash.slice(0, 8) + ' 计算=' + actual.slice(0, 8) + '），已拒绝写缓存' }
        }
        entry.fromCache = false
        rememberCached(songId, { score: entry.score, contentHash: entry.contentHash, cachedAt: Date.now(), adaptation: entry.adaptation, baseUrl: origin })
        this.recent.push(songId)
        return entry
      }.bind(this)).catch(function (error) {
        if (origin !== baseUrl || error && (error.code === 'HASH_MISMATCH' || error.code === 'BAD_DETAIL' || error.code === 'SOURCE_CHANGED')) throw error
        var cached = readCachedDetail(songId)
        if (cached) return cached
        throw error
      })
    },

    compile: function (songId, bpm, deviceSupportsCustomNotes) {
      var query = []
      if (bpm) query.push('bpm=' + bpm)
      if (deviceSupportsCustomNotes) query.push('customNotes=1')
      return request('GET', '/catalog/v1/songs/' + songId + '/compile' + (query.length ? '?' + query.join('&') : ''))
    },

    // ---- local collections ----
    favorites: {
      list: function () { var v = storage.get(CACHE_PREFIX + 'favorites'); return Array.isArray(v) ? v : [] },
      toggle: function (songId) {
        var list = this.list()
        var i = list.indexOf(songId)
        if (i >= 0) list.splice(i, 1); else list.push(songId)
        storage.set(CACHE_PREFIX + 'favorites', list)
        return i < 0
      },
      has: function (songId) { return this.list().indexOf(songId) >= 0 }
    },
    recent: {
      list: function () { var v = storage.get(CACHE_PREFIX + 'recent'); return Array.isArray(v) ? v : [] },
      push: function (songId) {
        var list = this.list().filter(function (id) { return id !== songId })
        list.unshift(songId)
        storage.set(CACHE_PREFIX + 'recent', list.slice(0, 20))
      }
    },
    cached: cachedSongs,
    readCachedDetail: readCachedDetail,

    clearCache: function () {
      var songs = cachedSongs()
      for (var i = 0; i < songs.length; i++) storage.remove(CACHE_PREFIX + 'song:' + songs[i].songId)
      storage.remove(CACHE_PREFIX + 'index')
      storage.remove(CACHE_PREFIX + 'list-cache')
      return songs.length
    }
  }
}

module.exports = { createCatalogClient, CACHE_PREFIX, MAX_CACHED_SONGS }
