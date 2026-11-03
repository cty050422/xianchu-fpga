const{test}=require('node:test'),assert=require('node:assert/strict'),{createAuditionSession}=require('../services/audition_session'),A=require('../utils/audition_score')
function rig(){let listener,s={hardwareMode:'real',freshness:'fresh',connectionRevision:1,lastStatus:{flags:16,step:0}},calls=[],timer;
 const hub={snapshot:()=>s,subscribe:f=>{listener=f;return()=>{}},auditionCommand:async(op,p)=>{calls.push([op,p]);if(op===0x1e&&p[0]===1)s.lastStatus.flags=112;return {ok:true}}};
 const session=createAuditionSession({hub,setTimer:f=>{timer=f;return 1},clearTimer:()=>{timer=null}});
 return{session,calls,set:v=>{Object.assign(s,v);listener(s)},tick:()=>timer&&timer(),s}
}
test('one explicit start after complete upload; capability first, heartbeat and real finish',async()=>{
 const r=rig(),score=A.compileTimeline([{startMs:0,endMs:300,notes:[60,64]}]);assert.equal(r.calls.length,0);
 await r.session.play(score,0,2);assert.deepEqual(r.calls.map(x=>x[0]),[31,27,28,29,30]);assert.equal(r.calls.at(-1)[1][0],1);assert.equal(r.session.snapshot().phase,'playing');
 await r.tick();assert.equal(r.calls.at(-1)[0],31);r.set({lastStatus:{flags:16,step:0}});assert.equal(r.session.snapshot().phase,'finished')
})
test('disconnected, simulator, guide and calibration reject before any write',async()=>{
 for(const change of [{hardwareMode:'disconnected'},{hardwareMode:'simulator'},{freshness:'stale'},{lastStatus:{flags:18}},{lastStatus:{flags:0}}]){const r=rig();r.set(change);await assert.rejects(r.session.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}])));assert.equal(r.calls.length,0)}
})
test('connection switch clears timer/state; never replay score',async()=>{
 const r=rig();await r.session.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}]));r.set({connectionRevision:2,hardwareMode:'disconnected'});const n=r.calls.length;await r.tick();assert.equal(r.calls.length,n);assert.equal(r.session.snapshot().phase,'idle')
})
test('background stop is an acknowledged STOP, not just a changed UI',async()=>{const r=rig();await r.session.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}]));await r.session.pause();assert.equal(r.calls.at(-1)[0],30);assert.equal(r.calls.at(-1)[1][0],0);assert.equal(r.session.snapshot().phase,'stopped')})
test('double hide shares one STOP promise; pending stop cannot look confirmed',async()=>{
 const r=rig();await r.session.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}]));
 let release;const old=r.session.stop();const second=r.session.pause();
 assert.equal(r.session.snapshot().phase,'stopping');await Promise.all([old,second]);assert.equal(r.calls.filter(x=>x[0]===30&&x[1][0]===0).length,1)
})
test('lost START ACK stays unknown and STOP really reaches FPGA',async()=>{
 let s={hardwareMode:'real',freshness:'fresh',connectionRevision:1,lastStatus:{flags:16}},calls=[];
 const hub={snapshot:()=>s,subscribe:()=>()=>{},auditionCommand:async(op,p)=>{calls.push([op,p]);if(op===30&&p[0]===1)throw {code:'TIMEOUT_UNKNOWN',message:'ACK lost'};return {ok:true}}};
 const c=createAuditionSession({hub});await assert.rejects(c.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}])));
 assert.equal(c.snapshot().phase,'unknown');await c.stop();assert.equal(calls.at(-1)[0],30);assert.equal(calls.at(-1)[1][0],0);assert.equal(c.snapshot().phase,'stopped')
})
test('queued old STOP never crosses to a replacement connection',async()=>{
 let listener,rejectQuery,calls=[],s={hardwareMode:'real',freshness:'fresh',connectionRevision:1,lastStatus:{flags:16}};
 const hub={snapshot:()=>s,subscribe:f=>{listener=f;return()=>{}},auditionCommand:(op,p)=>{calls.push({op,rev:s.connectionRevision});if(op===31)return new Promise((resolve,reject)=>{rejectQuery=reject});return Promise.resolve({ok:true})}};
 const c=createAuditionSession({hub});const playing=c.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}])).catch(()=>{});
 await new Promise(r=>setImmediate(r));const stop=c.stop();s={...s,connectionRevision:2};listener(s);rejectQuery(Error('old link closed'));await Promise.all([playing,stop]);
 assert.deepEqual(calls,[{op:31,rev:1}]);assert.equal(c.snapshot().phase,'idle')
})
test('capability probe alone can safely retry a stale last-sequence collision',async()=>{
 let attempts=0,s={hardwareMode:'real',freshness:'fresh',connectionRevision:1,lastStatus:{flags:16}};
 const hub={snapshot:()=>s,subscribe:()=>()=>{},auditionCommand:async(op,p)=>{if(op===31&&++attempts===1)throw {code:'FPGA_RESULT',result:231};if(op===30&&p[0]===1)s.lastStatus.flags=112;return{ok:true}}};
 const c=createAuditionSession({hub,setTimer:()=>1,clearTimer:()=>{}});await c.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}]));assert.equal(attempts,2);assert.equal(c.snapshot().phase,'playing');await c.stop()
})

test('fresh remote audition after reconnect must receive STOP even when local session is idle',async()=>{
 const r=rig();r.set({lastStatus:{flags:112,step:3}});assert.equal(r.session.snapshot().phase,'idle');
 await r.session.stop();assert.deepEqual(r.calls,[[30,[0,0,0]]]);assert.equal(r.session.snapshot().phase,'stopped')
})
