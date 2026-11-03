const{test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const{createRequire}=require('node:module');
test('native page unload does not close the app-owned BLE connection or install a second receiver',()=>{
 let receivers=0,closed=0;const wx={onBLECharacteristicValueChange(){receivers++},onBLEConnectionStateChange(){},offBLECharacteristicValueChange(){},offBLEConnectionStateChange(){},closeBLEConnection(){closed++},closeBluetoothAdapter(){}};
 const app={globalData:{sessionHub:{subscribe:()=>()=>{},publishReal(){}},controlLease:null}};
 app.getInstrumentController=()=>app.controller||(app.controller=require('../../src/wechat_miniprogram/services/instrument_controller').createInstrumentController({wx,app}));
 function page(){let p;const file=path.resolve(__dirname,'../../src/wechat_miniprogram/pages/index/index.js');vm.runInNewContext(fs.readFileSync(file,'utf8'),{require:createRequire(file),Page:x=>p=x,wx,getApp:()=>app,setTimeout,clearTimeout});p.data=structuredClone(p.data);p.setData=x=>Object.assign(p.data,x);p.onLoad();return p;}
 const a=page();a.onUnload();const b=page();b.onUnload();assert.equal(receivers,1);assert.equal(closed,0);app.controller.shutdown();
});
