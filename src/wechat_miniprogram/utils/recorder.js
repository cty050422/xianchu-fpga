// PTT recorder manager: press-to-talk over wx.getRecorderManager with a
// strict state machine and full mock injectability for host tests.
//
// WeChat contract used (per the official RecorderManager docs; verified
// against the developer-tools API surface, NOT Alipay my.* parameters):
//   wx.getRecorderManager() -> singleton manager
//   manager.start({ duration, sampleRate, numberOfChannels, encodeBitRate, format })
//     format 'mp3' is supported on both Android and iOS and is directly
//     acceptable to MP3-capable ASR backends — no container renaming.
//   onStop(res) -> { tempFilePath, duration, fileSize }
//   onError(err), onInterruptionBegin/End
// Recording needs scope.record authorization; denial is surfaced as the
// requesting-permission → error path with an "open settings" recovery action.
//
// Limits: max 15 s per segment, min 0.5 s effective, encoded size ≤ 2 MiB,
// max 20 s guard on device-reported duration (some devices over-run stop).
var recorderChannel = require('./recorder_lease').recorderChannel
var STATE_IDLE = 'idle'
var STATE_REQUESTING_PERMISSION = 'requesting-permission'
var STATE_RECORDING = 'recording'
var STATE_UPLOADING = 'uploading'
var STATE_RECOGNIZING = 'recognizing'
var STATE_READY = 'ready'
var STATE_CANCELLED = 'cancelled'
var STATE_ERROR = 'error'

var MAX_DURATION_MS = 15000
var MIN_DURATION_MS = 500
var MAX_FILE_BYTES = 2 * 1024 * 1024
var MAX_REPORTED_DURATION_MS = 20000

var START_OPTIONS = {
  duration: MAX_DURATION_MS,
  sampleRate: 16000,
  numberOfChannels: 1,
  encodeBitRate: 48000,
  format: 'mp3'
}

