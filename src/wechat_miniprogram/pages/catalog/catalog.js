// 曲库页：真实 HTTP 曲库（默认本地 localhost 服务）+ 校验缓存 + 四区适配预览。
// 来源状态显式标注：本地曲库服务 / 离线缓存 / 未配置；绝不把缓存当在线。
const compiler = require('../../utils/score_compiler')
const protocol = require('../../utils/protocol')
const {wireIdFor} = require('../../services/assistant_actions')

const PAGE_SIZE = 20
const SPEED_FILTERS = [
  { key: '', label: '全部速度' },
  { key: 'slow', label: '慢速 ≤90' },
  { key: 'fast', label: '快速 ≥110' }
]
const DIFF_FILTERS = [
  { key: '', label: '全部难度' },
  { key: '1', label: '难度1 入门' },
  { key: '2', label: '难度2' },
  { key: '3', label: '难度3' }
]

function hubOf() {
  return typeof getApp === 'function' ? getApp().globalData.sessionHub : null
}
function catalogOf() {
  return typeof getApp === 'function' ? getApp().globalData.catalogClient : null
}

Page({
  data: {
    serviceMode: 'unconfigured',
    sourceLabel: '未配置服务',
    sourceChip: 'chip-neutral',
    searchQuery: '',
    speedFilter: '',
    diffFilter: '',
    speedFilters: SPEED_FILTERS,
    diffFilters: DIFF_FILTERS,
    songs: [],
    total: 0, page: 1, totalPages: 1,
    loading: false, offline: false, error: '',
    unconfigured: true,
    favorites: [],
    cachedCount: 0,
    recentCount: 0,
    // 详情面板
    detailOpen: false, detail: null, detailError: '', detailLoading: false,
    detailFromCache: false,
    compilePreview: null, compileError: '', compileBpm: 0, customNotesSupported: false,
    uploadState: '', uploadProgress: '', uploadSegmentIndex: 0,
    hardwareMode: 'disconnected', isSimulator: false,
    previewPlaying: false, previewLabel: ''
  },

  onLoad() {
    this.disposed = false
    this.unsubscribe = null
  },

  onShow() {
    this.refreshServiceState()
    this.attachHub()
    this.reload()
  },

  onHide() { this.stopPreview() },
  onUnload() {
    this.disposed = true
    this.stopPreview()
    if (this.unsubscribe) { this.unsubscribe(); this.unsubscribe = null }
  },

  attachHub() {
    const hub = hubOf()
    if (!hub || this.unsubscribe) return
    this.unsubscribe = hub.subscribe(() => this.applyHubSnapshot())
    this.applyHubSnapshot()
  },

  applyHubSnapshot() {
    if (this.disposed) return
    const snap = hubOf().snapshot()
    this.setData({
      hardwareMode: snap.hardwareMode,
      isSimulator: snap.isSimulator,
      customNotesSupported: !!(snap.capability && protocol.supportsField(snap.capability.supportedMask, 1))
    })
  },

  refreshServiceState() {
    const app = typeof getApp === 'function' ? getApp() : null
    const client = catalogOf()
    if (!app || !client) return
    const { serviceMode } = app.globalData.serviceConfig.baseUrl
      ? { serviceMode: 'configured-service' } : { serviceMode: 'unconfigured' }
    const labels = {
      'configured-service': '曲库服务',
      'local-demo': '曲库服务',
      'unconfigured': '未连接'
    }
    this.setData({
      serviceMode,
      sourceLabel: labels[serviceMode] || labels.unconfigured,
      sourceChip: serviceMode === 'unconfigured' ? 'chip-neutral' : 'chip-ok',
      unconfigured: serviceMode === 'unconfigured',
      favorites: client.favorites.list(),
      cachedCount: client.cached().length,
      recentCount: client.recent.list().length
    })
  },

  reload() {
    if (this.data.loading) return
    const client = catalogOf()
    if (!client || !client.getBaseUrl()) {
      // 未配置服务时仍显示缓存中的已下载曲目（离线可练习）
      this.setData({ songs: [], loading: false, error: '', offline: false })
      this.loadCachedOnly()
      return
    }
    this.setData({ loading: true, error: '', offline: false })
    const params = { page: this.data.page, pageSize: PAGE_SIZE }
    if (this.data.searchQuery) params.q = this.data.searchQuery
    if (this.data.speedFilter === 'slow') params.bpmMax = 90
    if (this.data.speedFilter === 'fast') params.bpmMin = 110
    if (this.data.diffFilter) params.difficulty = this.data.diffFilter
    client.list(params).then((outcome) => {
      if (this.disposed) return
      this.setData({
        loading: false,
        songs: (outcome.data.songs || []).map(song => ({...song, isFavorite: client.favorites.list().includes(song.songId)})),
        total: outcome.data.total || 0,
        page: outcome.data.page || 1,
        totalPages: outcome.data.totalPages || 1,
        offline: !!outcome.offline,
        sourceLabel: outcome.offline ? '离线缓存' : '曲库服务',
        sourceChip: outcome.offline ? 'chip-warn' : 'chip-ok'
      })
    }).catch((error) => {
      if (this.disposed) return
      this.setData({ loading: false, songs: [], error: (error && error.message) || '曲库加载失败' })
    })
  },

  loadCachedOnly() {
    const client = catalogOf()
    if (!client) return
    const cached = client.cached().map((entry) => ({
      songId: entry.songId, revision: entry.revision, title: entry.title,
      difficulty: 0, tags: ['已缓存'], bpm: 0, timeSignature: [4, 4],
      contentHash: entry.contentHash,
      adaptation: { playable: true, mapping: { label: '已缓存到手机（离线可练习）' } }
    }))
    this.setData({ songs: cached.map(song => ({...song, isFavorite: client.favorites.list().includes(song.songId)})), total: cached.length, offline: cached.length > 0,
      sourceLabel: cached.length ? '离线缓存（未配置服务）' : '未配置服务',
      sourceChip: cached.length ? 'chip-warn' : 'chip-neutral' })
  },

  onSearchInput(event) { this.setData({ searchQuery: event.detail.value }) },
  onSearchConfirm() { this.setData({ page: 1 }); this.reload() },
  onSpeedFilter(event) {
    const key = event.currentTarget.dataset.key
    this.setData({ speedFilter: key, page: 1 })
    const idx = SPEED_FILTERS.findIndex(f => f.key === key)
    this.setData({ speedFilterLabel: SPEED_FILTERS[idx].label })
    this.reload()
  },
  onDiffFilter(event) {
    const key = event.currentTarget.dataset.key
    this.setData({ diffFilter: key, page: 1 })
    this.reload()
  },
  prevPage() { if (this.data.page > 1) { this.setData({ page: this.data.page - 1 }); this.reload() } },
  nextPage() { if (this.data.page < this.data.totalPages) { this.setData({ page: this.data.page + 1 }); this.reload() } },

  openDetail(event) {
    const songId = event.currentTarget.dataset.id
    const client = catalogOf()
    if (!client) return
    this.setData({ detailOpen: true, detailLoading: true, detail: null, detailError: '',
      compilePreview: null, compileError: '', uploadState: '', uploadProgress: '' })
    client.detail(songId).then((entry) => {
      if (this.disposed) return
      client.recent.push(songId)
      this.setData({
        detailLoading: false,
        detail: entry,
        detailFromCache: !!entry.fromCache,
        compileBpm: entry.score.bpm
      })
      this.recompile(entry.score, entry.score.bpm)
    }).catch((error) => {
      if (this.disposed) return
      this.setData({ detailLoading: false, detailError: (error && error.message) || '曲目加载失败' })
    })
  },

  noop() {},
  closeDetail() { this.setData({ detailOpen: false, detail: null }); this.stopPreview() },

  toggleFavorite(event) {
    const songId = event.currentTarget.dataset.id
    const client = catalogOf()
    if (!client) return
    const added = client.favorites.toggle(songId)
    this.setData({ favorites: client.favorites.list(), songs: this.data.songs.map(song => ({...song, isFavorite: client.favorites.list().includes(song.songId)})) })
    wx.showToast({ title: added ? '已收藏' : '已取消收藏', icon: 'none' })
  },

  onBpmInput(event) {
    const bpm = Number(event.detail.value) || 0
    this.setData({ compileBpm: bpm })
    if (this.data.detail && bpm >= compiler.BPM_MIN && bpm <= compiler.BPM_MAX) {
      this.recompile(this.data.detail.score, bpm)
    }
  },
  onBpmChange(event) {
    const bpm = Number(event.detail.value) || this.data.detail.score.bpm
    this.setData({ compileBpm: bpm })
    if (this.data.detail) this.recompile(this.data.detail.score, bpm)
  },

  // 变速重新编译的是“尚未上传”的本地版本；不会篡改正在运行的 FPGA 节拍。
  recompile(score, bpm) {
    const result = compiler.compileScore(score, {
      bpm, encoding:'v2',
      deviceSupportsCustomNotes: this.data.customNotesSupported
    })
    if (result.ok) {
      const first = result.segments[0]
      this.setData({
        uploadSegmentIndex:0,
        compilePreview: {
          stepCount: result.stepCount,
          segments: result.segments.length,
          segmentOptions:result.segments.map(function(s){return {index:s.index,label:s.label}}),
          segmentLabel: first.label,
          durationSeconds: result.durationSeconds,
          driftSamples: result.roundingDriftSamples,
          mappingLabel: result.requiredMapping.label,
          mappingNeedsConfig: result.requiredMapping.needsConfig,
          zonePitchNames: result.zonePitchNames || null,
          bpm: result.bpm,
          steps: first.steps
        },
        compileError: ''
      })
    } else {
      this.setData({ compilePreview: null, compileError: result.errors[0].message })
    }
  },

  downloadToDevice(event) {
    const segmentIndex = Number(event.currentTarget.dataset.segment || 0)
    const hub = hubOf()
    const detail = this.data.detail
    if (!hub || !detail || !this.data.compilePreview) return
    const compiled = compiler.compileScore(detail.score, {
      encoding: 'v2', bpm: this.data.compileBpm,
      deviceSupportsCustomNotes: this.data.customNotesSupported
    })
    if (!compiled.ok) {
      this.setData({ uploadState: '编译失败：' + compiled.errors[0].message })
      return
    }
    if (this.data.hardwareMode === 'disconnected') {
      hub.saveDraft({ kind: 'upload-song', songId: detail.songId, encoding: 'v2', bpm: this.data.compileBpm, at: Date.now() })
      this.setData({ uploadState: '未连接设备：已存为草稿（不会自动发送）。连接后需手动重新点击上传。' })
      return
    }
    this.setData({ uploadState: '上传中（等待FPGA确认）', uploadProgress: '', uploadSegmentIndex: segmentIndex })
    hub.simUploadSegmentV2(compiled, this.wireIdFor(detail), segmentIndex,
      (done, total, label) => {
        this.setData({ uploadProgress: label + ' 步骤 ' + done + '/' + total })
      })
      .then((outcome) => {
        if(hub.rememberScore)hub.rememberScore({songId:detail.score.songId,title:detail.score.title,bpm:compiled.bpm,wireId:outcome.status.song,segmentIndex,segments:compiled.segments.length,source:'catalog'})
        const total = compiled.segments.length
        const next = segmentIndex + 1
        this.setData({
          uploadState: 'FPGA已确认：' + (total > 1 ? '第' + (segmentIndex + 1) + '段/共' + total + '段已提交（曲目' + outcome.status.song + '）。' +
            (next < total ? '下一段（第' + (next + 1) + '段）需重新上传，FPGA 不能无缝拼接两段。' : '全部段完成。') : '曲目' + outcome.status.song + '已提交。'),
          uploadProgress: ''
        })
      })
      .catch((error) => {
        this.setData({
          uploadState: '上传未确认：' + (error.message || error.code || String(error)) + '（未得到 FPGA 确认前不算成功）',
          uploadProgress: ''
        })
      })
  },
  chooseUploadSegment(event){
    const index=Number(event.detail.value)
    const detail=this.data.detail
    if(!detail)return
    const compiled=compiler.compileScore(detail.score,{encoding:'v2',bpm:this.data.compileBpm,
      deviceSupportsCustomNotes:this.data.customNotesSupported})
    if(!compiled.ok||!compiled.segments[index])return
    this.stopPreview()
    this.setData({uploadSegmentIndex:index,
      compilePreview:{...this.data.compilePreview,steps:compiled.segments[index].steps,
        segmentLabel:compiled.segments[index].label},
      uploadState:'已选择分段，需手动上传；不会自动开始演奏'})
  },

  wireIdFor(detail) {
    return wireIdFor(detail.score ? detail.score.songId : detail.songId)
  },

  // 手机预览：本地节拍动画，明确标注“手机预览”，不代表 FPGA 引导。
  startPreview() {
    if (!this.data.compilePreview || this.data.previewPlaying) return
    const steps = this.data.compilePreview.steps
    let index = 0
    this.setData({ previewPlaying: true, previewLabel: '手机预览（非FPGA引导）' })
    const tick = () => {
      if (!this.data.previewPlaying || this.disposed) return
      const step = steps[index % steps.length]
      const target=step.mask===0?'休止':step.mask?[0,1,2,3].filter(z=>step.mask&(1<<z)).map(z=>z+1).join('+'):String(step.zone+1)
      this.setData({ previewLabel: '手机预览 · 第' + ((index % steps.length) + 1) + '步 → ' + (step.mask===0?'休止':'演奏区'+target) })
      index += 1
      this.previewTimer = setTimeout(tick, Math.max(120, step.durationSamples / 48))
    }
    this.previewTimer = setTimeout(tick, 200)
  },
  stopPreview() {
    if (this.previewTimer) { clearTimeout(this.previewTimer); this.previewTimer = null }
    if (this.data.previewPlaying) this.setData({ previewPlaying: false, previewLabel: '' })
  },

  async hearFpga(){
    if(this.data.detailLoading||this.data.uploadState==='uploading')return;
    const score=this.data.detail&&this.data.detail.score;if(!score)return;
    const app=getApp(),hub=app.globalData.sessionHub,snap=hub.snapshot();
    if(snap.hardwareMode!=='real')return this.setData({detailError:'先在乐器页连接并授权'});
    this.setData({detailLoading:true,detailError:''});
    try{
      const session=app.getAuditionSession();await session.stop();
      if(snap.observer&&snap.observer.mode!==0)await hub.practiceControl(0,4);
      const a=require('../../utils/audition_score').fromCatalog(score,this.data.compileBpm||score.bpm);
      await session.play(a,0,snap.lastStatus&&snap.lastStatus.preset||0,{whole:true,offline:a.segments.length===1&&!!snap.observer,title:score.title});
      this.setData({detailError:''});
    }catch(e){this.setData({detailError:e.message||'示范未确认'})}finally{this.setData({detailLoading:false})}
  },
  openAudition(){
    try{if(this.data.detail&&this.data.detail.score){const score=this.data.detail.score;getApp().globalData.auditionDraft={score,title:score.title,bpm:this.data.compileBpm||score.bpm,source:'曲库'}}
    wx.navigateTo({url:'/pages/audition/audition'})}catch(e){this.setData({detailError:e.message})}
  },
  clearCache() {
    const client = catalogOf()
    if (!client) return
    const removed = client.clearCache()
    wx.showToast({ title: '已清理 ' + removed + ' 首缓存', icon: 'none' })
    this.refreshServiceState()
  }
})
