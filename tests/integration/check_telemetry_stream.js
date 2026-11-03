const fs=require('node:fs'),assert=require('node:assert/strict')
const P=require('../../src/wechat_miniprogram/utils/protocol'),{createWaveAssembler}=require('../../src/wechat_miniprogram/utils/mobile_observer')
const {createInstrumentModel}=require('../../src/wechat_miniprogram/services/instrument_model'),{createSessionHub}=require('../../src/wechat_miniprogram/services/device_session')
const rows=fs.readFileSync(process.argv[2],'utf8').trim().split(/\r?\n/).slice(1)
for(const period of [15,10]){
 let now=1,windows=0,voices=0;const notes=new Set(),cues=new Set(),hub=createSessionHub({now:()=>now})
 hub.publishReal({connected:true,deviceId:'test'});const m=createInstrumentModel({},undefined,setTimeout,clearTimeout,setInterval,clearInterval);m.data=structuredClone(m.data);m.setData=p=>Object.assign(m.data,p);m.hub=hub
 const off=hub.subscribe(s=>m.onHubSnapshot(s)),wave=createWaveAssembler({now:()=>now})
 const feed=P.createReplyParser({onControl:c=>{m.onControlFrame(c);cues.add(m.data.expressionText)},onVoices:v=>{voices++;m.onVoicesFrame(v);m.data.voiceRows.forEach(x=>notes.add(x.note))},onWaveChunk:c=>{const w=wave.feed(c);if(w){windows++;assert.equal(w.columns.length,128);assert.deepEqual(w.columns[0],[-12,12])}}})
 for(const row of rows){const [ms,p,hex]=row.split(',');if(Number(p)!==period)continue;now=Number(ms);feed(Uint8Array.from(Buffer.from(hex,'hex')).buffer)}
 assert.ok(windows>=2);assert.ok(voices>=15);assert.ok(notes.has('C4')&&notes.has('C5'));assert.ok([...cues].some(x=>/摇杆1 X/.test(x)));assert.ok([...cues].some(x=>/摇杆1 Y/.test(x)))
 off();console.log(`PASS actual S3 ATT20 -> actual JS parser/model: period=${period}, voice_frames=${voices}, complete_wave_windows=${windows}, C4/C5 and glide/vibrato cues present`)
}
