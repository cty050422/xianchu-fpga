// Virtual FPGA+S3 instrument for board-less development and testing.
//
// This is NOT a UI shortcut: the device model implements the same wire contract
// as rtl/esp_score_link.sv (A5 5A, CRC8, 22-byte status snapshot, 18-byte config
// reply, MAX_STEPS=32 bank with transaction mask, guide control, result codes)
// and the R3 identity text. Clients talk to it through createSimTransport,
// which fragments notifications exactly like a BLE MTU-20 link, so the REAL
// client protocol.js / transaction.js code paths (serialise, CRC, sequence
// matching, per-step ACK waits, COMMIT readback) are exercised end-to-end.
//
// Profiles (selection of fault modes for the acceptance matrix):
//   normal             fully working authenticated instrument
//   uncalibrated       powers up with calibrated=0
//   unauthorized       S3 rejects phone commands (PAIR FIRST), no FPGA echo
//   stale-status       stops answering after N commands (freshness drops)
//   drop-step-ack      silently drops the STEP with index K once (lost ACK)
//   disconnect-mid     transport drops the link while STEP K is in flight
//   bad-crc            feed it corrupted frames, expect result 0xE1
//   old-firmware       identity advertises an older build
//   busy               guide running: BEGIN/STEP/COMMIT answered 0xE5

var protocol = require('./protocol')

var SUPPORTED_MASK = 0x3b80ff // fields 1-8, 16-18, 20-22 (mirrors rtl/config_capability.sv spec 1.5.0)
var CONFIG_LEASE_MS = 1000

function crcByte(crc, value) {
  crc ^= value
  for (var b = 0; b < 8; b++) crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff)
  return crc
}

