// Fake WeChat API: a read response may arrive before its success callback.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {createRequire}=require('node:module');
const filename=path.resolve(__dirname,'../pages/index/index.js');
function fixture(changeGeneration=false){
 let page;const listeners=new Set();
 const wx={onBLECharacteristicValueChange:fn=>listeners.add(fn),
  offBLECharacteristicValueChange:fn=>listeners.delete(fn),
  readBLECharacteristicValue(options){
   if(changeGeneration)page.generation++;
   const value=new TextEncoder().encode('XC-LINK-R2-TEST armed=0 protocol=1').buffer;
   for(const fn of [...listeners])fn({deviceId:'fixture-device',serviceId:'7a330001-4b62-4f70-9f60-66706761736d',
    characteristicId:'7a330004-4b62-4f70-9f60-66706761736d',value});
   options.success({});
  }};
 vm.runInNewContext(fs.readFileSync(filename,'utf8'),{require:createRequire(filename),wx,
  Page:value=>{page=value;},setTimeout,clearTimeout,console,Uint8Array,ArrayBuffer},{filename});
 page.deviceId='fixture-device';page.generation=1;page.setData=patch=>Object.assign(page.data,patch);
 return {page,listeners};
}
test('identity listener exists before an immediate BLE read response',async()=>{
 const {page,listeners}=fixture();await page.readIdentity();
 assert.equal(page.data.identityBuild,'XC-LINK-R2-TEST');
 assert.equal(listeners.size,0);
});
test('an old read cannot update a replacement connection',async()=>{
 const {page,listeners}=fixture(true);await page.readIdentity();
 assert.equal(page.data.identityBuild,'-');assert.equal(listeners.size,0);
});
