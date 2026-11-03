const {createInstrumentModel}=require('../../services/instrument_model')
const config=createInstrumentModel(typeof wx==='undefined'?{}:wx,typeof getApp==='function'?getApp:undefined,typeof setTimeout==='function'?setTimeout:undefined,typeof clearTimeout==='function'?clearTimeout:undefined,
  typeof setInterval==='function'?setInterval:undefined,typeof clearInterval==='function'?clearInterval:undefined)
const localLoad=config.onLoad,localUnload=config.onUnload,localShow=config.onShow,localHide=config.onHide
config.paintLatestWave=function(force){
 if(this.disposed||!this.canvasReady||!this.pageVisible||this.data.activeView!=='perform'||!this.hub)return
 const paint=()=>{if(this.disposed||!this.canvasReady||!this.pageVisible||this.data.activeView!=='perform')return;const w=this.hub.snapshot().wave;if(!w||(!force&&w===this.lastDrawnWave))return;this.drawWave(w);this.lastDrawnWave=w}
 if(typeof wx.nextTick==='function')wx.nextTick(paint);else setTimeout(paint,0)
}
config.onLoad=function(){
 const app=typeof getApp==='function'?getApp():null
 if(!app||!app.getInstrumentController)return localLoad.call(this)
 this.disposed=false;this.pageVisible=true;this.canvasReady=false;this.hub=app.globalData.sessionHub;this.link=app.getInstrumentController()
 this.setData(Object.assign({},this.link.data))
 this.offLink=this.link.subscribe(p=>{if(!this.disposed)this.setData(p,()=>{if(p.activeView==='perform')this.paintLatestWave(true)})})
 this.offHub=this.hub.subscribe(s=>{if(!s.wave)this.lastDrawnWave=null;this.paintLatestWave(false)})
}
config.onReady=function(){this.canvasReady=true;if(this.link)this.paintLatestWave(true)}
config.onShow=function(){if(!this.link)return localShow.call(this);this.pageVisible=true;this.paintLatestWave(true)}
config.onHide=function(){if(!this.link)return localHide.call(this);this.pageVisible=false}
config.onUnload=function(){
 if(!this.link)return localUnload.call(this)
 this.disposed=true;if(this.waveTimer)clearInterval(this.waveTimer);if(this.offLink)this.offLink();if(this.offHub)this.offHub()
 // The controller, issuer, receiver and lease outlive this native page.
}
for(const name of Object.keys(config)){
 if(typeof config[name]!=='function'||['onLoad','onUnload','onReady','onShow','onHide','drawWave','paintLatestWave'].includes(name))continue
 const local=config[name]
 config[name]=function(){return this.link?this.link[name].apply(this.link,arguments):local.apply(this,arguments)}
}
Page(config)
