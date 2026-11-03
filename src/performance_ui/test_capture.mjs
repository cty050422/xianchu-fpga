// Capture tests: the F17 regression is "a long session loses its newest bytes".
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { WireCapture } from './wire_capture.mjs';

const bytes = n => Uint8Array.from({ length: n }, (_, i) => (i * 7) & 0xff);

describe('WireCapture segmented export', () => {
  it('keeps a short capture in one segment with no gaps', () => {
    const capture = new WireCapture('2026-10-23T08:00:00Z', { segmentBytes: 64, budgetBytes: 4096 });
    capture.push(bytes(40), 100);
    capture.recordFrame({ type: 0x21, seq: 1 });
    const report = capture.snapshot();
    assert.equal(report.format, 'XIANCHU_RAW_SERIAL_V2');
    assert.equal(report.segments.length, 1);
    assert.equal(report.received_bytes, 40);
    assert.equal(report.stored_bytes, 40);
    assert.equal(report.complete_capture, true);
    assert.deepEqual(report.gaps, []);
    assert.equal(report.frames.length, 1);
    assert.match(report.session_id, /^xc-/);
  });

  it('rotates segments and keeps every byte while inside the budget', () => {
    const capture = new WireCapture('2026-10-23T08:00:00Z', { segmentBytes: 64, budgetBytes: 64 * 20 });
    for (let i = 0; i < 10; i += 1) capture.push(bytes(64), i * 10);
    const report = capture.snapshot();
    assert.ok(report.segments.length >= 10);
    assert.equal(report.stored_bytes, 640);
    assert.equal(report.complete_capture, true);
    // offsets must be contiguous and ordered
    let expected = 0;
    for (const segment of report.segments) {
      assert.equal(segment.start_offset, expected);
      expected += segment.bytes;
    }
    assert.equal(expected, 640);
  });

  it('keeps the newest bytes and records the gap when the budget is exceeded', () => {
    const capture = new WireCapture('2026-10-23T08:00:00Z', { segmentBytes: 100, budgetBytes: 300 });
    // 20 pushes of 100 bytes = 2000 bytes received, only ~300 can be stored
    for (let i = 0; i < 20; i += 1) capture.push(bytes(100), i);
    const report = capture.snapshot();
    assert.ok(report.dropped_bytes > 0, '预算外的字节必须计入 dropped');
    assert.ok(report.gaps.length > 0, '必须记录丢失范围');
    assert.equal(report.complete_capture, false);
    assert.ok(report.evicted_segments > 0);
    // The newest push must still be present (this is the regression).
    const stored = report.segments.reduce((sum, s) => sum + s.bytes, 0);
    assert.equal(stored, report.stored_bytes);
    assert.ok(report.stored_bytes <= 300 + 100, '存储不得无界增长');
    const lastByteOffsets = report.segments.flatMap(s => s.chunks.map(c => c.offset));
    const newestOffset = Math.max(...lastByteOffsets);
    assert.ok(newestOffset >= 1800, '最新动作必须可取证');
    for (const gap of report.gaps) assert.ok(gap.to_offset > gap.from_offset);
  });

  it('splits one oversized read across segments', () => {
    const capture = new WireCapture('2026-10-23T08:00:00Z', { segmentBytes: 32, budgetBytes: 4096 });
    capture.push(bytes(100), 5);
    const report = capture.snapshot();
    assert.equal(report.received_bytes, 100);
    assert.equal(report.stored_bytes, 100);
    assert.equal(report.complete_capture, true);
    assert.ok(report.segments.length >= 4);
  });
});

// Audit: segment offsets must describe one contiguous original byte stream.
it('keeps absolute offsets correct when one read crosses multiple segments', () => {
  const capture = new WireCapture('2026-10-23T00:00:00Z', { segmentBytes: 4, budgetBytes: 12 });
  capture.push(Uint8Array.from([0,1,2,3,4,5,6,7,8,9]), 10);
  const chunks=capture.snapshot().segments.flatMap(s=>s.chunks);
  assert.deepEqual(chunks.map(x=>x.offset),[0,4,8]);
});
