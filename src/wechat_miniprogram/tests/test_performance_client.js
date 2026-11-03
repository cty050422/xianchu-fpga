const {test}=require('node:test'),assert=require('node:assert/strict')
let api={};try{api=require('../utils/performance_client')}catch(e){if(e.code!=='MODULE_NOT_FOUND')throw e}
test('audio downloads carry authorization in headers, never URLs',async()=>{assert.equal(typeof api.createPerformanceClient,'function');let seen;const wx={downloadFile:o=>{seen=o;o.success({statusCode:200,tempFilePath:'/tmp/download.wav'});return{abort(){}}}};const c=api.createPerformanceClient({wx,getBaseUrl:()=> 'http://host:8891',getToken:()=> 'private-token'});const r=await c.download('take-'+'a'.repeat(24));assert.equal(r,'/tmp/download.wav');assert.equal(seen.header['x-device-token'],'private-token');assert.ok(!seen.url.includes('private-token'))})
test('service cancellation rejects settled operations and ignores late callbacks',async()=>{let cb,aborted=0;const c=api.createPerformanceClient({wx:{request:o=>{cb=o;return{abort(){aborted++}}}},getBaseUrl:()=> 'http://old',getToken:()=> ''});const p=c.list();c.cancelAll();await assert.rejects(p,e=>e.code==='CANCELLED');cb.success({statusCode:200,data:{items:[{id:'wrong'}]}});assert.equal(aborted,1)})
test('best effort capture stop is bound to the old service and credentials even after switching and cancellation',async()=>{
  let base='http://old',token='old-private',seen,aborts=0
  const c=api.createPerformanceClient({wx:{request:o=>{seen=o;return{abort(){aborts++}}}},getBaseUrl:()=>base,getToken:()=>token})
  const old=c.captureControl();base='http://new';token='new-private';const stopped=old.stop('take-old');c.cancelAll()
  assert.equal(seen.url,'http://old/performances/v1/takes/take-old/stop');assert.equal(seen.header['x-device-token'],'old-private');assert.equal(aborts,0)
  seen.success({statusCode:200});assert.equal(await stopped,true)
})
test('cancelled or rejected downloads dispose the native temporary file returned after cancellation',async()=>{
  let callback;const deleted=[]
  const c=api.createPerformanceClient({wx:{downloadFile:o=>{callback=o;return{abort(){}}},getFileSystemManager:()=>({unlink:o=>deleted.push(o.filePath)})},getBaseUrl:()=> 'http://host',getToken:()=> 'private'})
  const pending=c.download('take-late');c.cancelAll();await assert.rejects(pending,e=>e.code==='CANCELLED')
  callback.success({statusCode:200,tempFilePath:'/temporary/late.wav'});assert.deepEqual(deleted,['/temporary/late.wav'])
  const denied=c.download('take-denied');callback.success({statusCode:401,tempFilePath:'/temporary/denied.wav'});await assert.rejects(denied,e=>e.statusCode===401)
  assert.deepEqual(deleted,['/temporary/late.wav','/temporary/denied.wav'])
})
