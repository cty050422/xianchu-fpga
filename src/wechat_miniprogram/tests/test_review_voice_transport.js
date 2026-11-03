const test=require('node:test'),assert=require('node:assert/strict');
const p=require('../utils/protocol');
test('schema2 carries actual note/region/envelope and budget, not an inferred global pitch',()=>{
 const b=Array(45).fill(0);b[0]=2;b[1]=3;b[3]=0x34;b[4]=0x12;
 for(let v=0;v<4;v++){let o=5+10*v;b[o]=v+1;b[o+1]=(v<<6)|32;b[o+2]=255;b[o+3]=255;b[o+4]=64;b[o+5]=224;b[o+6]=60+v;b[o+7]=3-v;b[o+8]=0x34;b[o+9]=0x12;}
 const d=p.decodeVoices(b);assert.ok(d);assert.equal(d.budgetViolation,true);assert.equal(d.grants,0x1234);
 assert.deepEqual(d.voices.map(v=>[v.note,v.region,v.envelope,v.pcm]),[[60,3,0x1234,-1],[61,2,0x1234,-1],[62,1,0x1234,-1],[63,0,0x1234,-1]]);
 const frames=[];const feed=p.createReplyParser({onVoices:x=>frames.push(x)});const wire=new Uint8Array(p.frame(0x84,7,b));
 for(let k=0;k<wire.length;k+=20)feed(wire.slice(k,k+20));assert.equal(frames.length,1);
 wire[wire.length-1]^=1;feed(wire);assert.equal(frames.length,1);
});
test('effect family is explicit, invalid/live switches write nothing and labels require a device snapshot',async()=>{
 const {createInstrumentModel}=require('../services/instrument_model');const model=createInstrumentModel({},undefined,setTimeout,clearTimeout);
 model.setData=x=>Object.assign(model.data,x);model.data.connected=true;model.generation=1;let calls=[],active=false;
 let wet=0;model.hub={snapshot:()=>({freshness:'fresh',lastStatus:{wet},voicesFresh:true,voicesFrame:{schema:2,anyActive:active}}),simConfigTransaction:async s=>calls.push(s),simFxControl:async m=>calls.push(m)};
 await model.selectEffect({detail:{value:4}});assert.deepEqual(calls,[[{field:19,value:1}]]);assert.equal(model.data.effectLabel,'未回读');
 calls=[];await model.selectEffect({detail:{value:2}});assert.deepEqual(calls,[[{field:19,value:0}],2]);
 calls=[];active=true;await model.selectEffect({detail:{value:1}});assert.equal(calls.length,0);assert.match(model.data.lastError,/松开/);
 active=false;await model.selectEffect({detail:{value:99}});assert.equal(calls.length,0);
 wet=32;await model.selectEffect({detail:{value:1}});assert.equal(calls.length,0);assert.match(model.data.lastError,/J2Y/);
});
test('real BLE receiver publishes every voice frame and expires it independently of ordinary status',()=>{
 const {createSessionHub}=require('../services/device_session'),{createInstrumentModel}=require('../services/instrument_model');
 let now=1000;const hub=createSessionHub({wx:{},now:()=>now});hub.publishReal({connected:true,deviceId:'real'});
 const wx={onBLECharacteristicValueChange(){},onBLEConnectionStateChange(){}};
 const model=createInstrumentModel(wx,()=>({globalData:{sessionHub:hub}}),setTimeout,clearTimeout,setInterval,clearInterval);
 model.setData=patch=>Object.assign(model.data,patch);model.onLoad();model.data.connected=true;model.deviceId='real';
 const body=Array(45).fill(0);body[0]=2;for(let v=0;v<4;v++){let o=5+10*v;body[o+1]=32|(v<<6);body[o+5]=224;body[o+6]=60+v;body[o+7]=v;}
 function send(device){const wire=new Uint8Array(p.frame(0x84,1,body));for(let i=0;i<wire.length;i+=20)model.handleCharacteristic({deviceId:device,serviceId:p.SERVICE_UUID,characteristicId:p.STATUS_UUID,value:wire.slice(i,i+20).buffer})}
 send('another');assert.equal(hub.snapshot().voicesFrame,undefined);send('real');assert.equal(hub.snapshot().voicesFrame.schema,2);assert.equal(model.data.voiceRows[0].note,'C4');assert.equal(model.data.voiceRows[3].region,4);
 now+=701;assert.equal(hub.snapshot().voicesFresh,false);model.onHubSnapshot(hub.snapshot());assert.equal(model.data.voicesStale,true);
 now++;send('real');assert.equal(model.data.voicesStale,false);
 model.offHub();
});
