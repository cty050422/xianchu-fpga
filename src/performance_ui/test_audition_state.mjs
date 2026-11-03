import{test}from'node:test';import assert from'node:assert/strict';import{decodeFrame}from'./protocol.mjs';
test('new audition flag is separate from calibration refusal in the existing panel record',()=>{
 const p=new Uint8Array(53);p[39]=1;p[52]=2;const r=decodeFrame(0x22,p);assert.equal(r.panel.audition,true);assert.equal(r.panel.calRefused,false);
 p[52]=1;const s=decodeFrame(0x22,p);assert.equal(s.panel.audition,false);assert.equal(s.panel.calRefused,true);
})
