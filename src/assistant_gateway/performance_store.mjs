import fs from 'node:fs';import path from 'node:path';import {randomBytes,createHash,timingSafeEqual} from 'node:crypto';
import {inspectMusicAudio,MUSIC_LIMITS,wavHeader} from './performance_audio.mjs';
const fail=code=>Object.assign(new Error(code),{code});
const sha=b=>createHash('sha256').update(b).digest('hex');
const idOK=s=>typeof s==='string'&&/^take-[a-f0-9]{24}$/.test(s);
export function openPerformanceStore({directory,clock=Date.now,maxTakes=128,maxBytes=256*1024*1024}={}){
  if(!directory)throw fail('STORE_DIRECTORY_REQUIRED');fs.mkdirSync(directory,{recursive:true});
  const records=new Map();let producerAt=null;
  function save(x){const file=path.join(directory,x.id+'.json'),tmp=file+'.tmp';fs.writeFileSync(tmp,JSON.stringify(x));fs.renameSync(tmp,file);records.set(x.id,x)}
  for(const file of fs.readdirSync(directory).filter(x=>/^take-[a-f0-9]{24}\.json$/.test(x))){const x=JSON.parse(fs.readFileSync(path.join(directory,file),'utf8'));if(!idOK(x.id)||!['phone_mic','instrument_pcm'].includes(x.source))throw fail('STORE_CORRUPT');records.set(x.id,x);if(x.state==='capturing'){x.state='incomplete';x.error='采集服务重启，录音不完整';x.ticketHash=null;save(x)}}
  function get(id){if(!idOK(id)||!records.has(id))throw fail('TAKE_NOT_FOUND');const x=records.get(id);if(x.state==='capturing'&&clock()>=x.ticketExpires){x.state='incomplete';x.error='采集超时，录音未完整返回';x.ticketHash=null;save(x)}else if(x.state==='pending_capture'&&clock()-x.createdAt>15000){x.state='incomplete';x.error='录音接收器未及时开始采集';save(x)}return x}
  function pub(x){return {id:x.id,source:x.source,mode:x.mode,title:x.title,song:x.song,simulated:x.simulated,createdAt:x.createdAt,state:x.state,error:x.error||null,audio:x.audio||null,assessment:x.assessment||null,stopRequested:!!x.stopRequested,capturedFrames:Math.floor((x.capturedBytes||0)/2)}}
  function quota(extra=0){const used=[...records.values()].reduce((n,x)=>n+(x.audio?.bytes||x.capturedBytes||0),0);if(used+extra>maxBytes)throw fail('RECORDING_STORAGE_FULL')}
  function capture(id,ticket){const x=get(id);const key=typeof ticket==='string'?sha(ticket):'';if(!x.ticketHash||key.length!==x.ticketHash.length||!timingSafeEqual(Buffer.from(key),Buffer.from(x.ticketHash))||clock()>=x.ticketExpires)throw fail('CAPTURE_UNAUTHORIZED');return x}
  return {
    capabilities(){return {protocol:'performances/v1',sources:['phone_mic','instrument_pcm'],limits:{maxSeconds:120,maxBytes:MUSIC_LIMITS.maxBytes,maxTakes},receiverOnline:producerAt!==null&&clock()-producerAt<3000,instrumentCaptureHardwareVerified:false,preciseDeviceEvents:false,storage:'project-local',libraryScope:'同一项目的已授权客户端共享作品',liveApiCalls:0}},
    create(input){
      if(!input||typeof input.requestId!=='string'||!/^[A-Za-z0-9-]{8,64}$/.test(input.requestId)||!['phone_mic','instrument_pcm'].includes(input.source)||!['free','guided','challenge'].includes(input.mode))throw fail('TAKE_FORMAT');
      const title=typeof input.title==='string'?input.title.trim().slice(0,100):'未命名演奏';
      const song=input.song&&typeof input.song==='object'?{title:String(input.song.title||'').slice(0,100),id:String(input.song.id||'').slice(0,80),hash:String(input.song.hash||'').slice(0,80),bpm:Number.isFinite(input.song.bpm)?input.song.bpm:null}:null;
      const normalized={requestId:input.requestId,source:input.source,mode:input.mode,title,song,simulated:input.simulated===true},requestHash=sha(JSON.stringify(normalized));
      const old=[...records.values()].find(x=>x.requestId===input.requestId);if(old){if(old.requestHash!==requestHash)throw fail('IDEMPOTENCY_CONFLICT');return {created:false,take:pub(old)}}
      if(records.size>=maxTakes)throw fail('RECORDING_STORAGE_FULL');quota();
      const x={...normalized,requestHash,id:'take-'+randomBytes(12).toString('hex'),createdAt:clock(),state:input.source==='instrument_pcm'?'pending_capture':'awaiting_audio',assessment:null,audio:null};save(x);return {created:true,take:pub(x)}
    },
    list(){return [...records.keys()].map(get).sort((a,b)=>b.createdAt-a.createdAt||b.id.localeCompare(a.id)).map(pub)},
    detail(id){return pub(get(id))},
    putAudio(id,buffer,mime){const x=get(id);if(x.source!=='phone_mic')throw fail('SOURCE_CONFLICT');const info=inspectMusicAudio(buffer,mime),digest=sha(buffer);if(x.audio){if(x.audio.sha256===digest)return pub(x);throw fail('AUDIO_CONFLICT')}quota(buffer.length);const file=path.join(directory,id+'.'+info.extension);fs.writeFileSync(file+'.tmp',buffer);fs.renameSync(file+'.tmp',file);x.audio={...info,sha256:digest};x.state='ready';x.error=null;save(x);return pub(x)},
    setAssessment(id,result){const x=get(id);x.assessment={...result,evidenceOrigin:'client_recorded_device_data',hardwareVerification:false};save(x);return pub(x)},
    audio(id){const x=get(id);if(x.state!=='ready'||!x.audio)throw fail('AUDIO_NOT_READY');return {file:path.join(directory,id+'.'+x.audio.extension),mime:x.audio.mime,bytes:x.audio.bytes}},
    remove(id){const x=get(id);for(const suffix of ['.json','.json.tmp','.wav','.mp3','.part']){const file=path.join(directory,x.id+suffix);if(fs.existsSync(file))fs.unlinkSync(file)}records.delete(id);return {deleted:true,id}},
    stop(id){const x=get(id);x.stopRequested=true;if(x.state==='pending_capture')x.state='cancelled';save(x);return pub(x)},
    claim(){producerAt=clock();const x=[...records.values()].find(x=>x.source==='instrument_pcm'&&x.state==='pending_capture');if(!x)return null;const ticket=randomBytes(24).toString('hex');x.state='capturing';x.ticketHash=sha(ticket);x.ticketExpires=clock()+180000;x.capturedBytes=0;x.nextChunk=0;x.stopRequested=false;save(x);return {takeId:x.id,ticket,sampleRate:48000,channels:1,maxSeconds:120}},
    captureStatus(id,ticket){const x=capture(id,ticket);return {state:x.state,stopRequested:!!x.stopRequested,nextChunk:x.nextChunk,capturedFrames:x.capturedBytes/2}},
    append(id,ticket,sequence,offset,buffer){
      const x=capture(id,ticket);if(x.state!=='capturing')throw fail('CAPTURE_NOT_ACTIVE');if(!Number.isSafeInteger(sequence)||sequence<0||!Number.isSafeInteger(offset)||offset<0||!Buffer.isBuffer(buffer)||!buffer.length||buffer.length>32768||buffer.length%2)throw fail('CAPTURE_FORMAT');
      const digest=sha(buffer);if(sequence===x.nextChunk-1&&x.lastChunkHash===digest&&offset===x.lastOffset)return {accepted:true,replayed:true,nextChunk:x.nextChunk};
      if(sequence!==x.nextChunk||offset!==x.capturedBytes/2){x.state='incomplete';x.error='采集缺片或顺序错误';save(x);throw fail('CAPTURE_SEQUENCE')}
      if(x.capturedBytes+buffer.length>48000*2*120){x.state='incomplete';x.error='超过录音时长上限';save(x);throw fail('AUDIO_TOO_LONG')}quota(buffer.length);
      fs.appendFileSync(path.join(directory,id+'.part'),buffer);producerAt=clock();x.lastOffset=offset;x.lastChunkHash=digest;x.capturedBytes+=buffer.length;x.nextChunk++;save(x);return {accepted:true,nextChunk:x.nextChunk}
    },
    finish(id,ticket,body){
      const x=capture(id,ticket);if(x.state==='ready'&&body.complete===true&&body.frames===x.capturedBytes/2)return pub(x);if(x.state!=='capturing')throw fail('CAPTURE_NOT_ACTIVE');
      if(body.complete!==true||!x.capturedBytes||body.frames!==x.capturedBytes/2){x.state='incomplete';x.error=String(body.reason||'采集被中断或样本数不符').slice(0,100);save(x);return pub(x)}
      const pcm=fs.readFileSync(path.join(directory,id+'.part')),buffer=Buffer.concat([wavHeader(pcm.length),pcm]),info=inspectMusicAudio(buffer,'audio/wav');fs.writeFileSync(path.join(directory,id+'.wav.tmp'),buffer);fs.renameSync(path.join(directory,id+'.wav.tmp'),path.join(directory,id+'.wav'));fs.unlinkSync(path.join(directory,id+'.part'));x.audio={...info,sha256:sha(buffer)};x.state='ready';x.error=null;save(x);return pub(x)
    }
  }
}
