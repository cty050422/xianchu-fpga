// Assistant gateway: local-only HTTP + SSE, mock provider by default.
//
// Contract (API v1, see the S3 addendum):
//   GET  /assistant/v1/healthz
//   POST /assistant/v1/conversations
//   POST /assistant/v1/conversations/{id}/turns
//   POST /assistant/v1/conversations/{id}/turns/{turn}/cancel
//   POST /assistant/v1/proposals/review          (policy only; never writes the instrument)
//
// Everything is plain node:http - no framework, no dependency to audit. The default bind is loopback;
// binding to a LAN address and using a paid provider both require an explicit environment switch, so a
// forgotten flag cannot start spending money or expose the port.
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import {servicePort} from '../tools/service_config.mjs';
import { openLedger } from './ledger_store.mjs';
import { createServiceAuth } from './service_auth.mjs';
import { createAudioHandler } from './audio.mjs';
import { makeAudioPipeline } from './bailian_audio.mjs';
import { createCatalog } from './catalog.mjs';
import { createPerformanceRoutes } from './performance_routes.mjs';
import { createMusicRoutes } from './music_routes.mjs';
import { parseMultipart, validateAudio, makeAsrProvider, makeTtsProvider, MAX_BODY_BYTES } from './asr.mjs';

import { newConversation } from './conversation.mjs';
import { makeProvider } from './providers.mjs';
import { review, ProposalRejected } from './policy.mjs';

const require = createRequire(import.meta.url);
const intentRules = require('../wechat_miniprogram/utils/intent.js');

const VERSION = '1.1.0';

const SYSTEM_PROMPT = [
  '你是《弦触·云声》的中文音乐练习助手，可以正常聊天、讲解乐理、提供简短练习建议。优先在200字内回答。',
  '项目使用FPGA实时合成：四个独立声部，拨弦/吹管/钟声/合成贝斯四种音色，一个所有权绑定32分量层，四个FSR、双摇杆，自由/引导/挑战三模式。',
  '你没有实时设备读取或控制权限。不能声称连接、校准、上传、发声、音量、曲目或硬件状态已经改变或验证。',
  '小程序控制器支持搜索选曲、下载到手机或乐器、分段、练习速度、四音色、效果、音量和四区音高映射。明确控制命令由客户端识别并确认执行，只有FPGA回报能证明生效；你的文字回答不能代替执行结果。可建议短句如“下载玛丽有只小羊羔到乐器”“开始挑战”“音量设为50%”，不得假称任意网络曲目都能适配四区。',
  '曲库的真实名称、可演奏性和设备状态必须以页面查询/回报为准；不知道就明确说明。',
  '设备动作只能在页面生成确认卡，由用户确认并经正常协议执行。你只输出普通文字，不输出原始UART、固件命令、HTML或自动执行工具。'
].join(' ');

function json(response, status, body) {
  const text = JSON.stringify(body);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(text)
  });
  response.end(text);
}

function readBody(request, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) { reject(Object.assign(new Error('BODY_TOO_LARGE'), { code: 'BODY_TOO_LARGE' })); return; }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks)));
    request.on('error', reject);
  });
}

