// Confirmed actions share the existing session issuer and verified catalog.
// Plans are private records: a model reply/UI object can never supply wire bytes.
var protocol=require('../utils/protocol')
var compiler=require('../utils/score_compiler')
function failure(code,message){return Object.assign(new Error(message||code),{code:code})}
function wireIdFor(id){var h=0;for(var i=0;i<id.length;i++)h=((h*31)+id.charCodeAt(i))>>>0;return 128+(h%127)}
function createAssistantActions(options){
  var hub=options.hub,catalog=options.catalog,storage=options.storage||{get:function(){},set:function(){}},serial=0,prepareSerial=0,busy=false,records=new Map(),selection=null
  function source(){return catalog&&catalog.getBaseUrl?catalog.getBaseUrl():''}
  function context(){var s=hub.snapshot();return {mode:s.hardwareMode,revision:s.connectionRevision||0,device:s.realDevice&&s.realDevice.deviceId||''}}
  function checkContext(c){var n=context();if(c.mode!==n.mode||c.revision!==n.revision||c.device!==n.device)throw failure('CONTEXT_CHANGED','设备连接已变化，请重新确认')}
  function selected(){
    var s=selection||storage.get('assistant:selectedSong')||storage.get('practice:currentSong')
    return s&&(!s.baseUrl||s.baseUrl===source())?Object.assign({},s):null
  }
  function remember(entry,compiled,segmentIndex){
    selection={songId:entry.score.songId,title:entry.score.title,bpm:compiled.bpm,revision:entry.score.revision,contentHash:entry.contentHash,segments:compiled.segments.length,segmentIndex:segmentIndex,baseUrl:source()}
    storage.set('assistant:selectedSong',Object.assign({},selection));return selected()
  }
  function plan(kind,payload,view){
    prepareSerial++
    records.clear()
    var id='assistant-action-'+(++serial),v=Object.freeze(Object.assign({id:id,kind:kind,title:'确认操作',detail:'',confirmLabel:context().mode==='disconnected'?'存为草稿':'确认执行',disabled:false},view||{}))
    records.set(id,{view:v,kind:kind,payload:payload,context:context(),source:source()});return v
  }
  function compile(entry,bpm){
    var compiled=compiler.compileScore(entry.score,{encoding:'v2',bpm:bpm,deviceSupportsCustomNotes:true})
    if(!compiled.ok)throw failure(compiled.errors[0].code||'SCORE_UNSUPPORTED',compiled.errors[0].message)
    return compiled
  }
  function download(songId){
    if(typeof songId!=='string'||!/^[a-z0-9][a-z0-9-]{0,79}$/.test(songId))return Promise.reject(failure('INVALID_SONG_ID','曲目编号无效'))
    if(!catalog||!source())return Promise.reject(failure('SERVICE_UNCONFIGURED','请先连接曲库服务'))
    var origin=source()
    return catalog.detail(songId).then(function(entry){
      if(origin!==source())throw failure('SOURCE_CHANGED','曲库服务已变化，请重新选择')
      if(!entry||!entry.score)throw failure('BAD_DETAIL','曲谱数据不完整')
      return {entry:entry,source:entry.fromCache?'cache':'network'}
    })
  }
  function prepareSong(songId,params){
    params=params||{}
    var generation=++prepareSerial,originContext=context();records.clear()
    return download(songId).then(function(downloaded){
      if(generation!==prepareSerial)throw failure('PLAN_SUPERSEDED','已选择其他操作')
      checkContext(originContext)
      var entry=downloaded.entry,compiled=compile(entry,params.bpm),index=params.segmentIndex===undefined?0:params.segmentIndex
      if(!Number.isInteger(index)||index<0||index>=compiled.segments.length)throw failure('NO_SUCH_SEGMENT','没有这一段曲谱')
      remember(entry,compiled,index)
      return plan('song',{entry:entry,compiled:compiled,segmentIndex:index,wireId:wireIdFor(entry.score.songId),downloadSource:downloaded.source},{title:entry.score.title,detail:compiled.bpm+' BPM · '+compiled.stepCount+'步 · '+compiled.requiredMapping.label+'\n第'+(index+1)+'段 / 共'+compiled.segments.length+'段'+(downloaded.source==='cache'?' · 离线缓存':''),confirmLabel:context().mode==='disconnected'?'存为草稿':'下载到乐器'})
    })
  }
  function prepareSelected(params){var s=selected();if(!s)return Promise.reject(failure('NO_SELECTION','请先选择曲目'));return prepareSong(s.songId,Object.assign({bpm:s.bpm,segmentIndex:s.segmentIndex||0},params||{}))}
  function prepareConfig(sets,view){
    if(!Array.isArray(sets)||!sets.length||sets.length>8)throw failure('INVALID_CONFIG','参数列表无效')
    var seen={}
    var values=sets.map(function(s){var f=protocol.configField(s.field);if(!f||!f.supported)throw failure('UNSUPPORTED','当前程序未开放该参数');if(seen[s.field])throw failure('INVALID_CONFIG','参数重复');seen[s.field]=true;if(!Number.isInteger(s.value)||s.value<f.min||s.value>f.max)throw failure('OUT_OF_RANGE',f.label+'超出范围');return {field:s.field,value:s.value}})
    return plan('config',{sets:values},view)
  }
  function prepareMode(mode){if(![0,1,2].includes(mode))throw failure('OUT_OF_RANGE','模式无效');return plan('mode',{mode:mode},{title:['自由演奏','开始引导练习','开始节奏挑战'][mode],detail:mode?'使用乐器中已载入的曲谱':'停止曲谱指引，恢复自由演奏'})}
  function prepareEffect(mode){if(!Number.isInteger(mode)||mode<0||mode>3)throw failure('OUT_OF_RANGE','效果无效');return plan('effect',{mode:mode},{title:'效果：'+['干声','回声','合唱','合唱与回声'][mode]})}
  function checkSource(expected){if(expected!==source())throw failure('SOURCE_CHANGED','服务地址已变化，操作结果需重新核对')}
  function ensureCapabilities(fields,c,expectedSource){
    checkContext(c)
    checkSource(expectedSource)
    return hub.queryCapability().then(function(cap){checkContext(c);checkSource(expectedSource);var missing=fields.filter(function(id){return !protocol.supportsField(cap.supportedMask,id)});if(missing.length)throw failure('UNSUPPORTED','设备不支持参数 '+missing.join('、'));return cap})
  }
  function execute(view,options){
    options=options||{}
    if(busy)return Promise.reject(failure('BUSY','正在执行上一项操作'))
    var record=view&&records.get(view.id)
    if(!record||record.view!==view)return Promise.reject(failure('PLAN_INVALID','提案已失效，请重新选择'))
    records.delete(view.id);busy=true
    var p=record.payload,c=record.context
    return Promise.resolve().then(function(){
      if(record.source!==source())throw failure('SOURCE_CHANGED','服务地址已变化，请重新确认')
      checkContext(c)
      if(c.mode==='disconnected'){hub.saveDraft({kind:record.kind,title:view.title});return {confirmation:'draft',isSimulator:false}}
      if(hub.snapshot().freshness!=='fresh')throw failure('STALE','设备状态已失鲜，请检查连接')
      if(record.kind==='config')return ensureCapabilities(p.sets.map(function(s){return s.field}),c,record.source).then(function(){return hub.simConfigTransaction(p.sets)}).then(function(rb){return {readback:rb}})
      if(record.kind==='effect')return hub.simFxControl(p.mode).then(function(r){return {status:r.status}})
      if(record.kind==='mode'){
        if(p.mode&&!(hub.snapshot().lastStatus&&hub.snapshot().lastStatus.flags&1))throw failure('NO_SCORE','乐器尚未载入曲谱')
        return hub.simGuide(p.mode).then(function(r){return {status:r.status}})
      }
      if(record.kind==='song')return ensureCapabilities([1,2,3,4,22],c,record.source).then(function(){
        return hub.simUploadSegmentV2(p.compiled,p.wireId,p.segmentIndex,options.onProgress)
      }).then(function(r){
        checkContext(c)
        checkSource(record.source)
        var saved=remember(p.entry,p.compiled,p.segmentIndex)
        if(hub.rememberScore)hub.rememberScore(Object.assign({},saved,{wireId:p.wireId,source:'catalog'}))
        storage.set('practice:currentSong',Object.assign({},saved,{wireId:p.wireId}))
        return {status:r.status,segmentIndex:p.segmentIndex,segments:p.compiled.segments.length,wireId:p.wireId,title:p.entry.score.title,downloadSource:p.downloadSource}
      })
      throw failure('PLAN_INVALID','未知操作')
    }).then(function(result){checkContext(c);checkSource(record.source);if(result.confirmation==='draft')return result;return Object.assign(result,{confirmation:'fpga-confirmed',isSimulator:c.mode==='simulator'})}).finally(function(){busy=false})
  }
  function discard(){prepareSerial++;records.clear()}
  return {prepareSong:prepareSong,prepareSelected:prepareSelected,prepareConfig:prepareConfig,prepareMode:prepareMode,prepareEffect:prepareEffect,download:download,selected:selected,execute:execute,discard:discard,isBusy:function(){return busy}}
}
module.exports={createAssistantActions:createAssistantActions,wireIdFor:wireIdFor}
