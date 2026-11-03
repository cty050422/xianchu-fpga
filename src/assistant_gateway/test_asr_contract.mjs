// ASR provider contract + endpoint acceptance:
//   * bailian request shape verified against an injected fetch (URL, auth,
//     model, base64 data URI with the REAL mime) — the documented Qwen-ASR
//     body, never a guess;
//   * 401/429/timeout map to structured codes;
//   * paid mode cannot start without the explicit env switch;
//   * audio validation: WAV exact duration, MP3 CBR bound, size caps, wrong
//     container (AAC renamed to .wav) refused;
//   * /assistant/v1/asr over real HTTP: multipart (wx.uploadFile shape) and
//     JSON base64, idempotent replay (no double charge), quota 429.
// asr_live_verified stays false: no paid endpoint is contacted here.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { createGateway } from './server.mjs'
import { parseMultipart, validateAudio, makeAsrProvider, makeTtsProvider } from './asr.mjs'

function makeWav(durationMs, rate = 16000) {
  const samples = Math.floor(rate * durationMs / 1000)
  const pcm = Buffer.alloc(samples * 2)
  const header = Buffer.alloc(44)
  header.write('RIFF'); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8)
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22)
  header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28)
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34)
  header.write('data', 36); header.writeUInt32LE(pcm.length, 40)
  return Buffer.concat([header, pcm])
}

function makeMp3(bytes) {
  // Header-level MPEG1 Layer III fixture: 417 bytes/frame, 1152 samples/frame.
  // This tests container structure only; payload decoding is not claimed.
  const frame=Buffer.alloc(417);Buffer.from([0xff,0xfb,0x90,0]).copy(frame);
  return Buffer.concat(Array.from({length:Math.ceil(bytes/417)},()=>frame));
}

// ---- provider contract ------------------------------------------------------
test('bailian ASR provider sends the documented Qwen-ASR request shape', async () => {
  let captured = null
  const fetchStub = async (url, init) => {
    captured = { url, init }
    return {
      ok: true, status: 200, headers: new Map([['content-length', '100']]),
      text: async () => JSON.stringify({ choices: [{ message: { content: '找一首慢速练习' } }], usage: { input_tokens: 12 } })
    }
  }
  const provider = makeAsrProvider({
    ASR_MODE: 'bailian', GATEWAY_ALLOW_PAID_AUDIO: '1',
    BAILIAN_API_KEY: 'test-key', BAILIAN_ASR_URL: 'https://dashscope.example.com/api/v1/services/audio/asr',
    BAILIAN_ASR_MODEL: 'qwen3-asr-flash'
  }, { fetchImpl: fetchStub })
  assert.equal(provider.mode, 'live')
  assert.equal(provider.paid, true)
  const audio = makeWav(1500)
  const result = await provider.transcribe({ buffer: audio, mime: 'audio/wav' })
  assert.equal(result.text, '找一首慢速练习')
  // Request contract:
  assert.equal(captured.url, 'https://dashscope.example.com/api/v1/services/audio/asr')
  assert.equal(captured.init.headers.Authorization, 'Bearer test-key')
  const body = JSON.parse(captured.init.body)
  assert.equal(body.model, 'qwen3-asr-flash')
  assert.equal(body.stream, false)
  assert.equal(body.messages[0].role, 'user')
  assert.equal(body.messages[0].content[0].type, 'input_audio')
  assert.match(body.messages[0].content[0].input_audio.data, /^data:audio\/wav;base64,/)
  // usage flows through when the provider returns it
  assert.equal(result.usage.provider_usage.input_tokens, 12)
})

