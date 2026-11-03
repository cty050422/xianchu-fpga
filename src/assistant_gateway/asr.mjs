// ASR + TTS provider adapters and audio validation.
//
// Design rules from the addendum (docs/handoff_addendum):
//   * ASR, intent and TTS are SEPARATE endpoints — a transcription never
//     forces a chat or TTS call;
//   * provider keys live ONLY in server env; mock is default and paid calls
//     need GATEWAY_ALLOW_PAID_AUDIO=1;
//   * the server must not trust the client-claimed duration: WAV is parsed
//     exactly, MP3 duration is counted across complete frame headers, and the byte cap is enforced regardless;
//   * request/response contracts follow the Qwen-ASR / Qwen-TTS DashScope
//     docs consulted 2026-10-21/24 (help.aliyun.com/zh/model-studio/
//     qwen-asr-api-reference). Endpoints/models are operator configuration.
import { createHash } from 'node:crypto';

const MAX_AUDIO_BYTES = 2 * 1024 * 1024;       // 2 MiB upload cap
const MAX_AUDIO_SECONDS = 15;                  // PTT segment cap
const MAX_BODY_BYTES = 3 * 1024 * 1024;        // multipart overhead headroom

const fail = code => Object.assign(new Error(code), { code });

// ---------------------------------------------------------------------------
// Multipart/form-data parsing (wx.uploadFile contract). Minimal, bounded,
// no temp files.
// ---------------------------------------------------------------------------
export function parseMultipart(body, contentType) {
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
  if (!match) throw fail('MULTIPART_BOUNDARY_MISSING');
  const boundary = Buffer.from('--' + (match[1] || match[2]));
  const segments = [];
  let start = body.indexOf(boundary);
  while (start !== -1) {
    const next = body.indexOf(boundary, start + boundary.length);
    if (next === -1) break;
    segments.push(body.subarray(start + boundary.length, next));
    start = next;
  }
  const fields = {};
  const files = [];
  for (const segment of segments) {
    const headerEnd = segment.indexOf('\r\n\r\n');
    if (headerEnd === -1) continue;
    const headerText = segment.subarray(0, headerEnd).toString('utf8');
    const data = segment.subarray(headerEnd + 4);
    const cleaned = data.length >= 2 && data[data.length - 2] === 13 && data[data.length - 1] === 10
      ? data.subarray(0, data.length - 2) : data;
    const nameMatch = /name="([^"]*)"/i.exec(headerText);
    if (!nameMatch) continue;
    const fileMatch = /filename="([^"]*)"/i.exec(headerText);
    const typeMatch = /content-type:\s*([^\r\n]+)/i.exec(headerText);
    if (fileMatch) {
      files.push({ name: nameMatch[1], filename: fileMatch[1], contentType: typeMatch ? typeMatch[1].trim() : '', data: cleaned });
    } else {
      fields[nameMatch[1]] = cleaned.toString('utf8');
    }
  }
  return { fields, files };
}

// ---------------------------------------------------------------------------
// Audio validation. WAV: bounded PCM chunks. MP3: full frame lengths and sample counts.
// ---------------------------------------------------------------------------
const MP3_BITRATES_V1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const MP3_BITRATES_V2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
const MP3_RATES = { // samples per second, indexed by version+bits
  v1: [44100, 48000, 32000, 0],
  v2: [22050, 24000, 16000, 0],
  v25: [11025, 12000, 8000, 0]
};

