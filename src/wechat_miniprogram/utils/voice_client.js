// Voice service client: transcription upload (wx.uploadFile multipart, the
// real file-upload contract), intent (JSON POST), optional read-aloud TTS.
//
// Separation of concerns: transcription, intent and TTS are independent calls;
// a TTS failure must never block transcription or song selection upstream, so
// callers treat tts() as strictly optional. The client carries NO secrets —
// only the non-secret service base URL.
var intent = require('./intent')
var createChatClient = require('./chat_client').createChatClient

var recorderBusy = require('./recorder_lease').recorderBusy
function createVoiceClient(options) {
  var opts = options || {}
  var wxApi = opts.wx
  var baseUrl = opts.baseUrl || ''
  var serviceToken = opts.deviceToken || '', tokenExpires = serviceToken ? Infinity : 0
  function token() { return Date.now() < tokenExpires ? serviceToken : '' }
  var chatClient = createChatClient({wx:wxApi,getBaseUrl:function(){return baseUrl},getDeviceToken:token})
  var activeSpeech=null,activeUpload=null
  function cancelTranscription(){
    var old=activeUpload;activeUpload=null
    if(old){old.finish({code:'CANCELLED',message:'录音识别已取消'});if(old.task&&old.task.abort)old.task.abort()}
  }

  function pair(code) {
    return new Promise(function(resolve,reject){
      if(!baseUrl)return reject({code:'SERVICE_UNCONFIGURED',message:'请先保存服务地址'})
      if(!/^\d{6}$/.test(String(code)))return reject({code:'PAIR_CODE_INVALID',message:'请输入电脑显示的六位助手连接码'})
      wxApi.request({url:baseUrl+'/assistant/v1/pair',method:'POST',data:{code:String(code)},timeout:5000,
        success:function(res){if(res.statusCode===200&&res.data&&typeof res.data.access_token==='string')resolve(res.data);else reject({code:res.data&&res.data.error||'PAIR_FAILED',message:res.statusCode===410?'连接码已过期，请在电脑重启助手服务':res.statusCode===429?'连接码尝试过多，请在电脑重启助手服务':'连接码不正确，或服务尚未启用助手授权'})},
        fail:function(){reject({code:'NETWORK_ERROR',message:'无法连接电脑上的助手服务'})}})
    })
  }

  function newRequestId() {
    var text = ''
    for (var i = 0; i < 4; i++) text += Math.random().toString(36).slice(2, 8)
    return 'req-' + text
  }

  function transcribe(segment) {
    // segment: { tempFilePath, duration, size, mime } from the recorder.
    cancelTranscription()
    return new Promise(function (resolve, reject) {
      if (!baseUrl) return reject({ code: 'SERVICE_UNCONFIGURED', message: '尚未配置语音服务地址' })
      if (!segment || !segment.tempFilePath) return reject({ code: 'NO_AUDIO', message: '没有可识别的录音' })
      if (segment.size && segment.size > 2 * 1024 * 1024) {
        return reject({ code: 'AUDIO_TOO_LARGE', message: '录音文件超过2MiB上限' })
      }
      var requestId = newRequestId()
      var settled=false,record={task:null,finish:finish}
      function finish(error,result){
        if(settled)return;settled=true
        if(activeUpload===record)activeUpload=null
        if(error)reject(error);else resolve(result)
      }
      activeUpload=record
      var uploadTask = record.task = wxApi.uploadFile({
        url: baseUrl + '/assistant/v1/asr',
        filePath: segment.tempFilePath,
        name: 'audio',
        header: { 'x-device-token': token() },
        formData: {
          requestId: requestId,
          mime: segment.mime || 'audio/mp3',
          durationMs: String(segment.duration || 0)
        },
        timeout: 20000,
        success: function (res) {
          if(settled)return
          if (res.statusCode === 200) {
            try {
              var body = JSON.parse(res.data)
              finish(null,body)
            } catch (e) {
              finish({ code: 'BAD_RESPONSE', message: '语音服务返回无法解析的内容' })
            }
          } else {
            var message = '语音服务错误 ' + res.statusCode
            try { message += '：' + (JSON.parse(res.data).error || '') } catch (e) {}
            var code = res.statusCode === 429 ? 'QUOTA' : (res.statusCode === 413 ? 'TOO_LARGE' : 'SERVICE_ERROR')
            finish({ code: code, statusCode: res.statusCode, message: message })
          }
        },
        fail: function (err) {
          finish({ code: 'NETWORK_ERROR', message: (err && err.errMsg) || '上传失败' })
        }
      })
      if (uploadTask && uploadTask.onProgressUpdate && opts.onProgress) {
        uploadTask.onProgressUpdate(opts.onProgress)
      }
    })
  }

  function askIntent(text) {
    // Local rule parse first: deterministic phrasings never cost a network
    // round-trip. The server endpoint re-runs the SAME rules (shared module)
    // and is consulted only when configured, for audit parity.
    var local = intent.parse(text)
    return new Promise(function (resolve) {
      resolve({ intent: local, source: 'local-rules' })
    })
  }

  function tts(text) {
    return new Promise(function (resolve, reject) {
      if (!baseUrl) return reject({ code: 'SERVICE_UNCONFIGURED', message: '尚未配置语音服务地址' })
      wxApi.request({
        url: baseUrl + '/assistant/v1/tts',
        method: 'POST',
        header: { 'x-device-token': token() },
        data: { text: String(text).slice(0, 200) },
        timeout: 15000,
        success: function (res) {
          if (res.statusCode === 200 && res.data && res.data.audioBase64) resolve(res.data)
          else reject({ code: 'SERVICE_ERROR', statusCode: res.statusCode })
        },
        fail: function (err) { reject({ code: 'NETWORK_ERROR', message: (err && err.errMsg) || '请求失败' }) }
      })
    })
  }

  // Play a TTS payload through a temp file. Strictly optional: failures are
  // returned, never thrown into the transcription flow.
  function playSpeech(payload) {
    if(recorderBusy(wxApi))return Promise.reject({code:'RECORDER_BUSY',message:'录音期间不播放助手朗读'})
    stopSpeech()
    return new Promise(function (resolve, reject) {
      var fs = wxApi.getFileSystemManager()
      var path = wxApi.env.USER_DATA_PATH + '/tts-' + Date.now() + '.wav'
      var audio=null,settled=false
      function finish(error){
        if(settled)return;settled=true;if(activeSpeech&&activeSpeech.finish===finish)activeSpeech=null
        if(audio){try{audio.stop();audio.destroy&&audio.destroy()}catch(e){}}
        if(fs.unlink)fs.unlink({filePath:path,success:function(){},fail:function(){}})
        if(error)reject(error);else resolve(true)
      }
      activeSpeech={finish:finish}
      fs.writeFile({
        filePath: path,
        data: payload.audioBase64,
        encoding: 'base64',
        success: function () {
          if(settled){if(fs.unlink)fs.unlink({filePath:path,success:function(){},fail:function(){}});return}
          audio = wxApi.createInnerAudioContext()
          audio.src = path
          audio.onEnded(function () { finish() })
          audio.onError(function (err) { finish({ code: 'PLAY_FAILED', message: err && err.errMsg }) })
          if(!settled)audio.play()
        },
        fail: function (err) { finish({ code: 'WRITE_FAILED', message: err && err.errMsg }) }
      })
    })
  }
  function stopSpeech(){if(activeSpeech)activeSpeech.finish({code:'CANCELLED',message:'朗读已停止'})}

  function health() {
    return new Promise(function (resolve, reject) {
      if (!baseUrl) return reject({ code: 'SERVICE_UNCONFIGURED', message: '尚未配置服务地址' })
      wxApi.request({
        url: baseUrl + '/assistant/v1/healthz',
        method: 'GET', timeout: 5000,
        success: function (res) {
          if (res.statusCode === 200) resolve(res.data)
          else reject({ code: 'SERVICE_ERROR', statusCode: res.statusCode })
        },
        fail: function (err) { reject({ code: 'NETWORK_ERROR', message: (err && err.errMsg) || '服务不可达' }) }
      })
    })
  }

  return {
    setBaseUrl: function (url) { var next=String(url||'').replace(/\/+$/,'');if(next!==baseUrl){chatClient.cancel();cancelTranscription();stopSpeech();serviceToken='';tokenExpires=0}baseUrl=next },
    getBaseUrl: function () { return baseUrl },
    setDeviceToken: function(value,expires){if(String(value||'')!==serviceToken)chatClient.cancel();serviceToken=String(value||'');tokenExpires=serviceToken?Number(expires||0):0},
    isAuthorized: function(){return Boolean(token())},
    getDeviceToken: token,
    pair: pair,
    tokenExpiresAt:function(){return tokenExpires},
    renew:function(){return new Promise(function(resolve,reject){
      if(!token())return reject({code:'SERVICE_SESSION_REQUIRED',message:'作品服务会话已过期'});
      wxApi.request({url:baseUrl+'/assistant/v1/session/renew',method:'POST',data:{},header:{'x-device-token':token()},timeout:5000,
        success:function(r){if(r.statusCode===200&&r.data&&r.data.access_token)resolve(r.data);else reject({code:r.statusCode===401?'SERVICE_SESSION_REQUIRED':'SERVICE_RENEW_FAILED',message:r.statusCode===401?'作品服务已重启或会话失效，请重新连接作品服务':'服务续期未完成'})},
        fail:function(){reject({code:'NETWORK_ERROR',message:'暂时无法连接作品服务'})}})
    })},
    chat: function(text,onDelta){return chatClient.chat(text,onDelta)},
    cancelChat: function(){chatClient.cancel()},
    cancelTranscription: cancelTranscription,
    newRequestId: newRequestId,
    transcribe: transcribe,
    askIntent: askIntent,
    tts: tts,
    playSpeech: playSpeech,
    stopSpeech: stopSpeech,
    health: health
  }
}

module.exports = { createVoiceClient }
