const{test}=require('node:test'),assert=require('node:assert/strict');
const p=require('../../src/wechat_miniprogram/utils/protocol');
const{decodeControl,createWaveAssembler}=require('../../src/wechat_miniprogram/utils/mobile_observer');
test('actual direction comes from signed calibrated axes, not expected hint',()=>{
 const a=new Uint8Array(31);a[0]=1;a[1]=2;a[2]=2;a[8]=1;a[9]=2;a[10]=1;a[12]=1;a[15]=0;a[16]=0x90;
 a[17]=0;a[18]=4;a[19]=0;a[20]=2;a[21]=0;a[22]=254;a[25]=31;
 const c=decodeControl(a);assert.equal(c.glide.rod,'↓');assert.equal(c.vibrato.rod,'←');assert(c.glide.cents>0);assert(c.glide.active);
 a[10]=0;assert(!decodeControl(a).glide.active);assert.equal(decodeControl(a).glide.label,'待用');
});
test('MTU20 chunks reassemble one real window; missing/mixed/stale windows rejected',()=>{
 let now=0;const w=createWaveAssembler({now:()=>now});let completed;
 function b(id,i){return Uint8Array.from([1,1,id,0,i,8,...Array.from({length:32},(_,j)=>j%2?60:206)])}
 assert.equal(w.feed(b(1,2)),null);for(let i=0;i<8;i++)completed=w.feed(b(2,i));assert.equal(completed.columns.length,128);assert.deepEqual(completed.columns[0],[-50,60]);
 w.feed(b(3,0));assert.equal(w.feed(b(4,1)),null);w.feed(b(5,0));now=4000;assert.equal(w.feed(b(5,1)),null);
});
test('interleaved types remain whole and CRC checked across ATT20',()=>{
 const a=new Uint8Array(31);a[0]=1;let controls=0;const f=new Uint8Array(p.frame(0x82,4,Array.from(a)));
 const parser=p.createReplyParser({onControl:()=>controls++});parser(f.slice(0,20).buffer);parser(f.slice(20).buffer);assert.equal(controls,1);
 f[f.length-1]^=1;parser(f.buffer);assert.equal(controls,1);
});

test('paused or resumed interrupted challenge cannot retain a valid counter grade',()=>{
 const {createCounterTracker}=require('../../src/wechat_miniprogram/utils/performance_assessment');
 const a={hardwareMode:'real',freshness:'fresh',connectionRevision:1,lastStatus:{mode:2,flags:18,song:1,hits:1,wrong:0,misses:0},observer:{session:1,transport:2,interrupted:false}};
 const t=createCounterTracker();t.begin(a);t.observe({...a,observer:{session:1,transport:2,interrupted:true}});assert.equal(t.finish().status,'incomplete');
});