test('401/429/timeout map to distinct structured codes', async () => {
  const base = { ASR_MODE: 'bailian', GATEWAY_ALLOW_PAID_AUDIO: '1', BAILIAN_API_KEY: 'k',
    BAILIAN_ASR_URL: 'https://x.example.com/a', BAILIAN_ASR_MODEL: 'm' }
  const forStatus = async status => {
    const provider = makeAsrProvider(base, { fetchImpl: async () => ({ ok: false, status }) })
    return provider.transcribe({ buffer: makeWav(500), mime: 'audio/wav' }).catch(e => e.code)
  }
  assert.equal(await forStatus(401), 'ASR_UPSTREAM_401')
  assert.equal(await forStatus(403), 'ASR_UPSTREAM_401')
  assert.equal(await forStatus(429), 'ASR_UPSTREAM_429')
  assert.equal(await forStatus(500), 'ASR_UPSTREAM_500')
  const timeoutProvider = makeAsrProvider(base, { fetchImpl: async (u, i) => {
    return new Promise((resolve, reject) => {
      i.signal.addEventListener('abort', () => { const e = new Error('aborted'); e.name = 'AbortError'; reject(e) })
    })
  } })
  assert.equal(await timeoutProvider.transcribe({ buffer: makeWav(500), mime: 'audio/wav' }).catch(e => e.code), 'ASR_UPSTREAM_TIMEOUT')
})

test('paid provider refuses to start without the explicit switch or config', () => {
  assert.throws(() => makeAsrProvider({ ASR_MODE: 'bailian' }), /ASR_CONFIG_REQUIRED|PAID_AUDIO_NOT_ENABLED/)
  assert.throws(() => makeAsrProvider({ ASR_MODE: 'bailian', GATEWAY_ALLOW_PAID_AUDIO: '1' }), /ASR_CONFIG_REQUIRED/)
  assert.throws(() => makeAsrProvider({ ASR_MODE: 'bailian', GATEWAY_ALLOW_PAID_AUDIO: '1',
    BAILIAN_API_KEY: 'k', BAILIAN_ASR_URL: 'http://insecure.example.com/a', BAILIAN_ASR_MODEL: 'm' }),
    /ASR_ENDPOINT_REQUIRED_HTTPS/)
  assert.throws(() => makeAsrProvider({ ASR_MODE: 'unknown' }), /ASR_MODE_UNKNOWN/)
})

// ---- audio validation --------------------------------------------------------
test('WAV duration is parsed exactly; long audio refused server-side', () => {
  const ok = validateAudio({ buffer: makeWav(3000), mime: 'audio/wav' })
  assert.equal(ok.estimatedMs, 3000)
  assert.throws(() => validateAudio({ buffer: makeWav(30000), mime: 'audio/wav' }), /AUDIO_TOO_LONG/)
})

test('MP3 complete frames determine duration; 15-second limit is enforced', () => {
  const audio=makeMp3(160*1024);
  const ok=validateAudio({buffer:audio,mime:'audio/mp3'});
  assert.equal(ok.estimatedMs,Math.round(audio.length/417*1152/44100*1000));
  assert.throws(()=>validateAudio({buffer:makeMp3(300*1024),mime:'audio/mp3'}),/AUDIO_TOO_LONG/);
  assert.throws(()=>validateAudio({buffer:makeMp3(3*1024*1024),mime:'audio/mp3'}),/AUDIO_TOO_LARGE/);
})

test('truncated WAV/MP3 and reserved MPEG versions cannot pass container validation',()=>{
  assert.throws(()=>validateAudio({buffer:makeWav(1000).subarray(0,60),mime:'audio/wav'}),/AUDIO_CONTAINER_MISMATCH/);
  assert.throws(()=>validateAudio({buffer:makeMp3(1200).subarray(0,800),mime:'audio/mp3'}),/AUDIO_CONTAINER_MISMATCH/);
  const fake=Buffer.alloc(1000);Buffer.from([0xff,0xfb,0x90,0]).copy(fake);
  assert.throws(()=>validateAudio({buffer:fake,mime:'audio/mp3'}),/AUDIO_CONTAINER_MISMATCH/);
  const reserved=makeMp3(1200);reserved[1]=0xeb;
  assert.throws(()=>validateAudio({buffer:reserved,mime:'audio/mp3'}),/AUDIO_CONTAINER_MISMATCH/);
})

test('ID3 syncsafe sizes skip tags without scanning inside their payload',()=>{
  const tag=Buffer.alloc(10+128);tag.write('ID3');tag[3]=4;tag[8]=1;tag[9]=0;
  const audio=makeMp3(1000);
  const result=validateAudio({buffer:Buffer.concat([tag,audio]),mime:'audio/mp3'});
  assert.equal(result.estimatedMs,Math.round(audio.length/417*1152/44100*1000));
  assert.throws(()=>validateAudio({buffer:Buffer.from('ID3'),mime:'audio/mp3'}),/AUDIO_CONTAINER_MISMATCH/);
})

