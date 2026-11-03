const {createInstrumentController}=require('./services/instrument_controller')
const {createControlLease}=require('./services/control_lease')
// App shell: ONE device session hub + service clients, created once and shared
// by every tab. Pages never create their own protocol state; switching tabs
// must not drop listeners or re-register BLE callbacks.
const { createSessionHub } = require('./services/device_session')
const { createCatalogClient } = require('./utils/catalog_client')
const { createVoiceClient } = require('./utils/catalog_service_client')
const {createAuditionSession}=require('./services/audition_session')

App({
  globalData: {
    sessionHub: null,
    catalogClient: null,
    voiceClient: null,
    serviceConfig: { baseUrl: '' }
  },

  onLoadServiceConfig() {
    // Non-secret client-side configuration only: the service base URL. No
    // provider keys ever live in the miniprogram, storage, QR codes or logs.
    let baseUrl = ''
    try { baseUrl = wx.getStorageSync('service:baseUrl') || '' } catch (e) {}
    const serviceMode = baseUrl ? 'configured-service' : 'unconfigured'
    this.globalData.serviceConfig = { baseUrl }
    this.globalData.catalogClient.setBaseUrl(baseUrl)
    this.globalData.voiceClient.setBaseUrl(baseUrl)
    let auth = null
    try { auth = wx.getStorageSync('service:authorization') || null } catch(e) {}
    if(auth && auth.baseUrl===baseUrl && auth.expires>Date.now())this.globalData.voiceClient.setDeviceToken(auth.token,auth.expires)
    this.globalData.sessionHub.setServiceInfo({ serviceMode, baseUrl })
    return { baseUrl, serviceMode }
  },

  setServiceBaseUrl(url) {
    const clean = String(url || '').replace(/\/+$/, '')
    const changed=clean!==this.globalData.serviceConfig.baseUrl
    if(changed){this.globalData.auditionDraft=null;if(this.globalData.auditionSession)this.globalData.auditionSession.pause().catch(()=>{})}
    if(changed&&this.globalData.performanceSession)this.globalData.performanceSession.serviceChanged()
    if(changed&&this.globalData.performanceClient)this.globalData.performanceClient.cancelAll()
    try {
      if (clean) wx.setStorageSync('service:baseUrl', clean)
      else wx.removeStorageSync('service:baseUrl')
    } catch (e) {}
    this.globalData.serviceConfig = { baseUrl: clean }
    this.globalData.catalogClient.setBaseUrl(clean)
    this.globalData.voiceClient.setBaseUrl(clean)
    if(changed)try{wx.removeStorageSync('service:authorization')}catch(e){}
    this.globalData.sessionHub.setServiceInfo({
      serviceMode: clean ? 'configured-service' : 'unconfigured',
      baseUrl: clean
    })
  },

  setServiceAuthorization(result) {
    this.globalData.voiceClient.setDeviceToken(result.access_token,result.expires_at)
    try { wx.setStorageSync('service:authorization',{baseUrl:this.globalData.serviceConfig.baseUrl,token:result.access_token,expires:result.expires_at}) } catch(e) {}
  },
  clearServiceAuthorization() {
    this.globalData.voiceClient.setDeviceToken('',0)
    try { wx.removeStorageSync('service:authorization') } catch(e) {}
  },

  getInstrumentController() {
    if(!this.globalData.instrumentController)this.globalData.instrumentController=createInstrumentController({wx,app:this})
    return this.globalData.instrumentController
  },
  getAuditionSession() {
    if(!this.globalData.auditionSession)this.globalData.auditionSession=createAuditionSession({hub:this.globalData.sessionHub})
    return this.globalData.auditionSession
  },
  onHide() {
    if(this.globalData.controlLease)this.globalData.controlLease.suspend()
  },

  renewServiceSession() {
    const v=this.globalData.voiceClient;
    if(this.renewing||!v||!v.renew||!v.isAuthorized()||v.tokenExpiresAt()-Date.now()>300000)return;
    const base=this.globalData.serviceConfig.baseUrl;this.renewing=true;
    return v.renew().then(r=>{if(base===this.globalData.serviceConfig.baseUrl)this.setServiceAuthorization(r)})
      .catch(e=>{if(e.code==='SERVICE_SESSION_REQUIRED'&&base===this.globalData.serviceConfig.baseUrl)this.clearServiceAuthorization()})
      .finally(()=>{this.renewing=false});
  },
  onShow() {if(this.globalData.controlLease)this.globalData.controlLease.resume();this.renewServiceSession()},

  onLaunch() {
    this.globalData.controlLease=createControlLease()
    this.globalData.sessionHub = createSessionHub({ wx })
    this.globalData.catalogClient = createCatalogClient({ wx })
    this.globalData.voiceClient = createVoiceClient({ wx })
    this.onLoadServiceConfig()
    if(typeof setInterval==='function')this.serviceRenewTimer=setInterval(()=>this.renewServiceSession(),60000)
    if(this.serviceRenewTimer&&this.serviceRenewTimer.unref)this.serviceRenewTimer.unref()
    // Provider mode is a SERVER property; we learn it from the gateway health
    // check (settings page) and mirror it here. Default: unknown/unconfigured.
  }
})
