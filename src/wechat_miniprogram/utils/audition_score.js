// Symbolic music only. Same compiler for local service, phone and tests.
const err=(code,message)=>Object.assign(new Error(message),{code})
function crc(bytes){let c=0;for(const b of bytes){c^=b;for(let j=0;j<8;j++)c=(c&128)?((c<<1)^7)&255:(c<<1)&255}return c}
function frame(op,seq,payload){const a=[165,90,1,op,payload.length,seq&255].concat(payload);a.push(crc(a.slice(2)));return Uint8Array.from(a).buffer}
function stepPayload(step,i){const n=step.notes.concat([0,0,0,0]).slice(0,4),d=step.samples;return [i].concat(n,[d&255,(d>>>8)&255,(d>>>16)&255])}
function compileTimeline(timeline){
 if(!Array.isArray(timeline)||!timeline.length||timeline.length>1024)throw err('SCORE_LENGTH','需要1–1024个音符区间')
 let steps=[],end=0,total=0
 function add(notes,samples){
  if(samples<960||samples>2880000)throw err('DURATION_RANGE','每步时长须为20毫秒至60秒')
  if(notes.length>4)throw err('POLYPHONY','同一时刻最多四个音，不能自动丢弃声部')
  if(notes.some(n=>!Number.isInteger(n)||n<36||n>96)||new Set(notes).size!==notes.length)throw err('PITCH_RANGE','音符应在C2–C7之间，和弦不能重复音高')
  steps.push({notes:notes.slice().sort((a,b)=>a-b),samples});total+=samples
 }
 for(const item of timeline){
  if(!item||!Number.isFinite(item.startMs)||!Number.isFinite(item.endMs)||item.startMs<0||item.endMs<=item.startMs||!Array.isArray(item.notes))throw err('SCORE_FORMAT','音符时间或格式无效')
  const start=Math.round(item.startMs*48),stop=Math.round(item.endMs*48)
  if(start<end)throw err('OVERLAPPING_STEPS','重叠音符必须先整理为和弦区间')
  if(start>end)add([],start-end)
  add(item.notes,stop-start);end=stop
 }
 if(end>5760000)throw err('SCORE_TOO_LONG','试听最长两分钟，请拆分片段')
 const segments=[]
 for(let i=0;i<steps.length;i+=64){const part=steps.slice(i,i+64);segments.push({steps:part,crc:crc(part.flatMap(stepPayload)),samples:part.reduce((a,s)=>a+s.samples,0)})}
 return {steps,samples:total,durationMs:Math.round(total/48),segments,crc:segments.length===1?segments[0].crc:null,scope:'symbolic_fpga_synthesis',warnings:['采用所选合成音色；每步末尾留10毫秒换音间隔']}
}
function fromCatalog(score,bpm){
 const tempo=Number(bpm||score.bpm);if(!Number.isFinite(tempo)||tempo<30||tempo>240)throw err('BPM','速度范围30–240')
 let at=0;const map=[60,62,64,67]
 return compileTimeline(score.notes.map(n=>{const start=at;at+=Number(n.beats)*60000/tempo;let notes=[];
  if(n.midi!==undefined)notes=[n.midi];else if(n.zone===null||n.rest)notes=[];else if(Array.isArray(n.midis))notes=n.midis;else if(Array.isArray(n.zones))notes=n.zones.map(z=>map[z]);else notes=[map[n.zone]];
  return {startMs:start,endMs:at,notes}
 }))
}
function noteName(n){return ['C','C♯','D','E♭','E','F','F♯','G','A♭','A','B♭','B'][n%12]+(Math.floor(n/12)-1)}
module.exports={crc,frame,stepPayload,compileTimeline,fromCatalog,noteName}
