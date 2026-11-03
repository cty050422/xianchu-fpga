const {test}=require('node:test')
const assert=require('node:assert/strict')
const {createIssuer}=require('../utils/transaction')
const protocol=require('../utils/protocol')
function fixture(send){const timers=[];const issuer=createIssuer({send:send||(()=>Promise.resolve()),setTimeout:fn=>(timers.push(fn),timers.length),clearTimeout:()=>{}});return{issuer,timers}}
test('config cannot be acknowledged by periodic status with the same low sequence',async()=>{
 const {issuer}=fixture();const p=issuer.submit(seq=>protocol.configFrame({op:3,field:0,sequence:seq}),{type:0x15});p.catch(()=>{});
 try{assert.equal(issuer.onStatus({commandSequence:0,commandResult:0}),false);assert.equal(issuer.busy,true)}finally{issuer.reset();await p.catch(()=>{})}
})
test('config response must match operation and field as well as sequence',async()=>{
 const {issuer}=fixture();const p=issuer.submit(seq=>protocol.configFrame({op:2,field:20,sequence:seq}),{type:0x15});p.catch(()=>{});
 try{assert.equal(issuer.onStatus({commandSequence:0,commandResult:0,configReply:{op:2,field:19}}),false);assert.equal(issuer.busy,true)}finally{issuer.reset();await p.catch(()=>{})}
})
test('a missing wx write callback is bounded by the complete transaction timeout',async()=>{
 const {issuer,timers}=fixture(()=>new Promise(()=>{}));const p=issuer.submit(seq=>protocol.pingFrame(seq));p.catch(()=>{});
 try{assert.equal(timers.length,1);timers[0]();await assert.rejects(p,e=>e.code==='TIMEOUT_UNKNOWN')}finally{issuer.reset();await p.catch(()=>{})}
})
test('a late write rejection after reconnect cannot cancel the new request',async()=>{
 let rejectOld;let sends=0;const {issuer}=fixture(()=>++sends===1?new Promise((r,j)=>rejectOld=j):new Promise(()=>{}));
 const old=issuer.submit(seq=>protocol.pingFrame(seq));old.catch(()=>{});issuer.reset();await old.catch(()=>{});
 const next=issuer.submit(seq=>protocol.pingFrame(seq));next.catch(()=>{});
 try{rejectOld(Error('late GATT failure'));await Promise.resolve();await Promise.resolve();assert.equal(issuer.busy,true);assert.equal(issuer.currentSequence(),0)}finally{issuer.reset();await next.catch(()=>{})}
})
