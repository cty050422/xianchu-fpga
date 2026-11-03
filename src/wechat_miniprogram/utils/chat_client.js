// WeChat-native transport, no browser TextDecoder/fetch dependency.
function fail(code){return Object.assign(new Error(code),{code:code})}
function utf8(){
  var carry=[]
  return {feed:function(value,final){
    var bytes=carry.concat(Array.from(new Uint8Array(value||new ArrayBuffer(0)))),out='',i=0
    while(i<bytes.length){
      var b=bytes[i],n=b<128?1:(b>=194&&b<=223?2:(b>=224&&b<=239?3:(b>=240&&b<=244?4:0)))
      if(!n)throw fail('CHAT_BAD_UTF8')
      if(i+n>bytes.length)break
      var cp=b&((1<<(8-n-1))-1);if(n===1)cp=b
      for(var j=1;j<n;j++){if((bytes[i+j]&192)!==128)throw fail('CHAT_BAD_UTF8');cp=(cp<<6)|(bytes[i+j]&63)}
      if((n===2&&cp<128)||(n===3&&cp<2048)||(n===4&&cp<65536)||cp>1114111||(cp>=55296&&cp<=57343))throw fail('CHAT_BAD_UTF8')
      out+=cp<=65535?String.fromCharCode(cp):String.fromCharCode(55296+((cp-65536)>>10),56320+((cp-65536)&1023));i+=n
    }
    carry=bytes.slice(i);if(final&&carry.length)throw fail('CHAT_BAD_UTF8');return out
  }}
}
function sse(onDelta){
  var buffer='',answer='',done=false,end=false,size=0
  return {feed:function(text){
    size+=text.length;if(size>524288)throw fail('CHAT_RESPONSE_TOO_LARGE');buffer+=text
    var match
    while((match=buffer.match(/\r?\n\r?\n/))){
      var block=buffer.slice(0,match.index);buffer=buffer.slice(match.index+match[0].length)
      var event='',data=[]
      block.split(/\r?\n/).forEach(function(line){if(line.startsWith('event:'))event=line.slice(6).trim();if(line.startsWith('data:'))data.push(line.slice(5).trimStart())})
      if(!data.length)continue
      var body;try{body=JSON.parse(data.join('\n'))}catch(e){throw fail('CHAT_BAD_RESPONSE')}
      if(event==='error')throw fail(body.code||'CHAT_PROVIDER_ERROR')
      if(event==='cancelled')throw fail('CANCELLED')
      if(event==='assistant.delta'){
        if(done||typeof body.text!=='string')throw fail('CHAT_BAD_RESPONSE');answer+=body.text
        if(answer.length>16000)throw fail('CHAT_RESPONSE_TOO_LARGE');if(onDelta)onDelta(answer)
      }
      if(event==='assistant.done'){
        if(done||typeof body.text!=='string'||body.text.length>16000||(answer&&answer!==body.text))throw fail('CHAT_BAD_RESPONSE')
        answer=body.text;done=true;if(onDelta)onDelta(answer)
      }
      if(event==='end'){if(!done)throw fail('CHAT_TRUNCATED');end=true}
    }
  },finish:function(){if(!done||!end||buffer.trim())throw fail('CHAT_TRUNCATED');return {text:answer}}}
}
function createChatClient(options){
  var opts=options,conversation=null,busy=false,generation=0,task=null,rejectActive=null
  function request(url,data,stream,onDelta,ownGeneration){return new Promise(function(resolve,reject){
    var decoder=utf8(),parser=sse(onDelta),chunked=false,settled=false
    function finish(error,result){if(settled)return;settled=true;rejectActive=null;if(error)reject(error);else resolve(result)}
    rejectActive=function(){finish(fail('CANCELLED'))}
    task=opts.wx.request({url:url,method:'POST',data:data,header:{'content-type':'application/json','x-device-token':opts.getDeviceToken?opts.getDeviceToken():''},timeout:45000,
      enableChunked:Boolean(stream),responseType:stream?'arraybuffer':'text',dataType:stream?'text':'json',
      success:function(res){
        if(generation!==ownGeneration)return finish(fail('CANCELLED'))
        try{
          if(res.statusCode<200||res.statusCode>=300){var b=res.data;if(typeof b==='string')try{b=JSON.parse(b)}catch(e){};if(b instanceof ArrayBuffer)try{b=JSON.parse(decoder.feed(b,true))}catch(e){};throw fail(b&&b.error||(res.statusCode===401?'UNAUTHORIZED':res.statusCode===429?'BUDGET_EXHAUSTED':'CHAT_HTTP_'+res.statusCode))}
          if(!stream){var body=typeof res.data==='string'?JSON.parse(res.data):res.data;return finish(null,body)}
          if(!chunked){parser.feed(typeof res.data==='string'?res.data:decoder.feed(res.data,true))}else parser.feed(decoder.feed(null,true))
          finish(null,parser.finish())
        }catch(e){finish(e)}
      },fail:function(err){finish(fail(generation!==ownGeneration?'CANCELLED':/timeout/i.test(err&&err.errMsg||'')?'CHAT_TIMEOUT':'CHAT_NETWORK_ERROR'))}
    })
    if(stream&&task&&task.onChunkReceived)task.onChunkReceived(function(chunk){
      if(settled||generation!==ownGeneration)return
      chunked=true
      try{parser.feed(decoder.feed(chunk.data,false))}catch(e){finish(e);task.abort&&task.abort()}
    })
  })}
  return {
    chat:async function(text,onDelta){
      if(busy)throw fail('CHAT_BUSY');var base=opts.getBaseUrl()
      if(!base)throw fail('SERVICE_UNCONFIGURED');if(typeof text!=='string'||!text.trim()||text.length>2000)throw fail('CHAT_TEXT_LIMIT')
      busy=true;var ownGeneration=generation
      try{
        if(!conversation){var created=await request(base+'/assistant/v1/conversations',{},false,null,ownGeneration);if(generation!==ownGeneration)throw fail('CANCELLED');if(!created||typeof created.conversation_id!=='string')throw fail('CHAT_BAD_RESPONSE');conversation=created.conversation_id}
        var turn='phone-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,10)
        return await request(base+'/assistant/v1/conversations/'+encodeURIComponent(conversation)+'/turns',{client_turn_id:turn,text:text},true,onDelta,ownGeneration)
      }catch(e){if(e.code==='NO_SUCH_CONVERSATION'||e.code==='UNAUTHORIZED')conversation=null;throw e}
      finally{if(generation===ownGeneration){busy=false;task=null;rejectActive=null}}
    },
    cancel:function(){generation++;conversation=null;busy=false;var reject=rejectActive,old=task;task=null;rejectActive=null;if(reject)reject();if(old&&old.abort)old.abort()},
    snapshot:function(){return {busy:busy,conversationId:conversation}}
  }
}
module.exports={createChatClient:createChatClient}
