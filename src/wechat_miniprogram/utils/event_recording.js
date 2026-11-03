// T2 event recording: parse the FPGA's 0x85 performance-event telemetry, keep a
// versioned JSON session on the phone, and compile the recorded events into the
// SAME symbolic timeline the audition player already sends (0x1B–0x1F).
//
// Hard boundaries, by design:
//  * This records NOTE EVENTS (note-on/off, region, MIDI note, preset, owner
//    generation, FPGA sample deltas). It never captures audio or PCM and never
//    uploads a recording of sound.
//  * Delivery is best-effort telemetry: a lost frame is visible (sequence gap and
//    the frame's dropped counter) and marks a gap in the session; it is never
//    silently papered over, and no missing note-off is ever invented.
//  * Wall-clock time is UI decoration only; the timeline is built from FPGA sample
//    deltas exclusively.
//  * Replay is FPGA re-synthesis from the symbolic score (audition path), not audio
//    playback: timbre follows the chosen preset at play time, sustained notes that
//    overlap differently-phrased notes are re-struck at chord-slice boundaries, and
//    every note releases 480 samples (10 ms) before its step ends (protocol shape).
const VERSION = 1

function crc(bytes) {
  let c = 0
  for (const b of bytes) { c ^= b; for (let j = 0; j < 8; j++) c = (c & 128) ? ((c << 1) ^ 7) & 255 : (c << 1) & 255 }
  return c
}

// ---- 0x85 frame decoding ----------------------------------------------------
// Frame: A5 5A 01 85 len(8) seq? — body(8) crc. Body layout (see rtl/event_recorder.sv):
//   0 seq, 1 flags(b7 on, b6 loss, b5-4 region, b3-2 preset), 2 note, 3 generation,
//   4..6 sample delta LE24, 7 dropped (saturating counter).
function parseEventFrame(bytes) {
  if (!bytes || bytes.length !== 15) return null
  if (bytes[0] !== 0xA5 || bytes[1] !== 0x5A || bytes[2] !== 1 || bytes[3] !== 0x85 || bytes[4] !== 8) return null
  if (crc(bytes.slice(2, 14)) !== bytes[14]) return null
  const body = bytes.slice(6, 14)
  const flags = body[1]
  return {
    seq: body[0],
    on: (flags >> 7) & 1,
    loss: (flags >> 6) & 1,
    region: (flags >> 4) & 3,
    preset: (flags >> 2) & 3,
    note: body[2],
    generation: body[3],
    sampleDelta: body[4] | (body[5] << 8) | (body[6] << 16),
    dropped: body[7]
  }
}

// ---- recording session ------------------------------------------------------
// The recorder mirrors what the FPGA sent. Gap rule: a sequence jump, a loss flag,
// or a rising dropped counter marks the session as having gaps (kept true for the
// rest of the session); the events before/after the gap are still kept.
function createEventRecorder() {
  let recording = false
  let events = []
  let absoluteSample = 0
  let lastSeq = null
  let lastDropped = 0
  let hasLoss = false
  return {
    start() { recording = true; events = []; absoluteSample = 0; lastSeq = null; lastDropped = 0; hasLoss = false },
    stop() { recording = false },
    get isRecording() { return recording },
    get hasLoss() { return hasLoss },
    get count() { return events.length },
    onFrame(bytes) {
      const ev = parseEventFrame(bytes)
      if (!ev) return null
      if (ev.dropped > lastDropped) { hasLoss = true; lastDropped = ev.dropped }
      if (ev.loss) hasLoss = true
      if (lastSeq !== null) {
        const expect = (lastSeq + 1) & 255
        if (ev.seq !== expect) hasLoss = true
      }
      lastSeq = ev.seq
      if (!recording) return ev
      absoluteSample += ev.sampleDelta
      events.push({
        sample: absoluteSample,
        on: ev.on ? 1 : 0,
        region: ev.region,
        note: ev.note,
        preset: ev.preset,
        generation: ev.generation,
        seq: ev.seq
      })
      return ev
    },
    // Versioned JSON: raw events are the source of truth; replay re-derives the
    // timeline from them, so a future compiler revision never re-reads a stale
    // compiled form.
    toJSON(label) {
      return {
        schema: 'xianchu.event-recording',
        version: VERSION,
        sampleRate: 48000.529661,
        label: label || '',
        hasLoss: hasLoss,
        dropped: lastDropped,
        eventCount: events.length,
        durationSamples: absoluteSample,
        events: events.map(e => ({ s: e.sample, k: e.on, r: e.region, n: e.note, p: e.preset, g: e.generation }))
      }
    },
    staticFromJSON(json) {
      // load a saved recording for replay (no live capture attached)
      if (!json || json.schema !== 'xianchu.event-recording' || json.version !== VERSION) throw err('RECORDING_FORMAT', '录音文件版本不匹配')
      events = json.events.map(e => ({ sample: e.s, on: e.k, region: e.r, note: e.n, preset: e.p, generation: e.g }))
      absoluteSample = json.durationSamples || (events.length ? events[events.length - 1].sample : 0)
      hasLoss = !!json.hasLoss
      lastDropped = json.dropped || 0
      return this
    }
  }
}
function err(code, message) { return Object.assign(new Error(message), { code }) }

