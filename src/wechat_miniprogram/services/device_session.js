// Shared device session hub — the ONE place that owns device mode state.
//
// Layers (never collapsed into a single "demo" flag):
//   hardwareMode : disconnected | simulator | real
//   serviceMode  : unconfigured | local-demo | configured-service   (catalog/gateway)
//   providerMode : unconfigured | mock | live                      (ASR/LLM, from gateway)
//   confirmation : local-edited → service-downloaded → queued → ble-written → fpga-confirmed
//
// Real hardware stays owned by pages/index (the proven PING2-fixed flow); the
// page publishes snapshots here. The simulator session is owned HERE and uses
// the real client stack (protocol.js + transaction.js) over a fragmented
// MTU-20 sim transport — pages can never short-circuit it by setting UI state.
//
// Switching mode or disconnecting clears the pending action queue; nothing
// recorded in simulator mode is ever auto-replayed against real hardware.
var protocol = require('../utils/protocol')
var scoreCompiler = require('../utils/score_compiler')
var { createIssuer } = require('../utils/transaction')
var { createSimTransport } = require('../utils/sim_transport')

var STATUS_STALE_MS = 700

function createSessionHub(options) {
  var opts = options || {}
  var wxApi = opts.wx
  var now = opts.now || function () { return Date.now() }
  var setTimer = opts.setTimeout || function (fn, ms) { return setTimeout(fn, ms) }
  var clearTimer = opts.clearTimeout || function (id) { return clearTimeout(id) }

  var realDriver = null
  var listeners = []
  var state = {
    hardwareMode: 'disconnected',   // disconnected | simulator | real
    serviceMode: 'unconfigured',    // unconfigured | local-demo | configured-service
    providerMode: 'unconfigured',   // unconfigured | mock | live
    // simulator session
    sim: null,                      // { transport, issuer, replyParser, identity, lastStatusAt }
    // real link mirror (published by pages/index)
    real: null,                     // { deviceId, name, identity, lastStatusAt, lastStatus }
    capability: null,               // { supportedMask, firstField } from CAPABILITY op
    pendingActions: [],             // drafts only; NEVER auto-replayed
    lastError: '', connectionRevision: 0, activeScore: null, scoreCommitId: 0
  }

  function snapshot() {
    return {
      observer:state.real&&state.real.observer||null,observerAt:state.real&&state.real.observerAt||0,
      wave:state.real&&state.real.wave||null,
      hardwareMode: state.hardwareMode,
      connectionRevision: state.connectionRevision,
      activeScore: state.activeScore ? Object.assign({},state.activeScore) : null,
      serviceMode: state.serviceMode,
      providerMode: state.providerMode,
      connected: state.hardwareMode !== 'disconnected',
      isSimulator: state.hardwareMode === 'simulator',
      simProfile: state.sim ? state.sim.profile : null,
      realDevice: state.real ? { deviceId: state.real.deviceId, name: state.real.name, identity: state.real.identity } : null,
      lastStatus: state.sim ? state.sim.lastStatus : (state.real ? state.real.lastStatus : null),
      lastStatusAt: state.sim ? state.sim.lastStatusAt : (state.real ? state.real.lastStatusAt : null),
      freshness: freshness(),
      capability: state.capability,
      pendingActionCount: state.pendingActions.length,
      lastError: state.lastError,
      voicesFrame: state.sim ? state.sim.voicesFrame : (state.real ? state.real.voicesFrame : null),
      voicesFresh: !!(state.sim ? state.sim.voicesFrame : state.real && state.real.voicesFrame) && (now()-(state.sim ? state.sim.voicesFrameAt : state.real.voicesFrameAt))<=STATUS_STALE_MS,
      voicesFrameAt: state.sim ? state.sim.voicesFrameAt : (state.real ? state.real.voicesFrameAt : 0)
    }
  }

  function freshness() {
    var at = state.sim ? state.sim.lastStatusAt : (state.real ? state.real.lastStatusAt : null)
    if (!at) return 'none'
    return (now() - at) <= STATUS_STALE_MS ? 'fresh' : 'stale'
  }

  function emit() {
    var snap = snapshot()
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](snap) } catch (e) { /* one page's error must not break others */ }
    }
  }

  function clearSim() {
    state.activeScore=null
    if (state.sim) {
      if (state.sim.staleTimer) clearTimer(state.sim.staleTimer)
      try { state.sim.issuer.reset() } catch (e) {}
      try { state.sim.transport.disconnect() } catch (e) {}
    }
    state.sim = null
    state.capability = null
    // Mode switch wipes drafts: nothing simulated is ever replayed later.
    state.pendingActions = []
  }

  // -------------------------------------------------------------------------
  // Simulator session (real client code over the virtual device).
  // -------------------------------------------------------------------------
  function enterSimulator(profile) {
    if (state.hardwareMode === 'real') {
      state.lastError = '真实设备在线：请先断开再进入演示模式'
      emit()
      return Promise.reject({ code: 'REAL_LINK_ACTIVE', message: state.lastError })
    }
    state.connectionRevision++
    clearSim()
    var transport = createSimTransport({ profile: profile, now: now })
    var session = {
      profile: profile,
      transport: transport,
      identity: null,
      lastStatus: null,
      lastStatusAt: null,
      lastStatusAtWall: null,
      staleTimer: null
    }
    session.issuer = createIssuer({
      send: function (buffer) { return transport.write(buffer) },
      timeoutMs: opts.issuerTimeoutMs || 1200
    })
    session.replyParser = protocol.createReplyParser({
      onStatus: function (status) {
        if(state.activeScore&&(!(status.flags&1)||status.song!==state.activeScore.wireId))state.activeScore=null
        session.lastStatus = status
        session.lastStatusAt = now()
        // settle any in-flight command; publish snapshot either way
        session.issuer.onStatus(status)
        emit()
      },
      onConfig: function (reply) {
        // A config reply must also free the issuer's in-flight slot (the 0x15
        // submit is settled by the 0x81 answer, not by a status frame). SET's
        // normal intermediate answer is result=1 (staged): map that to success
        // so the slot frees; genuine error codes still reject the submit. The
        // authoritative per-op semantics live in waitReply, not here.
        session.issuer.onStatus({
          commandSequence: reply.sequence,
          commandResult: (reply.op === 0 && reply.result === 1) ? 0 : reply.result,
          configReply: reply
        })
        if (session.onConfigReply) session.onConfigReply(reply)
      },
      onVoices: function (frame) {
        // 0x84 four-voice snapshot: per-voice partials/pcm/gain. Kept on the
        // session state and republished so the 演奏 tab can show each sounding
        // voice's real timbre and level, not a single global pitch.
        session.voicesFrame = frame
        session.voicesFrameAt = now()
        emit()
      },
      onEventFrame: function (bytes) { if (simEventSink) simEventSink(bytes) }
    })
    transport.onNotify(function (buffer) { session.replyParser(buffer) })
    transport.onDisconnect(function () {
      if (state.sim === session) {
        clearSim()
        state.hardwareMode = 'disconnected'
        state.lastError = '演示设备连接已断开'
        emit()
      }
    })
    state.hardwareMode = 'simulator'
    state.lastError = ''
    return transport.connect().then(function (info) {
      return transport.readInfo().then(function (text) {
        session.identity = text
        session.deviceInfo = info
        state.sim = session
        emit()
        // Capability negotiation happens on demand (queryCapability).
        return snapshot()
      })
    })
  }

  function leaveSimulator() {
    state.connectionRevision++
    clearSim()
    if (state.hardwareMode === 'simulator') state.hardwareMode = 'disconnected'
    emit()
    return Promise.resolve(snapshot())
  }

  function requireSim(what) {
    if (state.hardwareMode === 'real' && state.real && realDriver) {
      if(freshness() !== 'fresh') throw {code:'STALE',message:'FPGA状态已失鲜'}
      return realDriver
    }
    if (state.hardwareMode !== 'simulator' || !state.sim) {
      state.lastError = what + '需要已连接的设备（当前未连接；未连接时不发送任何硬件命令）'
      emit()
      throw { code: 'NOT_CONNECTED', message: state.lastError }
    }
    return state.sim
  }

  function simPing() {
    var session = requireSim('PING')
    return session.issuer.submit(function (seq) { return protocol.pingFrame(seq) }, { type: 0x14 })
      .then(function (outcome) {
        emit()
        return outcome
      })
  }

  // Upload ONE segment (index into compiled.segments) as a full transaction.
  // The caller decides whether to continue with the next segment — the FPGA
  // cannot glue segments into one seamless song and we never claim it can.
  function simUploadSegment(song, compiled, segmentIndex, progress) {
    var session = requireSim('曲谱上传')
    var segment = compiled.segments[segmentIndex]
    if (!segment) return Promise.reject({ code: 'NO_SUCH_SEGMENT', message: '没有第 ' + (segmentIndex + 1) + ' 段' })
    var steps = segment.steps
    var seqSongId = segmentIndex === 0 ? (song.wireId || 1) : (song.wireId || 1) + segmentIndex
    return session.issuer.submit(function (seq) {
      return protocol.beginFrame({ id: seqSongId & 0xff, steps: { length: steps.length } }, seq)
    }, { type: 0x10 }).then(function () {
      var chain = Promise.resolve()
      steps.forEach(function (step, index) {
        chain = chain.then(function () {
          if (progress) progress(index + 1, steps.length, segment.label)
          return session.issuer.submit(function (seq) {
            return protocol.stepFrameSamples([step.zone, step.expression], index, seq, step.durationSamples)
          }, { type: 0x11 })
        })
      })
      return chain
    }).then(function () {
      return session.issuer.submit(function (seq) { return protocol.commitFrame(seqSongId & 0xff, seq) }, {
        type: 0x12,
        validate: function (status) {
          return (status.song === (seqSongId & 0xff) && (status.flags & 1))
            ? true : 'FPGA 读回曲目 ' + status.song + '，未确认曲目 ' + (seqSongId & 0xff)
        }
      })
    }).then(function (outcome) {
      emit()
      return outcome
    })
  }

  function simGuide(start) {
    start = typeof start === 'boolean' ? (start ? 1 : 0) : start
    var session = requireSim(start ? '开始引导' : '停止引导')
    // No local flag validation: a rejected control (e.g. 0xE4 no score loaded)
    // must surface as its FPGA result code, not as a misleading readback
    // mismatch. The authoritative state arrives with the status frame itself.
    return session.issuer.submit(function (seq) { return protocol.guideControl(start, seq) }, {
      type: 0x13, validate:function(s){var legacy=!s.extended&&(s.mode===undefined||s.mode===null);return !!(s.flags&2)===!!start && (!start || (start===1 && legacy) || s.mode===start) ? true : 'FPGA模式回读不一致'}
    }).then(function (outcome) { emit(); return outcome })
  }

  // S16: the v2 upload path. Frames are REBUILT with the issuer's live
  // sequence numbers (the issuer stamps one seq per in-flight command); the
  // steps CRC accumulates over the STEP2 payloads exactly like
  // rtl/esp_score_link.sv crc8_step2 (0x17 prefix + payload bytes).
  function crcStep(crc, payload) {
    var feed = [0x17].concat(payload)
    for (var i = 0; i < feed.length; i++) {
      crc ^= feed[i]
      for (var b = 0; b < 8; b++) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
    }
    return crc
  }

  function simUploadSegmentV2(compiled, wireId, segmentIndex, progress) {
    var session = requireSim('曲谱上传v2')
    var segCount = Math.ceil(compiled.steps.length / scoreCompiler.V2_MAX_STEPS)
    if (!Number.isInteger(segmentIndex) || segmentIndex<0 || segmentIndex >= segCount) return Promise.reject({ code: 'NO_SUCH_SEGMENT', message: '没有第 ' + (segmentIndex + 1) + ' 段' })
    var chunk = compiled.steps.slice(segmentIndex * scoreCompiler.V2_MAX_STEPS, (segmentIndex + 1) * scoreCompiler.V2_MAX_STEPS)
    var crc = 0
    var seqSongId = (wireId || 1) & 0xff
    var mapping=compiled.zonePitches || (compiled.requiredMapping && compiled.requiredMapping.notes)
    var ready=Promise.resolve()
    if(mapping && mapping.length===4) {
      ready=queryCapability().then(function(cap){
        var fields=[1,2,3,4,22]
        if(fields.some(function(id){return !protocol.supportsField(cap.supportedMask,id)}))
          throw {code:'UNSUPPORTED',message:'设备不能应用此曲目的音高映射'}
        var sets=mapping.map(function(note,i){return {field:i+1,value:note}})
        sets.push({field:22,value:0})
        return simConfigTransaction(sets)
      })
    }
    return ready.then(function(){return session.issuer.submit(function (seq) {
      return protocol.frame(0x16, seq, [seqSongId, chunk.length, segmentIndex, segCount])
    }, { type: 0x16 })}).then(function () {
      var chain = Promise.resolve()
      chunk.forEach(function (step, index) {
        chain = chain.then(function () {
          if (progress) progress(index + 1, chunk.length,'第'+(segmentIndex+1)+'段/共'+segCount+'段')
          var mask = (step.mask === undefined)
            ? (step.zone === null || step.zone === undefined ? 0 : (1 << step.zone))
            : step.mask
          var payload = [index & 0xff, (((step.expression || 0) & 3) << 4) | (mask & 0xf),
            step.durationSamples & 0xff, (step.durationSamples >>> 8) & 0xff, (step.durationSamples >>> 16) & 0xff]
          crc = crcStep(crc, payload)
          return session.issuer.submit(function (seq) {
            return protocol.frame(0x17, seq, payload)
          }, { type: 0x17 })
        })
      })
      return chain
    }).then(function () {
      return session.issuer.submit(function (seq) {
        return protocol.frame(0x18, seq, [seqSongId, crc])
      }, {
        type: 0x18,
        validate: function (status) {
          return (status.song === seqSongId && (status.flags & 1))
            ? true : 'FPGA 读回曲目 ' + status.song + '，未确认曲目 ' + seqSongId
        }
      })
    }).then(function (outcome) { emit(); return outcome })
  }

  function simFxControl(mode) {
    var session = requireSim('效果选择')
    return session.issuer.submit(function (seq) {
      return protocol.frame(0x19, seq, [mode & 0xff])
    }, { type: 0x19, validate:function(status){
      return status.extended && status.effectMode===mode ? true : 'FPGA 效果状态未确认'
    } }).then(function (outcome) { emit(); return outcome })
  }

  function queryCapability() {
    var session = requireSim('能力协商')
    return new Promise(function (resolve, reject) {
      var timer = setTimer(function () {
        session.onConfigReply = null
        reject({ code: 'TIMEOUT_UNKNOWN', message: '能力协商超时' })
      }, 1500)
      session.onConfigReply = function (reply) {
        if (reply.op !== 5) return
        clearTimer(timer)
        session.onConfigReply = null
        state.capability = { supportedMask: reply.supportedMask, firstField: reply.firstField }
        emit()
        resolve(state.capability)
      }
      session.issuer.submit(function (seq) {
        return protocol.configFrame({ op: 5, sequence: seq })
      }, { type: 0x15 }).catch(function (error) {
        clearTimer(timer); session.onConfigReply = null; reject(error)
      })
    })
  }

  // Full config transaction: ACQUIRE → SET… → COMMIT → GET readback.
  // Only succeeds when the GET echo matches the committed value.
  function simConfigTransaction(sets) {
    var session = requireSim('配置会话')
    var token = (Math.floor(Math.random() * 0xffff) || 1) & 0xffff
    function waitReply(expectedOp) {
      return new Promise(function (resolve, reject) {
        var timer = setTimer(function () {
          session.onConfigReply = null
          reject({ code: 'TIMEOUT_UNKNOWN', message: '配置应答超时（' + expectedOp + '）' })
        }, 1500)
        session.onConfigReply = function (reply) {
          if (reply.op !== expectedOp) return
          clearTimer(timer)
          session.onConfigReply = null
          resolve(reply)
        }
      })
    }
    function op(opcode, field, value) {
      var waiting = waitReply(opcode === 0 ? 0 : opcode)
      // The issuer submit settles either way (a config error code frees the
      // slot with a rejection); the AUTHORITATIVE semantics come from the
      // waited reply, so a submit rejection must not short-circuit it.
      var sent = session.issuer.submit(function (seq) {
        return protocol.configFrame({ op: opcode, field: field, value: value, token: token, sequence: seq })
      }, { type: 0x15 }).catch(function (error) { return error })
      return Promise.all([sent, waiting]).then(function (results) {
        if (results[0] && results[0].code === 'SEND_FAILED') throw results[0]
        return results[1]
      })
    }
    return op(3, 0, 0).then(function (acquired) {
      if (acquired.result !== 0) throw { code: 'ACQUIRE_FAILED', result: acquired.result, message: protocol.describeConfigResult(acquired.result) }
      var chain = Promise.resolve()
      sets.forEach(function (entry) {
        chain = chain.then(function () {
          return op(0, entry.field, entry.value).then(function (reply) {
            if (reply.result !== 1) throw { code: 'SET_FAILED', field: entry.field, result: reply.result, message: protocol.describeConfigResult(reply.result) }
          })
        })
      })
      return chain.then(function () { return op(1, 0, 0) }).then(function (commit) {
        if (commit.result !== 0) throw { code: 'COMMIT_FAILED', result: commit.result, message: protocol.describeConfigResult(commit.result) }
        var reads=Promise.resolve(null)
        sets.forEach(function(entry){ reads=reads.then(function(){return op(2,entry.field,0)}).then(function(rb){
          if(rb.result!==0 || rb.value!==entry.value) throw {code:'READBACK_MISMATCH',message:'字段'+entry.field+'回读不一致'}
          return rb
        }) })
        return reads
      }).then(function(readback){
        return op(4,0,0).then(function(released){
          if(released.result!==0) throw {code:'RELEASE_FAILED',message:'配置释放未确认'}
          emit();return readback
        })
      })
    })
  }

  // -------------------------------------------------------------------------
  // Real-link mirror (pages/index publishes here).
  // -------------------------------------------------------------------------
  function publishReal(patch) {
    if(patch.lastStatus&&state.activeScore&&(!(patch.lastStatus.flags&1)||patch.lastStatus.song!==state.activeScore.wireId))state.activeScore=null
    // A mirror must never keep the simulator as the preferred status source.
    // Every connection boundary also invalidates old drafts and capabilities.
    if (patch.connected === false || state.hardwareMode !== 'real') {
      state.connectionRevision++
      clearSim()
      state.pendingActions = []
      state.capability = null
    }
    if (!state.real) state.real = {}
    Object.assign(state.real, patch)
    if (patch.connected === false) {
      state.real = null
      realDriver = null
      if (state.hardwareMode === 'real') state.hardwareMode = 'disconnected'
    } else if (state.hardwareMode !== 'real') {
      state.hardwareMode = 'real'
    }
    emit()
  }

  function bindReal(driver) { realDriver=driver }
  function rememberScore(meta) {
    var s=snapshot()
    if(s.hardwareMode==='disconnected'||s.freshness!=='fresh'||!s.lastStatus||!(s.lastStatus.flags&1)||s.lastStatus.song!==meta.wireId)throw {code:'SCORE_IDENTITY_UNCONFIRMED',message:'曲目身份尚未得到设备确认'}
    state.activeScore={songId:meta.songId,title:String(meta.title||'').slice(0,100),wireId:meta.wireId,bpm:meta.bpm,segmentIndex:meta.segmentIndex||0,segments:meta.segments||1,source:meta.source||'catalog',commitId:++state.scoreCommitId}
    emit();return Object.assign({},state.activeScore)
  }
  function feedRealConfig(reply) {
    if(state.hardwareMode!=='real' || !realDriver) return
    realDriver.issuer.onStatus({commandSequence:reply.sequence,
      commandResult:(reply.op===0 && reply.result===1)?0:reply.result,configReply:reply})
    if(realDriver.onConfigReply) realDriver.onConfigReply(reply)
  }

  // -------------------------------------------------------------------------
  // Service configuration (catalog / gateway base URL, provider mode).
  // -------------------------------------------------------------------------
  function setServiceInfo(info) {
    if (info.serviceMode) state.serviceMode = info.serviceMode
    if (info.providerMode) state.providerMode = info.providerMode
    if (info.baseUrl !== undefined) state.baseUrl = info.baseUrl
    emit()
  }

  function saveDraft(action) {
    // Drafts are visible plans only. They are cleared on any mode switch and
    // are NEVER executed automatically on a later connection.
    state.pendingActions.push({ savedAt: now(), action: action })
    emit()
  }

  function clearDrafts() {
    state.pendingActions = []
    emit()
  }

  // Hardware actions surface as rejected PROMISES (not sync throws) so pages
  // and tests can uniformly await them.
  var operationTail=Promise.resolve()
  function promiseWrap(fn) {
    return function () {
      try {
        // Serialize WHOLE operations, not only individual frames. Otherwise two
        // Tabs can replace onConfigReply or interleave BEGIN/STEP transactions.
        // Capture the originating connection: queued work never replays after
        // a disconnect/reconnect or a simulator/real mode switch.
        var args=arguments,mode=state.hardwareMode,context=requireSim('设备操作')
        var result=operationTail.then(function(){
          if(state.hardwareMode!==mode || requireSim('设备操作')!==context)
            throw {code:'RESET',message:'连接已变化，排队操作已取消，请手动重试'}
          return fn.apply(null,args)
        })
        operationTail=result.catch(function(){})
        return result
      } catch (error) {
        return Promise.reject(error)
      }
    }
  }

  function subscribeState(fn){listeners.push(fn);return function(){const i=listeners.indexOf(fn);if(i>=0)listeners.splice(i,1)}}

  return {
    enterSimulator: enterSimulator,
    leaveSimulator: leaveSimulator,
    publishObserver:function(observer){if(state.hardwareMode==='real'&&state.real){state.real.observer=observer;state.real.observerAt=now();emit();}},
    publishVoices:function(frame){if(state.hardwareMode==='real'&&state.real){state.real.voicesFrame=frame;state.real.voicesFrameAt=now();emit();}},
    publishWave:function(wave){if(state.hardwareMode==='real'&&state.real){state.real.wave=wave;emit();}},
    practiceControl:promiseWrap(function(mode,action){
      const session=requireSim('练习控制'),snap=snapshot(),observed=snap.observer;
      if(!observed||now()-snap.observerAt>700)throw {code:'CAPABILITY_REQUIRED',message:'请先接入配套固件，等待演奏状态'};
      const id=(observed.request+1)&65535,revision=snap.connectionRevision;
      return new Promise(function(resolve,reject){
        let timer,off;const finish=(error,result)=>{if(timer)clearTimer(timer);if(off)off();error?reject(error):resolve(result)};
        off=subscribeState(function(s){
          if(s.connectionRevision!==revision)return finish({code:'RESET',message:'连接已变化'});
          const o=s.observer;if(!o||o.request!==id)return;
          if(o.mode!==(action===4?0:mode))return;
          if(action===1 && ![2,5].includes(o.transport))return;
          if(action===2 && o.transport!==3)return;
          if(action===3 && ![2,5].includes(o.transport))return;
          finish(null,o);
        });
        timer=setTimer(()=>finish({code:'TIMEOUT_UNKNOWN',message:'练习状态未确认，请读取设备状态'}),2000);
        session.issuer.submit(seq=>protocol.frame(0x20,seq,[mode,action,id&255,id>>>8]),{type:0x20}).catch(e=>finish(e));
      });
    }),
    auditionCommand: promiseWrap(function(op,payload){
      if(state.hardwareMode!=='real')throw {code:'NOT_REAL',message:'试听需要已连接的真实乐器'};
      if(op<0x1b||op>0x1f)throw {code:'OPCODE',message:'无效试听操作'};
      const session=requireSim('试听');
      return session.issuer.submit(function(seq){return require('../utils/audition_score').frame(op,seq,payload)},{type:op});
    }),
    simPing: promiseWrap(simPing),
    simUploadSegment: promiseWrap(simUploadSegment),
    simUploadSegmentV2: promiseWrap(simUploadSegmentV2),
    simFxControl: promiseWrap(simFxControl),
    simGuide: promiseWrap(simGuide),
    queryCapability: promiseWrap(queryCapability),
    simConfigTransaction: promiseWrap(simConfigTransaction),
    bindReal: bindReal,
    rememberScore: rememberScore,
    feedRealConfig: feedRealConfig,
    publishReal: publishReal,
    setServiceInfo: setServiceInfo,
    saveDraft: saveDraft,
    clearDrafts: clearDrafts,
    snapshot: snapshot,
    freshness: freshness,
    subscribe: function (fn) {
      listeners.push(fn)
      return function () {
        var i = listeners.indexOf(fn)
        if (i >= 0) listeners.splice(i, 1)
      }
    },
    _state: state
  }
}

// T2: 0x85 sink for the simulator path (the real path routes through
// instrument_model.setEventFrameSink); one global sink either way.
let simEventSink=null
function setEventSink(fn){simEventSink=fn||null}
module.exports = { createSessionHub, STATUS_STALE_MS, setEventSink }
