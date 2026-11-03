// Pure assessment. Device facts are not phone-arrival timestamps or acoustic AI.
var RULE_VERSION='event-assessment/1.0'
var clip=function(v){return Math.max(0,Math.min(1,v))}
var integer=function(v,min,max){return Number.isSafeInteger(v)&&v>=min&&v<=max}
function empty(status,reason,source){return {ruleVersion:RULE_VERSION,status:status,reason:reason,source:source||'device_events',total:null,accuracy:null,acousticScore:null,ranked:false,dimensions:{notes:null,timing:null,duration:null,expression:null},timeline:[],suggestions:[]}}
function assessEvents(input){
  var x=input||{},mode=x.mode,steps=x.steps,events=x.events
  if(mode==='free')return empty('ungraded','自由演奏没有参考曲谱')
  if(mode!=='guided'&&mode!=='challenge')return empty('ungraded','缺少演奏模式')
  if(!Array.isArray(steps)||!steps.length||steps.length>64)return empty('ungraded','缺少有效参考曲谱')
  if(x.timebase!=='device_samples')return empty('ungraded','需要设备采样时间，手机接收时间不能替代')
  if(!Array.isArray(events)||!events.length)return empty('ungraded','没有有效演奏事件')
  var rate=x.sampleRate||48000,start=x.startTick==null?0:x.startTick
  if(!integer(rate,8000,96000)||!integer(start,0,Number.MAX_SAFE_INTEGER)||events.length>4096)return empty('incomplete','事件数据越界')
  var expected=[],tick=start,prevTick=-1,prevSequence=null
  for(var i=0;i<steps.length;i++){
    var s=steps[i];if(!s||!integer(s.mask,0,15)||!integer(s.durationSamples,1,rate*120)||!integer(s.expression||0,0,2))return empty('incomplete','参考曲谱不合法')
    expected.push(tick);tick+=s.durationSamples
  }
  for(var j=0;j<events.length;j++){
    var e=events[j]
    if(!e||!integer(e.sequence,0,0xffffffff)||!integer(e.step,0,steps.length-1)||!integer(e.tick,0,Number.MAX_SAFE_INTEGER)||e.tick<prevTick||!integer(e.mask,0,15)||!integer(e.expression||0,0,2)||(e.heldSamples!=null&&!integer(e.heldSamples,0,rate*120))||(prevSequence!==null&&e.sequence!==prevSequence+1))return empty('incomplete','事件丢失、重复、乱序或无效')
    prevTick=e.tick;prevSequence=e.sequence
  }
  var out=empty(x.complete?'complete':'provisional',null),notes=0,timing=0,held=0,expression=0,heldN=0,expressionN=0,wrong=0,hits=0
  var tolerance=integer(x.toleranceSamples,1,rate)?x.toleranceSamples:Math.round(rate*.15)
  steps.forEach(function(s,index){
    var attempts=events.filter(function(e){return e.step===index}),correct=attempts.find(function(e){return e.mask===s.mask})
    wrong+=attempts.filter(function(e){return e.mask!==s.mask}).length+Math.max(0,attempts.filter(function(e){return e.mask===s.mask}).length-1)
    if(s.mask===0){correct=attempts.length===0?{tick:expected[index],heldSamples:s.durationSamples}:null}
    var hit=!!correct,dt=hit?correct.tick-expected[index]:null
    if(hit){hits++;notes++;timing+=clip(1-Math.abs(dt)/tolerance)}
    if(s.mask!==0&&s.durationRequired!==false){heldN++;if(correct&&correct.heldSamples!=null)held+=clip(1-Math.abs(correct.heldSamples-s.durationSamples)/s.durationSamples)}
    if(s.expression){expressionN++;if(correct&&correct.expression===s.expression)expression++}
    out.timeline.push({step:index,mask:s.mask,result:hit?'hit':attempts.length?'wrong':'miss',offsetMs:mode==='challenge'&&dt!==null?Math.round(dt/rate*10000)/10:null,expressionRequired:s.expression||0,expressionMet:!!(correct&&(!s.expression||correct.expression===s.expression))})
  })
  var missingDuration=events.some(function(e){return e.mask!==0&&e.mask===steps[e.step].mask&&e.heldSamples==null&&steps[e.step].durationRequired!==false})
  var missingExpression=events.some(function(e){return e.mask===steps[e.step].mask&&steps[e.step].expression>0&&e.expression==null})
  var dims={notes:notes/(steps.length+wrong),timing:mode==='challenge'?timing/steps.length:null,duration:heldN&&!missingDuration?held/heldN:null,expression:expressionN?expression/expressionN:null}
  var weights={notes:.4,timing:.3,duration:.15,expression:.15},sum=0,denom=0
  Object.keys(dims).forEach(function(k){if(dims[k]!==null){sum+=dims[k]*weights[k];denom+=weights[k]}out.dimensions[k]=dims[k]===null?null:Math.round(dims[k]*1000)/10})
  out.total=Math.round(sum/denom*1000)/10;out.accuracy=out.dimensions.notes;out.ranked=!!x.complete&&mode==='challenge'&&!missingDuration
  if(missingDuration||missingExpression){out.status='incomplete';out.reason='缺少必需的时值或表达记录，不能给完整评分';out.total=null;out.ranked=false}
  out.counts={hits:hits,wrong:wrong,misses:steps.length-hits};out.coverage={timing:mode==='challenge',duration:!!heldN&&!missingDuration,expression:!!expressionN};out.suggestions=practiceSuggestions(out.timeline)
  return out
}
function practiceSuggestions(timeline){
  var errors=timeline.filter(function(x){return x.result!=='hit'||x.expressionRequired&&!x.expressionMet||x.offsetMs!=null&&Math.abs(x.offsetMs)>60})
  if(!errors.length)return []
  var first=errors[0].step,last=Math.min(first+3,timeline.length-1),late=errors.filter(function(x){return x.offsetMs>60}).length
  return [{fromStep:first,toStep:last,label:'重练第'+(first+1)+'—'+(last+1)+'步',reason:late?'这段有拖拍，建议先降低速度':'先巩固错音或表达动作',requiresConfirmation:true}]
}
function createCounterTracker(){
  var initial=null,last=null,issue=null,origin=null,seen=0
  function valid(s){var p=s&&s.lastStatus;return s&&!(s.observer&&(s.observer.interrupted||[3,5,6].includes(s.observer.transport)))&&s.hardwareMode==='real'&&s.freshness==='fresh'&&p&&p.mode>0&&p.mode<3&&!!(p.flags&16)&&!(p.flags&12)&&['hits','wrong','misses'].every(function(k){return integer(p[k],0,65534)})}
  return {
    begin:function(s){initial=null;last=null;issue=null;origin=s||{};seen=0;if(valid(s)&&(s.lastStatus.flags&2)){initial=Object.assign({},s.lastStatus);last=initial}else issue='当前没有可计分的真实演奏状态'},
    observe:function(s){if(!initial||issue)return;if(!valid(s)||s.hardwareMode!==origin.hardwareMode||s.connectionRevision!==origin.connectionRevision||s.lastStatus.song!==initial.song||s.lastStatus.mode!==initial.mode||(s.observer&&origin.observer&&s.observer.session!==origin.observer.session)){issue='设备、模式或状态已改变';return}var p=s.lastStatus;if(['hits','wrong','misses'].some(function(k){return p[k]<last[k]})){issue='计数器重置，成绩记录不完整';return}last=Object.assign({},p);seen++},
    finish:function(){var out=empty(initial&&issue?'incomplete':initial?'basic':'ungraded',issue,'device_counters');if(!initial||issue)return out;out.counts={hits:last.hits-initial.hits,wrong:last.wrong-initial.wrong,misses:last.misses-initial.misses};var n=out.counts.hits+out.counts.wrong+out.counts.misses;out.accuracy=n?Math.round(out.counts.hits/n*1000)/10:null;out.dimensions.notes=out.accuracy;out.observations=seen;out.reason=n?'仅评价记录期间设备回报的命中率':'记录期间尚无已结算音符';return out}
  }
}
module.exports={RULE_VERSION: RULE_VERSION,assessEvents:assessEvents,createCounterTracker:createCounterTracker,practiceSuggestions:practiceSuggestions}
