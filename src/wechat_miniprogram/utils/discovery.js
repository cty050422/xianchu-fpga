// Device discovery and identity helpers.
//
// The old page matched only the advertised name "FPGA-Instrument", so a board
// advertising "XianChu-LINK-R1"/"R2" was invisible. Discovery now keys on the
// advertised service UUID first, and keeps the historical names only as a
// compatibility fallback. The service UUID is verified again after connecting:
// a device whose GATT table lacks the service is rejected instead of being
// driven with commands it cannot understand.

const SERVICE_UUID = '7a330001-4b62-4f70-9f60-66706761736d'
const INFO_UUID = '7a330004-4b62-4f70-9f60-66706761736d'

// Historical and current advertised names. Used only when the advertisement
// does not carry the service UUID (older firmware).
const COMPAT_NAMES = ['FPGA-Instrument', 'XianChu-LINK-R1', 'XianChu-LINK-R2', 'XianChu-LINK-R3']

function lower(value) { return String(value || '').toLowerCase() }

function advertisedUuids(device) {
  const out = []
  const push = list => {
    if (!list) return
    for (let i = 0; i < list.length; i += 1) out.push(lower(list[i]))
  }
  push(device && device.advertisServiceUUIDs)
  push(device && device.serviceUUIDs)
  return out
}

// Returns {matched, reason} so the UI can explain why a device was accepted.
function matchAdvertising(device) {
  if (!device) return { matched: false, reason: 'empty' }
  if (advertisedUuids(device).indexOf(SERVICE_UUID) >= 0) {
    return { matched: true, reason: 'service-uuid' }
  }
  const name = lower((device.localName || device.name || '')).trim()
  for (let i = 0; i < COMPAT_NAMES.length; i += 1) {
    if (name === lower(COMPAT_NAMES[i])) return { matched: true, reason: 'compat-name' }
  }
  return { matched: false, reason: 'no-service-uuid' }
}

// Verifies the connected GATT table really contains our service.
function hasService(services) {
  if (!services) return false
  for (let i = 0; i < services.length; i += 1) {
    if (lower(services[i].uuid) === SERVICE_UUID) return true
  }
  return false
}

// The info characteristic is written by the firmware with a short human/JSON
// identity string. It is diagnostic text, never a trusted capability claim:
// capabilities are negotiated from the decoded status flags.
function parseIdentity(text) {
  const raw = String(text || '').trim()
  const result = { raw, build: '', armed: null, protocolVersion: null, phoneArm: false, authenticated: null }
  if (!raw) return result
  const build = raw.match(/XC-LINK-[A-Z0-9.\-]+/i)
  if (build) result.build = build[0]
  if (/DISARM|armed\s*[=:]\s*(false|0|off)/i.test(raw)) result.armed = false
  else if (/armed\s*[=:]\s*(true|1|on)|ARM:\s*ON/i.test(raw)) result.armed = true
  const proto = raw.match(/"?protocol"?\s*[=:]\s*(\d+)/i)
  if (proto) result.protocolVersion = Number(proto[1])
  result.phoneArm = /phone_arm\s*[=:]\s*(true|1)\b/i.test(raw)
  const auth=raw.match(/\bauth\s*[=:]\s*([01])/i)
  if(auth)result.authenticated=auth[1]==='1'
  return result
}

module.exports = {
  SERVICE_UUID, INFO_UUID, COMPAT_NAMES,
  matchAdvertising, hasService, parseIdentity, advertisedUuids
}
