import {test}from'node:test';import assert from'node:assert/strict';import {transcribeMono,parseMidi}from'./transcription.mjs';
test('continuous monophonic sequence and rests retain pitch, no recording source on board',()=>{
 const rate=8000,a=new Float32Array(rate*2);for(let i=0;i<a.length;i++){let hz=i<rate*.7?261.625:i<rate?0:329.628;a[i]=hz?.4*Math.sin(2*Math.PI*hz*i/rate):0}
 const r=transcribeMono(a,rate);assert.ok(r.timeline.some(x=>x.notes[0]===60));assert.ok(r.timeline.some(x=>x.notes[0]===64));assert.ok(r.compiled.steps.some(x=>!x.notes.length));assert.equal(r.needsConfirmation,true);assert.equal(r.method,'monophonic_yin');
})
test('silence is rejected rather than invented notes',()=>assert.throws(()=>transcribeMono(new Float32Array(8000),8000),/NO_MELODY/))
test('MIDI parser reads note-on/off and tempo; malformed and SMPTE rejected',()=>{
 const b=Buffer.from('4d546864000000060000000100604d54726b0000000c00903c4060803c0000ff2f00','hex');
 const r=parseMidi(b);assert.deepEqual(r.timeline,[{startMs:0,endMs:500,notes:[60]}]);assert.equal(r.compiled.steps[0].samples,24000);
 assert.throws(()=>parseMidi(Buffer.from('MThd')));const c=Buffer.from(b);c.writeUInt16BE(0xe728,12);assert.throws(()=>parseMidi(c),/SMPTE/)
})
test('standard SysEx is skipped without shifting the following notes',()=>{
 const b=Buffer.from('4d546864000000060000000100604d54726b0000001100f0027ef700903c4060803c0000ff2f00','hex');
 assert.deepEqual(parseMidi(b).timeline,[{startMs:0,endMs:500,notes:[60]}]);
})
