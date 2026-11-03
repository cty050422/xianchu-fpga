function createPerformanceClient(options){
  var opts=options||{},wxApi=opts.wx,active=[],generation=0
  function base(){return String(opts.getBaseUrl()||'').replace(/\/+$/,'')}
  function discardDownload(res){
    if(!res||!res.tempFilePath)return
    try{wxApi.getFileSystemManager().unlink({filePath:res.tempFilePath,fail:function(){}})}catch(e){}
  }
  function call(kind,endpoint,data){return new Promise(function(resolve,reject){
    var url=base(),epoch=generation
    if(!/^https?:\/\//.test(url))return reject({code:'SERVICE_UNCONFIGURED',message:'先连接作品服务'})
    var record={task:null,done:false,failed:false,finish:function(error,result){
      if(record.done)return
      record.done=true;record.failed=!!error
      var at=active.indexOf(record);if(at>=0)active.splice(at,1)
      if(error)reject(error);else resolve(result)
    }}
    active.push(record)
    var config={url:url+'/performances/v1/'+endpoint,header:{'x-device-token':opts.getToken()||''},timeout:30000,
      success:function(res){
        // A cancelled native download may still yield a file. Never delete a
        // successfully delivered file, whose playback caller owns cleanup.
        if(record.done){if(kind==='download'&&record.failed)discardDownload(res);return}
        if(epoch!==generation||base()!==url){if(kind==='download')discardDownload(res);return record.finish({code:'CANCELLED',message:'服务已切换'})}
        if(res.statusCode>=200&&res.statusCode<300){
          if(kind==='download')return record.finish(null,res.tempFilePath)
          try{record.finish(null,typeof res.data==='string'?JSON.parse(res.data):res.data)}catch(e){record.finish({code:'BAD_RESPONSE',message:'作品服务返回格式错误'})}
        }else{
          if(kind==='download')discardDownload(res)
          record.finish({code:res.data&&res.data.error||'SERVICE_ERROR',statusCode:res.statusCode,message:res.statusCode===401?'请在设备页连接助手与作品服务':'作品服务暂时不可用'})
        }
      },
      fail:function(e){record.finish({code:'NETWORK_ERROR',message:e&&e.errMsg||'服务连接失败'})}
    }
    try{
      if(kind==='upload'){
        config.filePath=data.path;config.name='audio';config.formData={mime:data.mime||'audio/mpeg'}
        record.task=wxApi.uploadFile(config)
        if(record.task&&record.task.onProgressUpdate&&data.onProgress)record.task.onProgressUpdate(data.onProgress)
      }else if(kind==='download')record.task=wxApi.downloadFile(config)
      else{config.method=kind;config.data=data;record.task=wxApi.request(config)}
    }catch(e){record.finish({code:'CLIENT_ERROR',message:e.message||String(e)})}
  })}
  function captureControl(){
    var url=base(),token=opts.getToken()||''
    // Independent of service switches/cancelAll: old token only to old host.
    return {stop:function(id){return new Promise(function(resolve){
      try{wxApi.request({url:url+'/performances/v1/takes/'+encodeURIComponent(id)+'/stop',method:'POST',data:{},header:{'x-device-token':token},timeout:3000,success:function(r){resolve(r.statusCode===200)},fail:function(){resolve(false)}})}catch(e){resolve(false)}
    })}}
  }
  return {
    baseUrl:base,captureControl:captureControl,
    health:function(){return call('GET','healthz')},list:function(){return call('GET','takes')},
    create:function(meta){return call('POST','takes',meta)},detail:function(id){return call('GET','takes/'+encodeURIComponent(id))},
    upload:function(id,path,mime,progress){return call('upload','takes/'+encodeURIComponent(id)+'/audio',{path:path,mime:mime,onProgress:progress})},
    assessment:function(id,evidence){return call('POST','takes/'+encodeURIComponent(id)+'/assessment',evidence)},
    stop:function(id){return call('POST','takes/'+encodeURIComponent(id)+'/stop',{})},
    remove:function(id){return call('DELETE','takes/'+encodeURIComponent(id))},
    download:function(id){return call('download','takes/'+encodeURIComponent(id)+'/audio')},
    cancelAll:function(){generation++;active.slice().forEach(function(r){r.finish({code:'CANCELLED',message:'服务请求已取消'});if(r.task&&r.task.abort)r.task.abort()})}
  }
}
module.exports={createPerformanceClient:createPerformanceClient}
