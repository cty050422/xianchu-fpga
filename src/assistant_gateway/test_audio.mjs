import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createGateway,validateListenConfiguration} from './server.mjs';
import {INPUT_TYPE,OUTPUT_TYPE,MAX_INPUT,MAX_OUTPUT} from './audio.mjs';
// Each fixture gets its own ledger file. Sharing the default `.gateway-state`
// directory would make the turn counts depend on whatever an earlier run left
// behind, so the assertions would pass or fail for the wrong reason.
function tempLedgerFile(){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gateway-audio-'));
 return path.join(dir,'ledger.json');
}
async function fixture(options,fn){
 const ledgerFile=options.ledger?undefined:tempLedgerFile();
 const gateway=createGateway({env:{GATEWAY_PROVIDER:'mock'},deviceToken:'unit-test-token',log:()=>{},ledgerFile,...options});
 await new Promise(r=>gateway.server.listen(0,'127.0.0.1',r));
 const base=`http://127.0.0.1:${gateway.server.address().port}`;
 const post=(id,body=Buffer.alloc(6400),headers={})=>fetch(base+'/assistant/v1/audio/turns',{method:'POST',headers:{'Content-Type':INPUT_TYPE,'X-Device-Token':'unit-test-token','X-CC-Turn':String(id),'X-CC-Client':'testboot',...headers},body});
 try{await fn({gateway,base,post});}finally{await new Promise(r=>gateway.server.close(r));}
}
test('audio: default mock PCM, turn echo, format and duration bounded',()=>fixture({},async({post,gateway})=>{
 const r=await post(1);assert.equal(r.status,200);assert.equal(r.headers.get('content-type'),OUTPUT_TYPE);assert.equal(r.headers.get('x-cc-mode'),'mock');assert.equal(r.headers.get('x-cc-turn'),'1');
 const b=Buffer.from(await r.arrayBuffer());assert.equal(b.length,4800);assert(b.some(v=>v));assert.equal(gateway.ledger.turns,1);
}));
test('audio: auth before body/provider admission',()=>fixture({},async({post,gateway})=>{
 assert.equal((await post(1,Buffer.alloc(6400),{'X-Device-Token':'bad'})).status,401);assert.equal(gateway.ledger.turns,0);
}));
test('audio: unsupported rate, odd and too-short PCM rejected',()=>fixture({},async({post,gateway})=>{
 assert.equal((await post(1,Buffer.alloc(6400),{'Content-Type':'audio/wav'})).status,415);
 assert.equal((await post(2,Buffer.alloc(4801))).status,400);assert.equal((await post(3,Buffer.alloc(4798))).status,400);assert.equal(gateway.ledger.turns,0);
}));
test('audio: oversized capture rejected before paid work',()=>fixture({},async({post,gateway})=>{
 assert.equal((await post(1,Buffer.alloc(MAX_INPUT+2))).status,413);assert.equal(gateway.ledger.turns,0);
}));
test('audio: completed retry survives budget limit, body change is refused',()=>fixture({ledger:{turns:0,limit:1}},async({post,gateway})=>{
 const r=await post(1);const pcm=await r.arrayBuffer();const replay=await post(1);assert.equal(replay.status,200);assert.equal(replay.headers.get('x-cc-replay'),'1');assert.deepEqual(await replay.arrayBuffer(),pcm);
 assert.equal((await post(1,Buffer.alloc(6400,1))).status,409);assert.equal((await post(2)).status,429);assert.equal(gateway.ledger.turns,1);
}));
test('audio: duplicate while pending is not a second provider call',()=>{
 let release,calls=0;const ready=new Promise(r=>release=r);
 return fixture({audioPipeline:{mode:'live',async process(){calls++;await ready;return{pcm:Buffer.alloc(4800),mode:'live'};}}},async({post})=>{
  const first=post(1);while(!calls)await new Promise(r=>setTimeout(r,2));
  assert.equal((await post(1)).status,409);assert.equal((await post(2)).status,409);assert.equal(calls,1);release();assert.equal((await first).status,200);
 });
});
test('audio: generation cancel aborts work, late result never becomes replay',()=>{
 let started=false,aborted=false;
 return fixture({audioPipeline:{mode:'live',async process({signal}){started=true;await new Promise(r=>signal.addEventListener('abort',()=>{aborted=true;r();},{once:true}));return{pcm:Buffer.alloc(4800),mode:'live'};}}},async({post,base})=>{
 const first=post(7);while(!started)await new Promise(r=>setTimeout(r,2));
 const c=await fetch(base+'/assistant/v1/audio/turns/7/cancel',{method:'POST',headers:{'X-Device-Token':'unit-test-token','X-CC-Client':'testboot'}});assert.equal(c.status,200);
 assert.equal((await first).status,502);assert(aborted);assert.equal((await post(7)).status,409);
 });
});
test('audio: provider that never returns is bounded and visible',()=>fixture({audioTimeoutMs:25,audioPipeline:{mode:'live',process(){return new Promise(()=>{});}}},async({post})=>{
 const r=await post(1);assert.equal(r.status,504);assert.equal((await r.json()).error,'AUDIO_TIMEOUT');
}));
test('audio: excessive output rejected; cannot consume arbitrary RAM',()=>fixture({audioPipeline:{mode:'live',async process(){return{pcm:Buffer.alloc(MAX_OUTPUT+2),mode:'live'};}}},async({post})=>{
 assert.equal((await post(1)).status,502);
}));
test('audio: mode lie and malformed output rejected',()=>fixture({audioPipeline:{mode:'live',async process(){return{pcm:Buffer.alloc(1),mode:'mock'};}}},async({post})=>{
 assert.equal((await post(1)).status,502);
}));
test('audio: boot identity isolates generation reuse',()=>fixture({},async({post,gateway})=>{
 assert.equal((await post(1)).status,200);assert.equal((await post(1,Buffer.alloc(6400,1),{'X-CC-Client':'newboot'})).status,200);assert.equal(gateway.ledger.turns,2);
}));
test('audio: missing/unsafe identity rejected',()=>fixture({},async({post})=>{
 assert.equal((await post('not-a-turn')).status,400);assert.equal((await post(1,Buffer.alloc(6400),{'X-CC-Client':'../bad'})).status,400);
}));

