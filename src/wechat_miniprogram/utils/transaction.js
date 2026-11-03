// Single-issuer command queue for the FPGA link.
//
// The old page wrote the whole song with a fixed 35 ms gap and then claimed
// success. A GATT write returning OK only means the S3 received bytes; it says
// nothing about the FPGA accepting them. This module enforces:
//   * one command in flight at a time (no interleaved song/config traffic);
//   * the reply that settles a command is the FPGA status frame whose
//     commandSequence equals the command's sequence number;
//   * an explicit validator (identity/readback) on top of the result code;
//   * a bounded wait. On timeout the outcome is UNKNOWN, never "success", and
//     the caller decides whether a retry is safe (side-effecting commands are
//     not retried automatically);
//   * a bounded fingerprint window matching replay protection, so normal 8-bit
//     sequence wrap does not permanently lock the device after 256 commands.

const BUSY = 'BUSY'
const TIMEOUT = 'TIMEOUT_UNKNOWN'
const READBACK = 'READBACK_MISMATCH'
const SEQ_REUSE = 'SEQ_REUSE'

function fingerprint(bytes) {
  let text = ''
  for (let i = 0; i < bytes.length; i += 1) {
    text += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16)
  }
  return text
}

function errorText(error) {
  return String(error && (error.errMsg || error.message) || error)
}

function createIssuer(options) {
  const send = options.send
  const timeoutMs = options.timeoutMs || 1500
  const now = options.now || (() => Date.now())
  const setTimer = options.setTimeout || ((fn, ms) => setTimeout(fn, ms))
  const clearTimer = options.clearTimeout || (id => clearTimeout(id))

  let sequence = typeof options.startSequence === 'number' ? options.startSequence - 1 : -1
  let used = false
  let current = null
  const fingerprints = {}
  const fingerprintOrder = []
  const log = []

  function nextSequence() {
    sequence = (sequence + 1) & 0xffff
    used = true
    return sequence & 0xff
  }

  function settle(outcome) {
    if (!current) return
    const pending = current
    current = null
    if (pending.timer !== null) clearTimer(pending.timer)
    log.push({ sequence: pending.sequence, outcome })
    if(log.length>128)log.shift()
    if (outcome.ok) pending.resolve(outcome)
    else pending.reject(outcome)
  }

  // build(sequence) must return an ArrayBuffer with exactly one frame.
  function submit(build, options2) {
    const opts = options2 || {}
    if (current) {
      return Promise.reject({ code: BUSY, message: '上一条命令尚未得到应答' })
    }
    const seq = nextSequence()
    let buffer
    try {
      buffer = build(seq, sequence)
    } catch (error) {
      return Promise.reject({ code: 'BUILD_FAILED', message: String(error && error.message || error) })
    }
    const body = fingerprint(new Uint8Array(buffer))
    if (fingerprints[seq] && fingerprints[seq] !== body) {
      return Promise.reject({ code: SEQ_REUSE, message: '同一序号被用于不同内容' })
    }
    fingerprints[seq] = body
    fingerprintOrder.push(seq)
    if(fingerprintOrder.length>8) delete fingerprints[fingerprintOrder.shift()]

    return new Promise((resolve, reject) => {
      const pending = current = {
        sequence: seq,
        body,
        resolve,
        reject,
        startedAt: now(),
        timer: null,
        validate: opts.validate || null,
        type: opts.type || 0,
        config: new Uint8Array(buffer)[3] === 0x15 ? {op:new Uint8Array(buffer)[6],field:new Uint8Array(buffer)[7]} : null
      }
      // Bound the complete write + reply wait, including a missing wx callback.
      pending.timer = setTimer(() => {
        if (current !== pending) return
        settle({code:TIMEOUT,sequence:seq,unknown:true,message:'等待 FPGA 应答超时，结果未知（不要盲目重发有副作用的命令）'})
      }, timeoutMs)
      let sent
      try {
        sent = send(buffer, seq)
      } catch (error) {
        if(current===pending) settle({ code: 'SEND_FAILED', message: errorText(error), sequence: seq })
        return
      }
      Promise.resolve(sent).catch(error => {
        if(current===pending) settle({ code: 'SEND_FAILED', sequence: seq, message: errorText(error) })
      })
    })
  }

  // Feed every decoded status frame here. Frames for other sequence numbers are
  // ignored: an unrelated notification must never settle a command.
  function onStatus(status) {
    if (!current || !status) return false
    if (status.commandSequence !== current.sequence) return false
    if(current.config) {
      const reply=status.configReply
      if(!reply || reply.op!==current.config.op || reply.field!==current.config.field) return false
    } else if(status.configReply) return false
    if (status.commandResult === 0 && current.validate) {
      const verdict = current.validate(status)
      if (verdict !== true) {
        settle({
          code: READBACK,
          sequence: current.sequence,
          status,
          message: typeof verdict === 'string' ? verdict : 'FPGA 应答与读回不一致'
        })
        return true
      }
    }
    if (status.commandResult === 0) {
      settle({ ok: true, sequence: current.sequence, status })
    } else {
      settle({
        code: 'FPGA_RESULT',
        result: status.commandResult,
        sequence: current.sequence,
        status,
        message: 'FPGA 拒绝：结果码 0x' + status.commandResult.toString(16)
      })
    }
    return true
  }

  function reset() {
    if (current) {
      settle({ code: 'RESET', sequence: current.sequence, unknown: true, message: '连接已重置' })
    }
    sequence = -1
    used = false
    for (const key in fingerprints) delete fingerprints[key]
    log.length = 0
    fingerprintOrder.length=0
  }

  return {
    submit,
    onStatus,
    reset,
    observeSequence(seq) { if(!used && !current && Number.isInteger(seq)) sequence=seq & 0xff },
    get busy() { return current !== null },
    currentSequence() { return current ? current.sequence : null },
    history() { return log.slice() }
  }
}

module.exports = { createIssuer, fingerprint, BUSY, TIMEOUT, READBACK, SEQ_REUSE }
