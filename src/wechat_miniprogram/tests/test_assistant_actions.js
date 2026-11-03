const {test}=require('node:test'),assert=require('node:assert/strict')
const {createSessionHub}=require('../services/device_session')
const compiler=require('../utils/score_compiler')
function entry(n=5){const score={schemaVersion:2,songId:'test-mary',revision:1,title:'玛丽',source:{type:'original',license:'CC0',attribution:'fixture'},difficulty:1,tags:[],bpm:90,timeSignature:[4,4],notes:Array.from({length:n},(_,i)=>({midi:[60,62,64,67][i%4],beats:1}))};return {score,contentHash:compiler.scoreContentHash(score),fromCache:false}}
async function fixture(n=5){
  const {createAssistantActions}=require('../services/assistant_actions')
  const hub=createSessionHub({}),map=new Map(),song=entry(n),storage={get:k=>map.get(k),set:(k,v)=>map.set(k,v)}
  const catalog={getBaseUrl:()=> 'http://fixture',detail:async()=>song}
  await hub.enterSimulator('normal');await hub.simPing()
  return {hub,map,song,catalog,api:createAssistantActions({hub,catalog,storage}),dev:hub._state.sim.transport.device}
}
test('a downloaded score previews without writes and commits through the full fragmented protocol only after confirmation',async()=>{
  const f=await fixture(),before=f.dev.state.commandCounter,plan=await f.api.prepareSong('test-mary')
  assert.equal(f.dev.state.commandCounter,before);assert.match(plan.title,/玛丽/)
  const result=await f.api.execute(plan);assert.equal(result.confirmation,'fpga-confirmed');assert.equal(f.dev.state.scoreLoaded,true);assert.equal(f.dev.state.steps.length,5)
  assert.equal(f.api.selected().songId,'test-mary');assert.ok(f.map.get('practice:currentSong'));assert.equal(f.hub.snapshot().activeScore.title,'玛丽');await f.hub.leaveSimulator()
})
test('four timbres, chorus ceiling and effects reach consumers instead of returning advice',async()=>{
  const f=await fixture()
  for(const preset of [0,1,2,3]){const r=await f.api.execute(f.api.prepareConfig([{field:20,value:preset}],{title:'音色'}));assert.equal(r.confirmation,'fpga-confirmed');assert.equal(r.readback.value,preset)}
  const wet=await f.api.execute(f.api.prepareConfig([{field:17,value:32}],{title:'合唱上限'}));assert.equal(wet.readback.value,32)
  const effect=await f.api.execute(f.api.prepareEffect(3));assert.equal(effect.status.effectMode,3);await f.hub.leaveSimulator()
})
test('challenge and free play use typed mode values and authoritative state',async()=>{
  const f=await fixture();await f.api.execute(await f.api.prepareSong('test-mary'))
  const challenge=await f.api.execute(f.api.prepareMode(2));assert.equal(challenge.status.mode,2);assert.ok(challenge.status.flags&2)
  const free=await f.api.execute(f.api.prepareMode(0));assert.equal(free.status.flags&2,0);await f.hub.leaveSimulator()
})
test('segment bounds are exact and no upload of the remainder is automatic',async()=>{
  const f=await fixture(65),first=await f.api.prepareSong('test-mary')
  const r=await f.api.execute(first);assert.equal(r.segmentIndex,0);assert.equal(r.segments,2);assert.equal(f.dev.state.steps.length,64)
  const second=await f.api.prepareSelected({segmentIndex:1});await f.api.execute(second);assert.equal(f.dev.state.steps.length,1)
  await assert.rejects(f.api.prepareSelected({segmentIndex:2}),e=>e.code==='NO_SUCH_SEGMENT');await f.hub.leaveSimulator()
})
test('a reconnect invalidates an old confirmation card even with the same simulator profile',async()=>{
  const f=await fixture(),plan=f.api.prepareConfig([{field:20,value:2}],{title:'音色'})
  await f.hub.leaveSimulator();await f.hub.enterSimulator('normal');await f.hub.simPing();const before=f.hub._state.sim.transport.device.state.commandCounter
  await assert.rejects(f.api.execute(plan),e=>e.code==='CONTEXT_CHANGED');assert.equal(f.hub._state.sim.transport.device.state.commandCounter,before);await f.hub.leaveSimulator()
})
test('unavailable fields and invalid bounds fail without a SET and without silent clamping',async()=>{
  const f=await fixture();assert.throws(()=>f.api.prepareConfig([{field:20,value:4}]),e=>e.code==='OUT_OF_RANGE')
  assert.throws(()=>f.api.prepareConfig([{field:13,value:12}]),e=>e.code==='UNSUPPORTED')
  let sets=0;f.hub.queryCapability=async()=>({supportedMask:0});f.hub.simConfigTransaction=async()=>{sets++}
  await assert.rejects(f.api.execute(f.api.prepareConfig([{field:20,value:2}])),e=>e.code==='UNSUPPORTED');assert.equal(sets,0);await f.hub.leaveSimulator()
})
test('disconnected confirmation saves only a draft, forged proposals cannot execute, and duplicate confirmation is single-flight',async()=>{
  const f=await fixture();await f.hub.leaveSimulator();const draft=f.api.prepareMode(1);const result=await f.api.execute(draft)
  assert.equal(result.confirmation,'draft');assert.equal(f.hub.snapshot().pendingActionCount,1)
  await assert.rejects(f.api.execute({...draft}),e=>e.code==='PLAN_INVALID')
  await f.hub.enterSimulator('normal');await f.hub.simPing();const plan=f.api.prepareConfig([{field:20,value:2}]);const pending=f.api.execute(plan)
  await assert.rejects(f.api.execute(plan),e=>['BUSY','PLAN_INVALID'].includes(e.code));await pending;await f.hub.leaveSimulator()
})
test('a late upload ACK after a connection change cannot publish a committed song identity',async()=>{
  const {createAssistantActions}=require('../services/assistant_actions'),map=new Map();let revision=1,finish
  const hub={snapshot:()=>({hardwareMode:'real',connectionRevision:revision,realDevice:{deviceId:'board'},freshness:'fresh',lastStatus:{flags:17}}),queryCapability:async()=>({supportedMask:0x3fffff}),simUploadSegmentV2:()=>new Promise(r=>finish=r)}
  const api=createAssistantActions({hub,catalog:{getBaseUrl:()=> 'http://fixture',detail:async()=>entry()},storage:{get:k=>map.get(k),set:(k,v)=>map.set(k,v)}})
  const plan=await api.prepareSong('test-mary'),pending=api.execute(plan)
  await new Promise(r=>setImmediate(r));revision++;finish({status:{flags:17,song:128}})
  await assert.rejects(pending,e=>e.code==='CONTEXT_CHANGED');assert.equal(map.has('practice:currentSong'),false)
})
test('a late score lookup cannot replace a newer selected song or its confirmation card',async()=>{
  const {createAssistantActions}=require('../services/assistant_actions');let resolveOld
  const map=new Map(),hub={snapshot:()=>({hardwareMode:'disconnected',connectionRevision:0})},old=entry(),newer=entry()
  old.score.songId='old';old.score.title='旧曲目';newer.score.songId='new';newer.score.title='新曲目'
  const api=createAssistantActions({hub,catalog:{getBaseUrl:()=> 'http://fixture',detail:id=>id==='old'?new Promise(r=>resolveOld=r):Promise.resolve(newer)},storage:{get:k=>map.get(k),set:(k,v)=>map.set(k,v)}})
  const pending=api.prepareSong('old'),current=await api.prepareSong('new')
  resolveOld(old);await assert.rejects(pending,e=>e.code==='PLAN_SUPERSEDED');assert.equal(api.selected().songId,'new')
  hub.saveDraft=()=>{};const result=await api.execute(current);assert.equal(result.confirmation,'draft')
})
test('untrusted song identifiers cannot become arbitrary HTTP paths',async()=>{
  const {createAssistantActions}=require('../services/assistant_actions');let gets=0
  const api=createAssistantActions({hub:{snapshot:()=>({hardwareMode:'disconnected'})},catalog:{getBaseUrl:()=> 'http://fixture',detail:async()=>{gets++;return entry()}}})
  for(const id of ['../secret','a?token=x','%2fprivate','https://example.com/x'])await assert.rejects(api.download(id),e=>e.code==='INVALID_SONG_ID')
  assert.equal(gets,0)
})
test('an HTTP lookup started for one connection cannot bind a confirmation to a replacement connection',async()=>{
  const {createAssistantActions}=require('../services/assistant_actions');let revision=1,resolve
  const api=createAssistantActions({hub:{snapshot:()=>({hardwareMode:'real',connectionRevision:revision,realDevice:{deviceId:'board'}})},catalog:{getBaseUrl:()=> 'http://fixture',detail:()=>new Promise(r=>resolve=r)}})
  const pending=api.prepareSong('test-mary');revision++;resolve(entry())
  await assert.rejects(pending,e=>e.code==='CONTEXT_CHANGED');assert.equal(api.selected(),null)
})
test('changing the score service during an upload cannot publish the old song under the new service',async()=>{
  const {createAssistantActions}=require('../services/assistant_actions'),map=new Map();let base='http://old',finish
  const hub={snapshot:()=>({hardwareMode:'real',connectionRevision:1,realDevice:{deviceId:'board'},freshness:'fresh'}),queryCapability:async()=>({supportedMask:0x3fffff}),simUploadSegmentV2:()=>new Promise(r=>finish=r)}
  const api=createAssistantActions({hub,catalog:{getBaseUrl:()=>base,detail:async()=>entry()},storage:{get:k=>map.get(k),set:(k,v)=>map.set(k,v)}})
  const plan=await api.prepareSong('test-mary'),pending=api.execute(plan);await new Promise(r=>setImmediate(r));base='http://new';finish({status:{flags:17,song:128}})
  await assert.rejects(pending,e=>e.code==='SOURCE_CHANGED');assert.equal(map.has('practice:currentSong'),false)
})