export function validateAudio({ buffer, mime, declaredDurationMs }) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) throw fail('AUDIO_EMPTY');
  if (buffer.length > MAX_AUDIO_BYTES) throw fail('AUDIO_TOO_LARGE');
  const kind = (mime || '').toLowerCase();
  let estimatedMs = null;
  if (kind === 'audio/wav' || kind === 'audio/x-wav' || kind === 'audio/wave') {
    if (buffer.length < 44 || buffer.toString('ascii', 0, 4) !== 'RIFF' || buffer.toString('ascii', 8, 12) !== 'WAVE')
      throw fail('AUDIO_CONTAINER_MISMATCH');
    const end = buffer.readUInt32LE(4) + 8;
    if (end !== buffer.length) throw fail('AUDIO_CONTAINER_MISMATCH');
    let dataBytes = 0, channels = 0, rate = 0, bits = 0, alignment = 0, byteRate = 0;
    for (let i = 12; i + 8 <= buffer.length;) {
      const tag = buffer.toString('ascii', i, i + 4);
      const size = buffer.readUInt32LE(i + 4);
      if (i + 8 + size + (size & 1) > end) throw fail('AUDIO_CONTAINER_MISMATCH');
      if (tag === 'fmt ') {
        if (size < 16 || rate || buffer.readUInt16LE(i+8) !== 1) throw fail('AUDIO_CONTAINER_MISMATCH');
        channels=buffer.readUInt16LE(i+10);rate=buffer.readUInt32LE(i+12);
        byteRate=buffer.readUInt32LE(i+16);alignment=buffer.readUInt16LE(i+20);bits=buffer.readUInt16LE(i+22);
      }
      if (tag === 'data') { if (dataBytes) throw fail('AUDIO_CONTAINER_MISMATCH'); dataBytes = size; }
      i = i + 8 + size + (size & 1);
    }
    if (!dataBytes || rate < 8000 || rate > 48000 || ![1,2].includes(channels) || bits !== 16 ||
        alignment !== channels*2 || byteRate !== rate*alignment || dataBytes % alignment)
      throw fail('AUDIO_CONTAINER_MISMATCH');
    estimatedMs = Math.round(dataBytes / (rate * channels * 2) * 1000);
  } else if (kind === 'audio/mp3' || kind === 'audio/mpeg') {
    // Locate the first frame sync (skip ID3v2 if present).
    let offset = 0;
    if (buffer.toString('ascii', 0, 3) === 'ID3') {
      if (buffer.length < 10 || [...buffer.subarray(6,10)].some(b=>b&0x80)) throw fail('AUDIO_CONTAINER_MISMATCH');
      offset=10+((buffer[6]<<21)|(buffer[7]<<14)|(buffer[8]<<7)|buffer[9]);
      if (buffer[3]===4 && (buffer[5]&0x10)) offset+=10;
    }
    let found = -1;
    for (let i = offset; i < Math.min(buffer.length - 4, offset + 8192); i++) {
      if (buffer[i] === 0xff && (buffer[i + 1] & 0xe0) === 0xe0) { found = i; break; }
    }
    if (found === -1) throw fail('AUDIO_CONTAINER_MISMATCH');
    // Walk complete frame lengths. A first header alone cannot certify duration
    // (or distinguish truncated/fake uploads); VBR must count samples per frame.
    let seconds=0, frames=0, sampleRate=0;
    for (let i=found;i<buffer.length;) {
      if (buffer.length-i===128 && buffer.toString('ascii',i,i+3)==='TAG') break;
      if (i+4>buffer.length || buffer[i]!==0xff || (buffer[i+1]&0xe0)!==0xe0) throw fail('AUDIO_CONTAINER_MISMATCH');
      const b1=buffer[i+1],b2=buffer[i+2],versionBits=(b1>>3)&3;
      if(versionBits===1 || ((b1>>1)&3)!==1) throw fail('AUDIO_CONTAINER_MISMATCH');
      const version=versionBits===3?'v1':versionBits===2?'v2':'v25';
      const rate=MP3_RATES[version][(b2>>2)&3];
      const bitrate=(version==='v1'?MP3_BITRATES_V1L3:MP3_BITRATES_V2L3)[(b2>>4)&15];
      if(!rate || !bitrate || (sampleRate && sampleRate!==rate)) throw fail('AUDIO_CONTAINER_MISMATCH');
      const length=Math.floor((version==='v1'?144000:72000)*bitrate/rate)+((b2>>1)&1);
      if(i+length>buffer.length) throw fail('AUDIO_CONTAINER_MISMATCH');
      sampleRate=rate;seconds+=(version==='v1'?1152:576)/rate;frames++;i+=length;
    }
    if (!frames) throw fail('AUDIO_CONTAINER_MISMATCH');
    estimatedMs = Math.round(seconds*1000);
  } else {
    throw fail('AUDIO_FORMAT_UNSUPPORTED');
  }
  // Server-side duration bound (do not trust declaredDurationMs for accounting;
  // it is only recorded as a hint).
  if (estimatedMs !== null && estimatedMs > MAX_AUDIO_SECONDS * 1000 + 50) throw fail('AUDIO_TOO_LONG');
  if (declaredDurationMs !== undefined && declaredDurationMs !== null &&
      (!Number.isFinite(Number(declaredDurationMs)) || Number(declaredDurationMs)<0 || Number(declaredDurationMs)>MAX_AUDIO_SECONDS*1000+50)) throw fail('AUDIO_TOO_LONG');
  return { estimatedMs, bytes: buffer.length };
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------
export function makeAsrProvider(env = {}, options = {}) {
  const mode = env.ASR_MODE || 'mock';
  if (mode === 'mock') {
    const fixtures = options.fixtures || {};
    const fallback = env.MOCK_ASR_TEXT || null;
    return {
      mode: 'mock', name: 'mock-asr', paid: false,
      async transcribe({ buffer, mime }) {
        const key = createHash('sha256').update(buffer).digest('hex');
        const text = fixtures[key] || fallback;
        if (text === null) throw fail('ASR_MOCK_NO_FIXTURE');
        return { text, usage: { audioBytes: buffer.length } };
      }
    };
  }
  if (mode !== 'bailian') throw fail('ASR_MODE_UNKNOWN');
  if (env.GATEWAY_ALLOW_PAID_AUDIO !== '1') throw fail('PAID_AUDIO_NOT_ENABLED');
  const apiKey = env.BAILIAN_API_KEY, url = env.BAILIAN_ASR_URL, model = env.BAILIAN_ASR_MODEL;
  if (!apiKey || !url || !model) throw fail('ASR_CONFIG_REQUIRED');
  const endpoint = new URL(url);
  if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password) throw fail('ASR_ENDPOINT_REQUIRED_HTTPS');
  const fetchImpl = options.fetchImpl || fetch;
  const timeoutMs = Number(env.BAILIAN_ASR_TIMEOUT_MS || 15000);
  return {
    mode: 'live', name: 'bailian-qwen-asr', paid: true, model, endpoint: url,
    async transcribe({ buffer, mime, signal }) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      if (signal) signal.addEventListener('abort', () => controller.abort(), { once: true });
      let response;
      try {
        response = await fetchImpl(url, {
          method: 'POST', redirect: 'error', signal: controller.signal,
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
          body: JSON.stringify({
            model,
            stream: false,
            messages: [{ role: 'user', content: [{ type: 'input_audio', input_audio: { data: `data:${mime==='audio/mp3'?'audio/mpeg':mime};base64,${buffer.toString('base64')}` } }] }],
            asr_options: { enable_itn: false }
          })
        });
      } catch (error) {
        clearTimeout(timer);
        if (signal && signal.aborted) throw fail('CANCELLED');
        throw fail(error.name === 'AbortError' ? 'ASR_UPSTREAM_TIMEOUT' : 'ASR_UPSTREAM_UNREACHABLE');
      }
      clearTimeout(timer);
      if (response.status === 401 || response.status === 403) throw fail('ASR_UPSTREAM_401');
      if (response.status === 429) throw fail('ASR_UPSTREAM_429');
      if (!response.ok) throw fail('ASR_UPSTREAM_' + response.status);
      let body;
      try {
        const text = await response.text();
        if (text.length > 2 * 1024 * 1024) throw fail('ASR_RESULT_TOO_LARGE');
        body = JSON.parse(text);
      } catch { throw fail('ASR_RESULT_FORMAT'); }
      const transcription = body?.choices?.[0]?.message?.content;
      if (typeof transcription !== 'string' || !transcription.trim() || transcription.length > 2000) throw fail('ASR_RESULT_FORMAT');
      return {
        text: transcription.trim(),
        usage: { audioBytes: buffer.length, provider_usage: body?.usage || null }
      };
    }
  };
}

