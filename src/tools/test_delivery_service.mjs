import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

test('all service entries share a default and respect an explicit address',async()=>{
  const {servicePort,gatewayUrl}=await import('./service_config.mjs');
  assert.equal(servicePort({}),8893);
  assert.equal(gatewayUrl({}),'http://127.0.0.1:8893');
  assert.equal(gatewayUrl({XIANCHU_RECORDING_PORT:'18993'}),'http://127.0.0.1:18993');
  assert.equal(gatewayUrl({XIANCHU_GATEWAY_URL:'http://127.0.0.1:18891'}),'http://127.0.0.1:18891');
  assert.throws(()=>servicePort({XIANCHU_RECORDING_PORT:'abc'}));
});

test('catalog entry exposes the active product, not retired recording or voice pages',()=>{
  const config=JSON.parse(fs.readFileSync(new URL('../wechat_miniprogram/app.json',import.meta.url),'utf8'));
  assert.deepEqual(config.tabBar.list.map(t=>t.text),['演奏','曲库','设备']);
  assert.ok(!config.pages.some(p=>p.startsWith('pages/works/')||p.startsWith('pages/voice/')));
});

test('PC probe reaches the exact gateway passed to the launcher',async()=>{
  const {createGateway}=await import('../assistant_gateway/server.mjs');
  const {startUi}=await import('./start_ui.mjs');
  const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'xc-port-alignment-'));
  const gateway=createGateway({env:{GATEWAY_PROVIDER:'mock',ASR_MODE:'mock',TTS_MODE:'mock',GATEWAY_STATE_DIR:tmp},ledgerFile:path.join(tmp,'ledger.json')});
  await new Promise(r=>gateway.server.listen(0,'127.0.0.1',r));
  let ui;
  try{
    const url='http://127.0.0.1:'+gateway.server.address().port;
    ui=await startUi(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),{firstPort:19965,noBrowser:true,expectedGateway:url});
    const res=await fetch(ui.url+'/services/status');const state=await res.json();
    assert.equal(state.gateway_url,url);assert.equal(state.gateway.reachable,true);assert.equal(state.gateway.body.catalog.songs,14);
  }finally{
    if(ui)ui.stop();gateway.server.closeAllConnections();await new Promise(r=>gateway.server.close(r));
    fs.rmSync(tmp,{recursive:true,force:true});
  }
});
