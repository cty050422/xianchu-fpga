const {test}=require('node:test')
const assert=require('node:assert/strict')
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm')
const {createRequire}=require('node:module')
const filename=path.resolve(__dirname,'../pages/index/index.js')
const protocol=require('../utils/protocol')

// Compatibility model: replacing/removing an API value callback can leave the
// page without its original receiver. This models the failure mechanism; it
// does not assert that every WeChat version implements its event API this way.
function fixture() {
  let page,receiver=null
  const wx={
    onBLECharacteristicValueChange(fn){receiver=fn},
    offBLECharacteristicValueChange(){receiver=null},
    onBLEConnectionStateChange(){},
    readBLECharacteristicValue(o){
      if(receiver)receiver({deviceId:'receiver-test',serviceId:protocol.SERVICE_UUID,
        characteristicId:'7a330004-4b62-4f70-9f60-66706761736d',
        value:Uint8Array.from(Buffer.from('XC-LINK-R3-TEST armed=1 protocol=1 auth=1 phone_arm=1')).buffer})
      o.success({})
    }
  }
  const contents=fs.readFileSync(process.env.PING_PAGE_SOURCE||filename,'utf8')
  vm.runInNewContext(contents,{require:createRequire(filename),wx,Page:p=>page=p,
    Uint8Array,ArrayBuffer,console,setTimeout,clearTimeout},{filename})
  page.data={...page.data};page.setData=p=>Object.assign(page.data,p);page.onLoad()
  page.deviceId='receiver-test';page.generation=1
  page.setData({connected:true,deviceName:'XianChu-LINK-R3',phoneArmAvailable:true})
  const emit=value=>{if(receiver)receiver({deviceId:'receiver-test',
    serviceId:protocol.SERVICE_UUID,characteristicId:protocol.STATUS_UUID,value})}
  return {page,emit,hasReceiver:()=>!!receiver,dropReceiver:()=>{receiver=null}}
}

test('identity read cleanup must leave the status receiver installed',async()=>{
  const f=fixture();await f.page.readIdentity()
  assert.equal(f.page.data.identityBuild,'XC-LINK-R3-TEST')
  assert.equal(f.hasReceiver(),true,'identity cleanup detached the status callback')
  const bytes=protocol.frame(0x80,77,[0,16,0,0,0,0,0,0,0,0,0,32,0,9,0])
  f.emit(bytes.slice(0,20));f.emit(bytes.slice(20))
  assert.equal(f.page.data.statusFrameCount,1)
  assert.equal(f.page.data.lastStatusCommand,9)
  assert.equal(f.page.data.statusPacketCount,2)
  assert.equal(f.page.data.statusByteCount,22)
})

test('restoring an adapter receiver does not send a command or authorize it',()=>{
  const f=fixture();f.dropReceiver()
  f.page.restoreValueReceiver()
  assert.equal(f.hasReceiver(),true)
  assert.equal(f.page.data.armedText,'未知')
})

test('raw status packets are observable even when a fragment is corrupt',()=>{
  const f=fixture();const b=protocol.frame(0x80,77,[0,16,0,0,0,0,0,0,0,0,0,32,0,9,0])
  const corrupt=new Uint8Array(b);corrupt[21]^=1;f.emit(corrupt.buffer)
  assert.equal(f.page.data.statusPacketCount,1)
  assert.equal(f.page.data.statusByteCount,22)
  assert.equal(f.page.data.statusFrameCount,0)
})
