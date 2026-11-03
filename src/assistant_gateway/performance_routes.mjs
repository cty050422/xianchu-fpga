import fs from 'node:fs';import {createRequire} from 'node:module';
import {openPerformanceStore} from './performance_store.mjs';import {parseMultipart} from './asr.mjs';import {MUSIC_LIMITS} from './performance_audio.mjs';
import {runTranscription}from'./transcription_job.mjs';
const require=createRequire(import.meta.url),{assessEvents}=require('../wechat_miniprogram/utils/performance_assessment.js');
const fail=code=>Object.assign(new Error(code),{code});
function send(res,status,body){const text=JSON.stringify(body);res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store','content-length':Buffer.byteLength(text)});res.end(text)}
async function read(req,limit){const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>limit)throw fail('BODY_TOO_LARGE');chunks.push(chunk)}return Buffer.concat(chunks)}
async function json(req){try{return JSON.parse((await read(req,512*1024)).toString('utf8')||'{}')}catch(e){if(e.code)throw e;throw fail('TAKE_FORMAT')}}
const statuses={UNAUTHORIZED:401,CAPTURE_UNAUTHORIZED:401,TAKE_NOT_FOUND:404,AUDIO_NOT_READY:409,SOURCE_CONFLICT:409,AUDIO_CONFLICT:409,IDEMPOTENCY_CONFLICT:409,CAPTURE_SEQUENCE:409,CAPTURE_NOT_ACTIVE:409,TAKE_FORMAT:400,CAPTURE_FORMAT:400,ASSESSMENT_FORMAT:400,BODY_TOO_LARGE:413,AUDIO_TOO_LARGE:413,AUDIO_TOO_LONG:413,AUDIO_EMPTY:400,AUDIO_CONTAINER_MISMATCH:415,AUDIO_FORMAT_UNSUPPORTED:415,RECORDING_STORAGE_FULL:507};
export function createPerformanceRoutes({directory,authorized,store:givenStore}={}){
  // No provider/API calls. This project library is shared by its authorised clients.
  const store=givenStore||openPerformanceStore({directory});
  return async function route(req,res,url){
    if(!url.pathname.startsWith('/performances/v1/'))return false;
    const p=url.pathname,method=req.method;
    try{
      const cap=p.match(/^\/performances\/v1\/capture\/(take-[a-f0-9]{24})\/(status|finish|chunks\/(\d+))$/);
      if(cap){const ticket=req.headers['x-capture-token'];if(cap[2]==='status'&&method==='GET')send(res,200,store.captureStatus(cap[1],ticket));else if(cap[2]==='finish'&&method==='POST')send(res,200,store.finish(cap[1],ticket,await json(req)));else if(cap[3]!==undefined&&method==='POST')send(res,200,store.append(cap[1],ticket,Number(cap[3]),Number(req.headers['x-sample-offset']),await read(req,32768)));else send(res,405,{error:'METHOD_NOT_ALLOWED'});return true}
      if(!authorized(req)){send(res,401,{error:'UNAUTHORIZED'});return true}
      if(p==='/performances/v1/healthz'&&method==='GET'){send(res,200,store.capabilities());return true}
      if(p==='/performances/v1/capture/next'&&method==='GET'){const job=store.claim();if(job)send(res,200,job);else{res.writeHead(204,{'cache-control':'no-store'});res.end()}return true}
      if(p==='/performances/v1/takes'){
        if(method==='GET')send(res,200,{items:store.list()});else if(method==='POST'){const out=store.create(await json(req));send(res,out.created?201:200,out.take)}else send(res,405,{error:'METHOD_NOT_ALLOWED'});return true
      }
      const take=p.match(/^\/performances\/v1\/takes\/(take-[a-f0-9]{24})(?:\/(audio|assessment|stop|transcribe))?$/);
      if(!take){send(res,404,{error:'NO_SUCH_ROUTE'});return true}const id=take[1],action=take[2];
      if(!action&&method==='GET')send(res,200,store.detail(id));
      else if(!action&&method==='DELETE')send(res,200,store.remove(id));
      else if(action==='transcribe'&&method==='POST'){
        const audio=store.audio(id);
        try{send(res,200,{...(await runTranscription(fs.readFileSync(audio.file),audio.mime)),hardwareActions:0})}
        catch(e){send(res,e.code==='TRANSCRIPTION_BUSY'?429:422,{error:e.code||'TRANSCRIPTION_FAILED',hardwareActions:0})}
      }
      else if(action==='stop'&&method==='POST')send(res,200,store.stop(id));
      else if(action==='assessment'&&method==='POST'){
        const data=await json(req),takeMetadata=store.detail(id);let result;
        if(data.kind==='device_counters'){
          const c=data.counts;if(!c||!['hits','wrong','misses'].every(k=>Number.isSafeInteger(c[k])&&c[k]>=0&&c[k]<=65534))throw fail('ASSESSMENT_FORMAT');const n=c.hits+c.wrong+c.misses;
          result={ruleVersion:'counter-summary/1.0',status:data.incomplete?'incomplete':'basic',source:'device_counters',counts:{hits:c.hits,wrong:c.wrong,misses:c.misses},accuracy:n&&!data.incomplete?Math.round(c.hits/n*1000)/10:null,total:null,acousticScore:null,ranked:false,dimensions:{notes:n&&!data.incomplete?Math.round(c.hits/n*1000)/10:null,timing:null,duration:null,expression:null},reason:'当前固件只提供基础计数，未将其冒充精确节奏评分'};
        }else if(data.kind==='device_events'){result=assessEvents({...data,mode:takeMetadata.mode});result.ranked=false;result.reason=result.reason||'客户端提交的事件评估；未获得设备端签名或实板认证'}
        else throw fail('ASSESSMENT_FORMAT');
        if(takeMetadata.mode==='free'||takeMetadata.simulated){result.status='ungraded';result.total=null;result.accuracy=null;result.dimensions={notes:null,timing:null,duration:null,expression:null};result.reason=takeMetadata.simulated?'演示记录不计真实演奏成绩':'自由演奏没有参考曲谱，不计正确率';result.ranked=false}
        if(['incomplete','cancelled'].includes(takeMetadata.state)){result.status='incomplete';result.total=null;result.accuracy=null;result.ranked=false;result.dimensions={notes:null,timing:null,duration:null,expression:null};result.reason='录音未完整返回，不能展示有效成绩'}
        send(res,200,store.setAssessment(id,result));
      }else if(action==='audio'&&method==='POST'){
        store.detail(id);const type=String(req.headers['content-type']||''),body=await read(req,MUSIC_LIMITS.maxBytes+65536),parsed=parseMultipart(body,type),file=parsed.files.find(f=>f.name==='audio');if(!file)throw fail('AUDIO_EMPTY');const mime=file.contentType==='application/octet-stream'?parsed.fields.mime:file.contentType;send(res,200,store.putAudio(id,file.data,mime));
      }else if(action==='audio'&&method==='GET'){
        const a=store.audio(id),buffer=fs.readFileSync(a.file);let start=0,end=buffer.length-1,status=200;const range=req.headers.range;
        if(range){const m=range.match(/^bytes=(\d+)-(\d*)$/);if(!m||Number(m[1])>=buffer.length){res.writeHead(416,{'content-range':'bytes */'+buffer.length});res.end();return true}start=Number(m[1]);end=m[2]?Math.min(Number(m[2]),end):end;if(end<start){res.writeHead(416);res.end();return true}status=206}
        res.writeHead(status,{'content-type':a.mime,'cache-control':'private, no-store','content-length':end-start+1,'accept-ranges':'bytes',...(status===206?{'content-range':`bytes ${start}-${end}/${buffer.length}`}:{})});res.end(buffer.subarray(start,end+1));
      }else send(res,405,{error:'METHOD_NOT_ALLOWED'});
    }catch(e){send(res,statuses[e.code]||500,{error:statuses[e.code]?e.code:'RECORDING_STORE_ERROR'})}
    return true;
  }
}
