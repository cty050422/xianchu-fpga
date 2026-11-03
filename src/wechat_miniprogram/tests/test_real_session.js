// Real-mode hub and PING2 page-driver adapter contract; no radio or COM.
// The independently modelled board receives exactly the bytes sent by issuer.
const {test}=require('node:test');const assert=require('node:assert/strict');
const {createSessionHub}=require('../services/device_session');
const {createSimTransport}=require('../utils/sim_transport');
const {createIssuer}=require('../utils/transaction');
const protocol=require('../utils/protocol');

test('guide ACK validates both extended modes while retaining the explicit legacy guide fallback',async()=>{
 let readbackMode=2;const hub=createSessionHub({});
 hub.bindReal({issuer:{submit:async(frame,opts)=>{const payload=Array(15).fill(0);payload[1]=19;const status=readbackMode===null?protocol.decodeStatus(new Uint8Array(protocol.frame(0x80,1,payload))):{flags:19,mode:readbackMode};assert.ok(status);const valid=opts.validate(status);if(valid!==true)throw Error(valid);return {status}}}});
 hub.publishReal({connected:true,lastStatusAt:Date.now(),lastStatus:{flags:19}});
 await assert.rejects(hub.simGuide(1),/模式回读不一致/);
 readbackMode=1;await hub.simGuide(1);await assert.rejects(hub.simGuide(2),/模式回读不一致/);
 readbackMode=undefined;await hub.simGuide(1);await assert.rejects(hub.simGuide(2),/模式回读不一致/);
 readbackMode=null;await hub.simGuide(true);await assert.rejects(hub.simGuide(2),/模式回读不一致/);
});
function setup(authorized=true){
 const hub=createSessionHub({});const wire=createSimTransport({profile:'normal'});let writes=0;
 const issuer=createIssuer({timeoutMs:100,send:b=>{if(!authorized)throw Error('PAIR FIRST');writes++;return wire.write(b)}});
 const driver={issuer};hub.bindReal(driver);
 hub.publishReal({connected:true,lastStatusAt:Date.now(),lastStatus:{flags:16}});
 const parser=protocol.createReplyParser({onConfig:r=>hub.feedRealConfig(r),onStatus:s=>{
   issuer.onStatus(s);hub.publishReal({connected:true,lastStatus:s,lastStatusAt:Date.now()})
 }});
 wire.onNotify(parser);
 return {hub,wire,issuer,get writes(){return writes}};
}
test('real-mode catalog v2 path publishes all64 steps, rests and chords through one issuer',async()=>{
 const s=setup();await s.wire.connect();
 const steps=Array.from({length:64},(_,i)=>({mask:i===32?0:i===63?5:1,durationSamples:24000,expression:0}));
 const result=await s.hub.simUploadSegmentV2({steps},77,0);
 assert.equal(result.status.song,77);assert.equal(s.writes,66);
 assert.equal(s.wire.device.state.steps[63].mask,5);
 assert.equal(s.wire.device.state.steps[32].rest,true);
 await s.hub.simGuide(2);assert.equal(s.hub.snapshot().lastStatus.mode,2);
 assert.equal(s.hub.snapshot().lastStatus.targetMask,1);
 await s.wire.disconnect();
});
test('real-mode mapping is applied and EVERY field read back before publishing',async()=>{
 const s=setup();await s.wire.connect();
 const c={steps:[{mask:1,durationSamples:24000}],zonePitches:[60,62,64,67]};
 await s.hub.simUploadSegmentV2(c,78,0);
 for(let i=1;i<=4;i++)assert.equal(s.wire.device.state.values[i],c.zonePitches[i-1]);
 assert.equal(s.wire.device.state.songId,78);await s.wire.disconnect();
});
test('real-mode unauthorized/disconnected/stale commands NEVER write',async()=>{
 const s=setup(false);await s.wire.connect();
 await assert.rejects(s.hub.simPing());assert.equal(s.writes,0);
 s.hub.publishReal({connected:false});await assert.rejects(s.hub.simPing());assert.equal(s.writes,0);
 await s.wire.disconnect();
});
test('real-mode effect change confirms actual extended state and presets 2/3 survive readback',async()=>{
 const s=setup();await s.wire.connect();
 for(const value of [2,3]){await s.hub.simConfigTransaction([{field:20,value}]);
   assert.equal(s.wire.device.state.values[20],value)}
 for(const mode of [0,1,2,3]){await s.hub.simFxControl(mode);
   assert.equal(s.hub.snapshot().lastStatus.effectMode,mode)}
 await s.wire.disconnect();
});
test('mapping change plus failed score transfer makes old score unplayable until republished',async()=>{
 const s=setup();await s.wire.connect();
 const c={steps:[{mask:1,durationSamples:24000}],zonePitches:[60,62,64,67]};
 await s.hub.simUploadSegmentV2(c,42,0);
 const send=s.wire.write.bind(s.wire);let fail=true;
 s.wire.write=b=>{if(new Uint8Array(b)[3]===0x16&&fail){fail=false;throw Error('injected BEGIN failure')}return send(b)};
 await assert.rejects(s.hub.simUploadSegmentV2({...c,zonePitches:[65,67,69,72]},43,0));
 assert.equal(s.wire.device.state.songId,42);assert.equal(s.wire.device.state.mappingReady,false);
 await assert.rejects(s.hub.simGuide(1),e=>e.code==='FPGA_RESULT'&&e.result===0xe4);
 await s.hub.simUploadSegmentV2(c,42,0);await s.hub.simGuide(1);
 assert.equal(s.hub.snapshot().lastStatus.mappingReady,true);await s.wire.disconnect();
});
test('concurrent page operations serialize entire transactions, not just UART frames',async()=>{
 const s=setup();await s.wire.connect();
 await Promise.all([s.hub.simConfigTransaction([{field:20,value:2}]),s.hub.simConfigTransaction([{field:17,value:30}])]);
 assert.equal(s.wire.device.state.values[20],2);assert.equal(s.wire.device.state.values[17],30);await s.wire.disconnect();
});
