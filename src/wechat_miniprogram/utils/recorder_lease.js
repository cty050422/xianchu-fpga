// RecorderManager is native-global. A stopped owner keeps its lease until the
// native acknowledgement arrives; another page cannot consume its late onStop.
var buses=new WeakMap()
function recorderChannel(native){
  var bus=buses.get(native)
  if(!bus){bus={owner:null};buses.set(native,bus);['Start','Stop','Error','InterruptionBegin','InterruptionEnd'].forEach(function(event){if(typeof native['on'+event]!=='function')return;native['on'+event](function(payload){var channel=bus.owner;if(!channel)return;if(event==='Stop'||event==='Error')bus.owner=null;var fn=channel.handlers[event];if(fn)fn(payload)})})}
  var channel={handlers:{}}
  ;['Start','Stop','Error','InterruptionBegin','InterruptionEnd'].forEach(function(event){channel['on'+event]=function(fn){channel.handlers[event]=fn}})
  channel.start=function(options){if(bus.owner)throw {code:'RECORDER_BUSY',message:'原生录音停止尚未确认'};bus.owner=channel;try{native.start(options)}catch(e){bus.owner=null;throw e}}
  channel.stop=function(){if(bus.owner===channel)native.stop()}
  return channel
}
function recorderBusy(wxApi){if(!wxApi||!wxApi.getRecorderManager)return false;var bus=buses.get(wxApi.getRecorderManager());return !!(bus&&bus.owner)}
module.exports={recorderChannel:recorderChannel,recorderBusy:recorderBusy}
