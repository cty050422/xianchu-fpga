// Executes the actual app source in a minimal DOM and an entirely fake UART.
// This is a runtime unit test, not a real-browser or hardware acceptance claim.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {WireCapture} from './wire_capture.mjs';
import {TelemetryParser,diagnoseTelemetry} from './protocol.mjs';
import {initialState,joystick2View,updatePerformance,zoneViews} from './music.mjs';
import {signalPath} from './evidence.mjs';

class Element {
  constructor(){this.events={};this.children=[];this.nodes={};this.textContent='';
    this.style={setProperty(){}};this.classList={toggle(){},add(){},remove(){}};
    this.clientWidth=600;this.clientHeight=220;this.dataset={};}
  addEventListener(name,fn){this.events[name]=fn;}
  append(child){this.children.push(child);}
  querySelector(name){return this.nodes[name]??=(new Element());}
  getContext(){return new Proxy({}, {get:(obj,key)=>obj[key]??(()=>{}),set:(obj,key,v)=>(obj[key]=v,true)});}
  click(){return this.events.click?.();}
}
function fakePort(){
  const port={closed:0,pending:null};
  port.reader={released:0,read:()=>new Promise(r=>{port.pending=r;}),
    cancel:()=>new Promise(r=>{port.cancelled=r;}),releaseLock(){this.released++;}};
  port.readable={getReader:()=>port.reader};port.open=async()=>{};
  port.close=async()=>{port.closed++;port.readable=null;};return port;
}
function boot(){
  const html=fs.readFileSync(new URL('./index.html',import.meta.url),'utf8');
  const elements=new Map([...html.matchAll(/id="([^"]+)"/g)].map(m=>[m[1],new Element()]));
  const timers=[],paints=[],alerts=[],ports=[],blobs=[];let requests=0;
  const document={getElementById:id=>elements.get(id)??null,createElement:()=>new Element(),
    querySelectorAll:()=>Array.from({length:4},()=>new Element())};
  const serial={addEventListener(){},requestPort:async()=>{requests++;return ports.shift();}};
  const context=vm.createContext({document,navigator:{serial},window:{devicePixelRatio:1,alert:x=>alerts.push(x)},
    WireCapture,TelemetryParser,diagnoseTelemetry,initialState,joystick2View,updatePerformance,zoneViews,signalPath,
    performance:{now:()=>1000},console,Blob,URL:{createObjectURL:b=>(blobs.push(b),'blob:fixture'),revokeObjectURL(){}},
    setInterval:fn=>(timers.push(fn),timers.length),clearInterval(){},
    requestAnimationFrame:fn=>(paints.push(fn),paints.length),setTimeout:()=>0});
  const source=fs.readFileSync(new URL('./app.mjs',import.meta.url),'utf8').replace(/^import .+;\r?\n/gm,'');
  vm.runInContext(source,context,{filename:'actual-app.mjs'});
  const paint=()=>{for(const fn of paints.splice(0))fn();};paint();
  return {elements,timers,paint,alerts,ports,blobs,requests:()=>requests};
}
test('actual app starts offline; demo/export cannot create physical evidence',async()=>{
  const app=boot();assert.match(app.elements.get('connectionBadge').textContent,/未连接/);
  assert.equal(app.elements.get('harmonicBars').children.length,32);
  app.elements.get('demoButton').click();for(const fn of app.timers)fn();app.paint();
  assert.match(app.elements.get('connectionBadge').textContent,/演示/);
  app.elements.get('exportCapture').click();assert.equal(app.blobs.length,0);
  assert.equal(app.alerts.length,1);assert.equal(app.requests(),0);
});
test('late bytes and reader cleanup from an old connection cannot affect a new one',async()=>{
  const app=boot(),a=fakePort(),b=fakePort();app.ports.push(a,b);
  await app.elements.get('connectButton').click();
  app.elements.get('demoButton').click();
  await app.elements.get('connectButton').click();
  a.pending({value:new Uint8Array([1,2,3]),done:false});
  await new Promise(resolve=>setImmediate(resolve));app.paint();
  app.elements.get('exportCapture').click();
  const capture=JSON.parse(await app.blobs.at(-1).text());
  assert.equal(capture.received_bytes,0,'old-session bytes contaminated the new capture');
  assert.equal(b.reader.released,0,'old cleanup released the new session reader');
  assert.equal(a.reader.released,1);
  a.cancelled?.();b.pending({done:true});
});
