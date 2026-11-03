import {runTranscription}from'./transcription_job.mjs';
// Exact source allowlist, NOT an arbitrary URL proxy. No credentials or redirects.
export const ONLINE_SCORES=[{id:'petzold-minuet-g',title:'G大调小步舞曲',composer:'Christian Petzold',license:'Public Domain',
 source:'Mutopia Project',url:'https://www.mutopiaproject.org/ftp/BachJS/BWVAnh114/anna-magdalena-04/anna-magdalena-04.mid',
 attribution:'Mutopia-2017/01/19-75；原排版沿用历史巴赫归属，作品现归属Petzold',maxVoices:4}];
function send(res,status,body){const text=JSON.stringify(body);res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});res.end(text)}
async function bytes(req,limit){let n=0,parts=[];for await(const x of req){n+=x.length;if(n>limit)throw Object.assign(Error('MIDI_TOO_LARGE'),{code:'MIDI_TOO_LARGE'});parts.push(x)}return Buffer.concat(parts)}
export function createMusicRoutes({authorized,fetchImpl=fetch}={}){
 return async function(req,res,url){
 if(!url.pathname.startsWith('/music/v1/'))return false;
 if(!authorized(req)){send(res,401,{error:'UNAUTHORIZED'});return true}
 try{
  if(url.pathname==='/music/v1/online'&&req.method==='GET'){
   const q=(url.searchParams.get('q')||'').slice(0,80).toLowerCase();send(res,200,{items:ONLINE_SCORES.filter(s=>(s.title+' '+s.composer).toLowerCase().includes(q)).map(({url,...s})=>s),scope:'curated_public_scores'});return true;
  }
  let b,source;
  const id=url.pathname.match(/^\/music\/v1\/online\/([a-z0-9-]+)$/);
  if(id&&req.method==='POST'){
   source=ONLINE_SCORES.find(x=>x.id===id[1]);if(!source){send(res,404,{error:'SCORE_NOT_FOUND'});return true}
   const r=await fetchImpl(source.url,{redirect:'error',signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error('SOURCE_UNAVAILABLE');
   if(Number(r.headers.get('content-length'))>1024*1024)throw Error('MIDI_TOO_LARGE');
   const reader=r.body.getReader(),chunks=[];let size=0;try{for(;;){const x=await reader.read();if(x.done)break;size+=x.value.length;if(size>1024*1024)throw Error('MIDI_TOO_LARGE');chunks.push(Buffer.from(x.value))}}finally{await reader.cancel().catch(()=>{})}b=Buffer.concat(chunks);
  }else if(url.pathname==='/music/v1/import'&&req.method==='POST')b=await bytes(req,1024*1024);
  else{send(res,404,{error:'NO_SUCH_ROUTE'});return true}
  const quantize=Number(url.searchParams.get('quantizeMs')||0);
  if(![0,20].includes(quantize))throw Object.assign(Error('QUANTIZATION_UNSUPPORTED'),{code:'QUANTIZATION_UNSUPPORTED'});
  const output=await runTranscription(b,'audio/midi','midi',20000,quantize);
  send(res,200,{...output,source:source||{source:'用户导入MIDI'},hardwareActions:0});
 }catch(e){send(res,e.code==='TRANSCRIPTION_BUSY'?429:422,{error:e.code||'SOURCE_OR_MIDI_ERROR',hardwareActions:0})}
 return true;
 }
}