test('renamed containers are refused: AAC bytes in audio/wav is not a WAV', () => {
  const aac = Buffer.from([0xff, 0xf1, 0x50, 0x80, 0x00, 0x1f, 0xfc].concat(Array(500).fill(0)))
  assert.throws(() => validateAudio({ buffer: aac, mime: 'audio/wav' }), /AUDIO_CONTAINER_MISMATCH/)
  assert.throws(() => validateAudio({ buffer: makeWav(1000), mime: 'audio/mp4' }), /AUDIO_FORMAT_UNSUPPORTED/)
  assert.throws(() => validateAudio({ buffer: Buffer.alloc(0), mime: 'audio/wav' }), /AUDIO_EMPTY/)
})

test('multipart parsing extracts fields and the file part (wx.uploadFile shape)', () => {
  const fileData = makeWav(800)
  const boundary = 'WebKitFormBoundary7MA4YWxk'
  const parts = [
    `--${boundary}\r\nContent-Disposition: form-data; name="requestId"\r\n\r\nreq-abc12345\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="mime"\r\n\r\naudio/wav\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="durationMs"\r\n\r\n800\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="seg.mp3"\r\nContent-Type: audio/wav\r\n\r\n`,
    undefined, // binary slot
    `\r\n--${boundary}--\r\n`
  ]
  const body = Buffer.concat(parts.map(p => (p === undefined ? fileData : Buffer.from(p))))
  const { fields, files } = parseMultipart(body, `multipart/form-data; boundary=${boundary}`)
  assert.equal(fields.requestId, 'req-abc12345')
  assert.equal(fields.mime, 'audio/wav')
  assert.equal(files.length, 1)
  assert.equal(files[0].name, 'audio')
  assert.equal(files[0].contentType, 'audio/wav')
  assert.equal(files[0].data.equals(fileData), true)
})

