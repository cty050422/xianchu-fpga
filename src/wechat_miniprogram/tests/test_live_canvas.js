const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{createRequire}=require('node:module')
test('native canvas waits for ready, redraws cached data on workspace/tab return, and detaches safely',()=>{
 const file=path.resolve(__dirname,'../pages/index/index.js'),jobs=[],ls=[],hs=[];let page,draws=0,ready=false,snap={wave:null}
 const wx={nextTick:fn=>jobs.push(fn),createCanvasContext:(id,scope)=>{assert.equal(id,'pcmWave');assert.equal(scope,page);assert.equal(ready,true);return new Proxy({draw:()=>draws++},{get:(o,k)=>o[k]||(()=>{})})}}
 const link={data:{activeView:'perform',connected:true},subscribe:f=>(ls.push(f),()=>ls.splice(ls.indexOf(f),1)),switchView(e){const p={activeView:e.currentTarget.dataset.view};Object.assign(this.data,p);ls.slice().forEach(f=>f(p))}}
 const hub={snapshot:()=>snap,subscribe:f=>(hs.push(f),()=>hs.splice(hs.indexOf(f),1))},app={globalData:{sessionHub:hub},getInstrumentController:()=>link}
 vm.runInNewContext(fs.readFileSync(file,'utf8'),{require:createRequire(file),Page:p=>page=p,wx,getApp:()=>app,console,Uint8Array,ArrayBuffer,setTimeout,clearTimeout,setInterval,clearInterval})
 page.data=structuredClone(page.data);page.setData=(p,done)=>{Object.assign(page.data,p);if(done)done()};page.onLoad()
 function flush(){while(jobs.length)jobs.shift()()}
 function wave(id){snap={wave:{id,columns:Array.from({length:128},()=>[-12,12]),at:Date.now()}};hs.slice().forEach(f=>f(snap));flush()}
 wave(1);assert.equal(draws,0,'no canvas write before native ready')
 ready=true;assert.equal(typeof page.onReady,'function');page.onReady();flush();assert.equal(draws,1)
 page.switchView({currentTarget:{dataset:{view:'device'}}});wave(2);assert.equal(draws,1)
 page.switchView({currentTarget:{dataset:{view:'perform'}}});flush();assert.equal(draws,2,'return redraws cached wave without waiting for another generation')
 page.onHide();wave(3);assert.equal(draws,2);page.onShow();flush();assert.equal(draws,3)
 page.onUnload();assert.equal(ls.length,0);assert.equal(hs.length,0)
})
