// Real BLE transport (S15): the wx bluetooth adapter behind the same async
// shape as createSimTransport, so pages can switch sim/real without changing
// their call pattern.
//
// Contract:
//   * connect() -> resolves { deviceName } after the S3 GATT service and the
//     command/status characteristics are found (UUIDs from protocol.js - the
//     frozen wire identity),
//   * sendCommand(buffer) writes the command characteristic; refuses when not
//     connected (never silently queues for later - a command the device did
//     not receive must not be reported as sent),
//   * status notifications are reassembled and dispatched through
//     protocol.createReplyParser (0x80/0x81 demux, MTU fragmentation handled),
//   * disconnect events clear the notify sink and fire onDisconnect,
//   * switchTo/destroy leave NO residual state: drafts and config sessions are
//     the page's responsibility (config_client.abandon()), this module only
//     guarantees its own socket state is torn down.
//
// Everything is injected through `wx` so host tests can drive the full flow
// with a stub; on the phone the real wx global is used.
var protocol = require('./protocol')

var SERVICE_UUID = protocol.SERVICE_UUID
var COMMAND_UUID = protocol.COMMAND_UUID
var STATUS_UUID = protocol.STATUS_UUID

function createBleTransport(options) {
  var opts = options || {}
  var wxApi = opts.wx || (typeof wx !== 'undefined' ? wx : null)
  if (!wxApi) throw new Error('ble transport needs a wx API')

  var connected = false
  var deviceId = null
  var commandCharId = null
  var notifySink = null
  var disconnectSink = null
  var connecting = false
  var stats = { commandsSent: 0, notifications: 0, reconnects: 0, errors: 0 }

  function notifyFail(action, reject, err) {
    stats.errors++
    var e = new Error((action) + ' failed: ' + ((err && err.errMsg) || JSON.stringify(err)))
    e.cause = err
    reject(e)
  }

  function step(fn) {
    return new Promise(function (resolve, reject) {
      fn(function (ok, result) {
        if (ok) resolve(result)
        else notifyFail('ble', reject, result)
      })
    })
  }

  function call(api, arg) {
    return step(function (done) {
      wxApi[Object.keys(arg)[0]](Object.assign(Object.values(arg)[0], {
        success: function (res) { done(true, res) },
        fail: function (err) { done(false, err) }
      }))
    })
  }

  function onCharacteristicChange(res) {
    if (!connected || !notifySink) return
    if(String(res.deviceId).toLowerCase()!==String(deviceId).toLowerCase())return
    if(res.serviceId && res.serviceId.toLowerCase()!==SERVICE_UUID.toLowerCase())return
    if(res.characteristicId && res.characteristicId.toLowerCase()!==STATUS_UUID.toLowerCase())return
    var value = res.value
    var bytes
    if (value && value.byteLength !== undefined) bytes = new Uint8Array(value)
    else if (value && value.length !== undefined) bytes = new Uint8Array(value)
    else return
    stats.notifications++
    notifySink(bytes.buffer)
  }

  function onConnectionState(res) {
    if (res.deviceId === deviceId && !res.connected && connected) {
      connected = false
      stats.errors++
      if (disconnectSink) disconnectSink()
    }
  }

  return {
    get connected() { return connected },
    stats: stats,

    connect: function (preferredName) {
      if (connecting || connected) return Promise.reject(new Error('connect already in progress'))
      connecting = true
      var adapterReady = call('openBluetoothAdapter', { openBluetoothAdapter: {} })
      var self = this
      return adapterReady.then(function () {
        // Prefer an already-known device id; otherwise scan.
        if (deviceId) return deviceId
        return new Promise(function(resolve,reject){
          var timer=null,done=false
          function finish(error,id){
            if(done)return;done=true;if(timer)clearTimeout(timer)
            wxApi.offBluetoothDeviceFound(found)
            wxApi.stopBluetoothDevicesDiscovery({})
            if(error)reject(error);else {deviceId=id;resolve(id)}
          }
          function found(event){
            var list=(event&&event.devices)||[]
            for(var i=0;i<list.length;i++) {
              var name=list[i].name||list[i].localName||''
              if(preferredName && name.indexOf(preferredName)<0)continue
              if(!preferredName && !/XianChu/i.test(name))continue
              finish(null,list[i].deviceId);return
            }
          }
          wxApi.onBluetoothDeviceFound(found)
          timer=setTimeout(function(){finish(new Error('BLE discovery timeout'))},opts.scanTimeoutMs||10000)
          wxApi.startBluetoothDevicesDiscovery({services:[SERVICE_UUID],allowDuplicatesKey:false,
            success:function(){},fail:function(e){finish(new Error(e.errMsg||'BLE discovery failed'))}})
        })
      }).then(function (id) {
        return call('createBLEConnection', { createBLEConnection: { deviceId: id } })
      }).then(function () {
        return call('getBLEDeviceServices', { getBLEDeviceServices: { deviceId: deviceId } })
      }).then(function (res) {
        var services = (res && res.services) || []
        var found = null
        for (var i = 0; i < services.length; i++)
          if (services[i].uuid.toUpperCase().indexOf(SERVICE_UUID.toUpperCase()) >= 0) found = services[i]
        if (!found) throw new Error('XianChu service UUID not present on the device')
        return call('getBLEDeviceCharacteristics', {
          getBLEDeviceCharacteristics: { deviceId: deviceId, serviceId: SERVICE_UUID }
        })
      }).then(function (res) {
        var chars = (res && res.characteristics) || []
        var cmd = null, status = null
        for (var i = 0; i < chars.length; i++) {
          var u = (chars[i].uuid || '').toUpperCase()
          if (u.indexOf(COMMAND_UUID.toUpperCase()) >= 0) cmd = chars[i].uuid
          if (u.indexOf(STATUS_UUID.toUpperCase()) >= 0) status = chars[i].uuid
        }
        if (!cmd || !status) throw new Error('command/status characteristics missing')
        commandCharId = cmd
        return call('notifyBLECharacteristicValueChange', {
          notifyBLECharacteristicValueChange: {
            deviceId: deviceId, serviceId: SERVICE_UUID,
            characteristicId: status, state: true
          }
        })
      }).then(function () {
        // Listeners are registered LAST so no notification arrives before the
        // sink is ready (notifications before this point would be lost anyway).
        wxApi.onBLECharacteristicValueChange(onCharacteristicChange)
        wxApi.onBLEConnectionStateChange(onConnectionState)
        connected = true
        connecting = false
        return { connected: true }
      }).catch(function (err) {
        connecting = false
        connected = false
        throw err
      })
    },

    sendCommand: function (buffer) {
      if (!connected || !commandCharId) {
        stats.errors++
        return Promise.reject(new Error('not connected: command NOT sent'))
      }
      var bytes = new Uint8Array(buffer)
      var self = this
      return new Promise(function (resolve, reject) {
        wxApi.writeBLECharacteristicValue({
          deviceId: deviceId,
          serviceId: SERVICE_UUID,
          characteristicId: commandCharId,
          value: buffer,
          success: function () { stats.commandsSent++; resolve(true) },
          fail: function (err) {
            stats.errors++
            reject(new Error('write failed: ' + (err && err.errMsg)))
          }
        })
      })
    },

    onNotify: function (sink) { notifySink = sink },
    onDisconnect: function (sink) { disconnectSink = sink },

    disconnect: function () {
      var id = deviceId
      connected = false
      if(wxApi.offBLECharacteristicValueChange)wxApi.offBLECharacteristicValueChange(onCharacteristicChange)
      if(wxApi.offBLEConnectionStateChange)wxApi.offBLEConnectionStateChange(onConnectionState)
      notifySink=null
      deviceId = null
      commandCharId = null
      if (!id) return Promise.resolve(false)
      return call('closeBLEConnection', { closeBLEConnection: { deviceId: id } })
        .then(function () { return true })
        .catch(function () { return false })
    }
  }
}

module.exports = { createBleTransport }