function createSimDevice(options) {
  var opts = options || {}
  var profile = opts.profile || 'normal'
  var now = opts.now || function () { return Date.now() }
  var dropStepIndex = opts.dropStepIndex !== undefined ? opts.dropStepIndex : 2
  var staleAfter = opts.staleAfter !== undefined ? opts.staleAfter : 3

  var state = {
    profile: profile,
    // score bank (committed)
    songId: 0, stepCount: 0, scoreLoaded: false, guideActive: false, performanceMode:0, mappingReady:true,
    calibrated: profile !== 'uncalibrated',
    steps: [], txnActive: false, txnSongId: 0, txnCount: 0, txnMask: 0,
    step: 0, hits: 0, wrong: 0, misses: 0,
    // config session
    staged: {}, values: {}, epoch: 1,
    lease: { valid: false, owner: 0, expiresAt: 0 },
    commandCounter: 0,
    statusSequence: 0,
    infoNotices: []
  }
  var defaults = {}
  var fieldId
  for (fieldId = 5; fieldId <= 8; fieldId++) defaults[fieldId] = fieldId === 5 || fieldId === 6 ? 512 : 512
  defaults[16] = 32
  defaults[18] = 0
  state.values = Object.assign({}, defaults)

  function leaseValid() {
    return state.lease.valid && now() < state.lease.expiresAt
  }

  function expireLeaseIfDue() {
    if (state.lease.valid && now() >= state.lease.expiresAt) {
      state.lease.valid = false
      state.staged = {}
    }
  }

  function statusFrame(cmdSeq, result) {
    state.statusSequence = (state.statusSequence + 1) & 0xff
    var flags = (state.scoreLoaded ? 1 : 0) | (state.guideActive ? 2 : 0) |
      (0 << 2) | (0 << 3) | (state.calibrated ? 16 : 0) | ((state.performanceMode||0)<<5) | 128
    var current=state.steps[state.step]||{}
    var target=current.mask===undefined?(current.zone===undefined?0:(1<<current.zone)):current.mask
    var zone=target&1?0:target&2?1:target&4?2:3
    var payload = [
      state.songId, flags, state.step & 0x3f,
      (target<<4)|((current.expression||0)<<2)|zone,
      state.hits & 0xff, (state.hits >> 8) & 0xff,
      state.wrong & 0xff, (state.wrong >> 8) & 0xff,
      state.misses & 0xff, (state.misses >> 8) & 0xff,
      (state.mappingReady?64:0)|((state.values[20]||0)<<4)|((state.fxMode===undefined?2:state.fxMode)<<2), 32, 128, // actual mapping/preset/effect/layout
      cmdSeq & 0xff, result & 0xff
    ]
    return protocol.frame(0x80, state.statusSequence, payload)
  }

  function configReply(seq, op, field, result, value, firstField) {
    var epoch = state.epoch & 0xffff
    var mask = SUPPORTED_MASK
    var payload = [
      op & 0xff, field & 0xff, result & 0xff,
      value & 0xff, (value >> 8) & 0xff,
      epoch & 0xff, (epoch >> 8) & 0xff,
      mask & 0xff, (mask >> 8) & 0xff, (mask >> 16) & 0xff,
      (firstField || 0) & 0xff
    ]
    return protocol.frame(0x81, seq & 0xff, payload)
  }

  function fieldRange(field) {
    if(field>=1 && field<=4) return {min:36,max:96}
    if(field===17) return {min:0,max:64}
    if(field===20) return {min:0,max:3}
    if(field===21 || field===22) return {min:0,max:1}

    if (field >= 5 && field <= 8) return { min: 16, max: 4095 }
    if (field === 16) return { min: 2, max: 32 }
    if (field === 18) return { min: 0, max: 64 }
    return null
  }

  function firstSupportedField() {
    for (var id = 1; id <= 22; id++) if ((SUPPORTED_MASK >>> (id - 1)) & 1) return id
    return 0
  }

  // Process one raw write; returns an array of ArrayBuffers to notify back.
  function feed(arrayBuffer) {
    var bytes = Array.from(new Uint8Array(arrayBuffer))
    var frames = []
    var infoText = null
    if (bytes.length < 7 || bytes[0] !== 0xa5 || bytes[1] !== 0x5a) return { frames: frames, info: null }
    var total = 7 + bytes[4]
    if (bytes.length < total) return { frames: frames, info: null }
    var type = bytes[3]
    var seq = bytes[5]
    var payload = bytes.slice(6, total - 1)
    if (protocol.crc8(bytes, 2, total - 1) !== bytes[total - 1]) {
      if (profile === 'bad-crc') {
        frames.push(statusFrame(seq, 0xe1))
        return { frames: frames, info: null }
      }
      return { frames: frames, info: null } // dropped silently, like a strict parser
    }

    if (profile === 'unauthorized') {
      if (type >= 0x10 && type <= 0x19) {
        return { frames: [], info: 'CMD REJECTED: PAIR FIRST (sim)' }
      }
    }

    state.commandCounter += 1
    if (profile === 'stale-status' && state.commandCounter > staleAfter) {
      // Device is alive but the status stream stops: no reply at all.
      return { frames: [], info: null }
    }
    if (profile === 'disconnect-mid' && (type === 0x11 || type === 0x17) && payload[0] === dropStepIndex) {
      return { frames: [], info: null, dropConnection: true }
    }
    if (profile === 'drop-step-ack' && (type === 0x11 || type === 0x17) && payload[0] === dropStepIndex) {
      // Frame accepted by the device but the answer never reaches the client:
      // the client must end in TIMEOUT_UNKNOWN, never "success".
      state.txnMask = (state.txnMask | (1 << payload[0])) >>> 0
      return { frames: [], info: null }
    }

    var busy = state.guideActive
    var result = 0
    switch (type) {
      case 0x14: // PING
        result = 0
        break
      case 0x13: // guide control
        var want = payload[0] !== 0
        if (want && (!state.scoreLoaded || !state.mappingReady)) result = 0xe4
        else { state.guideActive = want;state.performanceMode=payload[0]; state.step = 0 }
        break
      case 0x10: // BEGIN
        if (busy) { result = 0xe5; break }
        var songId = payload[0], count = payload[1]
        if (count < 1 || count > 32) { result = 0xe2; break }
        state.txnV2 = false
        state.txnSegment = { index: 0, count: 1 }
        state.txnActive = true
        state.txnSongId = songId
        state.txnCount = count
        state.txnMask = 0
        state.txnSteps = []
        result = 0
        break
      case 0x11: // STEP
        if (busy) { result = 0xe5; break }
        if (!state.txnActive) { result = 0xe6; break }
        if (state.txnV2) { result = 0xe0; break }
        var index = payload[0], flagsByte = payload[1]
        var duration = payload[2] | (payload[3] << 8) | (payload[4] << 16)
        if (index >= state.txnCount || duration === 0) { result = 0xe2; break }
        state.txnSteps[index] = { zone: flagsByte & 3, expression: (flagsByte >> 2) & 3, duration: duration }
        // >>> 0: JS 1<<31 is negative; the mask must stay an unsigned 32-bit
        // value or a full 32-step song never looks complete.
        state.txnMask = (state.txnMask | (1 << index)) >>> 0
        result = 0
        break
      case 0x12: // COMMIT
        if (busy) { result = 0xe5; break }
        if (!state.txnActive) { result = 0xe6; break }
        if (state.txnV2) { result = 0xe0; break }
        if (payload[0] !== state.txnSongId) { result = 0xe3; break }
        var required = state.txnCount === 32 ? 0xffffffff : (((1 << state.txnCount) - 1) >>> 0)
        if ((state.txnMask >>> 0) !== required) { result = 0xe3; break }
        state.songId = state.txnSongId
        state.steps = state.txnSteps.slice(0, state.txnCount)
        state.stepCount = state.txnCount
        state.scoreLoaded = true
        state.mappingReady = true
        state.guideActive = false
        state.performanceMode=0
        state.txnActive = false
        state.step = 0
        result = 0
        break
      case 0x16: // BEGIN2 (S04): song, count 1..63, segment_index, segment_count
        if (busy) { result = 0xe5; break }
        var songId2 = payload[0], count2 = payload[1], segCount = payload[3]
        if (count2 < 1 || count2 > 64 || segCount < 1 || payload[2]>=segCount) { result = 0xe2; break }
        state.txnActive = true
        state.txnV2 = true
        state.txnSongId = songId2
        state.txnCount = count2
        state.txnSegment = { index: payload[2], count: segCount }
        state.txnMask = 0
        state.txnSteps = []
        state.txnStepsCrc = 0
        result = 0
        break
      case 0x17: // STEP2 (S04): index, mask_byte {2'b0, expr, zone_mask}, duration
        if (busy) { result = 0xe5; break }
        if (!state.txnActive || !state.txnV2) { result = state.txnActive ? 0xe0 : 0xe6; break }
        var index2 = payload[0], maskByte = payload[1]
        var duration2 = payload[2] | (payload[3] << 8) | (payload[4] << 16)
        if (index2 >= state.txnCount || maskByte >= 0x40 || (maskByte >> 4) === 3 || duration2 === 0) { result = 0xe2; break }
        state.txnSteps[index2] = { mask: maskByte & 15, expression: (maskByte >> 4) & 3, duration: duration2, rest: (maskByte & 15) === 0 }
        state.txnMask = (state.txnMask | (1 << index2)) >>> 0
        // steps CRC mirrors rtl/esp_score_link crc8_step2 (0x17 prefix)
        state.txnStepsCrc = crcByte(state.txnStepsCrc, 0x17)
        for (var ci = 0; ci < 5; ci++) state.txnStepsCrc = crcByte(state.txnStepsCrc, payload[ci])
        result = 0
        break
      case 0x18: // COMMIT2 (S04): song + steps CRC, atomic publish
        if (busy) { result = 0xe5; break }
        if (!state.txnActive || !state.txnV2) { result = state.txnActive ? 0xe0 : 0xe6; break }
        if (payload[0] !== state.txnSongId || payload[1] !== state.txnStepsCrc) { result = 0xe3; break }
        var complete2=true
        for(var si=0;si<state.txnCount;si++) if(!state.txnSteps[si])complete2=false
        if(!complete2) {result=0xe3;break}
        state.songId = state.txnSongId
        state.steps = state.txnSteps.slice(0, state.txnCount)
        state.stepCount = state.txnCount
        state.segment = state.txnSegment
        state.scoreLoaded = true
        state.mappingReady = true
        state.guideActive = false
        state.performanceMode=0
        state.txnActive = false
        state.step = 0
        result = 0
        break
      case 0x19: // FX_CONTROL (S08): mode 0..3, reset default chorus
        if (busy) { result = 0xe5; break }
        if (payload[0] > 3) { result = 0xe2; break }
        state.fxMode = payload[0]
        result = 0
        break
      case 0x15: // config
        expireLeaseIfDue()
        var op = payload[0], field = payload[1]
        var value = payload[2] | (payload[3] << 8)
        var token = payload[4] | (payload[5] << 8)
        if (op === 5) { // CAPABILITY
          frames.push(configReply(seq, op, 0, 0, 0, firstSupportedField()))
          return { frames: frames, info: null }
        }
        if (op === 3) { // ACQUIRE
          if (leaseValid() && state.lease.owner !== token) {
            frames.push(configReply(seq, op, field, 23, 0, firstSupportedField()))
            return { frames: frames, info: null }
          }
          state.lease = { valid: true, owner: token, expiresAt: now() + CONFIG_LEASE_MS }
          if (state.staged && Object.keys(state.staged).length) { state.staged = {}; state.epoch += 1 }
          frames.push(configReply(seq, op, 0, 0, state.epoch, firstSupportedField()))
          return { frames: frames, info: null }
        }
        if (op === 4) { // RELEASE
          if (!leaseValid() || state.lease.owner !== token) {
            frames.push(configReply(seq, op, field, 23, 0, firstSupportedField()))
            return { frames: frames, info: null }
          }
          state.lease.valid = false
          state.staged = {}
          frames.push(configReply(seq, op, 0, 0, state.epoch, firstSupportedField()))
          return { frames: frames, info: null }
        }
        // SET / COMMIT / GET need a valid lease held by this token
        if (!leaseValid() || state.lease.owner !== token) {
          frames.push(configReply(seq, op, field, leaseValid() ? 23 : 19, 0, firstSupportedField()))
          return { frames: frames, info: null }
        }
        state.lease.expiresAt = now() + CONFIG_LEASE_MS // activity renews the lease
        if (op === 0) { // SET
          if (!((SUPPORTED_MASK >>> (field - 1)) & 1)) {
            frames.push(configReply(seq, op, field, 16, 0, firstSupportedField()))
            return { frames: frames, info: null }
          }
          var range = fieldRange(field)
          if (!range || value < range.min || value > range.max) {
            frames.push(configReply(seq, op, field, 17, 0, firstSupportedField()))
            return { frames: frames, info: null }
          }
          state.staged[field] = value
          frames.push(configReply(seq, op, field, 1, value, firstSupportedField()))
          return { frames: frames, info: null }
        }
        if (op === 1) { // COMMIT
          if (!Object.keys(state.staged).length) {
            frames.push(configReply(seq, op, field, 22, 0, firstSupportedField()))
            return { frames: frames, info: null }
          }
          for (var f in state.staged) {
            if(state.scoreLoaded && ([1,2,3,4,21,22].indexOf(Number(f))>=0))state.mappingReady=false
            state.values[f] = state.staged[f]
          }
          state.staged = {}
          state.epoch += 1
          frames.push(configReply(seq, op, field, 0, state.values[field] || 0, firstSupportedField()))
          return { frames: frames, info: null }
        }
        if (op === 2) { // GET
          frames.push(configReply(seq, op, field, 0, state.values[field] || 0, firstSupportedField()))
          return { frames: frames, info: null }
        }
        frames.push(configReply(seq, op, field, 0xe0, 0, firstSupportedField()))
        return { frames: frames, info: null }
      default:
        result = 0xe0
    }
    frames.push(statusFrame(seq, result))
    return { frames: frames, info: infoText }
  }

  function identityText() {
    if (profile === 'old-firmware') {
      return 'XC-LINK-R1 build=SIM-OLD armed=1 phone_arm=false protocol=1 auth=1'
    }
    return 'XC-LINK-R3 build=SIM-2026-10-24 armed=1 phone_arm=true protocol=1 auth=1'
  }

  return {
    feed: feed,
    identityText: identityText,
    state: state,
    SUPPORTED_MASK: SUPPORTED_MASK,
    // Test hooks (host tests only; the UI never touches these).
    _forceStatus: function (patch) { Object.assign(state, patch) }
  }
}

module.exports = { createSimDevice, SUPPORTED_MASK, CONFIG_LEASE_MS }
