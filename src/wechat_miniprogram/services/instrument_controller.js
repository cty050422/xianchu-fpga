const {createInstrumentModel}=require('./instrument_model')
function createInstrumentController({wx,app}){
 const model=createInstrumentModel(wx,()=>app,setTimeout,clearTimeout,setInterval,clearInterval),listeners=[]
 model.data=JSON.parse(JSON.stringify(model.data))
 model.setData=function(patch,done){Object.assign(model.data,patch);listeners.slice().forEach(f=>{try{f(patch)}catch(e){}});if(done)done()}
 model.subscribe=function(fn){listeners.push(fn);return ()=>{const i=listeners.indexOf(fn);if(i>=0)listeners.splice(i,1)}}
 model.drawWave=function(){} // only a mounted native view owns its canvas
 const freshnessTimer=setInterval(()=>{const h=app.globalData.sessionHub;if(!h.snapshot)return;const s=h.snapshot(),fresh=s.hardwareMode==='real'&&s.freshness==='fresh';if(model.data.stateFresh!==fresh)model.setData({stateFresh:fresh});model.onHubSnapshot(s);if(model.data.waveFresh&&Date.now()-model.data.waveAt>2500)model.setData({waveFresh:false,waveLabel:'波形失鲜'})},200)
 if(freshnessTimer.unref)freshnessTimer.unref()
 model.shutdown=()=>{clearInterval(freshnessTimer);model.onUnload()} // tests/process teardown; page detach never calls this
 model.onLoad();return model
}
module.exports={createInstrumentController}
