const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const filename=path.resolve(__dirname,'../pages/index/index.js');
function fixture({confirm=true,replace=false,old=false}={}){
 let page,writes=0;const timers=[];
 const wx={notifyBLECharacteristicValueChange:o=>o.success({}),writeBLECharacteristicValue(o){writes++;
   assert.equal(o.characteristicId,'7a330004-4b62-4f70-9f60-66706761736d');
   assert.equal(Buffer.from(o.value).toString(),'ARM');
   if(replace){page.generation++;page.deviceId='replacement';page.setData({message:'replacement',busy:true})}
   o.success({});}};
 vm.runInNewContext(fs.readFileSync(filename,'utf8'),{require:createRequire(filename),wx,
   Page:p=>page=p,Uint8Array,ArrayBuffer,console,
   setTimeout:fn=>{timers.push(fn);queueMicrotask(fn);return timers.length},clearTimeout:()=>{}},{filename});
 page.generation=1;page.deviceId='test';page.data={...page.data,connected:true,phoneArmAvailable:!old};
 page.setData=p=>Object.assign(page.data,p);page.readIdentity=async()=>({armed:confirm,phoneArm:true,authenticated:true});
 return {page,writes:()=>writes};
}
test('R3 ARM is explicit and requires independent firmware readback',async()=>{
 const f=fixture();assert.equal(await f.page.armPhone(),true);assert.equal(f.writes(),1);
 assert.match(f.page.data.message,/读回确认授权/);assert.equal(f.page.data.busy,false);
});
test('a successful GATT write without armed readback must not report success',async()=>{
 const f=fixture({confirm:false});assert.equal(await f.page.armPhone(),false);
 assert.match(f.page.data.lastError,/不等于ARM成功/);
});
test('late ARM completion cannot overwrite replacement connection UI',async()=>{
 const f=fixture({replace:true});assert.equal(await f.page.armPhone(),false);
 assert.equal(f.page.data.message,'replacement');assert.equal(f.page.data.busy,true);
});
test('R1/R2 do not silently receive unsupported ARM over BLE',async()=>{
 const f=fixture({old:true});assert.equal(await f.page.armPhone(),false);assert.equal(f.writes(),0);
});
test('R3 identity capability is distinct from armed/authenticated state',()=>{
 const d=require('../utils/discovery');const a=d.parseIdentity('XC-LINK-R3-20261023 armed=0 protocol=1 auth=0 phone_arm=1');
 assert.equal(a.phoneArm,true);assert.equal(a.armed,false);assert.equal(a.authenticated,false);
 assert.equal(d.parseIdentity('XC-LINK-R2-20261022').phoneArm,false);
});

test('closing a page while opening Bluetooth cannot later start discovery',async()=>{
 let page,completeOpen,scans=0;
 const wx={openBluetoothAdapter:o=>{completeOpen=o.success},
  startBluetoothDevicesDiscovery:()=>{scans++},stopBluetoothDevicesDiscovery:o=>o.success({}),
  offBLECharacteristicValueChange(){},offBLEConnectionStateChange(){},closeBluetoothAdapter(){}};
 vm.runInNewContext(fs.readFileSync(filename,'utf8'),{require:createRequire(filename),wx,
  Page:p=>page=p,Uint8Array,ArrayBuffer,console,setTimeout,clearTimeout},{filename});
 page.generation=0;page.deviceId='';page.data={...page.data};page.setData=p=>Object.assign(page.data,p);
 const pending=page.connect();page.onUnload();const snapshot=JSON.stringify(page.data);
 completeOpen({});await pending;
 assert.equal(scans,0);assert.equal(JSON.stringify(page.data),snapshot);
});

test('disconnect after the last STEP cannot COMMIT onto a replacement session',async()=>{
 const f=fixture(),song=require('../utils/protocol').SONGS[0];let calls=0;
 f.page.issuer={submit:async()=>{
  calls++;
  if(calls===song.steps.length+1){f.page.generation++;f.page.setData({message:'replacement',connected:false})}
  return {};
 }};
 await f.page.downloadSong();
 assert.equal(calls,song.steps.length+1,'old download must stop before COMMIT');
 assert.equal(f.page.data.message,'replacement');
 assert.notEqual(f.page.data.uploadProgress,'提交');
});
