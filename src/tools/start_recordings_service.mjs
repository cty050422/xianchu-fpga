// New isolated entry: no private config reads, paid provider, COM or BLE access.
import os from 'node:os';import path from 'node:path';import fs from 'node:fs';import {randomBytes,randomInt} from 'node:crypto';import {fileURLToPath} from 'node:url';import {createGateway,validateListenConfiguration} from '../assistant_gateway/server.mjs';
import {servicePort} from './service_config.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),check=process.argv.includes('--check');
const ipv4=s=>/^10\./.test(s)||/^192\.168\./.test(s)||/^172\.(1[6-9]|2\d|3[01])\./.test(s);
const interfaces=Object.entries(os.networkInterfaces()).flatMap(([name,list])=>(list||[]).filter(x=>x.family==='IPv4'&&!x.internal&&ipv4(x.address)).map(x=>({name,address:x.address}))),wifi=interfaces.filter(x=>/WLAN|Wi-Fi|无线|^en0$/i.test(x.name));
const choices=wifi.length===1?wifi:interfaces;let host=check?'127.0.0.1':process.env.XIANCHU_LAN_HOST||(choices.length===1?choices[0].address:null);
if(!host||!check&&!interfaces.some(x=>x.address===host))throw Error('Set XIANCHU_LAN_HOST to this computer’s Wi-Fi IPv4: '+JSON.stringify(interfaces));
const port=check?0:servicePort();
const directory=check?fs.mkdtempSync(path.join(os.tmpdir(),'xc-launch-check-')):path.join(root,'.local','recordings'),token=randomBytes(32).toString('hex'),code=String(randomInt(0,1000000)).padStart(6,'0');
validateListenConfiguration(host,token);fs.mkdirSync(directory,{recursive:true});
const env={GATEWAY_DEVICE_TOKEN:token,GATEWAY_PAIR_CODE:code,GATEWAY_PROVIDER:'mock',ASR_MODE:'mock',TTS_MODE:'mock',GATEWAY_ALLOW_PAID_AUDIO:'0',GATEWAY_STATE_DIR:directory,XIANCHU_SERVICE_ID:process.env.XIANCHU_SERVICE_ID||'XC-RECORDING-SERVICE-20261027'};
const gateway=createGateway({env,ledgerFile:path.join(directory,'ledger.json')});
gateway.server.on('error',error=>{console.error(error.code==='EADDRINUSE'?'Port occupied; existing services were left running.':error.message);process.exitCode=1});
await new Promise((resolve,reject)=>{gateway.server.once('error',reject);gateway.server.listen(port,host,resolve)});
if(check){try{const url='http://127.0.0.1:'+gateway.server.address().port;const response=await fetch(url+'/performances/v1/healthz',{headers:{'x-device-token':token}}),health=await response.json();if(response.status!==200||health.protocol!=='performances/v1'||health.receiverOnline||health.instrumentCaptureHardwareVerified)throw Error('RECORDING_SELF_CHECK_FAILED');console.log('PASS recordings startup, bounded authenticated store, receiver NOT CONNECTED; zero hardware/API actions')}finally{gateway.server.closeAllConnections();await new Promise(r=>gateway.server.close(r));if(path.dirname(directory)===path.resolve(os.tmpdir()))fs.rmSync(directory,{recursive:true,force:true})}}
else {console.log('Phone service URL: http://'+host+':'+gateway.server.address().port);console.log('Assistant / works connection code: '+code+' (10 minutes; not BLE PIN)');console.log('Phone Settings: save address, connect assistant, then open Instrument > Recordings.');console.log('Recordings are project-local. Chat/ASR/TTS=mock; no API Key is read.');console.log('S3 capture requires explicit USB setup and verified physical signal taps; no hardware is accessed by this server.');console.log('Ctrl+C stops this service. Existing services were not stopped.')}
