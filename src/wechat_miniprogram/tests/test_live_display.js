const {test}=require('node:test'),assert=require('node:assert/strict')
const {createInstrumentModel}=require('../services/instrument_model')
const {decodeControl}=require('../utils/mobile_observer')
function control(mode,expression){const a=Array(31).fill(0);a[0]=1;a[1]=mode;a[2]=2;a[3]=8;a[8]=1;a[9]=3;a[10]=5;a[11]=5;a[12]=expression;a[13]=2;a[14]=5;a[16]=128;a[23]=32;a[25]=31;return decodeControl(a)}
function fixture(){const m=createInstrumentModel({},undefined,setTimeout,clearTimeout,setInterval,clearInterval);m.data=structuredClone(m.data);m.setData=p=>Object.assign(m.data,p);return m}
test('0x82 alone updates guide/challenge targets and assembled joystick cues',()=>{
 const m=fixture();m.applyControl(control(1,1));assert.equal(m.data.guideActive,true);assert.equal(m.data.targetLabel,'1+3');assert.match(m.data.expressionText,/摇杆1.*X/);assert.match(m.data.expressionText,/↓.*升音/)
 m.applyControl(control(2,2));assert.equal(m.data.modeLabel,'挑战');assert.match(m.data.expressionText,/摇杆1.*Y/);assert.match(m.data.expressionText,/→.*\+/)
 const rest=control(2,2);rest.target=0;m.applyControl(rest);assert.match(m.data.expressionText,/休止/);assert.doesNotMatch(m.data.expressionText,/推住/)
})
test('fresh control keeps target cue when ordinary status lags; fault still suppresses it',()=>{
 const m=fixture();m.onControlFrame(control(2,2));const status={flags:0x91,song:1,step:0,target:0,targetMask:0,mode:0,expression:0,mappingReady:true,preset:0,effectMode:0,hits:0,wrong:0,misses:0,layout:0,partials:32,wet:0,commandResult:0}
 m.applyStatus(status);assert.equal(m.data.performanceMode,2);assert.match(m.data.expressionText,/摇杆1.*Y/)
 m.applyStatus({...status,flags:0x99});assert.doesNotMatch(m.data.expressionText,/[↑↓→←]/)
})
test('two voice frames arriving in one millisecond both reach the live rows',()=>{
 const {createSessionHub}=require('../services/device_session'),hub=createSessionHub({now:()=>1000})
 hub.publishReal({connected:true,deviceId:'real'})
 const m=fixture();m.hub=hub;const off=hub.subscribe(s=>m.onHubSnapshot(s))
 const voices=note=>({schema:2,voices:Array.from({length:4},(_,i)=>({active:i===0,note:note+i,region:i,preset:0,partials:32,gain:64,envelope:65535,effectFamily:0}))})
 hub.publishVoices(voices(60));assert.equal(m.data.voiceRows[0].note,'C4')
 hub.publishVoices(voices(62));assert.equal(m.data.voiceRows[0].note,'D4');off()
})
