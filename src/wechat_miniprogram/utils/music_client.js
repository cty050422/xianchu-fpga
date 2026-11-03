function createMusicClient({wx:api,getBaseUrl,getToken}){
 function request(method,path,data,binary){return new Promise((resolve,reject)=>{
  const base=getBaseUrl(),token=getToken();if(!base||!token)return reject(Error('请先在设备页连接曲库与作品服务'))
  api.request({url:base+path,method,data,header:{'x-device-token':token,'content-type':binary?'application/octet-stream':'application/json'},timeout:30000,
   success:r=>{if(base!==getBaseUrl()||token!==getToken())return reject(Error('服务已变化，请重试'));if(r.statusCode===200)resolve(r.data);else reject(Object.assign(Error(({NO_MELODY:'没有检测到清晰旋律',TRANSCRIPTION_LIMIT:'转谱支持0.3至30秒的清晰单音录音',TRANSCRIPTION_BUSY:'已有转谱任务，请稍后',POLYPHONY:'同一时刻超过四个音',DURATION_RANGE:'含短于20毫秒的区间，可尝试20毫秒网格',UNAUTHORIZED:'服务授权已失效',MIDI_SUSTAIN_UNSUPPORTED:'这份MIDI带延音踏板，请先导出不含踏板的版本',MIDI_PITCH_BEND_UNSUPPORTED:'这份MIDI含弯音事件，请先转为普通音符',MIDI_DRUMS_UNSUPPORTED:'不支持鼓轨，请先导出旋律轨'}[r.data&&r.data.error]||'曲谱处理失败：'+(r.data&&r.data.error||r.statusCode))),{code:r.data&&r.data.error}))},
   fail:e=>reject(Error(e.errMsg||'服务无法连接'))})
 })}
 return {online:q=>request('GET','/music/v1/online?q='+encodeURIComponent(q||'')),download:(id,quantize)=>request('POST','/music/v1/online/'+encodeURIComponent(id)+'?quantizeMs='+(quantize?20:0),{}),importMidi:(b,q)=>request('POST','/music/v1/import?quantizeMs='+(q?20:0),b,true),transcribe:id=>request('POST','/performances/v1/takes/'+encodeURIComponent(id)+'/transcribe',{})}
}
module.exports={createMusicClient}
