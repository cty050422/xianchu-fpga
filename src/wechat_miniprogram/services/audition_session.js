// One explicit owner. No reconnect replay. FPGA watchdog stops on lost heartbeat.
const A=require('../utils/audition_score')
function createAuditionSession({hub,setTimer=setTimeout,clearTimer=clearTimeout}){
 let state={phase:'idle',step:0,error:'',segment:0},listeners=[],timer=null,epoch=0,disposed=false,lastRevision=hub.snapshot().connectionRevision
 const emit=()=>listeners.forEach(f=>{try{f(Object.assign({},state))}catch(e){}})
 let stopping=null,inflight=Promise.resolve(),playlist=null,prefetching=false,nextPrepared=-1
 function halt(){if(timer)clearTimer(timer);timer=null}
 function requireLink(){const s=hub.snapshot();if(s.hardwareMode!=='real')throw Error('先连接真实乐器');if(s.freshness!=='fresh')throw Error('乐器状态已失鲜');const f=s.lastStatus&&s.lastStatus.flags||0;if(f&14)throw Error('先停止引导、诊断或静音模式');if(!(f&16))throw Error('先完成乐器校准');return s}
 const command=(op,p)=>{const rev=hub.snapshot().connectionRevision,atEpoch=epoch;const next=inflight.catch(()=>{}).then(()=>{
  if(rev!==hub.snapshot().connectionRevision||atEpoch!==epoch)throw Error('连接或操作已变化');return hub.auditionCommand(op,p)
 });inflight=next;return next}
 function stop(){
  if(stopping)return stopping
  epoch++;halt();playlist=null;nextPrepared=-1;prefetching=false;
  // A reconnect clears local ownership, but an earlier FPGA audition can still
  // be running within its watchdog window. Fresh device state outranks local idle.
  const remote=hub.snapshot(),remotePlaying=remote.hardwareMode==='real'&&remote.freshness==='fresh'&&remote.lastStatus&&(remote.lastStatus.flags&96)===96;
  if(!remotePlaying&&!['playing','uploading','starting','unknown'].includes(state.phase)){state.phase='stopped';emit();return Promise.resolve()}
  state.phase='stopping';emit();
  const atEpoch=epoch,rev=hub.snapshot().connectionRevision;
  const ours=()=>epoch===atEpoch&&hub.snapshot().connectionRevision===rev;
  const task=(async()=>{try{await command(0x1e,[0,0,0]);if(ours())state.phase='stopped'}catch(e){if(ours()){state.phase='unknown';state.error=state.offline?'停止未确认；脱机示范可能继续，请按两杆Z停止或重连确认':'停止未确认；普通试听在心跳中断后三秒内停止'}}finally{if(stopping===task)stopping=null;if(ours())emit()}})();stopping=task;
  return stopping
 }
 async function play(compiled,segment=0,preset=0,options={}){
  if(['playing','uploading','starting','stopping','unknown'].includes(state.phase))throw Error('先停止当前试听并确认状态')
  requireLink();const part=compiled.segments&&compiled.segments[segment];if(!part||part.steps.length>64)throw Error('曲谱尚未确认或片段无效')
  if(options.offline && (compiled.segments.length!==1 || !hub.snapshot().observer))throw Error('脱机示范需要配套固件和完整单段曲谱');
  let startAttempted=false,capabilityPassed=false;
  const s=++epoch,rev=hub.snapshot().connectionRevision,id=(Date.now()%254)+1
  function check(){if(disposed||s!==epoch||hub.snapshot().connectionRevision!==rev)throw Error('连接或操作已变化')}
  playlist=null;nextPrepared=-1;prefetching=false;
  state={phase:'uploading',step:0,error:'',segment,title:options.title||'乐器示范',offline:!!options.offline,totalSegments:options.whole?compiled.segments.length-segment:1};emit()
  try{
   // QUERY has no musical side effect. A fresh phone issuer can collide with
   // the FPGA's previous last seq after reconnect; retry only this E7 once.
   try{await command(0x1f,[])}catch(e){if(e.code!=='FPGA_RESULT'||e.result!==0xe7)throw e;check();await command(0x1f,[])}
   capabilityPassed=true;check() // E0 means old firmware, no writes to score bank.
   await command(0x1b,[id,part.steps.length]);check()
   for(let i=0;i<part.steps.length;i++){await command(0x1c,A.stepPayload(part.steps[i],i));check();state.progress=Math.round((i+1)*100/part.steps.length);emit()}
   await command(0x1d,[id,part.crc]);check();state.phase='starting';emit()
   startAttempted=true;await command(0x1e,[options.offline?2:1,preset,id]);check();
   if(!(hub.snapshot().lastStatus&&(hub.snapshot().lastStatus.flags&96)===96))throw {code:'TIMEOUT_UNKNOWN',message:'尚未读回示范运行状态'};
   state.phase='playing';emit();
   if(options.whole && segment+1<compiled.segments.length){
    if(!hub.snapshot().observer)throw Error('连续分段需要配套固件');
    playlist={compiled,first:segment,last:compiled.segments.length-1,preset,id,idFor:i=>((id-1+i-segment)%255)+1,check};
    preload(segment+1);
   }
   function poll(){if(state.phase!=='playing')return;timer=setTimer(async()=>{try{check();if(state.phase!=='playing')return;await command(0x1f,[]);check();if(state.phase==='playing')poll()}catch(e){if(s===epoch){halt();state.phase='unknown';state.error=e.message||'通信中断';emit()}}},500)}poll()
  }catch(e){if(s===epoch){halt();state.phase=startAttempted&&e.code!=='FPGA_RESULT'?'unknown':'error';state.error=state.phase==='unknown'?'启动结果未确认，请先停止试听':!capabilityPassed?'未收到试听能力应答，请核对配套固件与设备授权':e.message||'乐器拒绝试听';emit()}throw e}
 }
 async function preload(index){
  if(prefetching||!playlist)return;prefetching=true;const job=playlist,part=job.compiled.segments[index];
  try{job.check();await command(0x1b,[job.idFor(index),part.steps.length]);job.check();
   for(let i=0;i<part.steps.length;i++){await command(0x1c,A.stepPayload(part.steps[i],i));job.check();}
   await command(0x1d,[job.idFor(index),part.crc]);job.check();if(playlist===job)nextPrepared=index;
  }catch(e){if(playlist===job){const message=e.message||'后续段未装载';await stop();state.error='曲目接续失败：'+message;state.phase=state.phase==='unknown'?'unknown':'error';emit();}}
  finally{prefetching=false;}
 }
 const off=hub.subscribe(s=>{
  if(lastRevision!==null&&s.connectionRevision!==lastRevision){epoch++;halt();stopping=null;state={phase:'idle',step:0,error:'连接已变化，请重新确认试听',segment:0};emit()}
  lastRevision=s.connectionRevision
  if(state.phase==='playing'){
   const st=s.lastStatus,active=!!(st&&(st.flags&96)===96)
   if(s.freshness!=='fresh'){epoch++;halt();state.phase='unknown';state.error=state.offline?'连接失鲜；已装载的有限示范可继续，需重连确认':'设备失鲜，试听结果未知';emit()}
   else if(!active){halt();if(playlist&&state.segment<playlist.last){state.phase='error';state.error='下一段未按时就绪，播放已结束；整首未完成'}else state.phase='finished';playlist=null;emit()}
   else if(playlist&&s.observer&&s.observer.mode===3&&s.observer.session===playlist.idFor(state.segment+1)&&nextPrepared===state.segment+1){
    state.segment++;nextPrepared=-1;state.step=s.observer.step+1;emit();if(state.segment<playlist.last)preload(state.segment+1);
   }
   else{state.step=st.step+1;emit()}
  }
 })
 return {play,stop,snapshot:()=>Object.assign({},state),subscribe:f=>{listeners.push(f);return()=>{listeners=listeners.filter(x=>x!==f)}},dispose(){disposed=true;stop();off();listeners=[]},pause(){return stop()}}
}
module.exports={createAuditionSession}
