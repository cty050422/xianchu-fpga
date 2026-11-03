// Phone-side configuration session client (spec 1.1.0, task S03).
//
// Owns the complete client half of the 0x15/0x81 contract:
//   * 16-bit request sequences, one request in flight, answers matched by the
//     echoed sequence byte,
//   * retry ONCE with byte-identical frames after a timeout - the FPGA replay
//     cache answers a repeat (same sequence + same body) with the cached result,
//     so a lost ACK is recovered idempotently and a commit can never apply twice,
//   * a second timeout fails the request; the caller decides what to show,
//   * a reply for a sequence nobody waits for is counted and dropped.
//
// Freshness separation: this module never touches the audio-status freshness
// state. Status frames keep flowing through protocol.createReplyParser's
// onStatus; config answers arrive through onConfig -> feed() here and nothing
// else. A burst of config replies cannot make stale audio state look fresh.
//
// The transport is injected: send(bytes) must write the frame to the device
// (BLE command characteristic in production, the simulator in tests).

const protocol = require('./protocol')

const CONFIG_OP = protocol.CONFIG_OPS

function createConfigClient(options) {
  const send = options.send
  if (typeof send !== 'function') throw new Error('config client needs a send(bytes) transport')
  const timeoutMs = options.timeoutMs || 400
  const tokenOf = options.token || (() => 0)
  let sequence = (options.firstSequence || 1) & 0xffff
  let pending = null // { seq, op, field, value, frame, sentAt, retries, resolve, reject, timer }

  const stats = { requests: 0, replies: 0, retries: 0, failed: 0, unmatched: 0 }

  function buildFrame(op, field, value, seq) {
    return protocol.configFrame({ op, field, value, token: tokenOf(), sequence: seq })
  }

  // Called by the app for every 0x81 reply from the demux.
  function feed(reply) {
    if (!pending) { stats.unmatched += 1; return }
    if (reply.sequence !== (pending.seq & 0xff)) { stats.unmatched += 1; return }
    clearTimeout(pending.timer)
    stats.replies += 1
    const { resolve } = pending
    pending = null
    resolve(reply)
  }

  function timeoutFired() {
    if (!pending) return
    if (pending.retries === 0) {
      // Resend the IDENTICAL bytes with the SAME sequence: the board's replay
      // cache turns this into either a cached answer or a first execution.
      pending.retries += 1
      stats.retries += 1
      pending.sentAt = Date.now()
      const frame = pending.frame
      send(frame)
      // A synchronous transport (the simulator) may have resolved the request
      // from inside send(); only arm the retry timer if it is still pending.
      if (!pending) return
      pending.timer = setTimeout(timeoutFired, timeoutMs)
      return
    }
    const { reject } = pending
    pending = null
    stats.failed += 1
    const err = new Error('config reply timeout (one retry spent)')
    err.code = 'CONFIG_TIMEOUT'
    reject(err)
  }

  function request(op, field, value) {
    if (pending) return Promise.reject(Object.assign(new Error('config request in flight'), { code: 'CONFIG_BUSY' }))
    stats.requests += 1
    const seq = sequence
    sequence = (sequence + 1) & 0xffff
    return new Promise((resolve, reject) => {
      pending = {
        seq, op, field, value, frame: buildFrame(op, field, value, seq),
        sentAt: Date.now(), retries: 0, resolve, reject,
        timer: setTimeout(timeoutFired, timeoutMs)
      }
      send(pending.frame)
    })
  }

  // ---- session helpers -----------------------------------------------------
  const capability = () => request(CONFIG_OP.CAPABILITY, 0, 0)
  const acquire = () => request(CONFIG_OP.ACQUIRE, 0, 0)
  const release = () => request(CONFIG_OP.RELEASE, 0, 0)
  const commit = () => request(CONFIG_OP.COMMIT, 0, 0)
  const get = field => request(CONFIG_OP.GET, field, 0)
  const set = (field, value) => request(CONFIG_OP.SET, field, value)

  // Stage, commit and verify through GET (the applied value, not the echo).
  // Returns the applied value; throws with .code = result number on refusal.
  async function setAndCommit(field, value) {
    const staged = await set(field, value)
    if (staged.result !== 1) throw Object.assign(new Error('stage refused'), { code: staged.result, reply: staged })
    const done = await commit()
    if (done.result !== 0) throw Object.assign(new Error('commit refused'), { code: done.result, reply: done })
    const read = await get(field)
    if (read.result !== 0) throw Object.assign(new Error('readback refused'), { code: read.result, reply: read })
    return read.value
  }

  function abandon() {
    // The session is over (BLE disconnect, disarm): fail any in-flight request
    // without retrying - the board will expire the lease on its own.
    if (!pending) return
    const { reject } = pending
    clearTimeout(pending.timer)
    pending = null
    reject(Object.assign(new Error('config session abandoned'), { code: 'CONFIG_ABANDONED' }))
  }

  return { request, capability, acquire, release, commit, get, set, setAndCommit, feed, abandon, stats }
}

module.exports = { createConfigClient }