// ---- endpoint over real HTTP ---------------------------------------------------
let base = '', gateway, ledgerFile
test.before(async () => {
  ledgerFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'asr-ledger-')), 'ledger.json')
  const fixtureKey = createHash('sha256').update(makeWav(1200)).digest('hex')
  gateway = createGateway({
    ledgerFile,
    asrProviderOptions: { fixtures: { [fixtureKey]: '把速度改成80' } }
  })
  await new Promise(resolve => gateway.server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${gateway.server.address().port}`
})
test.after(() => gateway.server.close())

function multipartBody(requestId, buffer, mime) {
  const boundary = 'WebKitFormBoundaryXC'
  const head = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="requestId"\r\n\r\n${requestId}\r\n` +
    `--${boundary}\r\nContent-Disposition: form-data; name="mime"\r\n\r\n${mime}\r\n` +
    `--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="seg"\r\nContent-Type: ${mime}\r\n\r\n`)
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`)
  return { body: Buffer.concat([head, buffer, tail]), contentType: `multipart/form-data; boundary=${boundary}` }
}

test('ASR endpoint: fixture transcribe returns honest usage and null confidence', async () => {
  const audio = makeWav(1200)
  const { body, contentType } = multipartBody('req-11111111', audio, 'audio/wav')
  const res = await fetch(base + '/assistant/v1/asr', {
    method: 'POST', headers: { 'content-type': contentType, 'content-length': body.length }, body
  })
  assert.equal(res.status, 200)
  const payload = await res.json()
  assert.equal(payload.text, '把速度改成80')
  assert.equal(payload.providerMode, 'mock')
  assert.equal(payload.requestId, 'req-11111111')
  assert.equal(payload.confidence, null)
  assert.equal(payload.usage.audioBytes, audio.length)
  assert.equal(payload.usage.estimatedDurationMs, 1200)
})

test('ASR idempotency: same requestId replays without a second charge', async () => {
  const before = gateway.ledger.turns
  const audio = makeWav(1200)
  const { body, contentType } = multipartBody('req-22222222', audio, 'audio/wav')
  const first = await fetch(base + '/assistant/v1/asr', {
    method: 'POST', headers: { 'content-type': contentType }, body })
  assert.equal(first.status, 200)
  assert.equal(gateway.ledger.turns, before + 1)
  const second = await fetch(base + '/assistant/v1/asr', {
    method: 'POST', headers: { 'content-type': contentType }, body })
  assert.equal(second.status, 200)
  const replay = await second.json()
  assert.equal(replay.replayed, true)
  assert.equal(replay.text, '把速度改成80')
  assert.equal(gateway.ledger.turns, before + 1, 'replay consumed no budget')
})

test('ASR validation: bad requestId, unsupported format, unregistered mock audio', async () => {
  const noId = await fetch(base + '/assistant/v1/asr', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ audioBase64: makeWav(500).toString('base64'), mime: 'audio/wav' })
  })
  assert.equal(noId.status, 400)
  assert.equal((await noId.json()).error, 'REQUEST_ID_REQUIRED')

  const badMime = await fetch(base + '/assistant/v1/asr', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ audioBase64: 'AAAA', mime: 'audio/mp4', requestId: 'req-33333333' })
  })
  assert.equal(badMime.status, 415)

  const unknown = await fetch(base + '/assistant/v1/asr', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ audioBase64: makeWav(700).toString('base64'), mime: 'audio/wav', requestId: 'req-44444444' })
  })
  assert.equal(unknown.status, 503) // mock has no fixture for this audio
  assert.equal((await unknown.json()).error, 'ASR_MOCK_NO_FIXTURE')
})

test('ASR quota: budget exhaustion returns 429, ledger is persistent', async () => {
  // Build a gateway with a 2-turn ledger; consume both, then expect 429.
  const tinyLedger = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'asr-ledger2-')), 'ledger.json')
  const fixtureKey = createHash('sha256').update(makeWav(1200)).digest('hex')
  const gw2 = createGateway({
    ledgerFile: tinyLedger, env: { GATEWAY_DAILY_TURN_LIMIT: '2' },
    asrProviderOptions: { fixtures: { [fixtureKey]: '测试' } }
  })
  await new Promise(r => gw2.server.listen(0, '127.0.0.1', r))
  const b2 = `http://127.0.0.1:${gw2.server.address().port}`
  const audio = makeWav(1200)
  for (const id of ['req-aaaa1111', 'req-aaaa2222']) {
    const { body, contentType } = multipartBody(id, audio, 'audio/wav')
    const res = await fetch(b2 + '/assistant/v1/asr', { method: 'POST', headers: { 'content-type': contentType }, body })
    assert.equal(res.status, 200)
  }
  const { body, contentType } = multipartBody('req-aaaa3333', audio, 'audio/wav')
  const limited = await fetch(b2 + '/assistant/v1/asr', { method: 'POST', headers: { 'content-type': contentType }, body })
  assert.equal(limited.status, 429)
  // Persistence: restart with the same ledger file keeps the spent budget.
  await new Promise(r => gw2.server.close(r))
  const gw3 = createGateway({ ledgerFile: tinyLedger,
    asrProviderOptions: { fixtures: { [fixtureKey]: '测试' } } })
  assert.equal(gw3.ledger.turns, 2, 'budget survived a restart (no fresh quota)')
})

test('intent endpoint runs the shared rule parser (server side parity)', async () => {
  const res = await fetch(base + '/assistant/v1/intent', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ text: '把速度改成80' })
  })
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.equal(body.source, 'rules')
  assert.equal(body.intent.type, 'set_bpm')
  assert.equal(body.intent.params.bpm, 80)
  const bad = await fetch(base + '/assistant/v1/intent', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: '' })
  })
  assert.equal(bad.status, 400)
})

test('mock TTS returns playable WAV bytes; text length capped', async () => {
  const ok = await fetch(base + '/assistant/v1/tts', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: '已选择曲目' })
  })
  assert.equal(ok.status, 200)
  const payload = await ok.json()
  assert.equal(payload.mime, 'audio/wav')
  assert.ok(payload.audioBase64.length > 100)
  const wav = Buffer.from(payload.audioBase64, 'base64')
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF')
  const tooLong = await fetch(base + '/assistant/v1/tts', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: 'x'.repeat(300) })
  })
  assert.equal(tooLong.status, 400)
})
