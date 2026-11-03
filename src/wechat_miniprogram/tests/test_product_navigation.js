// T4.1: the product is three tabs (演奏/曲库/设备); assistant and works entry
// points are retired. Deleted pages must leave no dead links or tab references.
const test=require('node:test'),assert=require('node:assert'),fs=require('fs'),path=require('path')
const root=path.resolve(__dirname,'..')
test('app.json registers exactly the three-tab product plus the audition demo route',()=>{
  const app=JSON.parse(fs.readFileSync(path.join(root,'app.json'),'utf8'))
  assert.deepEqual(app.pages,['pages/index/index','pages/catalog/catalog','pages/settings/settings','pages/audition/audition'])
  assert.equal(app.tabBar.list.length,3)
  assert.deepEqual(app.tabBar.list.map(t=>t.text),['演奏','曲库','设备'])
})
test('retired pages are archived out of the product tree and unreferenced',()=>{
  assert.ok(!fs.existsSync(path.join(root,'pages/voice')))
  assert.ok(!fs.existsSync(path.join(root,'pages/works')))
  const indexWxml=fs.readFileSync(path.join(root,'pages/index/index.wxml'),'utf8')
  assert.ok(!indexWxml.includes('works-entry'),'index must not link the retired works page')
  const appJs=fs.readFileSync(path.join(root,'app.js'),'utf8')
  assert.ok(!appJs.includes('performance_client'),'app shell must not create the retired recording client')
  assert.ok(!appJs.includes('performance_session'),'app shell must not create the retired recording session')
})
test('public catalog UI contains service health and no unused assistant or code prompts',()=>{
  const wxml=fs.readFileSync(path.join(root,'pages/settings/settings.wxml'),'utf8')
  assert.ok(!wxml.includes('助手'),'settings must not advertise the assistant')
  assert.ok(wxml.includes('检查连接'))
  assert.ok(wxml.includes('healthInfo.songs'))
  assert.ok(!wxml.includes('servicePairCode'))
})