// Mock TTS: deterministic PCM WAV tone whose length tracks the text. Clearly a
// synthetic placeholder — it never pretends to be a cloud voice.
export function makeTtsProvider(env = {}, options = {}) {
  const mode = env.TTS_MODE || 'mock';
  if (mode === 'mock') {
    return {
      mode: 'mock', name: 'mock-tts', paid: false,
      async synthesize({ text }) {
        const rate = 16000;
        const perChar = Math.min(120, Math.max(40, Math.round(text.length * 0.09 * 1000)));
        const samples = Math.min(rate * 20, Math.max(rate / 2, Math.floor(rate * perChar * text.length / 1000 / 8)));
        const pcm = Buffer.alloc(samples * 2);
        for (let i = 0; i < samples; i++) {
          const t = i / rate;
          const envelope = Math.min(1, Math.min(t * 20, (samples / rate - t) * 20));
          pcm.writeInt16LE(Math.round(6000 * envelope * Math.sin(2 * Math.PI * 440 * t)), i * 2);
        }
        const header = Buffer.alloc(44);
        header.write('RIFF'); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8);
        header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
        header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28);
        header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
        header.write('data', 36); header.writeUInt32LE(pcm.length, 40);
        return { mime: 'audio/wav', buffer: Buffer.concat([header, pcm]) };
      }
    };
  }
  if (mode !== 'bailian') throw fail('TTS_MODE_UNKNOWN');
  if (env.GATEWAY_ALLOW_PAID_AUDIO !== '1') throw fail('PAID_AUDIO_NOT_ENABLED');
  const apiKey = env.BAILIAN_API_KEY, url = env.BAILIAN_TTS_URL, model = env.BAILIAN_TTS_MODEL, voice = env.BAILIAN_TTS_VOICE;
  const hosts = (env.BAILIAN_AUDIO_HOSTS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (!apiKey || !url || !model || !voice) throw fail('TTS_CONFIG_REQUIRED');
  if (!hosts.length) throw fail('TTS_DOWNLOAD_ALLOWLIST_REQUIRED');
  const fetchImpl = options.fetchImpl || fetch;
  return {
    mode: 'live', name: 'bailian-qwen-tts', paid: true, model,
    async synthesize({ text }) {
      const response = await fetchImpl(url, {
        method: 'POST', redirect: 'error',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({ model, input: { text, voice, language_type: 'Auto' } })
      });
      if (response.status === 401 || response.status === 403) throw fail('TTS_UPSTREAM_401');
      if (response.status === 429) throw fail('TTS_UPSTREAM_429');
      if (!response.ok) throw fail('TTS_UPSTREAM_' + response.status);
      const body = JSON.parse((await response.text()));
      const audioUrl = body?.output?.audio?.url;
      if (typeof audioUrl !== 'string') throw fail('TTS_RESULT_FORMAT');
      const parsed = new URL(audioUrl);
      // The official Qwen-TTS example can return an HTTP OSS URL. Upgrade only
      // explicitly allowlisted hosts in the Beijing profile; never fetch HTTP.
      if(parsed.protocol==='http:'&&env.BAILIAN_TTS_UPGRADE_HTTP==='1'&&hosts.includes(parsed.hostname))parsed.protocol='https:';
      if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.port || !hosts.includes(parsed.hostname))
        throw fail('TTS_DOWNLOAD_REFUSED');
      const audio = await fetchImpl(parsed.href, { redirect: 'error' }); // NO Authorization to audio host
      if (!audio.ok) throw fail('TTS_DOWNLOAD_' + audio.status);
      const buffer = Buffer.from(await audio.arrayBuffer());
      if (buffer.length > 2 * 1024 * 1024) throw fail('TTS_RESULT_TOO_LARGE');
      return { mime: 'audio/wav', buffer };
    }
  };
}

export { MAX_AUDIO_BYTES, MAX_AUDIO_SECONDS, MAX_BODY_BYTES };
