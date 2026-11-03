// S15 conformance: the real BLE transport adapter, driven through a wx stub.
// No phone, no radio: the stub verifies the CONNECTION FLOW, the command path
// (refuse-when-disconnected, chunked writes reach the stub intact), the notify
// reassembly through the frozen protocol parsers, the disconnect propagation
// and the clean state teardown.
const assert = require('assert')
const protocol = require('../utils/protocol')
const { createBleTransport } = require('../utils/ble_transport')

function makeWxStub() {
  const calls = []
  let notifyCb = null, connCb = null, foundCb=null
  const written = []
  const stub = {
    calls, written,
    setNotifySink(cb) { notifyCb = cb },
    drop() { if (connCb) connCb({ deviceId: 'DEV1', connected: false }) },
    openBluetoothAdapter(o) { calls.push('open'); o.success({}) },
    onBluetoothDeviceFound(cb){foundCb=cb},
    offBluetoothDeviceFound(cb){if(foundCb===cb)foundCb=null},
    stopBluetoothDevicesDiscovery(){calls.push('scan-stop')},
    startBluetoothDevicesDiscovery(o) {
      calls.push('scan');o.success({});
      foundCb({devices:[{deviceId:'DEV2',name:'other'},{deviceId:'DEV1',name:'XianChu-LINK-R3'}]})
    },
    createBLEConnection(o) { calls.push('conn'); o.success({}) },
    getBLEDeviceServices(o) {
      calls.push('svc')
      o.success({ services: [{ uuid: '0000fe95-0000-1000-8000-00805f9b34fb' },
                             { uuid: protocol.SERVICE_UUID.toUpperCase() }] })
    },
    getBLEDeviceCharacteristics(o) {
      calls.push('chars')
      o.success({ characteristics: [
        { uuid: protocol.STATUS_UUID.toUpperCase(), properties: { notify: true } },
        { uuid: protocol.COMMAND_UUID.toUpperCase(), properties: { write: true } }
      ] })
    },
    notifyBLECharacteristicValueChange(o) { calls.push('notify-on'); o.success({}) },
    onBLECharacteristicValueChange(cb) { notifyCb = cb },
    onBLEConnectionStateChange(cb) { connCb = cb },
    writeBLECharacteristicValue(o) {
      calls.push('write'); written.push(Array.from(new Uint8Array(o.value)))
      o.success({})
    },
    closeBLEConnection(o) { calls.push('close'); o.success({}) }
  }
  stub.fireNotify = bytes => notifyCb({ deviceId: 'DEV1', value: Uint8Array.from(bytes).buffer })
  return stub
}

const tests = []
const test = (name, fn) => tests.push([name, fn])

test('connection flow finds the frozen service and both characteristics', async () => {
  const wxStub = makeWxStub()
  const t = createBleTransport({ wx: wxStub })
  const res = await t.connect('XianChu')
  assert.strictEqual(res.connected, true)
  assert.ok(t.connected)
  assert.ok(wxStub.calls.includes('scan'), 'scan happened')
  assert.ok(wxStub.calls.includes('notify-on'), 'notifications subscribed before use')
})

test('sendCommand refuses when disconnected and never queues', async () => {
  const wxStub = makeWxStub()
  const t = createBleTransport({ wx: wxStub })
  await assert.rejects(() => t.sendCommand(new Uint8Array([1, 2]).buffer), /not connected/)
  assert.strictEqual(wxStub.written.length, 0)
})

test('a ping goes out intact and a fragmented status frame reassembles', async () => {
  const wxStub = makeWxStub()
  const t = createBleTransport({ wx: wxStub })
  await t.connect('XianChu')
  let gotStatus = null
  const parser = protocol.createReplyParser({ onStatus: s => { gotStatus = s } })
  t.onNotify(buf => parser(buf))
  await t.sendCommand(protocol.pingFrame(7))
  assert.strictEqual(wxStub.written.length, 1)
  assert.strictEqual(wxStub.written[0][3], 0x14)

  // A 22-byte status frame arrives in three MTU-sized fragments.
  const payload = [0x07, 0x11, 0x00, 0x06, 0, 0, 0, 0, 0, 0, 32, 0, 255, 0, 0]
  const st = protocol.frame(0x80, 9, payload)
  const bytes = Array.from(new Uint8Array(st))
  wxStub.fireNotify(bytes.slice(0, 10))
  assert.strictEqual(gotStatus, null, 'partial fragment must not decode')
  wxStub.fireNotify(bytes.slice(10, 18))
  wxStub.fireNotify(bytes.slice(18))
  assert.ok(gotStatus, 'reassembled status decoded')
  assert.strictEqual(gotStatus.song, 7)
})

test('a BLE drop propagates and clears the connected state', async () => {
  const wxStub = makeWxStub()
  const t = createBleTransport({ wx: wxStub })
  await t.connect('XianChu')
  let dropped = false
  t.onDisconnect(() => { dropped = true })
  wxStub.drop()
  assert.strictEqual(t.connected, false)
  assert.ok(dropped)
  await assert.rejects(() => t.sendCommand(protocol.pingFrame(1).buffer), /not connected/)
})

test('disconnect tears the socket down with no residual device id', async () => {
  const wxStub = makeWxStub()
  const t = createBleTransport({ wx: wxStub })
  await t.connect('XianChu')
  const ok = await t.disconnect()
  assert.strictEqual(ok, true)
  assert.strictEqual(t.connected, false)
  assert.ok(wxStub.calls.includes('close'))
})

async function run() {
  for (const [name, fn] of tests) await fn()
  console.log(`PASS S15 BLE transport adapter (${tests.length} scenarios, wx-stub, real-shape)`)
}
run().catch(err => { console.error(err); process.exit(1) })
