const {test}=require('node:test')
const assert=require('node:assert/strict')
const fs=require('node:fs')
const path=require('node:path')
const vm=require('node:vm')
const {createRequire}=require('node:module')
const {createSessionHub}=require('../services/device_session')

test('entering a real link destroys simulator state, old capabilities and drafts',async()=>{
  const hub=createSessionHub()
  await hub.enterSimulator('normal')
  hub.saveDraft({kind:'guide'})
  hub._state.capability={supportedMask:0xffffffff}
  hub.publishReal({connected:true,deviceId:'real-device',lastStatus:{song:33},lastStatusAt:Date.now()})
  const s=hub.snapshot()
  assert.equal(s.hardwareMode,'real');assert.equal(s.simProfile,null)
  assert.equal(s.lastStatus.song,33);assert.equal(s.capability,null)
  assert.equal(s.pendingActionCount,0);assert.equal(hub._state.sim,null)
  hub.saveDraft({kind:'other'})
  hub.publishReal({connected:false})
  assert.equal(hub.snapshot().pendingActionCount,0)
  assert.equal(hub.snapshot().hardwareMode,'disconnected')
})

test('all three native tabs remain present and every WXML handler exists',()=>{
  const root=path.resolve(__dirname,'..')
  const app=JSON.parse(fs.readFileSync(path.join(root,'app.json')))
  assert.equal(app.tabBar.list.length,3)
  for(const tab of app.tabBar.list){
    const js=fs.readFileSync(path.join(root,tab.pagePath+'.js'),'utf8')
    let page
    vm.runInNewContext(js,{require:createRequire(path.join(root,tab.pagePath+'.js')),Page:p=>page=p,console,setTimeout,clearTimeout})
    const xml=fs.readFileSync(path.join(root,tab.pagePath+'.wxml'),'utf8')
    assert.doesNotMatch(xml,/\{\{[^}]*\.indexOf\(/,'WXML does not support JS method calls')
    const handlers=[...xml.matchAll(/(?:bind|catch)[\w:]*="([\w]+)"/g)].map(m=>m[1])
    for(const name of handlers) assert.equal(typeof page[name],'function',tab.pagePath+' missing '+name)
    const conf=JSON.parse(fs.readFileSync(path.join(root,tab.pagePath+'.json')))
    assert.equal(conf.disableScroll,true)
  }
})