export function createGateway(options = {}) {
  const env = options.env ?? process.env;
  const provider = options.provider ?? makeProvider(env);
  const deviceToken = options.deviceToken ?? env.GATEWAY_DEVICE_TOKEN ?? '';
  const serviceAuth = createServiceAuth({legacyToken:deviceToken,pairingCode:env.GATEWAY_PAIR_CODE||''});
  const authorized = request => serviceAuth.authorized(request.headers['x-device-token']);
  // Persistent budget: a process restart must not hand out a fresh daily quota.
  // The file lives outside the source tree by default and can be redirected with
  // GATEWAY_LEDGER_FILE (tests use a temporary file).
  const ledgerFile = options.ledgerFile ?? env.GATEWAY_LEDGER_FILE ??
    path.join(env.GATEWAY_STATE_DIR ?? path.join(process.cwd(), '.gateway-state'), 'ledger.json');
  const ledger = options.ledger ?? openLedger({
    file: ledgerFile,
    limit: Number(env.GATEWAY_DAILY_TURN_LIMIT ?? 200)
  });
  if (!Number.isSafeInteger(ledger.limit) || ledger.limit < 0 || ledger.limit > 10000 ||
      !Number.isSafeInteger(ledger.turns) || ledger.turns < 0) throw new Error('INVALID_TURN_BUDGET');
  const audioPipeline = options.audioPipeline ?? makeAudioPipeline(env);
  const audio = createAudioHandler({ pipeline: audioPipeline,
    authorized,
    ledger, timeoutMs: options.audioTimeoutMs ?? 15000 });
  // Catalog + ASR/TTS share this server, this ledger and this token scheme.
  // A catalog read is free; an ASR/TTS LIVE call consumes one budgeted turn.
  const catalog = options.catalog ?? createCatalog(options.catalogOptions || {});
  const asrProvider = options.asrProvider ?? makeAsrProvider(env, options.asrProviderOptions || {});
  const ttsProvider = options.ttsProvider ?? makeTtsProvider(env, options.ttsProviderOptions || {});
  const conversations = new Map();
  const log = options.log ?? ((line) => console.log(line));
  const performances = createPerformanceRoutes({authorized,
    directory: options.recordingDirectory ?? env.GATEWAY_RECORDING_DIR ?? path.join(path.dirname(ledgerFile),'performances')});

  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const path = url.pathname;

    try {
      if (await createMusicRoutes({authorized})(request,response,url)) return;
      if (await performances(request,response,url)) return;
      if(path==='/assistant/v1/session/renew'&&request.method==='POST'){
        try{return json(response,200,serviceAuth.renew(request.headers['x-device-token']));}
        catch(error){return json(response,401,{error:error.code||'SESSION_EXPIRED_OR_RESTARTED'});}
      }
      if(path==='/assistant/v1/pair'&&request.method==='POST'){
        try{
          const body=JSON.parse((await readBody(request,1024)).toString('utf8'));
          return json(response,200,serviceAuth.pair(body.code));
        }catch(error){
          const status={PAIR_NOT_ENABLED:404,PAIR_CODE_EXPIRED:410,PAIR_LOCKED:429,PAIR_CLIENT_LIMIT:429,PAIR_CODE_INVALID:401}[error.code]||400;
          return json(response,status,{error:error.code||'PAIR_REQUEST_FORMAT'});
        }
      }
      if (await audio(request, response, path)) return;
      if (path === '/assistant/v1/healthz' && request.method === 'GET') {
        return json(response, 200, {
          build: VERSION,
          software_bundle_id: env.XIANCHU_SERVICE_ID || null,
          protocol: 'assistant/v1',
          provider: provider.name,
          chat: {mode:provider.paid?'live':'mock',name:provider.name,model:provider.model||null},
          auth: serviceAuth.status(),
          paid_provider: provider.paid,
          ready: true,
          audio_mode: audioPipeline.mode,
          audio_live_verified: false,
          // Never a key, never a URL with credentials, never a Wi-Fi password.
          limits: { daily_turns: ledger.limit, turns_used: ledger.turns,
            day: typeof ledger.snapshot === 'function' ? ledger.snapshot().day : undefined,
            persistent: typeof ledger.snapshot === 'function' },
          conversations: conversations.size,
          catalog: { version: catalog.version, songs: catalog.size },
          asr: { mode: asrProvider.mode, name: asrProvider.name, paid: asrProvider.paid },
          tts: { mode: ttsProvider.mode, name: ttsProvider.name, paid: ttsProvider.paid }
        });
      }

      // ------------------------------------------------------------------
      // Catalog (local HTTP by default; deployment config is external).
      // ------------------------------------------------------------------
      if (path === '/catalog/v1/healthz' && request.method === 'GET') {
        return json(response, 200, {
          service: 'catalog', version: catalog.version, songs: catalog.size, ready: true,
          note: '本地曲库服务（localhost）；未公网部署'
        });
      }
      if (path === '/catalog/v1/songs' && request.method === 'GET') {
        return json(response, 200, catalog.list({
          page: url.searchParams.get('page') || undefined,
          pageSize: url.searchParams.get('pageSize') || undefined,
          q: url.searchParams.get('q') || undefined,
          difficulty: url.searchParams.get('difficulty') || undefined,
          maxDifficulty: url.searchParams.get('maxDifficulty') || undefined,
          tag: url.searchParams.get('tag') || undefined,
          bpmMin: url.searchParams.get('bpmMin') || undefined,
          bpmMax: url.searchParams.get('bpmMax') || undefined,
          sort: url.searchParams.get('sort') || undefined
        }));
      }
      const songDetailMatch = path.match(/^\/catalog\/v1\/songs\/([a-z0-9-]+)$/);
      if (songDetailMatch && request.method === 'GET') {
        const detail = catalog.detail(songDetailMatch[1]);
        if (!detail) return json(response, 404, { error: 'NO_SUCH_SONG' });
        const etag = `"${detail.contentHash}"`;
        if (request.headers['if-none-match'] === etag) {
          response.writeHead(304, { ETag: etag });
          return response.end();
        }
        const text = JSON.stringify(detail);
        response.writeHead(200, {
          'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
          ETag: etag, 'Content-Length': Buffer.byteLength(text)
        });
        return response.end(text);
      }
      const songCompileMatch = path.match(/^\/catalog\/v1\/songs\/([a-z0-9-]+)\/compile$/);
      if (songCompileMatch && request.method === 'GET') {
        const result = catalog.compileSong(songCompileMatch[1], {
          bpm: url.searchParams.get('bpm') || undefined,
          deviceSupportsCustomNotes: url.searchParams.get('customNotes') || undefined
        });
        if (!result) return json(response, 404, { error: 'NO_SUCH_SONG' });
        return json(response, 200, result);
      }

      // ------------------------------------------------------------------
      // ASR: POST multipart/form-data (wx.uploadFile) or JSON base64.
      // Idempotent by requestId through the persistent ledger; a retry after
      // an ACK loss replays the stored text and is never charged twice.
      // ------------------------------------------------------------------
      if (path === '/assistant/v1/asr' && request.method === 'POST') {
        if (!authorized(request)) {
          return json(response, 401, { error: 'UNAUTHORIZED' });
        }
        let buffer, mime, declaredDurationMs, requestId;
        const contentType = String(request.headers['content-type'] || '');
        try {
          const raw = await readBody(request, MAX_BODY_BYTES);
          if (contentType.startsWith('multipart/form-data')) {
            const { fields, files } = parseMultipart(raw, contentType);
            const file = files.find(f => f.name === 'audio') || files[0];
            if (!file) return json(response, 400, { error: 'AUDIO_PART_MISSING' });
            buffer = file.data;
            mime = file.contentType || fields.mime || '';
            declaredDurationMs = fields.durationMs !== undefined ? Number(fields.durationMs) : null;
            requestId = fields.requestId;
          } else {
            const body = JSON.parse(raw.toString('utf8') || '{}');
            if (typeof body.audioBase64 !== 'string') return json(response, 400, { error: 'AUDIO_PART_MISSING' });
            buffer = Buffer.from(body.audioBase64, 'base64');
            mime = body.mime || '';
            declaredDurationMs = body.durationMs != null ? Number(body.durationMs) : null;
            requestId = body.requestId;
          }
        } catch (error) {
          if (error.code === 'BODY_TOO_LARGE') return json(response, 413, { error: 'BODY_TOO_LARGE' });
          return json(response, 400, { error: 'ASR_REQUEST_FORMAT' });
        }
        if (!requestId || typeof requestId !== 'string' || !/^[A-Za-z0-9-]{8,64}$/.test(requestId)) {
          return json(response, 400, { error: 'REQUEST_ID_REQUIRED' });
        }
        const prior = typeof ledger.recall === 'function' ? ledger.recall('asr', requestId) : null;
        if (prior) {
          // Idempotent replay: never re-call the provider, never charge again.
          return json(response, 200, { ...JSON.parse(prior.answer), replayed: true });
        }
        let checked;
        try {
          checked = validateAudio({ buffer, mime, declaredDurationMs });
        } catch (error) {
          const status = { AUDIO_EMPTY: 400, AUDIO_TOO_LARGE: 413, AUDIO_TOO_LONG: 413,
            AUDIO_FORMAT_UNSUPPORTED: 415, AUDIO_CONTAINER_MISMATCH: 415 }[error.code] || 400;
          return json(response, status, { error: error.code });
        }
        try {
          if (typeof ledger.consume === 'function') ledger.consume();
          else ledger.turns += 1;
        } catch (error) {
          return json(response, 429, { error: 'BUDGET_EXHAUSTED' });
        }
        let result;
        try {
          result = await asrProvider.transcribe({ buffer, mime, signal: request.aborted ? AbortSignal.abort() : null });
        } catch (error) {
          const status = { ASR_UPSTREAM_401: 502, ASR_UPSTREAM_429: 429, ASR_UPSTREAM_TIMEOUT: 504,
            CANCELLED: 499, ASR_MOCK_NO_FIXTURE: 503 }[error.code] || 502;
          return json(response, status, { error: error.code });
        }
        const payload = {
          text: result.text, language: 'zh-CN',
          providerMode: asrProvider.mode, providerName: asrProvider.name,
          requestId,
          usage: { audioBytes: checked.bytes, estimatedDurationMs: checked.estimatedMs,
            declaredDurationMs: declaredDurationMs ?? null, provider: result.usage.provider_usage || null },
          // Mock and the current Qwen-ASR contract return no confidence score:
          // report null instead of inventing an accuracy number.
          confidence: result.confidence ?? null
        };
        if (typeof ledger.remember === 'function') {
          ledger.remember('asr', requestId, requestId, JSON.stringify(payload));
        }
        return json(response, 200, payload);
      }

      // Intent: deterministic rules only, shared code with the client.
      if (path === '/assistant/v1/intent' && request.method === 'POST') {
        if (!authorized(request)) {
          return json(response, 401, { error: 'UNAUTHORIZED' });
        }
        const body = JSON.parse((await readBody(request)).toString('utf8') || '{}');
        if (typeof body.text !== 'string' || !body.text.trim() || body.text.length > 500) {
          return json(response, 400, { error: 'TEXT_REQUIRED' });
        }
        return json(response, 200, {
          intent: intentRules.parse(body.text), source: 'rules',
          note: '确定性表达走规则解析；开放问答请使用 /conversations 接口'
        });
      }

      // Optional TTS: only called when the user enables read-aloud; failure
      // here never blocks transcription or song selection upstream.
      if (path === '/assistant/v1/tts' && request.method === 'POST') {
        if (!authorized(request)) {
          return json(response, 401, { error: 'UNAUTHORIZED' });
        }
        const body = JSON.parse((await readBody(request)).toString('utf8') || '{}');
        if (typeof body.text !== 'string' || !body.text.trim() || body.text.length > 200) {
          return json(response, 400, { error: 'TEXT_REQUIRED' });
        }
        if (ttsProvider.paid) {
          try {
            if (typeof ledger.consume === 'function') ledger.consume();
          } catch {
            return json(response, 429, { error: 'BUDGET_EXHAUSTED' });
          }
        }
        try {
          const spoken = await ttsProvider.synthesize({ text: body.text });
          return json(response, 200, {
            mime: spoken.mime, providerMode: ttsProvider.mode,
            audioBase64: spoken.buffer.toString('base64')
          });
        } catch (error) {
          const status = { TTS_UPSTREAM_401: 502, TTS_UPSTREAM_429: 429 }[error.code] || 502;
          return json(response, status, { error: error.code });
        }
      }

      if (path === '/assistant/v1/conversations' && request.method === 'POST') {
        if (!authorized(request)) {
          return json(response, 401, { error: 'UNAUTHORIZED' });
        }
        const conversation = newConversation();
        conversations.set(conversation.id, conversation);
        return json(response, 201, {
          conversation_id: conversation.id,
          expires_at: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
          limits: conversation.limits
        });
      }

      const turnMatch = path.match(/^\/assistant\/v1\/conversations\/([^/]+)\/turns$/);
      if (turnMatch && request.method === 'POST') {
        if (!authorized(request)) {
          return json(response, 401, { error: 'UNAUTHORIZED' });
        }
        const body = JSON.parse((await readBody(request)).toString('utf8') || '{}');
        const conversation = conversations.get(turnMatch[1]);
        if (!conversation) {
          // A conversation lives in memory, but the idempotency record is on disk:
          // after a restart a retried turn is answered from that record instead of
          // being charged again or reported as an unknown conversation.
          const prior = typeof ledger.recall === 'function'
            ? ledger.recall(turnMatch[1], body.client_turn_id) : null;
          if (prior && prior.text === body.text) {
            response.writeHead(200, {
              'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store',
              Connection: 'keep-alive'
            });
            const replaySeq = { value: 0 };
            const sendReplay = (event, data) => {
              response.write(`event: ${event}\n`);
              response.write(`data: ${JSON.stringify({ ...data, event_seq: ++replaySeq.value })}\n\n`);
            };
            sendReplay('ready', { conversation_id: turnMatch[1], turn_id: body.client_turn_id,
              replayed: true, restored_after_restart: true });
            sendReplay('assistant.done', { conversation_id: turnMatch[1], turn_id: body.client_turn_id,
              text: prior.answer });
            sendReplay('end', { conversation_id: turnMatch[1] });
            return response.end();
          }
          return json(response, 404, { error: 'NO_SUCH_CONVERSATION' });
        }
        // Order matters: a REPLAY of a completed turn is free and must be answered before the budget is
        // consulted, otherwise a client that retries after an ACK loss gets 429 for an answer it already paid
        // for (FR05 REPLAY_AT_BUDGET_LIMIT).
        let started;
        try {
          started = conversation.begin(body.client_turn_id, body.text);
        } catch (error) {
          const status = error.code === 'TURN_LIMIT' ? 429
            : error.code === 'TEXT_LIMIT' ? 413
            : error.code === 'TURN_IN_PROGRESS' ? 409 : 409;
          return json(response, status, { error: error.code });
        }
        if ((started.replay === null || started.replay === undefined) && ledger.turns >= ledger.limit) {
          // A new turn costs budget; release the pending slot first so the conversation is not left busy.
          conversation.abandonPending(started.generation);
          return json(response, 429, { error: 'BUDGET_EXHAUSTED' });
        }

        if (started.replay === null || started.replay === undefined) {
          try {
            if (typeof ledger.consume === 'function') ledger.consume();
            else ledger.turns += 1;
          } catch (error) {
            conversation.abandonPending(started.generation);
            return json(response, error.code === 'BUDGET_EXHAUSTED' ? 429 : 503,
              { error: error.code ?? 'LEDGER_UNAVAILABLE' });
          }
        }

        response.writeHead(200, {
          'Content-Type': 'text/event-stream; charset=utf-8',
          'Cache-Control': 'no-store',
          Connection: 'keep-alive'
        });
        const send = (event, data) => {
          response.write(`event: ${event}\n`);
          response.write(`data: ${JSON.stringify(data)}\n\n`);
        };

        if (started.replay !== null && started.replay !== undefined) {
          // A duplicate client_turn_id returns the stored answer and does NOT call the provider again.
          send('ready', { conversation_id: conversation.id, turn_id: body.client_turn_id, replayed: true });
          send('assistant.done', { conversation_id: conversation.id, turn_id: body.client_turn_id,
            text: started.replay, event_seq: conversation.nextSeq() });
          send('end', { conversation_id: conversation.id, event_seq: conversation.nextSeq() });
          return response.end();
        }

        const generation = started.generation;
        send('ready', { conversation_id: conversation.id, turn_id: body.client_turn_id, generation,
          event_seq: conversation.nextSeq() });

        const controller = new AbortController();
        // IncomingMessage.close can have fired as soon as its body was consumed.
        // The outgoing SSE response owns the actual client disconnect lifetime.
        response.once('close', () => { if (!response.writableEnded) controller.abort(); });
        let answer = '';
        let cancelled = false;
        try {
          for await (const chunk of provider.stream(conversation.messages(SYSTEM_PROMPT), controller.signal)) {
            if (conversation.isCancelled(generation) || controller.signal.aborted) { cancelled = true; break; }
            answer += chunk.text;
            send('assistant.delta', { conversation_id: conversation.id, turn_id: body.client_turn_id,
              generation, text: chunk.text, event_seq: conversation.nextSeq() });
          }
        } catch (error) {
          conversation.abandonPending(generation);
          send('error', { conversation_id: conversation.id, generation,
            code: error.code ?? 'PROVIDER_ERROR', event_seq: conversation.nextSeq() });
          send('end', { conversation_id: conversation.id, event_seq: conversation.nextSeq() });
          return response.end();
        }

        if (cancelled || conversation.isCancelled(generation)) {
          // The partial answer is NOT stored, and the pending slot is released: a cancelled turn must neither
          // become context nor keep the conversation busy.
          conversation.abandonPending(generation);
          send('cancelled', { conversation_id: conversation.id, generation,
            event_seq: conversation.nextSeq() });
        } else {
          conversation.complete(generation, answer, body.client_turn_id, body.text);
          // Durable idempotency: a retry after a restart replays this answer and
          // does not consume a second unit of budget.
          if (typeof ledger.remember === 'function') {
            ledger.remember(conversation.id, body.client_turn_id, body.text, answer);
          }
          send('assistant.done', { conversation_id: conversation.id, turn_id: body.client_turn_id,
            generation, text: answer, event_seq: conversation.nextSeq() });
        }
        send('end', { conversation_id: conversation.id, event_seq: conversation.nextSeq() });
        return response.end();
      }

      const cancelMatch = path.match(/^\/assistant\/v1\/conversations\/([^/]+)\/turns\/([^/]+)\/cancel$/);
      if (cancelMatch && request.method === 'POST') {
        if (!authorized(request)) {
          return json(response, 401, { error: 'UNAUTHORIZED' });
        }
        const conversation = conversations.get(cancelMatch[1]);
        if (!conversation) return json(response, 404, { error: 'NO_SUCH_CONVERSATION' });
        // A cancel that does not name a generation means "the turn that is running now"; generation 0 is
        // never a real turn, so it means the same thing.
        const asked = Number(url.searchParams.get('generation'));
        const generation = Number.isInteger(asked) && asked > 0
          ? asked
          : (conversation.pending ? conversation.pending.generation : conversation.generation);
        conversation.cancel(generation);
        return json(response, 200, { cancelled: true, generation,
          conversation_id: conversation.id });
      }

      if (path === '/assistant/v1/proposals/review' && request.method === 'POST') {
        if (!authorized(request)) {
          return json(response, 401, { error: 'UNAUTHORIZED' });
        }
        const raw = await readBody(request);
        try {
          const preview = review(raw);
          // The gateway NEVER applies anything here: it returns a preview that a human must confirm in the
          // app, and even then the app talks to the instrument through the normal configuration path.
          return json(response, 200, { ...preview, applied: false });
        } catch (error) {
          if (error instanceof ProposalRejected) return json(response, 422, { error: error.code });
          throw error;
        }
      }

      if (path.startsWith('/assistant/v1/')) return json(response, 404, { error: 'NO_SUCH_ROUTE' });
      return json(response, 404, { error: 'NOT_FOUND' });
    } catch (error) {
      log(`gateway error: ${error.code ?? error.message}`);
      if (!response.headersSent) return json(response, 500, { error: error.code ?? 'INTERNAL' });
      response.end();
    }
  });

  return { server, provider, ledger, conversations, catalog, asrProvider, ttsProvider };
}

const isMain = (() => {
  try {
    return Boolean(process.argv[1]) && process.argv[1].endsWith('server.mjs');
  } catch {
    return false;
  }
})();

if (isMain) {
  const host = process.env.GATEWAY_HOST ?? '127.0.0.1';
  const port = servicePort();
  validateListenConfiguration(host, process.env.GATEWAY_DEVICE_TOKEN ?? '');
  const { server, provider, ledger } = createGateway();
  server.listen(port, host, () => {
    console.log(`assistant gateway ${VERSION} on http://${host}:${port}/assistant/v1`);
    console.log(`provider=${provider.name} paid=${provider.paid} daily_turn_limit=${ledger.limit}`);
    if (host !== '127.0.0.1' && host !== 'localhost') {
      console.log('WARNING: bound to a non-loopback address; set GATEWAY_DEVICE_TOKEN before exposing it.');
    }
  });
}

export function validateListenConfiguration(host, token) {
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) && (!token || token.length < 16)) {
    throw new Error('LAN_BIND_REQUIRES_DEVICE_TOKEN_16_CHARS');
  }
}
