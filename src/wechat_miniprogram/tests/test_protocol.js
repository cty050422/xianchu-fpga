const assert = require('assert')
const protocol = require('../utils/protocol')

const result = protocol.songFrames(protocol.SONGS[0], 7)
assert.strictEqual(result.frames.length, 10)
const begin = Array.from(new Uint8Array(result.frames[0]))
assert.deepStrictEqual(begin.slice(0, 8), [0xa5, 0x5a, 1, 0x10, 2, 7, 1, 8])
assert.strictEqual(protocol.crc8(begin, 2, begin.length - 1), begin[begin.length - 1])

const payload = [1, 0x13, 2, 0x06, 3, 0, 1, 0, 4, 0, 1, 16, 128, 9, 0]
const statusFrame = protocol.frame(0x80, 9, payload)
const decoded = protocol.decodeStatus(Array.from(new Uint8Array(statusFrame)))
assert.strictEqual(decoded.song, 1)
assert.strictEqual(decoded.target, 2)
assert.strictEqual(decoded.expression, 1)
assert.strictEqual(decoded.hits, 3)
assert.strictEqual(decoded.misses, 4)

let parsed = null
const feed = protocol.createStatusParser(value => { parsed = value })
const bytes = new Uint8Array(statusFrame)
feed(bytes.slice(0, 11).buffer)
assert.strictEqual(parsed, null)
feed(bytes.slice(11).buffer)
assert.strictEqual(parsed.commandSequence, 9)
assert.strictEqual(decoded.extended,false)
assert.strictEqual(decoded.preset,null)
assert.strictEqual(decoded.effectMode,null)
const extended=payload.slice();extended[1]=0xd3;extended[2]=63;extended[3]=0xa9;extended[10]=0x35
const e=protocol.decodeStatus(Array.from(new Uint8Array(protocol.frame(0x80,42,extended))))
assert.strictEqual(e.extended,true);assert.strictEqual(e.preset,3);assert.strictEqual(e.effectMode,1)
assert.strictEqual(e.targetMask,10);assert.strictEqual(e.mode,2);assert.strictEqual(e.step,63)
console.log('PASS mini-program protocol (frame, CRC, song transaction, fragmented status)')
