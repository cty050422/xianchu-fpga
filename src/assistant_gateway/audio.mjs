// Bounded PTT audio transport. Default pipeline is explicitly MOCK (no ASR/TTS).
// Live adapters must be injected, never inferred from a key or model nickname.
import { createHash } from 'node:crypto';
export const INPUT_TYPE='audio/pcm;rate=16000;format=s16le';
export const OUTPUT_TYPE='audio/pcm;rate=24000;format=s16le';
export const MAX_INPUT=16000*2*15, MAX_OUTPUT=24000*2*8;
const error=(code)=>Object.assign(new Error(code),{code});
const digest=(b)=>createHash('sha256').update(b).digest('hex');
function json(res,status,code){res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify({error:code}));}
async function readPCM(req){
 let size=0;const chunks=[];let tooLarge=false;
 for await(const chunk of req){size+=chunk.length;if(size>MAX_INPUT)tooLarge=true;else if(!tooLarge)chunks.push(chunk);}
 if(tooLarge)throw error('AUDIO_TOO_LARGE');
 if(size<4800 || size%2)throw error('AUDIO_FORMAT');
 return Buffer.concat(chunks);
}
export const mockAudioPipeline={name:'mock',mode:'mock',async process({pcm,signal}){
 if(signal.aborted)throw error('CANCELLED');
 // A quiet 100 ms diagnostic tone only. This is not recognition or synthesized speech.
 const out=Buffer.alloc(24000/10*2);
 const amplitude=Math.min(128,Math.max(16,pcm.length/4800));
 for(let i=0;i<out.length/2;i++)out.writeInt16LE(Math.round(amplitude*Math.sin(i*2*Math.PI*440/24000)),i*2);
 return {pcm:out,mode:'mock'};
}};
export function createAudioHandler({pipeline=mockAudioPipeline,authorized,ledger,timeoutMs=15000}){
 const turns=new Map(),active=new Map();
 const prune=()=>{for(const [k,v]of turns)if(v.expires<Date.now() && v.state!=='pending')turns.delete(k);};
 const reply=(res,id,result,replay)=>{
  res.writeHead(200,{'Content-Type':OUTPUT_TYPE,'Content-Length':result.pcm.length,'X-CC-Turn':id,
   'X-CC-Mode':result.mode,'X-CC-Replay':replay?'1':'0','Cache-Control':'no-store'});res.end(result.pcm);
 };
 return async(req,res,path)=>{
  const cancel=path.match(/^\/assistant\/v1\/audio\/turns\/([0-9]{1,10})\/cancel$/);
  if(path!=='/assistant/v1/audio/turns' && !cancel)return false;
  if(req.method!=='POST'){json(res,405,'METHOD');return true;}
  if(!authorized(req)){json(res,401,'UNAUTHORIZED');return true;}
  const client=req.headers['x-cc-client']??'development';
  if(typeof client!=='string' || !/^[a-zA-Z0-9_-]{1,40}$/.test(client)){json(res,400,'CLIENT_ID');return true;}
  const identity=digest(Buffer.from(String(req.headers['x-device-token']??'')+'|'+client));
  const id=cancel?cancel[1]:req.headers['x-cc-turn'];
  if(typeof id!=='string' || !/^[0-9]{1,10}$/.test(id)){json(res,400,'TURN_ID');return true;}
  const key=identity+':'+id;prune();
  if(cancel){const old=turns.get(key);if(old?.state==='pending')old.controller.abort();json(res,200,'CANCEL_REQUESTED');return true;}
  if(req.headers['content-type']!==INPUT_TYPE){json(res,415,'AUDIO_FORMAT');return true;}
  const declared=Number(req.headers['content-length']);
  if(Number.isFinite(declared) && declared>MAX_INPUT){req.resume();json(res,413,'AUDIO_TOO_LARGE');return true;}
  let pcm;
  try{pcm=await readPCM(req);}catch(e){if(!res.destroyed)json(res,e.code==='AUDIO_TOO_LARGE'?413:400,e.code??'AUDIO_ABORTED');return true;}
  const hash=digest(pcm),old=turns.get(key);
  if(old){
   if(old.hash!==hash){json(res,409,'TURN_REUSED');return true;}
   if(old.state==='done'){reply(res,id,old.result,true);return true;}
   json(res,409,old.state==='pending'?'TURN_IN_PROGRESS':old.code);return true;
  }
  if(active.has(identity)){json(res,409,'TURN_IN_PROGRESS');return true;}
  if(turns.size>=32){json(res,503,'AUDIO_CACHE_FULL');return true;}
  if(ledger.turns>=ledger.limit){json(res,429,'BUDGET_EXHAUSTED');return true;}
  try { if(typeof ledger.consume==='function')ledger.consume();else ledger.turns++; }
  catch(e){json(res,e.code==='BUDGET_EXHAUSTED'?429:503,e.code??'LEDGER_UNAVAILABLE');return true;}
  const controller=new AbortController(),entry={hash,state:'pending',controller,expires:Date.now()+120000};
  turns.set(key,entry);active.set(identity,key);
  const closed=()=>{if(!res.writableEnded)controller.abort();};res.once('close',closed);
  let timeout;
  try{
   const cancelled=new Promise((_,reject)=>{
    controller.signal.addEventListener('abort',()=>reject(error('CANCELLED')),{once:true});
    timeout=setTimeout(()=>{entry.timedOut=true;controller.abort();},timeoutMs);
   });
   const result=await Promise.race([pipeline.process({pcm,rate:16000,turnId:id,client,signal:controller.signal}),cancelled]);
   if(controller.signal.aborted)throw error('CANCELLED');
   if(!Buffer.isBuffer(result?.pcm) || !result.pcm.length || result.pcm.length%2 || result.pcm.length>MAX_OUTPUT || !['mock','live'].includes(result.mode) || result.mode!==pipeline.mode)throw error('AUDIO_PROVIDER_FORMAT');
   entry.result={pcm:Buffer.from(result.pcm),mode:result.mode};entry.state='done';entry.expires=Date.now()+120000;
   if(!res.destroyed)reply(res,id,entry.result,false);
  }catch(e){entry.state='failed';entry.code=entry.timedOut?'AUDIO_TIMEOUT':e.code??'AUDIO_PROVIDER_ERROR';if(!res.destroyed)json(res,entry.timedOut?504:502,entry.code);}
  finally{clearTimeout(timeout);res.removeListener('close',closed);active.delete(identity);}
  return true;
 };
}
