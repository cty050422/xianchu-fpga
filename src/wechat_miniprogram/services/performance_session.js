var {recorderChannel}=require('../utils/recorder_lease')
var {createCounterTracker}=require('../utils/performance_assessment')
var KEY='performance:local-takes'
var OPTIONS={duration:120000,sampleRate:44100,numberOfChannels:1,encodeBitRate:128000,format:'mp3'}
function createPerformanceSession(opts){
  var wxApi=opts.wx,hub=opts.hub,client=opts.client,clock=opts.now||Date.now
  var listeners=[],channel=null,version=0,started=0,tracker=null,tracking=false,lastStatusAt=null
  var offHub=null,stopWait=null,stopTimer=null,startTimer=null,limitTimer=null,remoteTimer=null,remotePoll=null
  var remoteId=null,remoteControl=null,startMeta=null,startReference=null,uploads={}
  var state={phase:'idle',durationMs:0,error:null,localTakes:[],remoteTakes:[],current:null,assessment:null,receiverOnline:false,uploadProgress:0,interrupted:false}
  try{var saved=wxApi.getStorageSync(KEY);if(Array.isArray(saved))state.localTakes=saved.filter(function(x){return x&&typeof x.id==='string'&&typeof x.path==='string'}).slice(0,12)}catch(e){}
  function fileMethod(name){
    var manager=null;try{if(wxApi.getFileSystemManager)manager=wxApi.getFileSystemManager()}catch(e){}
    if(manager&&typeof manager[name]==='function')return manager[name].bind(manager)
    return typeof wxApi[name]==='function'?wxApi[name].bind(wxApi):null
  }
  function device(){return hub&&hub.snapshot?hub.snapshot():{}}
  function observeFacts(s){
    if(!tracking||!tracker)return
    s=s||device()
    if(lastStatusAt!=null&&Number.isFinite(s.lastStatusAt)&&s.lastStatusAt-lastStatusAt>5000)tracker.observe(Object.assign({},s,{freshness:'stale'}))
    tracker.observe(s)
    if(Number.isFinite(s.lastStatusAt))lastStatusAt=s.lastStatusAt
  }
  function snapshot(){
    observeFacts()
    return Object.assign({},state,{durationMs:state.phase==='recording'?Math.min(120000,clock()-started):state.durationMs,localTakes:state.localTakes.slice(),remoteTakes:state.remoteTakes.slice(),assessment:tracking&&tracker?tracker.finish():state.assessment})
  }
  function emit(){var s=snapshot();listeners.slice().forEach(function(fn){try{fn(s)}catch(e){}})}
  function persist(){try{wxApi.setStorageSync(KEY,state.localTakes)}catch(e){state.error={code:'LOCAL_INDEX_FAILED',message:'录音文件已保存，列表持久化失败，请先上传'}}}
  function stopTimers(){if(limitTimer)clearTimeout(limitTimer);if(startTimer)clearTimeout(startTimer);if(stopTimer)clearTimeout(stopTimer);limitTimer=startTimer=stopTimer=null}
  function settle(error,value){if(stopWait){var p=stopWait;stopWait=null;error?p.reject(error):p.resolve(value)}}
  function detach(){if(offHub)offHub();offHub=null;tracking=false}
  function invalidate(a,reason){a=a||{source:'device_counters',counts:null,dimensions:{notes:null,timing:null,duration:null,expression:null},ranked:false};return Object.assign({},a,{status:'incomplete',accuracy:null,total:null,ranked:false,reason:reason||'记录不完整'})}
  function finishFacts(incomplete,reason){observeFacts();var a=tracking&&tracker?tracker.finish():state.assessment;detach();if(!a)a={source:'device_counters',status:'ungraded',accuracy:null,total:null,counts:null,ranked:false,dimensions:{notes:null,timing:null,duration:null,expression:null},reason:'未观察到可关联的真实演奏窗口'};if(incomplete)a=invalidate(a,reason);state.assessment=a;return a}
  function fail(error){stopTimers();finishFacts(true,error.message);state.phase='error';state.error={code:error.code||'RECORDER_ERROR',message:error.message||'录音失败'};settle(state.error);emit()}
  function mode(s){return s&&s.lastStatus&&(s.lastStatus.flags&2)?s.lastStatus.mode===1?'guided':s.lastStatus.mode===2?'challenge':'free':'free'}
  function metadata(){var s=device(),m=mode(s);return {source:'phone_mic',mode:m,title:s.activeScore&&s.activeScore.title||(m==='challenge'?'挑战演奏':m==='guided'?'引导演奏':'自由演奏'),song:s.activeScore?{title:s.activeScore.title,id:s.activeScore.songId||String(s.activeScore.wireId),bpm:s.activeScore.bpm}:null,simulated:s.hardwareMode==='simulator'}}
  function reference(s){return {revision:s.connectionRevision,hardware:s.hardwareMode,song:s.lastStatus&&s.lastStatus.song,mode:s.lastStatus&&s.lastStatus.mode}}
  function beginFacts(){
    detach();var s=device();tracker=createCounterTracker();tracker.begin(s);tracking=true;lastStatusAt=Number.isFinite(s.lastStatusAt)?s.lastStatusAt:null
    if(hub&&hub.subscribe)offHub=hub.subscribe(function(snap){observeFacts(snap);emit()})
  }
  function upsertRemote(take){state.remoteTakes=state.remoteTakes.filter(function(t){return t.id!==take.id});state.remoteTakes.unshift(take)}
  function cancelRemote(){
    var id=remoteId,control=remoteControl;remoteId=null;remoteControl=null
    if(remoteTimer)clearInterval(remoteTimer);remoteTimer=null;remotePoll=null
    if(id){try{Promise.resolve(control?control.stop(id):client.stop(id)).catch(function(){})}catch(e){}}
  }
  function saveStopped(res){
    if(state.phase!=='recording'&&state.phase!=='stopping')return
    stopTimers();var a=finishFacts(state.interrupted,'录音被中断')
    if(!res||typeof res.tempFilePath!=='string'||!Number.isFinite(res.duration)||res.duration<500||res.duration>121000||!Number.isFinite(res.fileSize)||res.fileSize<=0||res.fileSize>16*1024*1024)return fail({code:'RECORDING_INVALID',message:'录音过短、过长或文件无效'})
    state.phase='saving';state.durationMs=res.duration;var epoch=version;emit()
    var local=Object.assign({},startMeta,{id:'local-'+clock()+'-'+Math.random().toString(36).slice(2,10),requestId:'record-'+clock()+'-'+Math.random().toString(36).slice(2,12),createdAt:clock(),durationMs:res.duration,bytes:res.fileSize,path:res.tempFilePath,mime:'audio/mpeg',assessment:a,interrupted:state.interrupted,persistent:false})
    function saved(path,persistent){
      if(epoch!==version){var remove=fileMethod('removeSavedFile');if(persistent&&remove)remove({filePath:path,fail:function(){}});return}
      local.path=path;local.persistent=persistent;state.localTakes.unshift(local);state.current=local;state.assessment=a;state.phase='ready'
      if(!persistent)state.error={code:'TEMPORARY_AUDIO',message:'本次录音尚未持久保存，请在退出前上传'}
      persist();settle(null,local);emit()
    }
    var save=fileMethod('saveFile')
    if(save)save({tempFilePath:res.tempFilePath,success:function(r){saved(r.savedFilePath,true)},fail:function(){saved(res.tempFilePath,false)}});else saved(res.tempFilePath,false)
  }
  function ensureChannel(){
    if(channel)return
    channel=recorderChannel(wxApi.getRecorderManager())
    channel.onStart(function(){
      if(state.phase!=='starting'){channel.stop();return}
      if(startTimer)clearTimeout(startTimer);startTimer=null;startMeta=metadata();beginFacts();started=clock();state.phase='recording'
      // A small guard margin also avoids encoder padding crossing the 120s file limit.
      limitTimer=setTimeout(function(){if(state.phase==='recording')session.stop().catch(function(){})},119000);emit()
    })
    channel.onError(function(e){if(state.phase!=='cancelled')fail({code:'RECORDER_ERROR',message:e&&e.errMsg||'录音设备不可用'})})
    channel.onInterruptionBegin(function(){session.interrupt('录音被系统打断').catch(function(){})})
    channel.onStop(saveStopped)
  }
  function permission(epoch){return new Promise(function(resolve,reject){
    function cancelled(){if(epoch!==version){reject({code:'CANCELLED',message:'录音已取消'});return true}return false}
    function requestMicrophone(){
      if(cancelled())return
      wxApi.getSetting({success:function(r){
        if(cancelled())return
        var a=r.authSetting||{}
        if(a['scope.record']===true)return resolve()
        if(a['scope.record']===false)return reject({code:'PERMISSION_DENIED',message:'请在微信小程序设置中允许麦克风'})
        wxApi.authorize({scope:'scope.record',success:resolve,fail:function(){reject({code:'PERMISSION_DENIED',message:'麦克风未授权'})}})
      },fail:function(){if(!cancelled())reject({code:'PERMISSION_FAILED',message:'无法读取麦克风权限'})}})
    }
    if(typeof wxApi.requirePrivacyAuthorize==='function')wxApi.requirePrivacyAuthorize({success:requestMicrophone,fail:function(){if(!cancelled())reject({code:'PRIVACY_REQUIRED',message:'请先同意小程序隐私指引，再开始录音'})}})
    else requestMicrophone()
  })}
  function audioMeta(local){return {requestId:local.requestId,source:local.source,mode:local.mode,title:local.title,song:local.song,simulated:local.simulated}}
  function busy(){return ['requesting_permission','requesting_capture','starting','recording','stopping','saving','instrument_waiting','instrument_recording','processing'].indexOf(state.phase)>=0}
  function reset(){state.error=null;state.interrupted=false;state.durationMs=0;state.current=null;state.assessment=null;tracker=null;lastStatusAt=null}
  var session={
    snapshot:snapshot,
    subscribe:function(fn){listeners.push(fn);return function(){var i=listeners.indexOf(fn);if(i>=0)listeners.splice(i,1)}},
    start:function(){
      if(busy())return Promise.reject({code:'RECORDER_BUSY',message:'当前录音尚未结束'})
      if(state.localTakes.length>=12)return Promise.reject({code:'LOCAL_LIMIT',message:'请先上传或删除部分本地录音'})
      version++;var epoch=version;reset();state.phase='requesting_permission';emit()
      return permission(epoch).then(function(){
        if(epoch!==version)throw {code:'CANCELLED',message:'录音已取消'}
        ensureChannel();if(opts.voice&&opts.voice.stopSpeech)opts.voice.stopSpeech();state.phase='starting';channel.start(OPTIONS)
        if(state.phase==='error')throw state.error
        if(state.phase==='starting')startTimer=setTimeout(function(){if(state.phase==='starting'){fail({code:'START_TIMEOUT',message:'麦克风启动未确认'});channel.stop()}},4000)
        emit()
      }).catch(function(e){if(epoch===version)fail(e);throw e})
    },
    stop:function(){
      if(state.phase==='instrument_recording'||state.phase==='instrument_waiting'){
        var id=remoteId,epoch=version;finishFacts(state.interrupted,'采集中断，成绩不可用');state.phase='processing';emit()
        return client.stop(id).then(function(){if(epoch===version)return session.refreshRemote()}).catch(function(e){if(epoch===version){state.error={code:e.code||'NETWORK_ERROR',message:'采集结束尚未确认，可退出等待后重试'};emit()}throw e})
      }
      if(state.phase!=='recording')return Promise.reject({code:'NOT_RECORDING',message:'当前没有录音'})
      state.phase='stopping';emit()
      return new Promise(function(resolve,reject){stopWait={resolve:resolve,reject:reject};stopTimer=setTimeout(function(){fail({code:'STOP_TIMEOUT',message:'录音结束未确认；等待原生停止应答后才能重新录音'});channel.stop()},4000);try{channel.stop()}catch(e){fail(e)}})
    },
    cancel:function(){
      version++;var active=['starting','recording','stopping'].indexOf(state.phase)>=0;cancelRemote();state.phase='cancelled';state.error=null
      stopTimers();detach();settle({code:'CANCELLED',message:'录音已取消'});if(active&&channel)channel.stop();emit()
    },
    interrupt:function(reason){
      if(['requesting_permission','starting','requesting_capture'].indexOf(state.phase)>=0){session.cancel();return Promise.resolve()}
      if(['recording','instrument_waiting','instrument_recording'].indexOf(state.phase)<0)return Promise.resolve()
      state.interrupted=true;state.error={code:'INTERRUPTED',message:reason||'录音被中断'};return session.stop()
    },
    serviceChanged:function(){
      var capture=state.phase==='requesting_capture'||!!remoteId
      if(capture){version++;cancelRemote();finishFacts(true,'作品服务已切换');state.phase='cancelled';state.current=null;state.assessment=null}
      else session.interrupt('作品服务已切换，已结束本地录音').catch(function(){})
      state.remoteTakes=[];state.receiverOnline=false;emit()
    },
    upload:function(id){
      if(uploads[id])return uploads[id]
      var local=state.localTakes.find(function(x){return x.id===id});if(!local)return Promise.reject({code:'TAKE_NOT_FOUND'})
      if(!client.baseUrl())return Promise.reject({code:'SERVICE_UNCONFIGURED',message:'先连接作品服务'})
      var base=client.baseUrl();state.uploadProgress=0;state.error=null;emit()
      var promise=Promise.resolve(local.remoteBase===base&&local.remoteId?{id:local.remoteId}:client.create(audioMeta(local))).then(function(remote){local.remoteId=remote.id;local.remoteBase=base;persist();return client.upload(remote.id,local.path,local.mime,function(p){state.uploadProgress=p.progress;emit()})}).then(function(remote){if(local.assessment&&local.assessment.counts)return client.assessment(remote.id,{kind:'device_counters',counts:local.assessment.counts,incomplete:local.assessment.status==='incomplete'});return remote}).then(function(remote){local.uploaded=true;local.remote=remote;state.uploadProgress=100;persist();emit();return remote}).catch(function(e){state.error=e;emit();throw e})
      uploads[id]=promise;promise.then(function(){delete uploads[id]},function(){delete uploads[id]});return promise
    },
    removeLocal:function(id){
      var local=state.localTakes.find(function(x){return x.id===id});if(!local)return Promise.resolve()
      if(uploads[id])return Promise.reject({code:'UPLOAD_BUSY',message:'上传完成后再删除'})
      return new Promise(function(resolve,reject){function done(){state.localTakes=state.localTakes.filter(function(x){return x.id!==id});persist();emit();resolve()}var remove=fileMethod('removeSavedFile');if(local.persistent){if(remove)remove({filePath:local.path,success:done,fail:reject});else reject({code:'FILE_API_UNAVAILABLE',message:'无法删除已保存文件，请检查微信文件权限'})}else done()})
    },
    refresh:function(){return Promise.all([client.list(),client.health()]).then(function(results){state.remoteTakes=results[0].items;state.receiverOnline=!!results[1].receiverOnline;state.error=null;emit();return snapshot()}).catch(function(e){state.error=e;emit();throw e})},
    startInstrument:function(){
      if(busy())return Promise.reject({code:'RECORDER_BUSY',message:'当前录音尚未结束'})
      version++;var epoch=version,control=client.captureControl?client.captureControl():{stop:function(id){return client.stop(id)}};reset();state.phase='requesting_capture';emit()
      return client.health().then(function(h){
        if(epoch!==version)throw {code:'CANCELLED'}
        if(!h.receiverOnline)throw {code:'CAPTURE_OFFLINE',message:'乐器录音接收器未在线'}
        startMeta=metadata();startReference=reference(device());var meta=Object.assign({},startMeta,{source:'instrument_pcm',requestId:'capture-'+clock()+'-'+Math.random().toString(36).slice(2,10)});return client.create(meta)
      }).then(function(take){
        if(epoch!==version){control.stop(take.id).catch(function(){});throw {code:'CANCELLED'}}
        remoteId=take.id;remoteControl=control;state.current=take;upsertRemote(take);state.phase='instrument_waiting';remoteTimer=setInterval(function(){session.refreshRemote().catch(function(){})},800);emit();return take
      }).catch(function(e){if(epoch===version)fail(e);throw e})
    },
    refreshRemote:function(){
      if(!remoteId)return Promise.resolve();if(remotePoll)return remotePoll
      var id=remoteId,epoch=version
      var p=client.detail(id).then(function(take){
        if(epoch!==version||remoteId!==id)return take
        state.current=take;upsertRemote(take)
        if(state.phase==='instrument_waiting'&&take.state==='capturing'&&take.capturedFrames>0){
          if(JSON.stringify(reference(device()))===JSON.stringify(startReference)){beginFacts();state.phase='instrument_recording'}
          else{state.assessment=invalidate(null,'采集启动前设备或曲目发生变化');state.phase='instrument_recording'}
        }
        if(take.capturedFrames)state.durationMs=Math.floor(take.capturedFrames/48)
        if(['ready','incomplete','cancelled'].indexOf(take.state)>=0){
          if(remoteTimer)clearInterval(remoteTimer);remoteTimer=null;remoteId=null;remoteControl=null
          var a=finishFacts(state.interrupted||take.state!=='ready',take.error||'采集中断，成绩不可用');a.observationScope='receiver_confirmation_to_stop_or_result';state.assessment=a
          take.assessment=a;state.current=take;upsertRemote(take);state.phase=take.state==='ready'?'ready':take.state==='cancelled'?'cancelled':'error';state.durationMs=take.audio?take.audio.durationMs:state.durationMs;state.error=take.error?{message:take.error}:null;emit()
          if(a.counts)return client.assessment(id,{kind:'device_counters',counts:a.counts,incomplete:a.status==='incomplete'}).then(function(t){if(epoch===version){state.current=t;upsertRemote(t);emit()}return t}).catch(function(e){if(epoch===version){state.error={code:e.code||'NETWORK_ERROR',message:'录音已保存，成绩尚未回传'};emit()}throw e})
        }
        emit();return take
      }).catch(function(e){
        if(epoch===version&&(e.statusCode===404||e.code==='TAKE_NOT_FOUND')){
          cancelRemote();finishFacts(true,'录音已被移除，成绩不可用');state.remoteTakes=state.remoteTakes.filter(function(t){return t.id!==id});state.current=null;state.phase='error';state.error={code:'TAKE_NOT_FOUND',message:'录音已被移除，可以重新开始'};emit()
        }
        throw e
      })
      remotePoll=p;p.then(function(){if(remotePoll===p)remotePoll=null},function(){if(remotePoll===p)remotePoll=null});return p
    },
    dispose:function(){session.cancel();listeners=[]}
  }
  return session
}
module.exports={createPerformanceSession:createPerformanceSession,PERFORMANCE_RECORD_OPTIONS:OPTIONS}
