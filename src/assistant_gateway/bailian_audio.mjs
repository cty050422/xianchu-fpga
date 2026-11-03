// Qwen-ASR compatible API -> chat compatible API -> Qwen-TTS DashScope API.
// Exact endpoints/models are operator configuration. No automatic paid fallback.
// Primary contracts: help.aliyun.com/zh/model-studio/qwen-asr-api-reference
// and help.aliyun.com/zh/model-studio/qwen-tts-api (consulted 2026-10-21).
import {MAX_INPUT,MAX_OUTPUT,mockAudioPipeline} from './audio.mjs';
const fail=code=>Object.assign(new Error(code),{code});
export function pcmToWave(pcm,rate=16000){
 if(!Buffer.isBuffer(pcm)||pcm.length%2||pcm.length>MAX_INPUT)throw fail('PCM_FORMAT');
 const h=Buffer.alloc(44);h.write('RIFF');h.writeUInt32LE(36+pcm.length,4);h.write('WAVEfmt ',8);
 h.writeUInt32LE(16,16);h.writeUInt16LE(1,20);h.writeUInt16LE(1,22);h.writeUInt32LE(rate,24);
 h.writeUInt32LE(rate*2,28);h.writeUInt16LE(2,32);h.writeUInt16LE(16,34);h.write('data',36);h.writeUInt32LE(pcm.length,40);
 return Buffer.concat([h,pcm]);
}
export function waveToPCM(wav){
 if(!Buffer.isBuffer(wav)||wav.length<44||wav.toString('ascii',0,4)!=='RIFF'||wav.toString('ascii',8,12)!=='WAVE'||wav.readUInt32LE(4)+8!==wav.length)throw fail('TTS_WAVE_FORMAT');
 let format=false,pcm=null;
 for(let i=12;i+8<=wav.length;){
  const tag=wav.toString('ascii',i,i+4),n=wav.readUInt32LE(i+4),start=i+8;
  if(start+n>wav.length)throw fail('TTS_WAVE_FORMAT');
  if(tag==='fmt '){if(n<16||wav.readUInt16LE(start)!==1||wav.readUInt16LE(start+2)!==1||wav.readUInt32LE(start+4)!==24000||wav.readUInt16LE(start+12)!==2||wav.readUInt16LE(start+14)!==16)throw fail('TTS_WAVE_FORMAT');format=true;}
  if(tag==='data'){if(pcm||n%2||!n||n>MAX_OUTPUT)throw fail('TTS_WAVE_FORMAT');pcm=wav.subarray(start,start+n);}
  i=start+n+(n&1);
 }
 if(!format||!pcm)throw fail('TTS_WAVE_FORMAT');return Buffer.from(pcm);
}
async function bounded(response,max){
 if(!response.ok)throw fail('PROVIDER_HTTP_'+response.status);
 const length=Number(response.headers.get('content-length'));if(length>max)throw fail('PROVIDER_TOO_LARGE');
 let n=0;const pieces=[];
 for await(const b of response.body){n+=b.length;if(n>max){await response.body.cancel?.().catch(()=>{});throw fail('PROVIDER_TOO_LARGE');}pieces.push(b);}
 return Buffer.concat(pieces);
}
export class BailianAudioPipeline {
 constructor({apiKey,asrUrl,chatUrl,ttsUrl,asrModel,chatModel,ttsModel,voice,audioHosts,fetchImpl=fetch}){
  for(const value of [apiKey,asrUrl,chatUrl,ttsUrl,asrModel,chatModel,ttsModel,voice])if(!value)throw fail('AUDIO_CONFIG_REQUIRED');
  for(const endpoint of [asrUrl,chatUrl,ttsUrl]){const u=new URL(endpoint);if(u.protocol!=='https:'||u.username||u.password)throw fail('AUDIO_ENDPOINT_REQUIRED_HTTPS');}
  if(!Array.isArray(audioHosts)||!audioHosts.length)throw fail('AUDIO_DOWNLOAD_ALLOWLIST_REQUIRED');
  Object.assign(this,{apiKey,asrUrl,chatUrl,ttsUrl,asrModel,chatModel,ttsModel,voice,audioHosts,fetchImpl});
  this.name='bailian-ptt';this.mode='live';this.history=new Map();
 }
 async process({pcm,client,signal}){
  const check=()=>{if(signal.aborted)throw fail('CANCELLED');};
  const call=async(url,body)=>{check();const r=await this.fetchImpl(url,{method:'POST',redirect:'error',headers:{'Content-Type':'application/json',Authorization:`Bearer ${this.apiKey}`},body:JSON.stringify(body),signal});const b=await bounded(r,2*1024*1024);check();return JSON.parse(b.toString('utf8'));};
  const asr=await call(this.asrUrl,{model:this.asrModel,stream:false,messages:[{role:'user',content:[{type:'input_audio',input_audio:{data:'data:audio/wav;base64,'+pcmToWave(pcm).toString('base64')}}]}],asr_options:{enable_itn:false}});
  const text=asr.choices?.[0]?.message?.content;
  if(typeof text!=='string'||!text.trim()||text.length>2000)throw fail('ASR_RESULT_FORMAT');
  const history=this.history.get(client)??[];
  const chat=await call(this.chatUrl,{model:this.chatModel,stream:false,max_tokens:128,messages:[{role:'system',content:'你是FPGA乐器助手。只用纯文本回答，不超过50个汉字。只能解释和建议，不能声称改变乐器参数、触发音符、校准或已执行任何动作。'},...history,{role:'user',content:text}]});
  const full=chat.choices?.[0]?.message?.content;
  if(typeof full!=='string'||!full.trim()||full.length>4000)throw fail('CHAT_RESULT_FORMAT');
  const reply=Array.from(full).slice(0,80).join('');
  const tts=await call(this.ttsUrl,{model:this.ttsModel,input:{text:reply,voice:this.voice,language_type:'Auto'}});
  const rawURL=tts.output?.audio?.url;if(typeof rawURL!=='string')throw fail('TTS_RESULT_FORMAT');
  const u=new URL(rawURL);
  if(u.protocol!=='https:'||u.username||u.password||u.port||!this.audioHosts.includes(u.hostname))throw fail('TTS_DOWNLOAD_REFUSED');
  check();const audio=await this.fetchImpl(u,{redirect:'error',signal}); // NO Authorization to audio host
  const wave=await bounded(audio,MAX_OUTPUT+4096),out=waveToPCM(wave);check();
  if(!this.history.has(client)&&this.history.size>=16)this.history.delete(this.history.keys().next().value);
  this.history.set(client,[...history,{role:'user',content:text},{role:'assistant',content:reply}].slice(-12));
  return{pcm:out,mode:'live'};
 }
}
export function makeAudioPipeline(env={},fetchImpl){
 if(!env.GATEWAY_AUDIO_MODE||env.GATEWAY_AUDIO_MODE==='mock')return mockAudioPipeline;
 if(env.GATEWAY_AUDIO_MODE!=='bailian'||env.GATEWAY_ALLOW_PAID_AUDIO!=='1')throw fail('PAID_AUDIO_NOT_ENABLED');
 return new BailianAudioPipeline({apiKey:env.BAILIAN_API_KEY,asrUrl:env.BAILIAN_ASR_URL,chatUrl:env.BAILIAN_CHAT_URL,ttsUrl:env.BAILIAN_TTS_URL,asrModel:env.BAILIAN_ASR_MODEL,chatModel:env.BAILIAN_CHAT_MODEL,ttsModel:env.BAILIAN_TTS_MODEL,voice:env.BAILIAN_TTS_VOICE,audioHosts:(env.BAILIAN_AUDIO_HOSTS??'').split(',').map(x=>x.trim()).filter(Boolean),fetchImpl});
}
