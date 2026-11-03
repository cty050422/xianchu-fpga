// Catalog only. No decoder install, assistant, key reads or hardware access.
import os from 'node:os';
import assert from 'node:assert/strict';
const check=process.argv.includes('--check');
if(check){process.env.XIANCHU_CATALOG_HOST='127.0.0.1';process.env.XIANCHU_CATALOG_PORT='0'}
const {server}=await import('../catalog_service/server.mjs');
if(!server.listening)await new Promise((resolve,reject)=>{server.once('listening',resolve);server.once('error',reject)});
const port=server.address().port;
if(check){
 try{
  const base=`http://127.0.0.1:${port}`;
  const health=await(await fetch(base+'/catalog/v1/healthz')).json();assert.equal(health.ready,true);assert.ok(health.songs>0);
  const songs=await(await fetch(base+'/catalog/v1/songs')).json();assert.ok(songs);
  for(const route of ['/assistant/v1/healthz','/assistant/v1/chat','/assistant/v1/asr','/recordings/v1/healthz'])assert.equal((await fetch(base+route)).status,404);
  console.log('PASS catalog service: reachable, populated, assistant and recording routes absent');
 } finally {server.closeAllConnections();await new Promise(r=>server.close(r))}
}else{
 const urls=Object.values(os.networkInterfaces()).flat().filter(n=>n&&n.family==='IPv4'&&!n.internal).map(n=>`http://${n.address}:${port}`);
 console.log('电脑开发者工具：http://127.0.0.1:'+port);
 console.log('手机与电脑接入同一网络，在设备页保存适用地址：\n'+urls.join('\n'));
 console.log('健康检查：地址 + /catalog/v1/healthz；微信预览须开启开发调试，正式发布须 HTTPS 合法域名。');
 console.log('只提供曲库，无需 API Key，无蓝牙或串口访问；Ctrl+C 停止。');
}
