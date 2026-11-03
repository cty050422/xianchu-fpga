// Deterministic local single-melody estimate, never an acoustic grade or PCM source.
import {createRequire}from'node:module';const require=createRequire(import.meta.url);
const {compileTimeline}=require('../wechat_miniprogram/utils/audition_score.js');
const fail=code=>Object.assign(new Error(code),{code});
export function transcribeMono(input,rate){
 if(!input||input.length<rate*.3||input.length>rate*30||!Number.isFinite(rate)||rate<8000||rate>48000)throw fail('TRANSCRIPTION_LIMIT');
 const fs=8000,frames=Math.floor(input.length*fs/rate),audio=new Float32Array(frames);
 // Average source samples in each target time cell; avoids point-sampling high-rate PCM.
 for(let i=0;i<frames;i++){let sum=0,n=0;for(let j=Math.floor(i*rate/fs);j<Math.floor((i+1)*rate/fs);j++){sum+=input[j];n++}audio[i]=n?sum/n:0}
 const hop=128,window=768,track=[];let voiced=0,confidence=0;
 for(let at=0;at+window<=audio.length;at+=hop){
  let mean=0,energy=0;for(let i=0;i<512;i++)mean+=audio[at+i];mean/=512;
  for(let i=0;i<512;i++)energy+=(audio[at+i]-mean)**2;
  let midi=null,conf=0;
  if(energy/512>1e-5){
   const d=new Float64Array(125);let sum=0;
   for(let lag=1;lag<125;lag++){let v=0;for(let i=0;i<512;i++){const z=audio[at+i]-audio[at+i+lag];v+=z*z}sum+=v;d[lag]=sum?v*lag/sum:1}
   for(let lag=3;lag<123;lag++)if(d[lag]<.13){while(lag<123&&d[lag+1]<d[lag])lag++;const a=d[lag-1],b=d[lag],c=d[lag+1],den=a-2*b+c,period=lag+(den?(a-c)/(2*den):0),hz=fs/period;
    const n=Math.round(69+12*Math.log2(hz/440));conf=Math.max(0,1-b);if(n>=36&&n<=96&&conf>.87)midi=n;break}
  }
  if(midi!==null){voiced++;confidence+=conf}track.push({atMs:(at+256)/fs*1000,midi,conf});
 }
 // Median vote over three frames suppresses isolated octave errors; it does not
 // invent a harmony. Low-confidence material is left unvoiced for user review.
 const smooth=track.map((p,i)=>{const near=track.slice(Math.max(0,i-1),i+2).map(x=>x.midi),count=near.filter(n=>n===p.midi).length;return {...p,midi:count>=2?p.midi:null}});
 const runs=[];for(const p of smooth){const last=runs.at(-1);if(last&&last.midi===p.midi)last.end=p.atMs+8;else runs.push({midi:p.midi,start:p.atMs-8,end:p.atMs+8})}
 const timeline=[];
 for(const r of runs){if(r.midi===null||r.end-r.start<48)continue;let start=Math.max(0,Math.round((r.start-24)/20)*20),end=Math.min(Math.round(frames/fs*50)*20,Math.round((r.end-24)/20)*20);
  const last=timeline.at(-1);if(last&&start<last.endMs+20)start=last.endMs;if(!last&&start<20)start=0;if(end-start<20)continue;timeline.push({startMs:start,endMs:end,notes:[r.midi]})}
 if(!timeline.length)throw fail('NO_MELODY');
 return {method:'monophonic_yin',needsConfirmation:true,confidence:Math.round(confidence/Math.max(1,voiced)*100)/100,
  timingResolutionMs:20,timeline,compiled:compileTimeline(timeline),warnings:['仅适用于清晰单音旋律；和弦、鼓点、人声伴奏可能误判','音高与节拍需要预览确认，不能还原原唱音色']};
}
export function parseMidi(b,{quantizeMs=0}={}){
 if(quantizeMs!==0 && quantizeMs!==20)throw fail('QUANTIZATION_UNSUPPORTED');
 if(!Buffer.isBuffer(b)||b.length<14||b.length>1024*1024||b.toString('ascii',0,4)!=='MThd'||b.readUInt32BE(4)!==6)throw fail('MIDI_FORMAT');
 const format=b.readUInt16BE(8),tracks=b.readUInt16BE(10),division=b.readUInt16BE(12);
 if(division&32768)throw fail('MIDI_SMPTE_UNSUPPORTED');if(format>1||!division||tracks<1||tracks>32)throw fail('MIDI_FORMAT');
 const events=[];let off=14,total=0;
 for(let tr=0;tr<tracks;tr++){
  if(off+8>b.length||b.toString('ascii',off,off+4)!=='MTrk')throw fail('MIDI_TRACK');const end=off+8+b.readUInt32BE(off+4);off+=8;if(end>b.length)throw fail('MIDI_TRACK');let tick=0,running=0;
  function byte(){if(off>=end)throw fail('MIDI_TRUNCATED');return b[off++]}
  function vlq(){let x=0;for(let i=0;i<4;i++){const v=byte();x=x*128+(v&127);if(!(v&128))return x}throw fail('MIDI_VLQ')}
  while(off<end){tick+=vlq();let st=byte();if(st<128){if(!running)throw fail('MIDI_RUNNING_STATUS');off--;st=running}else if(st<240)running=st;
   if(++total>16384)throw fail('MIDI_EVENT_LIMIT');
   if(st===255){running=0;const type=byte(),len=vlq();if(off+len>end)throw fail('MIDI_META');if(type===81){if(len!==3)throw fail('MIDI_TEMPO');const tempo=b.readUIntBE(off,3);if(!tempo)throw fail('MIDI_TEMPO');events.push({tick,tempo})}off+=len}
   else if(st===240||st===247){running=0;const size=vlq();off+=size;if(off>end)throw fail('MIDI_SYSEX')}
   else if(st<240){const type=st>>4,ch=st&15,a=byte(),v=(type===12||type===13)?0:byte();if(a>127||v>127)throw fail('MIDI_DATA');
    if(type===9||type===8){if(ch===9)throw fail('MIDI_DRUMS_UNSUPPORTED');events.push({tick,on:type===9&&v!==0,note:a,ch})}
    if(type===11&&a===64&&v>=64)throw fail('MIDI_SUSTAIN_UNSUPPORTED');
    if(type===14&&(a!==0||v!==64))throw fail('MIDI_PITCH_BEND_UNSUPPORTED');
   }else throw fail('MIDI_STATUS');
  }
 }
 if(off!==b.length)throw fail('MIDI_TRAILING_DATA');
 events.sort((a,b)=>a.tick-b.tick||(a.tempo?-1:b.tempo?1:0));let previous=0,ms=0,tempo=500000,held=new Map(),timeline=[];
 for(let i=0;i<events.length;){const tick=events[i].tick;const nextMs=ms+(tick-previous)*tempo/division/1000;
  if(nextMs>120000)throw fail('SCORE_TOO_LONG');
  if(nextMs>ms && held.size)timeline.push({startMs:ms,endMs:nextMs,notes:[...held.values()].sort((a,b)=>a-b)});
  while(i<events.length&&events[i].tick===tick){const e=events[i++];if(e.tempo)tempo=e.tempo;else{const key=e.ch+':'+e.note;if(e.on){if(held.has(key))throw fail('MIDI_REPEATED_HELD_NOTE');held.set(key,e.note)}else held.delete(key)}}previous=tick;ms=nextMs;
 }
 if(held.size)throw fail('MIDI_UNRELEASED_NOTE');if(!timeline.length)throw fail('NO_MELODY');
 let collapsed=0;
 if(quantizeMs){timeline=timeline.flatMap(t=>{const startMs=Math.round(t.startMs/20)*20,endMs=Math.round(t.endMs/20)*20;if(endMs<=startMs){collapsed++;return []}return [{...t,startMs,endMs}]})}
 return {method:'midi_events',needsConfirmation:true,quantizeMs,collapsedIntervals:collapsed,timeline,compiled:compileTimeline(timeline),warnings:['仅导入音高与节拍；使用乐器所选音色','最多四个同时音；不支持鼓轨、踏板及MIDI弯音',...(quantizeMs?['已按20毫秒网格量化；合并的极短状态区间：'+collapsed]:[])]};
}