function createRecorder(options) {
  var opts = options || {}
  var wxApi = opts.wx
  var now = opts.now || function () { return Date.now() }
  var log = []

  var state = {
    phase: STATE_IDLE,
    session: 0,          // increment per attempt: stale callbacks die here
    startedAt: 0,
    autoStopTimer: null,
    result: null,
    error: null
  }
  var listeners = []
  var manager = recorderChannel(opts.recorderManager || wxApi.getRecorderManager())

  function publish() {
    var snap = snapshot()
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](snap) } catch (e) {}
    }
  }

  function snapshot() {
    return {
      phase: state.phase,
      durationMs: state.phase === STATE_RECORDING ? now() - state.startedAt : (state.result ? state.result.duration : 0),
      result: state.result,
      error: state.error
    }
  }

  function fail(code, message, recover) {
    state.phase = STATE_ERROR
    state.error = { code: code, message: message, recover: recover || null }
    publish()
  }

  function ensureAuthorized() {
    return new Promise(function (resolve, reject) {
      wxApi.getSetting({
        success: function (res) {
          var auth = res.authSetting || {}
          if (auth['scope.record'] === true) return resolve(true)
          if (auth['scope.record'] === false) {
            // Previously denied: only a manual settings trip can undo this.
            return reject({ code: 'PERMISSION_DENIED', needOpenSettings: true })
          }
          wxApi.authorize({
            scope: 'scope.record',
            success: function () { resolve(true) },
            fail: function (err) {
              reject({ code: 'PERMISSION_DENIED', needOpenSettings: true, detail: err && err.errMsg })
            }
          })
        },
        fail: function (err) { reject({ code: 'SETTING_FAILED', detail: err && err.errMsg }) }
      })
    })
  }

  // ---- device callbacks (bound once; session guard rejects stale ones) ----
  manager.onStart(function () {
    if (state.phase !== STATE_REQUESTING_PERMISSION && state.phase !== STATE_RECORDING) return
    state.phase = STATE_RECORDING
    state.startedAt = now()
    publish()
  })
  manager.onStop(function (res) {
    // A stop belonging to an older attempt (cancel + quick restart) must not
    // overwrite the newer session: validate by session counter.
    var session = state.session
    if (state.phase !== STATE_RECORDING && state.phase !== STATE_UPLOADING) return
    var duration = res && res.duration
    var size = res && res.fileSize
    state.autoStopClear()
    if (duration !== undefined && duration < MIN_DURATION_MS) {
      state.phase = STATE_IDLE
      fail('TOO_SHORT', '录音太短（' + duration + ' ms < ' + MIN_DURATION_MS + ' ms），请按住多说一会儿')
      return
    }
    if (duration !== undefined && duration > MAX_REPORTED_DURATION_MS) {
      fail('TOO_LONG', '录音超过上限（' + duration + ' ms）')
      return
    }
    if (size !== undefined && size > MAX_FILE_BYTES) {
      fail('TOO_LARGE', '编码后文件 ' + size + ' 字节超过 2MiB 上限')
      return
    }
    state.phase = STATE_READY
    state.result = {
      tempFilePath: res.tempFilePath,
      duration: duration,
      size: size,
      mime: 'audio/mp3',
      format: 'mp3',
      session: session
    }
    state.error = null
    publish()
  })
  manager.onError(function (err) {
    var message = (err && err.errMsg) || String(err)
    if (/auth|deny|denied|permission/i.test(message)) {
      fail('PERMISSION_DENIED', '麦克风授权被拒绝：请在设置中允许录音', 'openSettings')
    } else if (/busy|occup/i.test(message)) {
      fail('RECORDER_BUSY', '录音设备忙（可能被其他应用占用），请稍后重试', 'retry')
    } else {
      fail('RECORDER_ERROR', '录音失败：' + message, 'retry')
    }
  })
  manager.onInterruptionBegin(function () {
    // Phone call / other app stole the mic: stop and surface a cancel.
    if (state.phase === STATE_RECORDING) {
      try { manager.stop() } catch (e) {}
      state.phase = STATE_CANCELLED
      state.error = { code: 'INTERRUPTED', message: '录音被系统打断（来电或其他应用占用麦克风）' }
      publish()
    }
  })

  state.autoStopClear = function () {
    if (state.autoStopTimer) { clearTimeout(state.autoStopTimer); state.autoStopTimer = null }
  }

  function begin() {
    state.session += 1
    state.result = null
    state.error = null
    state.startedAt = 0
    state.autoStopClear()
    state.phase = STATE_REQUESTING_PERMISSION
    publish()
  }

  return {
    START_OPTIONS: START_OPTIONS,
    MAX_DURATION_MS: MAX_DURATION_MS,
    MIN_DURATION_MS: MIN_DURATION_MS,
    snapshot: snapshot,
    subscribe: function (fn) { listeners.push(fn); return function () { listeners.splice(listeners.indexOf(fn), 1) } },

    // Press-to-talk start. Rejects (state → error) instead of throwing when
    // authorization is denied so the page can offer the settings recovery.
    start: function () {
      if (state.phase === STATE_RECORDING || state.phase === STATE_REQUESTING_PERMISSION) {
        return Promise.reject({ code: 'ALREADY_RECORDING', message: '已经在录音中' })
      }
      begin()
      var startingSession = state.session
      return ensureAuthorized().then(function () {
        if (startingSession !== state.session || state.phase !== STATE_REQUESTING_PERMISSION) throw { code: 'CANCELLED', message: '录音已取消' }
        manager.start(START_OPTIONS)
        // Hard ceiling: never trust the device timer alone.
        state.autoStopTimer = setTimeout(function () {
          if (state.phase === STATE_RECORDING) {
            try { manager.stop() } catch (e) {}
          }
        }, MAX_DURATION_MS + 500)
      }).catch(function (error) {
        if (state.phase === STATE_REQUESTING_PERMISSION) {
          fail(error.code || 'PERMISSION_DENIED',
            error.code === 'SETTING_FAILED' ? '无法读取授权状态' : '麦克风授权被拒绝：请在设置中允许录音',
            'openSettings')
        }
        throw error
      })
    },

    // Release-to-send: resolves with the finished segment.
    stop: function () {
      if (state.phase !== STATE_RECORDING) {
        return Promise.reject({ code: 'NOT_RECORDING', message: '当前没有在录音' })
      }
      state.phase = STATE_UPLOADING // intermediate; onStop finalizes to READY
      publish()
      return new Promise(function (resolve, reject) {
        var session = state.session
        var off = null
        var timer = setTimeout(function () {
          if (off) off()
          reject({ code: 'STOP_TIMEOUT', message: '录音结束超时，请重试' })
        }, 4000)
        off = snapshot0Subscribe(function (snap) {
          if (snap.phase === STATE_READY && snap.result && snap.result.session === session) {
            if (off) off(); clearTimeout(timer); resolve(snap.result)
          } else if (snap.phase === STATE_ERROR || snap.phase === STATE_CANCELLED) {
            if (off) off(); clearTimeout(timer)
            reject(snap.error || { code: 'CANCELLED', message: '录音已取消' })
          }
        })
        try { manager.stop() } catch (e) {
          if (off) off(); clearTimeout(timer)
          reject({ code: 'STOP_FAILED', message: String(e) })
        }
      })
    },

    // Slide-up cancel / page leave / app background: discard the segment.
    cancel: function () {
      if (state.phase !== STATE_RECORDING && state.phase !== STATE_REQUESTING_PERMISSION &&
          state.phase !== STATE_UPLOADING) return
      var wasRecording = state.phase === STATE_RECORDING
      state.session += 1 // invalidate any in-flight onStop
      state.autoStopClear()
      if (wasRecording) { try { manager.stop() } catch (e) {} }
      state.phase = STATE_CANCELLED
      state.error = { code: 'CANCELLED', message: '已取消本段录音' }
      publish()
    },

    // Page onHide/onUnload hook.
    abortForLifecycle: function () {
      if (state.phase === STATE_RECORDING || state.phase === STATE_UPLOADING) this.cancel()
    },

    reset: function () {
      state.session += 1
      state.autoStopClear()
      state.phase = STATE_IDLE
      state.result = null
      state.error = null
      publish()
    },
    _manager: manager
  }

  function snapshot0Subscribe(fn) {
    listeners.push(fn)
    return function () {
      var i = listeners.indexOf(fn)
      if (i >= 0) listeners.splice(i, 1)
    }
  }
}

module.exports = {
  createRecorder,
  STATES: { IDLE: STATE_IDLE, REQUESTING_PERMISSION: STATE_REQUESTING_PERMISSION, RECORDING: STATE_RECORDING,
    UPLOADING: STATE_UPLOADING, RECOGNIZING: STATE_RECOGNIZING, READY: STATE_READY, CANCELLED: STATE_CANCELLED, ERROR: STATE_ERROR },
  MAX_DURATION_MS, MIN_DURATION_MS, MAX_FILE_BYTES
}
