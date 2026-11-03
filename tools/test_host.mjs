// Host-only regression. No BLE adapters, serial ports or board programmers.
import {spawnSync} from 'node:child_process';
import {readdirSync,mkdirSync,writeFileSync,readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {join,dirname,relative} from 'node:path';
import {createHash} from 'node:crypto';
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const files=(dir,pattern)=>readdirSync(join(root,dir),{withFileTypes:true}).filter(e=>e.isFile()&&pattern.test(e.name)).map(e=>join(root,dir,e.name)).sort();
const groups=[
 ['miniprogram',files('src/wechat_miniprogram/tests',/^test_.*\.js$/)],
 ['gateway',files('src/assistant_gateway',/^test_.*\.mjs$/)],
 ['monitor',files('src/performance_ui',/^test(?:_.*)?\.mjs$/)],
 ['integration',files('tests/integration',/^test_.*\.(?:m?js)$/)],
 ['catalog',files('src/tools',/^test_.*\.mjs$/)]
];
const all=groups.flatMap(g=>g[1]);
function sourceFiles(dir){return readdirSync(join(root,dir),{withFileTypes:true}).filter(e=>!['node_modules','__pycache__'].includes(e.name)).flatMap(e=>e.isDirectory()?sourceFiles(join(dir,e.name)):[join(root,dir,e.name)]).sort()}
const inputs=['src','tests','tools'].flatMap(sourceFiles);
const hashes=()=>Object.fromEntries(inputs.map(p=>[relative(root,p).replaceAll('\\','/'),createHash('sha256').update(readFileSync(p)).digest('hex')]));
const before=hashes();const out=join(root,'build','host',new Date().toISOString().replaceAll(/[:.]/g,'-'));mkdirSync(out,{recursive:true});
const results=[];
for(const [group,paths] of groups){
 const r=spawnSync(process.execPath,['--test','--test-reporter=tap','--test-concurrency=1',...paths],{cwd:root,encoding:'utf8',timeout:900000,maxBuffer:16*1024*1024,env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'}});
 const log=(r.stdout||'')+(r.stderr||'');writeFileSync(join(out,group+'.log'),log);
 const counts=Object.fromEntries([...log.matchAll(/^# (tests|pass|fail|skipped) (\d+)$/gm)].map(m=>[m[1],Number(m[2])]));
 const result={group,files:paths.length,exit_code:r.status,...counts,error:r.error?.message||null};results.push(result);console.log(JSON.stringify(result));
}
const stable=JSON.stringify(before)===JSON.stringify(hashes());const passed=stable&&results.every(r=>r.exit_code===0&&!r.error);
writeFileSync(join(out,'results.json'),JSON.stringify({scope:'host-only',inputs_stable:stable,inputs:before,passed,results},null,2));
console.log('Evidence: '+out);process.exitCode=passed?0:1;
