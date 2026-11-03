// Passive capture of actual Web Serial bytes. Demo frames never enter this class.
//
// The old version stopped storing after 2 MiB and kept only the OLD prefix, so a
// long session silently lost the newest actions — exactly the bytes a hardware
// debug session needs. This version writes in segments:
//   * a segment rotates every `segmentBytes` (default 512 KiB);
//   * total storage is bounded by `budgetBytes` (default 16 MiB);
//   * when the budget is exceeded the OLDEST segment is evicted and the lost
//     byte range is recorded in `gaps`, so the export says what is missing
//     instead of pretending the capture is complete;
//   * every entry carries the session id, byte offsets and timestamps, and
//     parsed frame records are kept alongside the raw bytes.

let sessionCounter = 0;

function makeSessionId(startedAt) {
  sessionCounter += 1;
  const stamp = String(startedAt).replace(/[^0-9]/g, '').slice(0, 17);
  return `xc-${stamp}-${sessionCounter.toString(36)}`;
}

const toHex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');

export class WireCapture {
  constructor(startedAt = new Date().toISOString(), options = {}) {
    const opts = typeof options === 'number' ? { segmentBytes: options } : options;
    this.startedAt = startedAt;
    this.segmentBytes = opts.segmentBytes ?? 512 * 1024;
    this.budgetBytes = opts.budgetBytes ?? 16 * 1024 * 1024;
    if (!Number.isSafeInteger(this.segmentBytes) || this.segmentBytes < 1 ||
        !Number.isSafeInteger(this.budgetBytes) || this.budgetBytes < this.segmentBytes)
      throw new RangeError('Invalid capture segment/budget sizes');
    this.nextSegmentIndex = 0;
    this.sessionId = opts.sessionId || makeSessionId(startedAt);
    this.receivedBytes = 0;
    this.storedBytes = 0;
    this.droppedBytes = 0;
    this.segments = [];
    this.gaps = [];
    this.frames = [];
    this.evictedSegments = 0;
    this._openSegment(null);
  }

  _openSegment(atMs) {
    this.segments.push({
      index: this.nextSegmentIndex++,
      opened_at_ms: atMs ?? null,
      start_offset: this.receivedBytes,
      bytes: 0,
      chunks: []
    });
  }

  get current() { return this.segments[this.segments.length - 1]; }

  _evictIfNeeded() {
    while (this.storedBytes > this.budgetBytes && this.segments.length > 1) {
      const oldest = this.segments.shift();
      this.storedBytes -= oldest.bytes;
      this.evictedSegments += 1;
      const last = this.gaps[this.gaps.length - 1];
      const from = oldest.start_offset;
      const to = oldest.start_offset + oldest.bytes;
      if (last && last.to_offset === from) last.to_offset = to;
      else this.gaps.push({ from_offset: from, to_offset: to, reason: 'segment_evicted_budget' });
    }
  }

  push(bytes, atMs) {
    if (!bytes?.length) return;
    const total = bytes.length;
    if (!this.current.chunks.length) this.current.opened_at_ms = atMs ?? null;
    // Split a large read across segments so one busy burst cannot create a
    // single unbounded chunk.
    let offset = 0;
    while (offset < total) {
      const room = this.segmentBytes - this.current.bytes;
      if (room <= 0) { this._openSegment(atMs); continue; }
      const take = Math.min(room, total - offset);
      const slice = bytes.subarray ? bytes.subarray(offset, offset + take) : bytes.slice(offset, offset + take);
      this.current.chunks.push({ at_ms: atMs ?? null,
        offset: this.current.start_offset + this.current.bytes, hex: toHex(slice) });
      this.current.bytes += take;
      this.storedBytes += take;
      this.receivedBytes += take;
      offset += take;
      if (this.current.bytes >= this.segmentBytes) this._openSegment(atMs);
    }
    this._evictIfNeeded();
  }

  /** Records a parsed frame next to the raw bytes (telemetry is metadata, not audio). */
  recordFrame(frame) {
    this.frames.push({ ...frame, stored_after_bytes: this.storedBytes, stream_end_offset: this.receivedBytes });
    if (this.frames.length > 20000) this.frames.splice(0, this.frames.length - 20000);
  }

  get full() { return this.gaps.length > 0; }

  snapshot() {
    const segments = this.segments.filter(s => s.chunks.length > 0).map(s => ({
      index: s.index, opened_at_ms: s.opened_at_ms, start_offset: s.start_offset,
      bytes: s.bytes, chunks: s.chunks.map(c => ({ ...c }))
    }));
    return {
      format: 'XIANCHU_RAW_SERIAL_V2',
      source: 'physical_web_serial',
      baud: 115200,
      session_id: this.sessionId,
      started_at: this.startedAt,
      expected_fpga_sha256: null,
      actual_fpga_identity_verified: false,
      identity_note: 'UART does not carry build identity. Attach Programmer record and file SHA; do not infer identity from this expectation.',
      received_bytes: this.receivedBytes,
      stored_bytes: this.storedBytes,
      dropped_bytes: this.receivedBytes - this.storedBytes,
      evicted_segments: this.evictedSegments,
      gaps: this.gaps.map(g => ({ ...g })),
      complete_capture: this.gaps.length === 0 && this.receivedBytes === this.storedBytes,
      segment_bytes: this.segmentBytes,
      budget_bytes: this.budgetBytes,
      segments,
      frames: this.frames.map(f => ({ ...f }))
    };
  }
}
