import {test} from 'node:test';import assert from 'node:assert/strict';
import {BailianChat} from './providers.mjs';import {makeAsrProvider,makeTtsProvider} from './asr.mjs';import {beijingConfig} from './beijing_config.mjs';
test('bounded Qwen response stops as incomplete on token-length truncation',async()=>{
  let request;const p=new BailianChat({apiKey:'fixture',model:'qwen3.8-flash',baseUrl:'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',maxTokens:512,enableThinking:false,fetchImpl:async(url,init)=>{request=JSON.parse(init.body);return new Response('data: {"choices":[{"delta":{"content":"半句"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\ndata: [DONE]\n\n')}});
  await assert.rejects(async()=>{for await(const c of p.stream([{role:'user',text:'hello'}])){}},{code:'UPSTREAM_OUTPUT_LIMIT'});assert.equal(request.max_tokens,512);assert.equal(request.enable_thinking,false);
});
test('WeChat MP3 uses the documented MPEG data URI at the actual ASR adapter',async()=>{
  let sent;const c=beijingConfig({ASR_MODE:'bailian',GATEWAY_ALLOW_PAID_AUDIO:'1',BAILIAN_API_KEY:'fixture'});const p=makeAsrProvider(c,{fetchImpl:async(url,init)=>{sent=JSON.parse(init.body);return new Response(JSON.stringify({choices:[{message:{content:'和弦'}}]}))}});await p.transcribe({buffer:Buffer.from('fixture'),mime:'audio/mp3'});assert.match(sent.messages[0].content[0].input_audio.data,/^data:audio\/mpeg;base64,/);
});
test('Beijing TTS result upgrades an approved OSS HTTP result to HTTPS without forwarding Key',async()=>{
  const calls=[],c=beijingConfig({TTS_MODE:'bailian',GATEWAY_ALLOW_PAID_AUDIO:'1',BAILIAN_API_KEY:'fixture'});const p=makeTtsProvider(c,{fetchImpl:async(url,init)=>{calls.push({url,init});return calls.length===1?new Response(JSON.stringify({output:{audio:{url:'http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/result.wav?sign=fixture'}}})):new Response(Buffer.from('RIFFfixture'))}});await p.synthesize({text:'你好'});assert.match(calls[1].url,/^https:\/\//);assert.equal(calls[1].init.headers,undefined);assert.equal(calls[1].init.redirect,'error');
});
