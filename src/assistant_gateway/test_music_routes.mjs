import{test}from'node:test';import assert from'node:assert/strict';import {createServer}from'node:http';import{createMusicRoutes}from'./music_routes.mjs';import{wavHeader}from'./performance_audio.mjs';import{runTranscription}from'./transcription_job.mjs';
const midi=Buffer.from('4d546864000000060000000100604d54726b0000000c00903c4060803c0000ff2f00','hex');
test('actual HTTP auth, curated source fetch and MIDI worker; no arbitrary proxy',async()=>{
 let downloads=0;const route=createMusicRoutes({authorized:r=>r.headers['x-device-token']==='local-test',fetchImpl:async url=>{assert.ok(url.startsWith('https://www.mutopiaproject.org/'));downloads++;return new Response(midi)}});
 const server=createServer(async(q,s)=>{if(!await route(q,s,new URL(q.url,'http://localhost')))s.end()});await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port,headers={'x-device-token':'local-test'};
 try{
 assert.equal((await fetch(base+'/music/v1/online')).status,401);assert.equal(downloads,0);
 let r=await fetch(base+'/music/v1/online',{headers});assert.equal((await r.json()).items.length,1);
 r=await fetch(base+'/music/v1/online/petzold-minuet-g?quantizeMs=20',{method:'POST',headers});const b=await r.json();assert.equal(r.status,200);assert.equal(b.compiled.steps[0].notes[0],60);assert.equal(b.hardwareActions,0);assert.equal(downloads,1);
 assert.equal((await fetch(base+'/music/v1/online/http-localhost',{method:'POST',headers})).status,404);
 r=await fetch(base+'/music/v1/import',{method:'POST',headers,body:midi});assert.equal(r.status,200);
 }finally{await new Promise(r=>server.close(r))}
})
test('real WAV worker estimates a note; isolated concurrency rejects extra jobs',async()=>{
 const pcm=Buffer.alloc(16000);for(let i=0;i<8000;i++)pcm.writeInt16LE(Math.round(15000*Math.sin(2*Math.PI*440*i/8000)),i*2);const wav=Buffer.concat([wavHeader(pcm.length,8000),pcm]);
 const first=runTranscription(wav,'audio/wav');await assert.rejects(runTranscription(wav,'audio/wav'),{code:'TRANSCRIPTION_BUSY'});const r=await first;assert.ok(r.timeline.some(t=>t.notes.includes(69)));assert.equal(r.needsConfirmation,true);
})

import fs from 'node:fs';
test('real MP3 WASM decoder transcribes generated A4 fixture',async()=>{const b=fs.readFileSync(new URL('./testdata/synth_a4_test_only.mp3',import.meta.url));const r=await runTranscription(b,'audio/mpeg');assert.ok(r.timeline.some(t=>t.notes[0]===69));assert.equal(r.needsConfirmation,true)});