// ---- events -> symbolic timeline ---------------------------------------------
// Per region the instrument never overlaps its own notes, so note-on/off pairs
// build one segment per (region, note) hold. The chord slices run between every
// segment boundary; the note set of a slice is whatever is held inside it. A note
// ending exactly at a slice boundary releases 480 samples early in the protocol,
// so each segment's end is extended by 480 samples (10 ms) to land the off at the
// recorded instant; the extension never pushes a boundary past the next ON in the
// same region (segments per region are strictly sequential).
//
// Quantization error: boundary times are FPGA sample stamps; compileTimeline rounds
// ms*48 per boundary, so each boundary lands within ±1 sample and no drift
// accumulates. The release shape itself (uniform 480-sample pre-off + ADSR tail)
// is the documented protocol behaviour, not an error term.
const OFF_COMPENSATION_SAMPLES = 480
const MIN_STEP_SAMPLES = 960
function eventsToTimeline(events, opts) {
  if (!Array.isArray(events) || !events.length) throw err('RECORDING_EMPTY', '没有可回放的演奏事件')
  const off = (opts && opts.offCompensation) || OFF_COMPENSATION_SAMPLES
  // pair on/off per region (the instrument never overlaps a region with itself)
  const open = [null, null, null, null]
  const segments = []
  const lastSample = events[events.length - 1].sample
  for (const e of events) {
    if (e.on) {
      if (open[e.region]) segments.push({ region: e.region, note: open[e.region].note, start: open[e.region].sample, end: e.sample, preset: open[e.region].preset })
      open[e.region] = e
    } else if (open[e.region]) {
      segments.push({ region: e.region, note: open[e.region].note, start: open[e.region].sample, end: e.sample, preset: open[e.region].preset })
      open[e.region] = null
    }
    // a release with no matching on (telemetry gap) is skipped, never invented
  }
  for (let r = 0; r < 4; r++) {
    if (open[r]) segments.push({ region: r, note: open[r].note, start: open[r].sample, end: lastSample + off, preset: open[r].preset })
  }
  const usable = segments.filter(s => s.end > s.start)
  if (!usable.length) throw err('RECORDING_EMPTY', '没有可回放的演奏事件')
  // chord slices between all boundaries, then enforce the 960-sample minimum step:
  // slices shorter than one step are merged into their neighbour (union of notes),
  // which moves one boundary by at most 20 ms and never accumulates.
  const cuts = []
  for (const s of usable) { cuts.push(s.start, s.end) }
  cuts.sort((a, b) => a - b)
  const uniq = []
  for (const b of cuts) if (!uniq.length || b > uniq[uniq.length - 1]) uniq.push(b)
  // Time origin = first boundary: a leading silence shorter than one step cannot be
  // expressed as a rest step (960-sample minimum), and the replay should simply start
  // at the first note. Later gaps stay absolute once the origin is subtracted once.
  const t0 = uniq[0]
  let slices = []
  for (let i = 0; i < uniq.length - 1; i++) {
    const a = uniq[i] - t0, b = uniq[i + 1] - t0
    const notes = dedup(usable.filter(s => s.start <= uniq[i] && s.end > uniq[i]).map(s => s.note))
    slices.push({ start: a, end: b, notes })
  }
  let merged = true
  while (merged && slices.length > 0) {
    merged = false
    for (let i = 0; i < slices.length; i++) {
      if (slices[i].end - slices[i].start < MIN_STEP_SAMPLES) {
        if (i > 0) {
          slices[i - 1] = { start: slices[i - 1].start, end: slices[i].end, notes: dedup(slices[i - 1].notes.concat(slices[i].notes)) }
          slices.splice(i, 1)
        } else if (slices.length > 1) {
          slices[1] = { start: slices[1].start, end: Math.max(slices[1].end, slices[0].end), notes: dedup(slices[0].notes.concat(slices[1].notes)) }
          slices[1].start = slices[0].start
          slices.splice(0, 1)
        } else {
          slices[0] = { start: slices[0].start, end: slices[0].start + MIN_STEP_SAMPLES, notes: slices[0].notes }
        }
        merged = true
        break
      }
    }
  }
  // merge adjacent slices that touch AND share the identical note set (the protocol
  // re-strikes every step, so an unchanged chord must not be split needlessly)
  for (let i = 0; i < slices.length - 1;) {
    const a = slices[i], b = slices[i + 1]
    if (a.end === b.start && a.notes.join(',') === b.notes.join(',')) {
      slices[i] = { start: a.start, end: b.end, notes: a.notes }
      slices.splice(i + 1, 1)
    } else i++
  }
  return slices.map(s => ({ startMs: s.start / 48, endMs: s.end / 48, notes: s.notes }))
}
function dedup(arr) { return Array.from(new Set(arr)).sort((a, b) => a - b) }

module.exports = { VERSION, crc, parseEventFrame, createEventRecorder, eventsToTimeline, OFF_COMPENSATION_SAMPLES, MIN_STEP_SAMPLES }
