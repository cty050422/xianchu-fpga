// 设备/设置页：连接状态、演示模式、服务地址、配置事务与诊断。
// 真实BLE连接流程在「乐器/练习」页（已验证的PING2链路）；本页聚合其状态。
// 演示模式显式进入/退出，切换时清空会话与草稿，绝不自动重放。
const protocol = require('../../utils/protocol')

function hubOf() { return typeof getApp === 'function' ? getApp().globalData.sessionHub : null }
function appOf() { return typeof getApp === 'function' ? getApp() : null }

const SIM_PROFILES = [
  { key: 'normal', label: '正常设备' },
  { key: 'uncalibrated', label: '未校准' },
  { key: 'unauthorized', label: '未授权（PAIR FIRST）' },
  { key: 'stale-status', label: '状态失鲜（不应答）' },
  { key: 'drop-step-ack', label: '丢一次STEP应答' },
  { key: 'disconnect-mid', label: '上传中断线' },
  { key: 'bad-crc', label: '坏CRC应答E1' },
  { key: 'busy', label: '引导中（忙）' },
  { key: 'old-firmware', label: '旧版固件身份' }
]

Page({
  data: {
    hardwareMode: 'disconnected',
    hardwareLabel: '未连接设备',
    serviceMode: 'unconfigured', providerMode: 'unconfigured',
    baseUrl: '', baseUrlInput: '',
    healthInfo: null, healthError: '',
    servicePairCode: '', servicePairBusy: false, serviceAuthLabel: '曲库服务未授权',
    settingsScrollTarget: 'catalog-service',
    simProfiles: SIM_PROFILES, simProfile: 'normal', simProfileIndex: 0, simProfileLabel: '正常设备',
    snapshotJson: '',
    freshness: 'none', statusFrames: 0,
    capability: null, capabilityText: '未协商',
    configFields: [], configValues: {}, configBusy: false, configResult: '',
    diagnosticsOpen: false, advancedOpen: false,
    versions: require('../../version')
  },

  onLoad() { this.disposed = false },
  onShow() {
    const app = appOf()
    if (app) this.setData({ baseUrlInput: app.globalData.serviceConfig.baseUrl,serviceAuthLabel:app.globalData.voiceClient.isAuthorized()?'曲库服务已授权':'曲库服务未授权' })
    this.attachHub()
    this.refresh()
  },
  onUnload() {
    this.disposed = true
    if (this.unsubscribe) { this.unsubscribe(); this.unsubscribe = null }
  },

  attachHub() {
    const hub = hubOf()
    if (!hub || this.unsubscribe) return
    this.unsubscribe = hub.subscribe(() => this.refresh())
  },

  refresh() {
    if (this.disposed) return
    const hub = hubOf()
    if (!hub) return
    const snap = hub.snapshot()
    const labels = {
      disconnected: '未连接设备（默认状态；不会发送任何硬件命令）',
      simulator: '演示设备（模拟器 · ' + snap.simProfile + ' · 非实板数据）',
      real: '真实设备（' + (snap.realDevice ? snap.realDevice.name : '') + '）'
    }
    // 可配置字段表（与固件能力掩码对应）
    const fields = protocol.CONFIG_FIELDS.filter(f => f.supported && snap.capability && protocol.supportsField(snap.capability.supportedMask,f.id) && (f.id!==19 || (snap.voicesFresh && snap.voicesFrame.schema===2))).map(f => ({
      id: f.id, label: f.label, min: f.min, max: f.max
    }))
    this.setData({
      hardwareMode: snap.hardwareMode,
      hardwareLabel: labels[snap.hardwareMode] || labels.disconnected,
      serviceMode: snap.serviceMode,
      providerMode: snap.providerMode,
      baseUrl: snap.baseUrl || '',
      freshness: snap.freshness,
      capability: snap.capability,
      capabilityText: snap.capability
        ? '支持掩码 0x' + snap.capability.supportedMask.toString(16) + ' · 首个支持字段 ' + snap.capability.firstField
        : '未协商（连接演示设备后自动协商）',
      configFields: fields,
      snapshotJson: JSON.stringify({
        hardwareMode: snap.hardwareMode, serviceMode: snap.serviceMode, providerMode: snap.providerMode,
        freshness: snap.freshness, lastStatus: snap.lastStatus,
        pendingActionCount: snap.pendingActionCount, lastError: snap.lastError
      }, null, 2)
    })
  },

  // ---- 演示模式（显式进入，全程显著标注）----
  onSimProfile(event) {
    const index = Number(event.detail.value)
    const item = SIM_PROFILES[index]
    if (item) this.setData({ simProfile: item.key, simProfileIndex: index, simProfileLabel: item.label })
  },
  onEnterSimulator() {
    const hub = hubOf()
    if (!hub) return
    hub.enterSimulator(this.data.simProfile).then(() => {
      return hub.simPing().then(() => hub.queryCapability()).catch(() => null)
    }).then(() => {
      wx.showToast({ title: '演示设备已连接（非实板）', icon: 'none' })
      this.refresh()
    }).catch((error) => {
      wx.showToast({ title: (error && error.message) || '进入演示失败', icon: 'none' })
    })
  },
  onLeaveSimulator() {
    hubOf().leaveSimulator().then(() => {
      wx.showToast({ title: '已退出演示模式（会话与草稿已清空）', icon: 'none' })
    })
  },

  // ---- 服务地址（非秘密配置）----
  onShowServicePair() {
    // Native tab/IDE hot reload can retain an old scroll offset. Clearing the
    // anchor first also makes repeated presses return to the same card.
    this.setData({ settingsScrollTarget: '' }, () => {
      if (!this.disposed) this.setData({ settingsScrollTarget: 'catalog-service' })
    })
  },
  onBaseUrlInput(event) { this.setData({ baseUrlInput: event.detail.value }) },
  onServicePairInput(event) { this.setData({servicePairCode:event.detail.value}) },
  onPairService() {
    const app=appOf(),base=app.globalData.serviceConfig.baseUrl
    const generation=this.servicePairGeneration=(this.servicePairGeneration||0)+1
    this.setData({servicePairBusy:true,serviceAuthLabel:'正在授权…'})
    app.globalData.voiceClient.pair(this.data.servicePairCode).then(result=>{
      if(this.disposed||generation!==this.servicePairGeneration||base!==app.globalData.serviceConfig.baseUrl)return
      app.setServiceAuthorization(result);this.setData({servicePairBusy:false,servicePairCode:'',serviceAuthLabel:'曲库服务已授权（2小时）'})
    }).catch(error=>{if(!this.disposed&&generation===this.servicePairGeneration)this.setData({servicePairBusy:false,serviceAuthLabel:error.message||error.code||'授权失败'})})
  },
  onClearServiceAuth() { this.servicePairGeneration=(this.servicePairGeneration||0)+1;appOf().clearServiceAuthorization();this.setData({servicePairBusy:false,servicePairCode:'',serviceAuthLabel:'曲库服务授权已撤销（本机）'}) },
  onSaveBaseUrl() {
    const app = appOf()
    const url = (this.data.baseUrlInput || '').trim()
    if (url && !/^https?:\/\//.test(url)) {
      wx.showToast({ title: '地址需以 http:// 或 https:// 开头', icon: 'none' })
      return
    }
    this.servicePairGeneration=(this.servicePairGeneration||0)+1
    app.setServiceBaseUrl(url)
    this.setData({ healthInfo: null, healthError: '',servicePairBusy:false,serviceAuthLabel:app.globalData.voiceClient.isAuthorized()?'曲库服务已授权':'曲库服务未授权' })
    wx.showToast({ title: url ? '已保存服务地址' : '已清空服务地址', icon: 'none' })
    this.refresh()
  },
  onCheckHealth() {
    const app = appOf()
    app.globalData.voiceClient.health().then((health) => {
      this.setData({
        healthInfo: {build:health.version,songs:health.songs,ready:health.ready},
        healthError: ''
      })
      app.globalData.sessionHub.setServiceInfo({ providerMode: 'catalog-only' })
    }).catch((error) => {
      this.setData({ healthInfo: null, healthError: (error && error.message) || '服务不可达' })
    })
  },

  // ---- 配置事务（演示设备路径：能力→ACQUIRE→SET→COMMIT→GET）----
  onConfigInput(event) {
    const id = Number(event.currentTarget.dataset.id)
    const value = Number(event.detail.value)
    this.setData({ ['configValues.field' + id]: value })
  },
  onCommitConfig() {
    const hub = hubOf()
    const sets = []
    for (const field of this.data.configFields) {
      const value = this.data.configValues['field' + field.id]
      if (value === undefined || value === '' || Number.isNaN(Number(value))) continue
      const n = Number(value)
      if (n < field.min || n > field.max) {
        this.setData({ configResult: '字段' + field.id + ' 超范围（' + field.min + '–' + field.max + '），未发送' })
        return
      }
      sets.push({ field: field.id, value: n })
    }
    if (!sets.length) { this.setData({ configResult: '没有可提交的修改' }); return }
    const snap=hub.snapshot()
    if(sets.some(s=>s.field===19)&&(!snap.voicesFresh||!snap.voicesFrame||snap.voicesFrame.schema!==2||snap.voicesFrame.anyActive||snap.freshness!=='fresh'||!snap.lastStatus||snap.lastStatus.wet!==0)){
      this.setData({configResult:'效果族切换需先J2Y回中、湿度回读0、松开全部压力键并等待尾音结束'});return
    }
    this.setData({ configBusy: true, configResult: '事务进行中…' })
    hub.simConfigTransaction(sets).then((readback) => {
      this.setData({ configBusy: false, configResult: '已提交且回读一致：字段' + readback.field + ' = ' + readback.value })
    }).catch((error) => {
      this.setData({ configBusy: false, configResult: '未确认：' + (error.message || error.code) })
    })
  },

  onToggleDiagnostics() { this.setData({ diagnosticsOpen: !this.data.diagnosticsOpen }) },
  onToggleAdvanced() { this.setData({ advancedOpen: !this.data.advancedOpen }) },

  copyDiagnostics() {
    wx.setClipboardData({ data: this.data.snapshotJson })
  }
})
