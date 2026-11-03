// Music recordings have their own limits; never route them into paid ASR.
export const MUSIC_LIMITS=Object.freeze({maxBytes:16*1024*1024,maxSeconds:120});
const fail=code=>Object.assign(new Error(code),{code});
export function wavHeader(bytes,rate=48000,channels=1){const b=Buffer.alloc(44);b.write('RIFF');b.writeUInt32LE(bytes+36,4);b.write('WAVEfmt ',8);b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(channels,22);b.writeUInt32LE(rate,24);b.writeUInt32LE(rate*channels*2,28);b.writeUInt16LE(channels*2,32);b.writeUInt16LE(16,34);b.write('data',36);b.writeUInt32LE(bytes,40);return b}
export function inspectMusicAudio(buffer,mime){
  if(!Buffer.isBuffer(buffer)||!buffer.length)throw fail('AUDIO_EMPTY');if(buffer.length>MUSIC_LIMITS.maxBytes)throw fail('AUDIO_TOO_LARGE');
  const kind=String(mime||'').split(';')[0].toLowerCase();let info;
  if(['audio/wav','audio/x-wav','audio/wave'].includes(kind))info=inspectWav(buffer);
  else if(['audio/mp3','audio/mpeg'].includes(kind))info=inspectMp3(buffer);
  else throw fail('AUDIO_FORMAT_UNSUPPORTED');
  if(info.durationMs>MUSIC_LIMITS.maxSeconds*1000)throw fail('AUDIO_TOO_LONG');return {...info,bytes:buffer.length};
}
function inspectWav(b){
  if(b.length<44||b.toString('ascii',0,4)!=='RIFF'||b.toString('ascii',8,12)!=='WAVE'||b.readUInt32LE(4)!==b.length-8)throw fail('AUDIO_CONTAINER_MISMATCH');
  let fmt=null,data=null,off=12,chunks=0;
  while(off+8<=b.length&&chunks++<256){const tag=b.toString('ascii',off,off+4),size=b.readUInt32LE(off+4),at=off+8;if(at+size>b.length)throw fail('AUDIO_CONTAINER_MISMATCH');if(tag==='fmt '){if(fmt||size<16)throw fail('AUDIO_CONTAINER_MISMATCH');fmt={format:b.readUInt16LE(at),channels:b.readUInt16LE(at+2),rate:b.readUInt32LE(at+4),byteRate:b.readUInt32LE(at+8),align:b.readUInt16LE(at+12),bits:b.readUInt16LE(at+14)}}if(tag==='data'){if(data)throw fail('AUDIO_CONTAINER_MISMATCH');data={at,size}}off=at+size+(size&1)}
  if(!fmt||!data||off!==b.length||fmt.format!==1||fmt.bits!==16||![1,2].includes(fmt.channels)||![8000,11025,16000,22050,24000,32000,44100,48000].includes(fmt.rate)||fmt.align!==fmt.channels*2||fmt.byteRate!==fmt.rate*fmt.align||!data.size||data.size%fmt.align)throw fail('AUDIO_CONTAINER_MISMATCH');
  const frames=data.size/fmt.align,durationMs=Math.round(frames/fmt.rate*1000);if(durationMs>120000)throw fail('AUDIO_TOO_LONG');
  let peak=0,squares=0,clipped=0;const waveform=Array(64).fill(0);
  for(let i=0;i<frames;i++){for(let c=0;c<fmt.channels;c++){const v=b.readInt16LE(data.at+(i*fmt.channels+c)*2)/32768;peak=Math.max(peak,Math.abs(v));squares+=v*v;if(Math.abs(v)>.998)clipped++}const v=Math.abs(b.readInt16LE(data.at+i*fmt.align)/32768),bin=Math.min(63,Math.floor(i*64/frames));waveform[bin]=Math.max(waveform[bin],v)}
  const rms=Math.sqrt(squares/(frames*fmt.channels)),pitch=[];const stride=Math.max(1,Math.round(fmt.rate/16000)),analysisRate=fmt.rate/stride,window=2048;
  if(rms>.0003&&frames>=window*stride){for(let j=0;j<Math.min(12,Math.floor(frames/(window*stride)));j++){const at=Math.floor(j*(frames-window*stride)/Math.max(1,Math.min(12,Math.floor(frames/(window*stride)))-1));const samples=Array.from({length:window},(_,i)=>b.readInt16LE(data.at+(at+i*stride)*fmt.align)/32768);const f=yin(samples,analysisRate);if(f)pitch.push({atMs:Math.round(at/fmt.rate*1000),hz:f.hz,confidence:f.confidence})}}
  const sorted=pitch.map(x=>x.hz).sort((a,b)=>a-b);
  return {mime:'audio/wav',extension:'wav',sampleRate:fmt.rate,channels:fmt.channels,frames,durationMs,analysis:{decoded:true,silent:rms<.0003,peak,rms,clippedRatio:clipped/(frames*fmt.channels),waveform:waveform.map(v=>Math.round(v*1000)/1000),pitchHz:sorted.length?sorted[Math.floor(sorted.length/2)]:null,pitchSegments:pitch,acousticScore:null,pitchScope:'sampled_monophonic_segments_not_chord_or_song_grade'}};
}
function yin(x,rate){const min=Math.max(2,Math.floor(rate/1500)),max=Math.min(1023,Math.ceil(rate/55)),d=new Float64Array(max+1);let sum=0;for(let tau=1;tau<=max;tau++){let v=0;for(let i=0;i<1024;i++){const a=x[i]-x[i+tau];v+=a*a}sum+=v;d[tau]=sum?v*tau/sum:1}let best=-1;for(let t=min;t<max;t++)if(d[t]<.14){while(t+1<max&&d[t+1]<d[t])t++;best=t;break}if(best<0)return null;const a=d[best-1],b=d[best],c=d[best+1]||b,den=a-2*b+c,lag=best+(den?(a-c)/(2*den):0);return {hz:Math.round(rate/lag*10)/10,confidence:Math.round((1-b)*1000)/1000}}
function inspectMp3(b){
  let at=0;if(b.toString('ascii',0,3)==='ID3'){if(b.length<10||[...b.subarray(6,10)].some(v=>v&128))throw fail('AUDIO_CONTAINER_MISMATCH');at=10+((b[6]<<21)|(b[7]<<14)|(b[8]<<7)|b[9]);if(b[3]===4&&(b[5]&16))at+=10}
  let seconds=0,frames=0,rate=0,channels=0;const rates=[44100,48000,32000],v1=[0,32,40,48,56,64,80,96,112,128,160,192,224,256,320],v2=[0,8,16,24,32,40,48,56,64,80,96,112,128,144,160];
  while(at+4<=b.length){if(b.length-at===128&&b.toString('ascii',at,at+3)==='TAG'){at=b.length;break}if(b[at]!==255||(b[at+1]&224)!==224)throw fail('AUDIO_CONTAINER_MISMATCH');const version=(b[at+1]>>3)&3,layer=(b[at+1]>>1)&3,index=b[at+2]>>4,sr=(b[at+2]>>2)&3;if(version===1||layer!==1||index===0||index===15||sr===3)throw fail('AUDIO_CONTAINER_MISMATCH');const r=rates[sr]/(version===3?1:version===2?2:4),br=(version===3?v1:v2)[index]*1000,n=Math.floor((version===3?144:72)*br/r)+((b[at+2]>>1)&1),ch=(b[at+3]>>6)===3?1:2;if(at+n>b.length||rate&&rate!==r||channels&&channels!==ch)throw fail('AUDIO_CONTAINER_MISMATCH');rate=r;channels=ch;seconds+=(version===3?1152:576)/r;frames++;at+=n;if(seconds>120)throw fail('AUDIO_TOO_LONG')}
  if(at!==b.length||frames<2)throw fail('AUDIO_CONTAINER_MISMATCH');return {mime:'audio/mpeg',extension:'mp3',sampleRate:rate,channels,durationMs:Math.round(seconds*1000),analysis:{decoded:false,pitchHz:null,acousticScore:null,waveform:null,reason:'压缩录音已校验容器；转谱单独解码，未生成声学评分'}};
}
