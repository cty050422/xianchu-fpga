// Catalog connectivity only. No microphone, chat, speech or recorder.
function createVoiceClient(options={}) {
  const api=options.wx;let base=options.baseUrl||'',token='',expires=0
  function request(route,method='GET',data) {return new Promise((resolve,reject)=>{
    if(!base)return reject({code:'SERVICE_UNCONFIGURED',message:'请先保存曲库地址'})
    api.request({url:base+route,method,data,timeout:5000,header:{'x-device-token':Date.now()<expires?token:''},
      success:r=>r.statusCode===200?resolve(r.data):reject({code:r.data&&r.data.error||'HTTP_'+r.statusCode,message:'曲库服务返回 '+r.statusCode}),
      fail:e=>reject({code:'NETWORK_ERROR',message:e.errMsg||'曲库服务不可达'})})
  })}
  return {setBaseUrl(v){base=String(v||'').replace(/\/+$/,'');token='';expires=0},
    health:()=>request('/catalog/v1/healthz'),
    pair:code=>request('/assistant/v1/pair','POST',{code:String(code)}),
    renew:()=>request('/assistant/v1/session/renew','POST',{}),
    setDeviceToken(t,e){token=t||'';expires=e||0},isAuthorized:()=>!!token&&Date.now()<expires,tokenExpiresAt:()=>expires}
}
module.exports={createVoiceClient}
