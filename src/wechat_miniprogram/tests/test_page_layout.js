const {test}=require('node:test')
const assert=require('node:assert/strict')
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm')
const {createRequire}=require('node:module')
const file=path.resolve(__dirname,'../pages/index/index.js')
function boot(){
  let page,modal,writes=0,closed=0
  const wx={onBLECharacteristicValueChange(){},onBLEConnectionStateChange(){},
    showModal:o=>{modal=o},writeBLECharacteristicValue(){writes++},closeBLEConnection(){closed++}}
  vm.runInNewContext(fs.readFileSync(file,'utf8'),{require:createRequire(file),wx,
    Page:p=>page=p,Uint8Array,ArrayBuffer,console,setTimeout,clearTimeout})
  page.data=structuredClone(page.data);page.setData=p=>Object.assign(page.data,p);page.onLoad()
  return {page,modal:()=>modal,writes:()=>writes,closed:()=>closed}
}
test('workspace changes and song browsing never transmit or reset the BLE session',()=>{
  const f=boot(),p=f.page,issuer=p.issuer,receiver=p.onCharacteristic
  for(const view of ['device','songs','perform','unknown'])p.switchView({currentTarget:{dataset:{view}}})
  assert.equal(p.data.activeView,'perform');assert.equal(p.issuer,issuer);assert.equal(p.onCharacteristic,receiver)
  p.chooseSong({currentTarget:{dataset:{index:'3'}}});assert.equal(p.data.selectedSong,3)
  p.chooseSong({currentTarget:{dataset:{index:'-1'}}});assert.equal(p.data.selectedSong,3)
  assert.equal(f.writes(),0)
})
test('two thousand status updates change scalar values without growing the UI model or changing the selected panel',()=>{
  const p=boot().page;p.switchView({currentTarget:{dataset:{view:'device'}}})
  const keys=Object.keys(p.data).sort(),zones=JSON.stringify(p.data.guideZones)
  for(let i=0;i<2000;i++)p.applyStatus({flags:i%2?19:16,song:1,step:i%32,target:i%4,
    expression:i%3,hits:i,wrong:Math.floor(i/3),misses:Math.floor(i/5),partials:32,wet:128,commandResult:0})
  assert.equal(p.data.activeView,'device');assert.equal(p.data.hits,1999)
  assert.deepEqual(Object.keys(p.data).sort(),keys);assert.equal(JSON.stringify(p.data.guideZones),zones)
  assert.equal(p.data.guideZones.length,4)
})
test('long error text remains fully accessible without adding a log row or truncating the underlying message',()=>{
  const f=boot(),message='下载未确认：'.repeat(180)
  f.page.setData({lastError:message});f.page.showMessage()
  assert.equal(f.modal().content,message);assert.equal(f.modal().showCancel,false)
})
test('the main action guides disconnected users to setup without scanning or writing',()=>{
  const f=boot(),p=f.page
  p.primaryAction();assert.equal(p.data.activeView,'device');assert.equal(f.writes(),0)
  p.setData({connected:true,calibrated:true,songLoaded:false});p.primaryAction()
  assert.equal(p.data.activeView,'songs');assert.equal(f.writes(),0)
  let starts=0;p.startGuide=()=>starts++;p.setData({songLoaded:true,selectionCommitted:true});p.primaryAction()
  assert.equal(starts,1)
  p.setData({guideActive:true});p.primaryAction();assert.equal(starts,1)
})
test('choosing a different score cannot label the old committed score as the new selection',()=>{
  const p=boot().page;p.setData({connected:true,calibrated:true})
  const status={flags:17,song:1,step:0,target:0,expression:0,hits:0,wrong:0,misses:0,partials:32,wet:0,commandResult:0}
  p.applyStatus(status);assert.equal(p.data.selectionCommitted,true)
  p.onSongChange({detail:{value:3}});p.applyStatus(status)
  assert.equal(p.data.songLoaded,true,'the existing FPGA active bank is still loaded')
  assert.equal(p.data.selectionCommitted,false,'the newly browsed song is not downloaded')
  p.primaryAction();assert.equal(p.data.activeView,'songs')
})
test('manual disconnect invalidates the old session without transmitting a command',()=>{
  const f=boot(),p=f.page;p.deviceId='fixture';p.setData({connected:true,guideActive:true,songLoaded:true})
  const generation=p.generation;p.disconnect()
  assert.equal(p.data.connected,false);assert.equal(p.data.guideActive,false)
  assert.equal(p.generation,generation+1);assert.equal(f.closed(),1);assert.equal(f.writes(),0)
})
test('the page itself cannot scroll; only fixed-height library and diagnostic containers scroll',()=>{
  const config=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../pages/index/index.json'),'utf8'))
  const wxml=fs.readFileSync(path.resolve(__dirname,'../pages/index/index.wxml'),'utf8')
  const css=fs.readFileSync(path.resolve(__dirname,'../pages/index/index.wxss'),'utf8')
  assert.equal(config.disableScroll,true)
  assert.equal((wxml.match(/<scroll-view\b/g)||[]).length,2)
  assert.match(css,/\.message-slot\{[^}]*height:84rpx/)
  assert.match(css,/\.data-row\{[^}]*height:64rpx/)
  assert.match(css,/font-variant-numeric:tabular-nums/)
  assert.doesNotMatch(wxml,/wx:if="\{\{uploadProgress\}\}"/)
})