test('gateway: LAN bind requires an explicit device token; invalid budget fails closed',()=>{
 assert.doesNotThrow(()=>validateListenConfiguration('127.0.0.1',''));
 assert.throws(()=>validateListenConfiguration('0.0.0.0',''),/LAN_BIND_REQUIRES/);
 assert.throws(()=>validateListenConfiguration('192.168.1.2','short'),/LAN_BIND_REQUIRES/);
 assert.doesNotThrow(()=>validateListenConfiguration('0.0.0.0','test-token-at-least-sixteen'));
 assert.throws(()=>createGateway({env:{GATEWAY_PROVIDER:'mock',GATEWAY_DAILY_TURN_LIMIT:'NaN'}}),/INVALID_TURN_BUDGET/);
});
test('text: closing the SSE response aborts provider work',async()=>{
 let called=false,aborted=false;
 const provider={name:'fixture',paid:false,async *stream(messages,signal){called=true;yield{text:'first'};await new Promise(resolve=>signal.addEventListener('abort',()=>{aborted=true;resolve();},{once:true}));}};
 await fixture({provider},async({base})=>{
  const create=await fetch(base+'/assistant/v1/conversations',{method:'POST',headers:{'X-Device-Token':'unit-test-token'}});
  const id=(await create.json()).conversation_id;
  const c=new AbortController();const response=await fetch(`${base}/assistant/v1/conversations/${id}/turns`,{method:'POST',headers:{'Content-Type':'application/json','X-Device-Token':'unit-test-token'},body:JSON.stringify({client_turn_id:'disconnect',text:'hi'}),signal:c.signal});
  const reader=response.body.getReader();await reader.read();c.abort();
  for(let i=0;i<100&&!aborted;i++)await new Promise(r=>setTimeout(r,5));
  assert(called&&aborted);
 });
});
