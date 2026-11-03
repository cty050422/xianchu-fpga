const {test}=require('node:test'),assert=require('node:assert/strict')
const A=require('../utils/audition_score')
test('audition compiles arbitrary pitches, 4-note chords and rests, not zone modulo',()=>{
 const r=A.compileTimeline([{startMs:0,endMs:500,notes:[60,64,67,72]},{startMs:700,endMs:1000,notes:[61]}]);
 assert.equal(r.steps.length,3);assert.deepEqual(r.steps[0].notes,[60,64,67,72]);assert.deepEqual(r.steps[1].notes,[]);assert.equal(r.steps[1].samples,9600);assert.deepEqual(r.steps[2].notes,[61]);assert.equal(r.samples,48000)
})
test('unsupported polyphony/range/too short rejected, never silently dropped',()=>{
 for(const notes of [[60,61,62,63,64],[35],[97]])assert.throws(()=>A.compileTimeline([{startMs:0,endMs:500,notes}]))
 assert.throws(()=>A.compileTimeline([{startMs:0,endMs:1,notes:[60]}]))
})
test('steps checksum and 15-byte frame CRC are independent and stable',()=>{
 const r=A.compileTimeline([{startMs:0,endMs:500,notes:[60]}]);const b=A.stepPayload(r.steps[0],0);assert.deepEqual(b,[0,60,0,0,0,192,93,0]);
 const f=new Uint8Array(A.frame(0x1c,9,b));assert.equal(f.length,15);assert.equal(f[14],A.crc(f.slice(2,14)));assert.equal(r.crc,A.crc(b));
})
test('catalog musical notes retain rhythm and can use more than four distinct pitches',()=>{
 const r=A.fromCatalog({bpm:120,notes:[{midi:60,beats:1},{midi:62,beats:1},{midi:64,beats:1},{midi:65,beats:1},{midi:67,beats:1}]});assert.equal(r.steps.length,5);assert.equal(r.samples,120000)
})
