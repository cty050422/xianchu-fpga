const {test}=require('node:test')
const assert=require('node:assert/strict')
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm')
const {createRequire}=require('node:module')
const filename=path.resolve(__dirname,'../pages/index/index.js')
const protocol=require('../utils/protocol')

function fixture({failWrite=false}={}) {
  let page,notification,writes=0
  const wx={
    onBLECharacteristicValueChange(fn){notification=fn},
    offBLECharacteristicValueChange(){notification=null},
    onBLEConnectionStateChange(){},
    writeBLECharacteristicValue(o){
      writes++
      if(failWrite){o.fail({errMsg:'writeBLECharacteristicValue:fail 10008'});return}
      const sent=new Uint8Array(o.value)
      assert.equal(sent[3],0x14)
      const reply=protocol.frame(0x80,240,[1,16,0,0,0,0,0,0,0,0,0,32,0,sent[5],0])
      o.success({})
      queueMicrotask(()=>{
        for(const value of [reply.slice(0,20),reply.slice(20)])notification({
          deviceId:'phone-fixture',serviceId:protocol.SERVICE_UUID,
          characteristicId:protocol.STATUS_UUID,value})
      })
    }
  }
  vm.runInNewContext(fs.readFileSync(filename,'utf8'),{
    require:createRequire(filename),wx,Page:p=>page=p,Uint8Array,ArrayBuffer,console,
    setTimeout,clearTimeout
  },{filename})
  page.data={...page.data};page.setData=p=>Object.assign(page.data,p)
  page.onLoad();page.deviceId='phone-fixture';page.setData({connected:true})
  page.readIdentity=async()=>({phoneArm:true,armed:true,authenticated:true})
  return {page,writes:()=>writes}
}

test('legacy client can retry PING and settles only a reassembled FPGA answer',async()=>{
  const f=fixture()
  assert.equal(f.page.data.phoneArmAvailable,false)
  assert.equal(await f.page.ping(),true)
  assert.equal(f.writes(),1);assert.equal(f.page.data.busy,false)
  assert.equal(f.page.data.statusFrameCount,1)
  assert.equal(f.page.data.lastStatusCommand,0)
  assert.match(f.page.data.message,/FPGA 已应答 PING/)
})

test('PING cannot send while disconnected or another operation is busy',async()=>{
  const f=fixture();f.page.setData({connected:false})
  assert.equal(await f.page.ping(),false)
  f.page.setData({connected:true,busy:true})
  assert.equal(await f.page.ping(),false);assert.equal(f.writes(),0)
})

test('BLE write failure retains platform error and cannot report FPGA success',async()=>{
  const f=fixture({failWrite:true})
  assert.equal(await f.page.ping(),false)
  assert.match(f.page.data.message,/10008/)
  assert.doesNotMatch(f.page.data.message,/未定义结果|已应答/)
  assert.equal(f.page.data.busy,false)
})

test('R3 timeout asks for phone authentication rather than legacy USB-only ARM',async()=>{
  const f=fixture();f.page.setData({phoneArmAvailable:true})
  f.page.issuer={submit:async()=>{throw {code:'TIMEOUT_UNKNOWN',message:'timeout'}}}
  assert.equal(await f.page.ping(),false)
  assert.match(f.page.data.message,/配对授权/)
  assert.doesNotMatch(f.page.data.message,/R1\/R2/)
})

test('expired R3 authority refuses to transmit instead of waiting for a fake PING timeout',async()=>{
  const f=fixture();f.page.setData({phoneArmAvailable:true})
  f.page.readIdentity=async()=>({phoneArm:true,armed:false,authenticated:true})
  assert.equal(await f.page.ping(),false)
  assert.equal(f.writes(),0);assert.equal(f.page.data.armedText,'未授权')
  assert.match(f.page.data.message,/授权未确认或已过期/)
})

test('an S3 expiry notice updates stale phone authorization state',()=>{
  const f=fixture();f.page.setData({armedText:'已授权',phoneArmAvailable:true})
  f.page.handleCharacteristic({deviceId:'phone-fixture',serviceId:protocol.SERVICE_UUID,
    characteristicId:'7a330004-4b62-4f70-9f60-66706761736d',
    value:Uint8Array.from(Buffer.from('AUTH / LINK EXPIRED')).buffer})
  assert.equal(f.page.data.armedText,'未授权')
  assert.match(f.page.data.message,/授权已失效/)
})

test('an old PING completion cannot clear a replacement operation busy state',async()=>{
  const f=fixture();let complete
  f.page.issuer={submit:()=>new Promise(resolve=>{complete=resolve})}
  const pending=f.page.ping()
  await new Promise(setImmediate)
  f.page.generation++;f.page.setData({message:'replacement',busy:true})
  complete({sequence:7})
  assert.equal(await pending,false)
  assert.equal(f.page.data.message,'replacement');assert.equal(f.page.data.busy,true)
})

test('the retry button remains available to legacy clients in the device workspace',()=>{
  const wxml=fs.readFileSync(path.resolve(__dirname,'../pages/index/index.wxml'),'utf8')
  const buttons=[...wxml.matchAll(/<button\b([^>]*\bbindtap="ping"[^>]*)>([^<]*)/g)]
  assert.equal(buttons.length,1,'one independently usable PING entry is required')
  assert.match(buttons[0][2],/验证.*FPGA PING/)
  assert.match(buttons[0][1],/disabled="\{\{!connected \|\| busy\}\}"/)
  assert.doesNotMatch(buttons[0][1],/phoneArmAvailable|wx:if/,'R1/R2 must not lose the PING entry')
  assert.doesNotMatch(wxml,/<view[^>]*wx:if="\{\{phoneArmAvailable\}\}"/,
    'the PING row must not be nested in an R3-only conditional group')
})
