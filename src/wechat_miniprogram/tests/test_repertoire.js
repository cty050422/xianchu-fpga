const assert=require('assert')
const protocol=require('../utils/protocol')
assert.equal(new Set(protocol.SONGS.map(s=>s.id)).size,protocol.SONGS.length)
for(const song of protocol.SONGS){
  assert.ok(song.steps.length>=1 && song.steps.length<=32)
  for(const [zone,hint,ms] of song.steps){
    assert.ok(Number.isInteger(zone)&&zone>=0&&zone<4)
    assert.ok(Number.isInteger(hint)&&hint>=0&&hint<=2)
    assert.ok(Number.isInteger(ms)&&ms>0&&ms*48<=0xffffff)
  }
}
assert.ok(!protocol.SONGS.some(s=>/小星星|欢乐颂/.test(s.name)),'old eight-step examples are not labelled as those melodies')
const mary=protocol.SONGS.find(s=>s.id===4)
assert.match(mary.name,/A组标准八度/)
const notes=[60,62,64,67]
assert.deepEqual(mary.steps.map(s=>notes[s[0]]),[
  64,62,60,62,64,64,64,62,62,62,64,67,67,
  64,62,60,62,64,64,64,64,62,62,64,62,60
])
const transaction=protocol.songFrames(mary,240)
assert.equal(transaction.frames.length,28)
for(const frame of transaction.frames){const b=new Uint8Array(frame);assert.equal(protocol.crc8(b,2,b.length-1),b[b.length-1])}
console.log('PASS repertoire: 32-step bounds, genuine 26-note A-layout melody, 28 transaction frames and CRC')
