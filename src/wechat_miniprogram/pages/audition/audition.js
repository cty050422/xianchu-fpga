const A=require('../../utils/audition_score')
const R=require('../../utils/event_recording')
const {createMusicClient}=require('../../utils/music_client')
Page({
 data:{title:'曲谱试听',source:'',loaded:false,loading:false,error:'',phase:'idle',status:'等待曲谱',progress:0,
  preset:0,presets:['拨弦','吹管','钟声','贝斯'],segment:0,parts:[],bars:[],step:0,steps:0,duration:'0.0',warnings:[],onlineItems:[],onlineOpen:false,quantize:true,
  editOpen:false,editStep:0,stepNames:[],editNotes:'',editDuration:'',canPlay:false,
  rec:{active:false,count:0,seconds:'0.0',loss:false,saved:false}},
 onLoad(){const app=getApp();this.app=app;this.visible=true;this.hub=app.globalData.sessionHub;this.session=app.getAuditionSession();
  this.client=createMusicClient({wx,getBaseUrl:()=>app.globalData.serviceConfig.baseUrl,getToken:()=>app.globalData.voiceClient.getDeviceToken()});
  this.off=this.session.subscribe(s=>{if(this.visible)this.apply(s)});this.offHub=this.hub.subscribe(()=>{if(this.visible)this.updateConnection()});
  const draft=app.globalData.auditionDraft;if(draft){app.globalData.auditionDraft=null;this.setScore(draft)}this.apply(this.session.snapshot());this.updateConnection()
 },
 onShow(){this.visible=true;if(this.session)this.apply(this.session.snapshot());if(this.hub)this.updateConnection()},
 onHide(){this.visible=false},
 onUnload(){this.visible=false;if(this.off)this.off();if(this.offHub)this.offHub()},
 updateConnection(){const s=this.hub.snapshot(),f=s.lastStatus&&s.lastStatus.flags||0;this.setData({canPlay:s.hardwareMode==='real'&&s.freshness==='fresh'&&!!(f&16)&&!(f&14),linkLabel:s.hardwareMode==='real'?(s.freshness==='fresh'?'乐器在线':'乐器失鲜'):'未连接乐器'})},
 apply(s){const label={idle:'等待试听',uploading:'正在装载',starting:'正在启动',playing:'乐器正在合成',stopping:'正在停止',stopped:'已停止',finished:'本段已结束',unknown:'状态未确认',error:'操作未完成'}[s.phase]||'等待试听';this.setData({phase:s.phase,status:label,progress:s.progress||0,step:s.step||0,error:s.error||''})},
 setScore(draft){this.compiled=draft.compiled||A.fromCatalog(draft.score,draft.bpm);this.setData({title:draft.title||'未命名旋律',source:draft.source||'所选曲谱',loaded:true,segment:0,warnings:draft.warnings||this.compiled.warnings||[],parts:this.compiled.segments.map((p,i)=>'第'+(i+1)+'段 / '+this.compiled.segments.length+'段')});this.renderPart()},
 renderPart(){const p=this.compiled.segments[this.data.segment],bars=[];let at=0;const notes=p.steps.flatMap(x=>x.notes),low=Math.min(48,...notes),high=Math.max(84,...notes),span=high-low+1;
  p.steps.forEach((s,i)=>{for(const n of s.notes)bars.push({id:i+'-'+n,left:Math.round(at*10000/p.samples)/100,width:Math.max(.25,Math.round(s.samples*10000/p.samples)/100),top:Math.round((high-n)*88/span)+4,name:A.noteName(n)});at+=s.samples});
  this.setData({bars,steps:p.steps.length,duration:(p.samples/48000).toFixed(1),stepNames:p.steps.map((s,i)=>String(i+1).padStart(2,'0')+' · '+(s.notes.length?s.notes.map(A.noteName).join(' '):'休止')),step:0})},
 choosePart(e){if(this.busy())return;this.setData({segment:Number(e.detail.value)});this.renderPart()},
 choosePreset(e){if(!this.busy())this.setData({preset:Number(e.detail.value)})},
 busy(){return ['uploading','starting','playing','stopping'].includes(this.data.phase)},
 async play(){if(!this.compiled||this.busy())return;wx.showModal({title:'用乐器试听',content:this.data.presets[this.data.preset]+' · '+this.data.parts[this.data.segment]+'\n只传音符与节拍。请先结束手动演奏。',confirmText:'开始试听',success:async r=>{if(!r.confirm||!this.visible)return;try{await this.session.play(this.compiled,this.data.segment,this.data.preset,{whole:true,offline:this.compiled.segments.length===1&&!!this.hub.snapshot().observer,title:this.data.title})}catch(e){this.setData({error:e.message||'试听未启动'})}}})},
 async stop(){await this.session.stop()},
 openOnline(){if(this.busy())return;this.setData({onlineOpen:true,loading:true,error:''});this.client.online('').then(r=>{if(this.visible)this.setData({onlineItems:r.items})}).catch(e=>this.setData({error:e.message})).finally(()=>this.setData({loading:false}))},
 closeOnline(){this.setData({onlineOpen:false})},
 async downloadOnline(e){if(this.data.loading)return;this.setData({loading:true,error:''});try{const r=await this.client.download(e.currentTarget.dataset.id,this.data.quantize);if(!this.visible)return;this.setScore({title:r.source.title,source:r.source.source,compiled:r.compiled,warnings:r.warnings});this.setData({onlineOpen:false})}catch(e){this.setData({error:e.message})}finally{if(this.visible)this.setData({loading:false})}},
 toggleGrid(e){this.setData({quantize:!!e.detail.value})},
 importMidi(){if(this.busy())return;wx.chooseMessageFile({count:1,type:'file',extension:['mid','midi'],success:r=>{const f=r.tempFiles[0];if(f.size>1048576)return this.setData({error:'MIDI文件不能超过1MB'});this.setData({loading:true,error:''});wx.getFileSystemManager().readFile({filePath:f.path,success:async a=>{try{const s=await this.client.importMidi(a.data,this.data.quantize);if(this.visible)this.setScore({title:f.name.replace(/\.midi?$/i,''),source:'导入 MIDI',compiled:s.compiled,warnings:s.warnings})}catch(e){if(this.visible)this.setData({error:e.message})}finally{if(this.visible)this.setData({loading:false})}},fail:()=>this.setData({loading:false,error:'无法读取所选文件'})})}})},
 openEdit(){if(!this.compiled||this.busy())return;this.setData({editOpen:true,editStep:0});this.loadEdit()},
 closeEdit(){this.setData({editOpen:false})},
 editSelect(e){this.setData({editStep:Number(e.detail.value)});this.loadEdit()},
 loadEdit(){const s=this.compiled.segments[this.data.segment].steps[this.data.editStep];this.setData({editNotes:s.notes.join(','),editDuration:String(s.samples/48)})},
 inputNotes(e){this.setData({editNotes:e.detail.value})},inputDuration(e){this.setData({editDuration:e.detail.value})},
 saveEdit(){try{const notes=this.data.editNotes.trim()?this.data.editNotes.split(/[,，\s]+/).map(Number):[],samples=Math.round(Number(this.data.editDuration)*48),all=this.compiled.steps.map(s=>({notes:s.notes.slice(),samples:s.samples}));
  // Copy all durations, edit only the selected step in the whole sequence.
  const index=this.data.segment*64+this.data.editStep;all[index]={notes,samples};let at=0;
  this.compiled=A.compileTimeline(all.map(s=>{const startMs=at/48;at+=s.samples;return {startMs,endMs:at/48,notes:s.notes}}));this.setData({editOpen:false,source:'已修订曲谱',error:''});this.renderPart()
 }catch(e){this.setData({error:e.message})}},
 // ---- T2 事件录音（非音频）：捕获 FPGA 接受的演奏事件，回放走 FPGA 重合成 ----
 toggleRecording(){
  if(this.data.rec.active){
   if(this.recSink){this.recSink.off();this.recSink=null}
   require('../../services/instrument_model').setEventFrameSink(null)
   require('../../services/device_session').setEventSink(null)
   const snap=this.recorder.toJSON(this.data.title||'演奏录音')
   this.recorder.stop()
   const seconds=(snap.durationSamples/48000.529661).toFixed(1)
   this.setData({rec:{active:false,count:snap.eventCount,seconds,loss:snap.hasLoss,saved:false}})
   if(snap.eventCount>0){
    wx.setStorageSync('event_recording_'+Date.now(),snap)
    wx.setStorageSync('event_recording_latest',snap)
    this.setData({rec:Object.assign({},this.data.rec,{saved:true})})
    if(snap.durationSamples>2880000)wx.showToast({title:'超过60秒，回放可能被截断',icon:'none'})
   }
   this.recorder=null
  }else{
   this.recorder=R.createEventRecorder()
   this.recorder.start()
   const frameSink=b=>this.recorder&&this.recorder.onFrame(new Uint8Array(b))
   require('../../services/instrument_model').setEventFrameSink(frameSink)
   require('../../services/device_session').setEventSink(frameSink)
   this.recSink={off:()=>{}}
   this.setData({rec:{active:true,count:0,seconds:'0.0',loss:false,saved:false}})
  }
 },
 playRecording(){
  const snap=wx.getStorageSync('event_recording_latest')
  if(!snap||!snap.eventCount){this.setData({error:'还没有已保存的演奏录音'});return}
  try{
   const rec=R.createEventRecorder().staticFromJSON(snap)
   const j=rec.toJSON()
   const timeline=R.eventsToTimeline(j.events.map(e=>({sample:e.s,on:e.k,region:e.r,note:e.n,preset:e.p,generation:e.g})))
   const compiled=A.compileTimeline(timeline)
   if(snap.hasLoss)wx.showToast({title:'录音含丢失事件，回放不完整',icon:'none'})
   this.setScore({title:snap.label||'演奏录音',source:'演奏录音 · 事件重合成（非音频回放）',compiled,warnings:(compiled.warnings||[]).concat(snap.hasLoss?['录音期间有事件丢失（已标记）']:[])})
  }catch(e){this.setData({error:e.message||'录音无法编译'})}
 },
 openDevice(){wx.switchTab({url:'/pages/index/index'})}
})
