// Shared behavior. The app owns BLE; pages attach views to the same model.
function createInstrumentModel(wx,getApp,setTimeout,clearTimeout,setInterval,clearInterval){
const {createWaveAssembler}=require('../utils/mobile_observer')
const protocol = require('../utils/protocol')
const discovery = require('../utils/discovery')
const { createIssuer } = require('../utils/transaction')
const {expressionGuidance,AXIS_LEGENDS}=require('../utils/joystick_guidance')

function wxCall(name, options = {}) {
  return new Promise((resolve, reject) => wx[name]({...options, success: resolve, fail: reject}))
}
function waveGain(w){const peak=Math.max(1,...w.columns.flatMap(p=>p.map(Math.abs)));return peak<16?8:peak<32?4:peak<64?2:1}

return {
  data: {
    voicesStale:true,effectFamily:null,voiceRows:[],zoneNotes:['—','—','—','—'],groupLabel:'—',voiceFrameCount:0,waveWindowCount:0,
    stateFresh:false,heldActive:[false,false,false,false],assessmentInterrupted:false,practiceTransport:0,modeLabel:'自由',transportLabel:'待机',octaveLabel:'—',glideText:'滑音 · 未提供',vibratoText:'颤音 · 未提供',waveLabel:'等待数字波形',waveFresh:false,waveAt:0,
    auditionActive:false,
    presetNames:['拨弦','吹管','钟声','合成贝斯'], effectNames:['干声','回声','合唱','合唱+回声','空间混响'], presetLabel:'未回读', effectLabel:'未回读',
    activeView: 'perform', connectionDetailsOpen: false, catalogSelection:false, selectedCatalogTitle:'', mappingReady:true, uploadPercent: 0, targetIndex: -1, targetLabel:'—', targetActive:[false,false,false,false], performanceMode:0,
    selectionCommitted: false, currentSongName: '未提交曲目',
    guideZones: [0,1,2,3].map(index => ({index,label:`0${index+1}`})),
    connected: false, scanning: false, busy: false, message: '未连接乐器',
    deviceName: '-', deviceMatch: '-', identityBuild: '-', armedText: '未知', protocolText: '-',
    songNames: protocol.SONGS.map(song => song.name), selectedSong: 0,
    songLoaded: false, guideActive: false, calibrated: false, panicMute: false, testMode: false,
    currentSong: 0, step: 0, targetText: '-', expressionText: '-',
    joystickDirectionsOpen:false,axisLegends:AXIS_LEGENDS,
    hits: 0, wrong: 0, misses: 0, partials: 0, wetPercent: 0,
    commandResult: '-', uploadProgress: '', linkMode: 'DISCONNECTED', lastError: '',
    phoneArmAvailable: false, authenticatedText: '未声明',
    statusFrameCount: 0, lastStatusCommand: '-', lastStatusResult: '-',
    bleEventCount:0,statusPacketCount:0,statusByteCount:0
  },

  onToggleConnectionDetails() { this.setData({ connectionDetailsOpen: !this.data.connectionDetailsOpen }) },
  onToggleJoystickDirections() { this.setData({joystickDirectionsOpen:!this.data.joystickDirectionsOpen}) },

  onLoad() {
    this.controlLease=typeof getApp==='function'?getApp().globalData.controlLease:null
    this.disposed = false
    this.generation = 0
    this.deviceId = ''
    this.issuer = createIssuer({
      send: buffer => this.writeRaw(buffer),
      timeoutMs: 2000
    })
    this.waveAssembler=createWaveAssembler()
    this.statusParser = protocol.createReplyParser({
      onVoices: frame=>this.onVoicesFrame(frame),
      onControl: state=>this.onControlFrame(state),
      onWaveChunk: chunk=>{const w=this.waveAssembler.feed(chunk);if(w&&this.hub)this.hub.publishWave(w)},
      onStatus: status => this.onStatusFrame(status),
      onConfig: reply => {if(this.hub) this.hub.feedRealConfig(reply)},
      onEventFrame: bytes => feedEventFrame(bytes)
    })
    this.onCharacteristic = event => this.handleCharacteristic(event)
    this.onConnectionState = event => this.handleConnectionState(event)
    wx.onBLECharacteristicValueChange(this.onCharacteristic)
    wx.onBLEConnectionStateChange(this.onConnectionState)
    // Shared session hub mirror (guarded: legacy VM test harness has no getApp).
    this.hub = typeof getApp === 'function' ? getApp().globalData.sessionHub : null
    if (this.hub) this.offHub = this.hub.subscribe(snap => this.onHubSnapshot(snap))
  },

  onShow() {
    if(this.waveTimer)clearInterval(this.waveTimer);
    if(typeof setInterval==='function')this.waveTimer=setInterval(()=>{if(this.data.waveFresh&&Date.now()-this.data.waveAt>2500)this.setData({waveFresh:false,waveLabel:'波形失鲜'})},500);
    if(this.voiceFreshTimer)clearInterval(this.voiceFreshTimer);
    if(typeof setInterval==='function')this.voiceFreshTimer=setInterval(()=>{if(this.hub)this.onHubSnapshot(this.hub.snapshot())},400);
    if(this.voiceFreshTimer&&this.voiceFreshTimer.unref)this.voiceFreshTimer.unref();
    if(this.waveTimer&&this.waveTimer.unref)this.waveTimer.unref();
    // 当前练习曲目摘要（曲库/语音页写入），只读展示，不影响设备状态。
    if (this.disposed) return
    let practice = null
    try { practice = wx.getStorageSync('practice:currentSong') || null } catch (e) {}
    this.setData({
      practiceSong: practice ? practice.title + '（' + practice.bpm + ' BPM）' : '',
      practiceSongId: practice ? practice.songId : ''
    })
    if (this.hub && this.data.connected) {
      this.hub.publishReal({ connected: true, deviceId: this.deviceId })
    }
  },

  onHubSnapshot(snap) {
    if (this.disposed) return
    // The hub aggregates modes for other tabs; the instrument page only reads
    // back the aggregate label for display (its own BLE state stays canonical).
    if(snap.observer && snap.observerAt!==this.lastObserverAt){this.lastObserverAt=snap.observerAt;this.applyControl(snap.observer,snap.observerAt);}
    if(snap.wave && snap.wave!==this.lastWaveFrame){this.lastWaveFrame=snap.wave;this.lastWaveId=snap.wave.id;this.setData({waveLabel:'数字波形 · 21.3ms · 显示×'+waveGain(snap.wave),waveAt:snap.wave.at,waveFresh:Date.now()-snap.wave.at<=2500,waveWindowCount:this.data.waveWindowCount+1});this.drawWave(snap.wave);}
    if(snap.voicesFrame && snap.voicesFresh && (snap.voicesFrame!==this.lastVoicesFrame || this.data.voicesStale)){
      this.lastVoicesFrame=snap.voicesFrame
      this.lastVoicesAt=snap.voicesFrameAt
      const presetNames=this.data.presetNames||['拨弦','吹管','钟声','贝斯']
      this.setData({voiceRows:snap.voicesFrame.voices.map(function(v){
        return {index:snap.voicesFrame.voices.indexOf(v),active:v.active,
          note:v.active&&v.note!==null?['C','C♯','D','D♯','E','F','F♯','G','G♯','A','A♯','B'][v.note%12]+(Math.floor(v.note/12)-1):'—',
          region:!v.active||v.region===null?'—':v.region+1,tone:v.active?(presetNames[v.preset]||'—'):'—',
          partials:v.partials,level:v.gain,pcm:v.pcm,levelPercent:Math.min(100,Math.round(Math.abs(v.pcm||0)*100/32768)),envelope:v.envelope}
      }), voicesStale:false,effectFamily:snap.voicesFrame.voices[0].effectFamily,
        effectLabel:snap.voicesFrame.voices[0].effectFamily?'空间混响':(this.data.effectNames[this.lastEffectMode||0]),
        wetPercent:this.lastWet===undefined?0:Math.min(100,Math.round(this.lastWet*100/(snap.voicesFrame.voices[0].effectFamily?64:256)))})
      const zoneNotes=['—','—','—','—'];this.data.voiceRows.forEach(v=>{if(v.active&&Number.isInteger(v.region))zoneNotes[v.region-1]=v.note});this.setData({zoneNotes})
    } else if(!snap.voicesFresh && this.data.voiceRows){this.setData({voicesStale:true,effectLabel:'未回读',zoneNotes:['—','—','—','—']})}
    this.setData({ hubHardwareMode: snap.hardwareMode, hubPending: snap.pendingActionCount })
    const score=snap.activeScore
    if(score&&score.commitId!==this.lastScoreCommitId){
      this.lastScoreCommitId=score.commitId
      this.setData({catalogSelection:score.source==='catalog',selectedCatalogTitle:score.title})
      if(snap.hardwareMode==='real'&&this.data.connected&&snap.lastStatus)this.applyStatus(snap.lastStatus)
    }else if(!score&&this.data.catalogSelection)this.setData({catalogSelection:false,selectedCatalogTitle:''})
  },

  hubPublish(patch) {
    if (this.hub) this.hub.publishReal(patch)
  },

  onHide(){if(this.voiceFreshTimer)clearInterval(this.voiceFreshTimer);if(this.waveTimer)clearInterval(this.waveTimer)},

  onUnload() {
    if(this.voiceFreshTimer)clearInterval(this.voiceFreshTimer);
    if(this.waveTimer)clearInterval(this.waveTimer);
    this.disposed = true
    this.generation += 1
    if(this.cancelScan)this.cancelScan()
    // Symmetric teardown: an old page instance must not keep receiving frames.
    wx.offBLECharacteristicValueChange(this.onCharacteristic)
    wx.offBLEConnectionStateChange(this.onConnectionState)
    if (this.issuer) this.issuer.reset()
    if (this.deviceId) wx.closeBLEConnection({deviceId: this.deviceId})
    wx.closeBluetoothAdapter({})
    if(this.controlLease)this.controlLease.close()
    if (this.offHub) this.offHub()
    this.hubPublish({connected:false})
  },

  restoreValueReceiver() {
    if(this.disposed || !this.onCharacteristic)return
    // Adapter initialization and temporary INFO reads must not leave the page
    // without its long-lived status receiver. Reinstall only our callback.
    wx.offBLECharacteristicValueChange(this.onCharacteristic)
    wx.onBLECharacteristicValueChange(this.onCharacteristic)
  },

  // A notification is only accepted when it comes from the device and the
  // service/characteristic this session subscribed to.
  handleCharacteristic(event) {
    if (!this.data.connected) return
    if (String(event.deviceId).toLowerCase() !== String(this.deviceId).toLowerCase()) return
    this.setData({bleEventCount:this.data.bleEventCount+1})
    if (String(event.serviceId).toLowerCase() !== protocol.SERVICE_UUID) return
    if (String(event.characteristicId).toLowerCase() === discovery.INFO_UUID) {
      const bytes=new Uint8Array(event.value);let notice=''
      for(let i=0;i<bytes.length;i++)notice+=String.fromCharCode(bytes[i])
      if(/AUTH \/ LINK EXPIRED|UART TX DISARMED|CONTROL EXPIRED/.test(notice)) {
        if(this.controlLease)this.controlLease.authorize(this.generation,false);
        this.setData({armedText:'未授权',message:'控制授权已失效，请重新授权'})
      }
      else if(/CMD REJECTED|PAIR FIRST|PAIR \/ FPGA REQUIRED/.test(notice))
        this.setData({lastError:`S3 拒绝手机命令：${notice}`})
      return
    }
    if (String(event.characteristicId).toLowerCase() !== protocol.STATUS_UUID) return
    this.setData({statusPacketCount:this.data.statusPacketCount+1,
      statusByteCount:this.data.statusByteCount+new Uint8Array(event.value).length})
    this.statusParser(event.value)
  },

  async subscribeStatus() {
    this.restoreValueReceiver()
    await wxCall('notifyBLECharacteristicValueChange', {
      state:true,deviceId:this.deviceId,serviceId:protocol.SERVICE_UUID,
      characteristicId:protocol.STATUS_UUID
    })
  },

  handleConnectionState(event) {
    if (String(event.deviceId).toLowerCase() !== String(this.deviceId).toLowerCase()) return
    if (event.connected) return
    this.generation += 1
    if(this.controlLease)this.controlLease.close()
    if (this.issuer) this.issuer.reset()
    this.statusParser = protocol.createReplyParser({
      onVoices: frame=>this.onVoicesFrame(frame),
      onControl: state=>this.onControlFrame(state),
      onWaveChunk: chunk=>{const w=this.waveAssembler.feed(chunk);if(w&&this.hub)this.hub.publishWave(w)},
      onStatus: status => this.onStatusFrame(status),
      onConfig: reply => {if(this.hub) this.hub.feedRealConfig(reply)},
      onEventFrame: bytes => feedEventFrame(bytes)
    })
    this.deviceId = ''
    this.waveAssembler.reset();this.lastWaveFrame=this.lastVoicesFrame=this.latestControl=null;this.controlAt=0;this.lastObserverAt=undefined
    this.hubPublish({connected:false})
    this.setData({
      connected: false, busy: false, songLoaded: false, guideActive: false,
      voiceRows:[],voicesStale:true,zoneNotes:['—','—','—','—'],waveFresh:false,waveAt:0,waveLabel:'等待数字波形',voiceFrameCount:0,waveWindowCount:0,
      statusFrameCount: 0, lastStatusCommand: '-', lastStatusResult: '-',
      bleEventCount:0,statusPacketCount:0,statusByteCount:0,
      phoneArmAvailable: false, armedText: '未授权', authenticatedText: '未连接',
      linkMode: 'DISCONNECTED', lastError: '连接已断开；未自动重放曲谱提交',
      message: '连接已断开，请重新连接并重新读取 FPGA 状态'
    })
  },

  switchView(event) {
    const view = event.currentTarget.dataset.view
    if (['perform','songs','device'].includes(view) && view !== this.data.activeView)
      this.setData({activeView: view})
  },

  chooseSong(event) {
    const value = Number(event.currentTarget.dataset.index)
    if (Number.isInteger(value) && value >= 0 && value < protocol.SONGS.length)
      this.onSongChange({detail: {value}})
  },

  showMessage() {
    wx.showModal({title: this.data.lastError ? '操作未确认' : '当前状态',
      content: String(this.data.lastError || this.data.message || '暂无消息'),showCancel:false})
  },

  disconnect() {
    const deviceId = this.deviceId
    if (!deviceId) return
    this.handleConnectionState({deviceId,connected:false})
    wx.closeBLEConnection({deviceId})
    this.setData({message:'连接已断开；重新连接后需要重新核对授权和曲谱。',lastError:''})
  },

  primaryAction() {
    if (this.data.busy || this.data.guideActive) return
    if (!this.data.connected || !this.data.calibrated || this.data.panicMute || this.data.testMode) {
      this.setData({activeView:'device'})
    } else if (!this.data.songLoaded || !this.data.selectionCommitted) {
      this.setData({activeView:'songs'})
    } else {
      return this.startGuide()
    }
  },

  onSongChange(event) { this.setData({selectedSong: Number(event.detail.value), catalogSelection:false, selectionCommitted:false, uploadPercent:0}) },

  async connect() {
    if (this.disposed || this.data.scanning || this.data.connected) return
    const generation=++this.generation
    const current=()=>!this.disposed && this.generation===generation
    const requireCurrent=()=>{if(!current())throw new Error('连接操作已取消')}
    this.setData({scanning: true, message: '正在按服务 UUID 扫描…', lastError: '',
      statusFrameCount:0,lastStatusCommand:'-',lastStatusResult:'-',
      bleEventCount:0,statusPacketCount:0,statusByteCount:0})
    let foundListener = null
    let pendingDeviceId = ''
    try {
      await wxCall('openBluetoothAdapter')
      requireCurrent()
      this.restoreValueReceiver()
      const device = await new Promise((resolve, reject) => {
        let timer
        this.cancelScan=()=>{
          clearTimeout(timer)
          if(foundListener)wx.offBluetoothDeviceFound(foundListener)
          reject(new Error('页面已关闭'))
        }
        foundListener = result => {
          const list = (result && result.devices) || []
          for (let i = 0; i < list.length; i += 1) {
            const verdict = discovery.matchAdvertising(list[i])
            if (verdict.matched) {
              clearTimeout(timer)
              wx.offBluetoothDeviceFound(foundListener)
              resolve({device: list[i], verdict})
              return
            }
          }
        }
        wx.onBluetoothDeviceFound(foundListener)
        // services: [SERVICE_UUID] is honoured on Android; iOS ignores the filter
        // and relies on matchAdvertising above.
        const scanOptions = {allowDuplicatesKey: false}
        try {
          if (wx.getSystemInfoSync().platform === 'android') scanOptions.services = [discovery.SERVICE_UUID]
        } catch (_) {}
        wxCall('startBluetoothDevicesDiscovery', scanOptions).catch(reject)
        timer = setTimeout(() => {
          wx.offBluetoothDeviceFound(foundListener)
          reject(new Error('未找到携带 XianChu 服务 UUID 的设备'))
        }, 12000)
      })
      requireCurrent()
      this.cancelScan=null
      await wxCall('stopBluetoothDevicesDiscovery').catch(() => {})
      requireCurrent()
      this.setData({deviceName: device.device.name || device.device.localName || '未命名',
        deviceMatch: device.verdict.reason})
      await wxCall('createBLEConnection', {deviceId: device.device.deviceId, timeout: 10000})
      pendingDeviceId=device.device.deviceId
      requireCurrent()
      this.deviceId = device.device.deviceId
      try { await wxCall('setBLEMTU', {deviceId: this.deviceId, mtu: 64}) } catch (_) {}
      requireCurrent()
      const services = await wxCall('getBLEDeviceServices', {deviceId: this.deviceId})
      requireCurrent()
      if (!discovery.hasService(services.services)) {
        throw new Error('设备缺少 XianChu 服务，可能是同名但不同固件的设备')
      }
      await wxCall('getBLEDeviceCharacteristics', {deviceId: this.deviceId, serviceId: protocol.SERVICE_UUID})
      requireCurrent()
      await this.subscribeStatus()
      await wxCall('notifyBLECharacteristicValueChange', {
        state:true,deviceId:this.deviceId,serviceId:protocol.SERVICE_UUID,
        characteristicId:discovery.INFO_UUID
      }).catch(()=>{})
      requireCurrent()
      this.setData({connected: true, linkMode: 'CONNECTED', message: '已连接，正在核对链路（PING）'})
      this.hubPublish({connected:true, deviceId:this.deviceId, name:this.data.deviceName})
      const identity=await this.readIdentity()
      requireCurrent()
      if(identity && identity.phoneArm && identity.armed!==true)
        this.setData({message:'已连接，请完成蓝牙配对授权。'})
      else await this.ping()
    } catch (error) {
      if(pendingDeviceId)wx.closeBLEConnection({deviceId:pendingDeviceId})
      if(current()) {
        this.deviceId=''
        this.setData({connected:false,lastError: `连接失败：${error.errMsg || error.message || error}`,
          message: '未连接', linkMode: 'DISCONNECTED'})
      }
      if (foundListener) wx.offBluetoothDeviceFound(foundListener)
      await wxCall('stopBluetoothDevicesDiscovery').catch(() => {})
    } finally {
      if(current()){this.cancelScan=null;this.setData({scanning: false})}
    }
  },

  async readIdentity() {
    const deviceId=this.deviceId, generation=this.generation
    let handler=null,timer=null
    try {
      // Install before readBLECharacteristicValue: some platforms emit the
      // value event synchronously before their API success callback.
      const pending=new Promise((resolve,reject)=>{
        handler=event=>{
          if(this.generation!==generation){reject(new Error('过期连接'));return}
          if(String(event.deviceId).toLowerCase()!==String(deviceId).toLowerCase() ||
             String(event.serviceId).toLowerCase()!==protocol.SERVICE_UUID.toLowerCase() ||
             String(event.characteristicId).toLowerCase()!==discovery.INFO_UUID) return
          const bytes=new Uint8Array(event.value);let text=''
          for(let i=0;i<bytes.length;i++)text+=String.fromCharCode(bytes[i])
          // R3 local notices and the read response share the INFO characteristic.
          // A concurrent "CMD FORWARDED" notice is not an identity response.
          if((this.data.phoneArmAvailable || /LINK-R3/i.test(this.data.deviceName)) &&
             !discovery.parseIdentity(text).build)return
          resolve(text)
        }
        wx.onBLECharacteristicValueChange(handler)
        timer=setTimeout(()=>reject(new Error('身份读取超时')),1500)
      })
      const [,info]=await Promise.all([wxCall('readBLECharacteristicValue',{
        deviceId,serviceId:protocol.SERVICE_UUID,characteristicId:discovery.INFO_UUID}),pending])
      if(this.generation!==generation || this.deviceId!==deviceId)return
      const identity=discovery.parseIdentity(info)
      this.setData({identityBuild:identity.build||'未声明',
        armedText:identity.armed===null?'授权状态未知':identity.armed?'已授权':'未授权',
        protocolText:identity.protocolVersion===null?'legacy 22 字节状态':`v${identity.protocolVersion}`,
        phoneArmAvailable:identity.phoneArm,
        authenticatedText:identity.authenticated===null?'未声明':identity.authenticated?'已认证加密':'待系统配对'})
      if(this.controlLease)this.controlLease.authorize(generation,identity.armed===true&&identity.authenticated===true)
      return identity
    } catch(error) {
      if(this.generation===generation && this.deviceId===deviceId)
        this.setData({identityBuild:'读取失败',armedText:'未知（需 USB 控制台 ARM）',
          lastError:`身份读取：${error.message||error.errMsg||error}`})
    } finally {
      if(timer!==null)clearTimeout(timer)
      if(handler)wx.offBLECharacteristicValueChange(handler)
      this.restoreValueReceiver()
    }
  },

  async setAuthorization(enable) {
    if(!this.data.connected || this.data.busy)return false
    if(!this.data.phoneArmAvailable){this.setData({message:'该固件需先通过电脑串口授权。'});return false}
    const generation=this.generation,deviceId=this.deviceId
    this.setData({busy:true,lastError:'',message:enable?'请完成系统蓝牙配对，输入OLED上的六位码…':'正在撤销发送授权…'})
    try {
      const text=enable?'ARM':'DISARM', bytes=new Uint8Array(text.length)
      for(let i=0;i<text.length;i++)bytes[i]=text.charCodeAt(i)
      await wxCall('writeBLECharacteristicValue',{deviceId,serviceId:protocol.SERVICE_UUID,
        characteristicId:discovery.INFO_UUID,value:bytes.buffer})
      if(generation!==this.generation || deviceId!==this.deviceId)return false
      let identity=null
      for(let i=0;i<4;i++) {
        await new Promise(resolve=>setTimeout(resolve,150))
        if(generation!==this.generation || deviceId!==this.deviceId)return false
        identity=await this.readIdentity()
        if(identity && identity.armed===enable)break
      }
      if(!identity || identity.armed!==enable)throw new Error('固件尚未读回确认授权；GATT写成功不等于ARM成功')
      if(enable) {
        // Re-establish the status subscription after authentication. The page
        // still requires an actual FPGA answer before declaring PING success.
        await this.subscribeStatus()
        if(generation!==this.generation || deviceId!==this.deviceId)return false
      }
      this.setData({message:enable?'S3已读回确认授权；请点击PING核对FPGA，不会自动播放。':'S3已读回确认撤销授权。'})
      return true
    } catch(error) {
      if(generation===this.generation && deviceId===this.deviceId)
        this.setData({lastError:error.errMsg||error.message||String(error),message:'授权未确认；检查系统配对及FPGA新鲜状态。'})
      return false
    } finally {
      if(generation===this.generation && deviceId===this.deviceId)this.setData({busy:false})
    }
  },
  armPhone(){return this.setAuthorization(true)},
  disarmPhone(){return this.setAuthorization(false)},

  async requireCommandAuthorization(generation) {
    if(!this.data.phoneArmAvailable && !/LINK-R3/i.test(this.data.deviceName))return
    const identity=await this.readIdentity()
    if(generation!==this.generation)throw new Error('连接已变化，未发送命令')
    if(!identity || !identity.phoneArm || !identity.authenticated || !identity.armed) {
      this.setData({armedText:identity && identity.armed?'已授权（认证未确认）':'未授权'})
      throw new Error('手机授权未确认或已过期，请重新配对授权。')
    }
  },

  // One command, one matching FPGA answer.
  async ping() {
    if (!this.data.connected || this.data.busy) return false
    const generation=this.generation
    this.setData({busy:true, lastError:'', message:'正在等待 FPGA PING 应答…'})
    try {
      await this.requireCommandAuthorization(generation)
      if(generation!==this.generation || !this.data.connected)return false
      const outcome = await this.issuer.submit(seq => protocol.pingFrame(seq), {type: 0x14})
      if(generation!==this.generation)return false
      this.setData({linkMode: 'REAL',
        message: `链路正常：FPGA 已应答 PING（序号 ${outcome.sequence}）`, lastError: ''})
      return true
    } catch (error) {
      if(generation!==this.generation)return false
      const text = error.code === 'TIMEOUT_UNKNOWN'
        ? (this.data.phoneArmAvailable
          ? 'PING 无应答：检查是否已配对授权、FPGA状态是否新鲜及跨板串口。'
          : 'PING 无应答：此固件需先在电脑串口发送 ARM。')
        : (error.code === 'FPGA_RESULT'
          ? `PING 被 FPGA 拒绝：${protocol.describeResult(error.result)}`
          : `PING 发送未确认：${error.errMsg || error.message || error.code || String(error)}`)
      this.setData({linkMode: 'UNAUTHORIZED', message: text, lastError: error.message || text})
      return false
    } finally {
      if(generation===this.generation)this.setData({busy:false})
    }
  },

  async writeRaw(buffer) {
    await wxCall('writeBLECharacteristicValue', {
      deviceId: this.deviceId, serviceId: protocol.SERVICE_UUID,
      characteristicId: protocol.COMMAND_UUID, value: buffer
    })
  },

  async downloadSong() {
    if (!this.data.connected || this.data.busy) return
    const generation=this.generation
    const song = protocol.SONGS[this.data.selectedSong]
    this.setData({busy: true, uploadProgress: '准备', uploadPercent:0, lastError: '', message: '正在事务式下载曲谱…'})
    try {
      await this.requireCommandAuthorization(generation)
      if(generation!==this.generation || !this.data.connected)return
      await this.issuer.submit(seq => protocol.beginFrame(song, seq), {type: 0x10})
      for (let index = 0; index < song.steps.length; index += 1) {
        if(generation!==this.generation)return
        this.setData({uploadProgress: `${index + 1}/${song.steps.length}`,
          uploadPercent: Math.floor((index+1)*90/song.steps.length)})
        await this.issuer.submit(seq => protocol.stepFrame(song.steps[index], index, seq), {type: 0x11})
      }
      // The last STEP can settle just before disconnect/reset. Never let its
      // continuation submit a COMMIT through the replacement session's issuer.
      if(generation!==this.generation || !this.data.connected)return
      this.setData({uploadProgress: '提交', uploadPercent:95})
      const outcome = await this.issuer.submit(seq => protocol.commitFrame(song.id, seq), {
        type: 0x12,
        validate: status => ((status.song === song.id && (status.flags & 1))
          ? true : `FPGA 读回曲目 ${status.song}，未确认曲目 ${song.id}`)
      })
      if(generation!==this.generation)return
      this.setData({
        songLoaded: true, selectionCommitted:true, uploadProgress: '', uploadPercent:100,
        message: `曲目 ${song.id} 已在 FPGA 提交并读回（序号 ${outcome.sequence}）`
      })
      this.applyStatus(outcome.status)
    } catch (error) {
      if(generation!==this.generation)return
      const detail = error.code === 'TIMEOUT_UNKNOWN'
        ? '等待 FPGA 应答超时，结果未知；请重新读取状态后再决定是否重发'
        : (error.code === 'FPGA_RESULT' ? protocol.describeResult(error.result) : (error.message || String(error)))
      this.setData({uploadProgress: '', uploadPercent:0, message: `下载未确认：${detail}`, lastError: detail})
    } finally {
      if(generation===this.generation)this.setData({busy: false})
    }
  },

  async setGuide(start) {
    if (!this.data.connected || this.data.busy) return
    if (start && !this.data.songLoaded) {
      this.setData({message: 'FPGA 尚未确认曲谱，不能启动引导'})
      return
    }
    const generation=this.generation
    this.setData({busy: true, lastError: ''})
    try {
      await this.requireCommandAuthorization(generation)
      if(generation!==this.generation || !this.data.connected)return
      await this.issuer.submit(seq => protocol.guideControl(start, seq), {
        type: 0x13,
        validate: status => ((!!(status.flags & 2) === !!start) && (start!==2 || status.mode===2)
          ? true : `FPGA 引导状态未切换（flags=0x${status.flags.toString(16)}）`)
      })
      if(generation!==this.generation)return
      this.setData({message: start ? 'FPGA 已确认启动 LED 引导' : 'FPGA 已确认停止 LED 引导'})
    } catch (error) {
      if(generation!==this.generation)return
      const detail = error.code === 'TIMEOUT_UNKNOWN' ? '超时，引导状态未知'
        : (error.code === 'FPGA_RESULT' ? protocol.describeResult(error.result) : (error.message || String(error)))
      this.setData({message: `引导控制未确认：${detail}`, lastError: detail})
    } finally {
      if(generation===this.generation)this.setData({busy: false})
    }
  },

  onVoicesFrame(frame){this.setData({voiceFrameCount:this.data.voiceFrameCount+1});if(this.hub)this.hub.publishVoices(frame)},
  onControlFrame(state){this.latestControl=state;this.controlAt=Date.now();if(this.hub)this.hub.publishObserver(state);this.applyControl(state)},
  applyControl(o,observedAt){
    if(observedAt!==undefined){this.latestControl=o;this.controlAt=observedAt}
    const running=(o.mode===1||o.mode===2)&&o.transport===2&&o.length>0
    const cue=expressionGuidance({flags:(running?2:0)|(o.health&16)|(this.data.panicMute?8:0)|(this.data.testMode?4:0),mode:o.mode,extended:true,targetMask:o.target,expression:o.expression,mappingReady:this.data.mappingReady})
    this.setData({heldActive:[0,1,2,3].map(i=>!!(o.held&(1<<i))),performanceMode:o.mode,practiceTransport:o.transport,modeLabel:['自由','引导','挑战','示范'][o.mode],assessmentInterrupted:!!o.interrupted,
      guideActive:running,expressionText:cue.text,targetLabel:o.target?[0,1,2,3].filter(i=>o.target&(1<<i)).map(i=>i+1).join('+'):'休止',targetActive:[0,1,2,3].map(i=>!!(o.target&(1<<i))),step:o.step+1,
      groupLabel:o.mode===3?'谱定':(o.layout&1)?'B组':'A组',presetLabel:this.data.presetNames[o.preset&3],
      transportLabel:['待机','待开始','进行中','已暂停','已完成','先松开按键','倒数开始'][o.transport]+(o.interrupted?' · 中断场次':''),
      octaveLabel:o.mode===3?'谱定':(o.layout&2)?'高八度':'原八度',
      glideText:'J1 X'+o.glide.rod+' · '+o.glide.label,vibratoText:'J1 Y'+o.vibrato.rod+' · '+o.vibrato.label,
      glideActive:o.glide.active,vibratoActive:o.vibrato.active,
      j2Text:'J2 X'+require('../utils/mobile_observer').rod('X',o.j2x)+' '+o.partials+'/32  Y'+require('../utils/mobile_observer').rod('Y',o.j2y)+' '+Math.min(100,Math.round(o.wet*100/(this.data.effectFamily?64:256)))+'%'});
  },
  drawWave(w){
    if(typeof wx.createCanvasContext!=='function')return;
    const c=wx.createCanvasContext('pcmWave',this),width=300,height=70;
    const gain=waveGain(w);
    c.setFillStyle('#101b20');c.fillRect(0,0,width,height);c.setStrokeStyle('#30444b');c.setLineWidth(1);c.beginPath();c.moveTo(0,35);c.lineTo(width,35);c.stroke();
    c.setStrokeStyle('#9bdbc5');c.beginPath();
    w.columns.forEach((p,i)=>{const x=i*width/128;c.moveTo(x,35-p[0]*.24*gain);c.lineTo(x,35-p[1]*.24*gain)});c.stroke();c.draw();
    this.setData({waveLabel:'数字波形 · 21.3ms · 显示×'+gain,waveAt:Date.now(),waveFresh:true});
  },
  async chooseMode(e){return this.practiceAction(Number(e.currentTarget.dataset.mode),0)},
  async practiceAction(mode,action){if(this.data.busy||!this.hub)return;this.setData({busy:true,lastError:''});
    try{const o=await this.hub.practiceControl(mode,action);this.applyControl(o);this.setData({message:'设备状态已确认'})}
    catch(e){this.setData({lastError:e.message||'操作未确认'})}finally{this.setData({busy:false})}
  },
  runPractice(){const m=this.data.performanceMode;if(m===0)return this.setData({message:'自由模式直接按压力键演奏'});
    this.practiceAction(m,this.data.practiceTransport===3?3:this.data.practiceTransport===2?2:1)},
  stopPractice(){return this.practiceAction(0,4)},
  async selectPreset(event) {
    if(!this.data.connected||this.data.busy)return
    const value=Number(event.detail.value),generation=this.generation
    this.setData({busy:true,lastError:''})
    try { await this.hub.simConfigTransaction([{field:20,value}]);
      if(generation===this.generation)this.setData({message:'下一次上音音色已提交并回读；已按住的音保持原音色'})
    } catch(e){if(generation===this.generation)this.setData({lastError:e.message||'音色未确认'})}
    finally{if(generation===this.generation)this.setData({busy:false})}
  },
  async selectEffect(event) {
    if(!this.data.connected||this.data.busy)return
    const generation=this.generation;this.setData({busy:true,lastError:''})
    try {
      const value=Number(event.detail.value), snap=this.hub.snapshot()
      if(!Number.isInteger(value)||value<0||value>4)throw Error('无效效果选项')
      if(!snap.voicesFresh||!snap.voicesFrame||snap.voicesFrame.schema!==2)throw Error('请等待配套固件的四声部状态')
      if(snap.voicesFrame.anyActive||this.data.auditionActive)throw Error('请先停止示范并松开压力键，待尾音结束再切换效果族')
      if(snap.freshness!=='fresh'||!snap.lastStatus||snap.lastStatus.wet!==0)throw Error('请先将J2Y回中，待湿度回读为0且尾音结束后切换')
      await this.hub.simConfigTransaction([{field:19,value:value===4?1:0}])
      if(value!==4)await this.hub.simFxControl(value)
      if(generation===this.generation)this.setData({message:'效果已提交；以设备回读为准'})
    } catch(e){if(generation===this.generation)this.setData({lastError:e.message||'效果未确认'})}
    finally{if(generation===this.generation)this.setData({busy:false})}
  },
  startGuide() { this.setGuide(1) },
  startChallenge() { this.setGuide(2) },
  stopGuide() { this.setGuide(false) },

  onStatusFrame(status) {
    if(this.issuer && typeof this.issuer.observeSequence==='function')this.issuer.observeSequence(status.commandSequence)
    if(this.hub && this.realDriverGeneration!==this.generation) {
      this.realDriverGeneration=this.generation
      const generation=this.generation
      if(this.controlLease)this.controlLease.bind({generation,keepAlive:async()=>{
        if(generation!==this.generation||!this.data.connected)throw Error('连接已变化');
        await wxCall('writeBLECharacteristicValue',{deviceId:this.deviceId,serviceId:protocol.SERVICE_UUID,
          characteristicId:discovery.INFO_UUID,value:new Uint8Array([75,69,69,80]).buffer});
      },reconcile:async()=>{const i=await this.readIdentity();return !!(i&&i.armed&&i.authenticated)},onExpired:()=>this.setData({armedText:'未授权',message:'控制会话已失效'})});
      this.hub.bindReal({issuer:{
        submit:async(build,options)=>{
          await this.requireCommandAuthorization(generation)
          if(generation!==this.generation || !this.data.connected) throw {code:'RESET',message:'连接已变化'}
          return this.issuer.submit(build,options)
        },
        onStatus:reply=>this.issuer.onStatus(reply)
      }})
    }
    this.hubPublish({connected:true,lastStatus:status,lastStatusAt:Date.now()})
    this.setData({statusFrameCount:this.data.statusFrameCount+1,
      lastStatusCommand:status.commandSequence,
      lastStatusResult:protocol.describeResult(status.commandResult)})
    const settled = this.issuer.onStatus(status)
    this.applyStatus(status)
  },

  applyStatus(status) {
    this.lastEffectMode=status.effectMode;this.lastWet=status.wet
    this.setData({auditionActive:(status.flags&96)===96})
    const guidance=expressionGuidance(status)
    const flags = protocol.decodeFlags(status.flags)
    const knownSong = protocol.SONGS.find(song => song.id === status.song)
    const active=this.hub&&this.hub.snapshot().activeScore
    const catalogCommitted=!!(this.data.catalogSelection&&active&&active.wireId===status.song)
    this.setData({
      selectionCommitted: flags.scoreLoaded && (catalogCommitted || protocol.SONGS[this.data.selectedSong]?.id === status.song),
      currentSongName: active&&active.wireId===status.song?active.title:knownSong ? knownSong.name : `设备曲目 ${status.song}`,
      songLoaded: flags.scoreLoaded, guideActive: flags.guideActive,
      calibrated: flags.calibrated, panicMute: flags.panicMute, testMode: flags.testMode,
      currentSong: status.song, step: status.step + 1,
      targetIndex: status.target,
      targetLabel:status.targetMask ? [0,1,2,3].filter(i=>status.targetMask&(1<<i)).map(i=>i+1).join('+') : (status.mode?'休止':String(status.target+1)),
      targetActive:[0,1,2,3].map(i=>status.targetMask?!!(status.targetMask&(1<<i)):(!status.mode && i===status.target)),
      performanceMode:status.mode || (flags.guideActive?1:0),
      mappingReady:status.mappingReady!==false,
      presetLabel:status.preset===null?'旧固件未回读':this.data.presetNames[status.preset],
      effectLabel:this.data.voicesStale?'未回读':this.data.effectFamily?'空间混响':status.effectMode===null?'未回读':this.data.effectNames[status.effectMode],
      targetText: `演奏区 ${status.target + 1}`,
      expressionText: guidance.text,
      hits: status.hits, wrong: status.wrong, misses: status.misses,
      partials: status.partials, wetPercent: Math.min(100,Math.round(status.wet * 100 / (this.data.effectFamily?64:256))),
      commandResult: protocol.describeResult(status.commandResult),
      linkMode: 'REAL'
    })
    if(this.latestControl && Date.now()-this.controlAt<=700)this.applyControl(this.latestControl)
  }
};

}
// T2 performance-event telemetry sink (0x85 frames): the recording UI registers
// itself here while armed; frames are forwarded verbatim (CRC already checked by
// the parser). No sink registered = telemetry observed and dropped, exactly like
// the FPGA's own bounded queue policy.
let eventFrameSink=null
function setEventFrameSink(fn){eventFrameSink=fn||null}
function feedEventFrame(bytes){if(eventFrameSink)eventFrameSink(bytes)}
module.exports={createInstrumentModel,setEventFrameSink};
