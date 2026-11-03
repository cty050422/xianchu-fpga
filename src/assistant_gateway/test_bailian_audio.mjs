import {test} from 'node:test';import assert from 'node:assert/strict';
import {BailianAudioPipeline,makeAudioPipeline,pcmToWave,waveToPCM} from './bailian_audio.mjs';
const settings={apiKey:'TEST_ONLY',asrUrl:'https://api.test/asr',chatUrl:'https://api.test/chat',ttsUrl:'https://api.test/tts',asrModel:'operator-asr',chatModel:'operator-chat',ttsModel:'operator-tts',voice:'operator-voice',audioHosts:['audio.test']};
const wav=()=>pcmToWave(Buffer.alloc(4800),24000);
const json=v=>new Response(JSON.stringify(v),{headers:{'Content-Type':'application/json'}});
function fake({audioURL='https://audio.test/reply.wav',chatText='测试回答',wave=wav(),onCall=()=>{}}={}){
 const calls=[];
 const fetchImpl=async(url,options)=>{const u=String(url);calls.push({url:u,...options});onCall(u,options);
 if(u===settings.asrUrl)return json({choices:[{message:{content:'刚才按了第四区'}}]});
 if(u===settings.chatUrl)return json({choices:[{message:{content:chatText}}]});
 if(u===settings.ttsUrl)return json({output:{audio:{url:audioURL}}});
 return new Response(wave);
 };return{calls,fetchImpl};
}
test('cloud audio: opt-in required; environment defaults to mock',()=>{
 assert.equal(makeAudioPipeline({}).mode,'mock');
 assert.throws(()=>makeAudioPipeline({GATEWAY_AUDIO_MODE:'bailian'}),/PAID_AUDIO_NOT_ENABLED/);
 assert.throws(()=>makeAudioPipeline({GATEWAY_AUDIO_MODE:'bailian',GATEWAY_ALLOW_PAID_AUDIO:'1'}),/AUDIO_CONFIG_REQUIRED/);
});
test('cloud audio: exact PCM WAV header; wrong sample rate never reinterpreted',()=>{
 const b=pcmToWave(Buffer.from([0,0,255,127,0,128]),24000);assert.equal(b.readUInt32LE(24),24000);assert.equal(b.readUInt16LE(22),1);assert.deepEqual(waveToPCM(b),b.subarray(44));
 assert.throws(()=>waveToPCM(pcmToWave(Buffer.alloc(4800),16000)),/TTS_WAVE_FORMAT/);
 b[20]=3;assert.throws(()=>waveToPCM(b),/TTS_WAVE_FORMAT/);
});
test('cloud audio: real adapter request contracts, no auth to download, six paired turns',async()=>{
 const {calls,fetchImpl}=fake();const p=new BailianAudioPipeline({...settings,fetchImpl});
 for(let i=0;i<7;i++){const r=await p.process({pcm:Buffer.alloc(6400),client:'boot',signal:new AbortController().signal});assert.equal(r.mode,'live');assert.equal(r.pcm.length,4800);}
 assert.equal(calls.length,28);const asr=JSON.parse(calls[0].body);assert.equal(asr.model,'operator-asr');assert.equal(asr.stream,false);const data=asr.messages[0].content[0].input_audio.data;assert(data.startsWith('data:audio/wav;base64,'));assert.equal(Buffer.from(data.split(',')[1],'base64').readUInt32LE(24),16000);
 const chat=JSON.parse(calls[25].body);assert.equal(chat.messages.length,14);assert.equal(chat.messages.at(-1).role,'user');assert.equal(p.history.get('boot').length,12);
 assert.equal(calls[3].headers,undefined);assert.equal(calls[3].redirect,'error');
});
test('cloud audio: canceled before work makes zero API calls',async()=>{
 const f=fake(),p=new BailianAudioPipeline({...settings,...f});const c=new AbortController();c.abort();
 await assert.rejects(p.process({pcm:Buffer.alloc(6400),client:'x',signal:c.signal}),/CANCELLED/);assert.equal(f.calls.length,0);
});
test('cloud audio: cancellation between ASR/chat prevents TTS and history',async()=>{
 const c=new AbortController();const f=fake({onCall(url){if(url===settings.chatUrl)c.abort();}}),p=new BailianAudioPipeline({...settings,...f});
 await assert.rejects(p.process({pcm:Buffer.alloc(6400),client:'x',signal:c.signal}),/CANCELLED/);assert.equal(f.calls.length,2);assert.equal(p.history.size,0);
});
test('cloud audio: downloaded URL is allowlisted HTTPS without credentials',async()=>{
 for(const audioURL of ['https://127.0.0.1/private','https://bad.test/x','http://audio.test/x','https://user:pass@audio.test/x','https://audio.test:8443/x']){
 const f=fake({audioURL}),p=new BailianAudioPipeline({...settings,...f});await assert.rejects(p.process({pcm:Buffer.alloc(6400),client:'x',signal:new AbortController().signal}),/TTS_DOWNLOAD_REFUSED/);assert.equal(f.calls.length,3);
 }
});
test('cloud audio: incompatible TTS data is rejected rather than mislabeled as PCM',async()=>{
 const f=fake({wave:Buffer.from('not a wav')}),p=new BailianAudioPipeline({...settings,...f});
 await assert.rejects(p.process({pcm:Buffer.alloc(6400),client:'x',signal:new AbortController().signal}),/TTS_WAVE_FORMAT/);assert.equal(p.history.size,0);
});
test('cloud audio: long answer is explicitly bounded before synthesis',async()=>{
 const f=fake({chatText:'长'.repeat(500)}),p=new BailianAudioPipeline({...settings,...f});
 await p.process({pcm:Buffer.alloc(6400),client:'x',signal:new AbortController().signal});assert.equal(JSON.parse(f.calls[2].body).input.text.length,80);
});
test('cloud audio: API endpoint cannot be plaintext or carry credentials',()=>{
 assert.throws(()=>new BailianAudioPipeline({...settings,asrUrl:'http://api.test/asr'}),/AUDIO_ENDPOINT_REQUIRED_HTTPS/);
 assert.throws(()=>new BailianAudioPipeline({...settings,audioHosts:[]}),/AUDIO_DOWNLOAD_ALLOWLIST_REQUIRED/);
});
test('cloud audio: non-200 response does not continue or hide failure',async()=>{
 let calls=0;const p=new BailianAudioPipeline({...settings,fetchImpl:async()=>{calls++;return new Response('denied',{status:429});}});
 await assert.rejects(p.process({pcm:Buffer.alloc(6400),client:'x',signal:new AbortController().signal}),/PROVIDER_HTTP_429/);assert.equal(calls,1);
});
