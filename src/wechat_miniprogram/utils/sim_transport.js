// BLE-like transport over the virtual instrument. Same async shape as the real
// wx BLE adapter (connect / write / notify / disconnect), notifications are
// fragmented into MTU-20 sized chunks exactly like the S3 relay, so the real
// client reassembly code (createReplyParser / createStatusParser) is what glues
// them back together. No page may bypass this and poke device state directly.
var protocol = require('./protocol')
var sim = require('./sim_device')

function createSimTransport(options) {
  var opts = options || {}
  var mtu = opts.mtu || 20
  var latencyMs = opts.latencyMs !== undefined ? opts.latencyMs : 8
  var device = sim.createSimDevice(opts)
  var connected = false
  var notifySink = null
  var infoSink = null
  var disconnectSink = null

  function later(fn, arg) {
    return new Promise(function (resolve) {
      setTimeout(function () { resolve(fn(arg)) }, latencyMs)
    })
  }

  function emitFrame(frameBuffer) {
    if (!notifySink || !connected) return
    // Fragment like a GATT notification: MTU-3 payload bytes per notify.
    var bytes = Array.from(new Uint8Array(frameBuffer))
    var chunkSize = Math.max(1, mtu - 3)
    for (var start = 0; start < bytes.length; start += chunkSize) {
      var chunk = bytes.slice(start, start + chunkSize)
      notifySink(Uint8Array.from(chunk).buffer, 'status')
    }
  }

  return {
    profile: opts.profile || 'normal',
    connect: function () {
      return later(function () {
        connected = true
        return {
          deviceId: 'sim-' + (opts.profile || 'normal'),
          name: 'XianChu-LINK-R3-SIM(' + (opts.profile || 'normal') + ')',
          matchReason: 'simulator'
        }
      })
    },
    write: function (buffer) {
      if (!connected) return Promise.reject({ errMsg: 'writeBLECharacteristicValue:fail not connected' })
      return later(function () {
        var outcome = device.feed(buffer)
        if (outcome.info && infoSink) infoSink(outcome.info)
        for (var i = 0; i < outcome.frames.length; i++) emitFrame(outcome.frames[i])
        if (outcome.dropConnection && connected) {
          connected = false
          if (disconnectSink) disconnectSink({ deviceId: 'sim', simulated: true })
        }
        return true
      })
    },
    readInfo: function () {
      return later(function () { return device.identityText() })
    },
    onNotify: function (cb) { notifySink = cb },
    onInfo: function (cb) { infoSink = cb },
    onDisconnect: function (cb) { disconnectSink = cb },
    isConnected: function () { return connected },
    disconnect: function () {
      connected = false
      return Promise.resolve(true)
    },
    device: device
  }
}

module.exports = { createSimTransport }
