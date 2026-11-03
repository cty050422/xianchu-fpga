// Hardening tests for the gateway: concurrency, budget/replay and answer limits (FR05), and the real
// Bailian adapter's SSE handling (FR06). Every case is a scenario the review reproduced, written against the
// documented contract rather than against the current implementation.
//
// No network and no key: the provider is either the MockProvider or a fetch fixture injected into BailianChat.
import { after, describe, it } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const testStateRoot=fs.mkdtempSync(path.join(os.tmpdir(),'gateway-hardening-'));
let fixtureNumber=0;
after(()=>fs.rmSync(testStateRoot,{recursive:true,force:true}));
import assert from 'node:assert/strict';

import { createGateway } from './server.mjs';
import { MockProvider, BailianChat } from './providers.mjs';

/* ---------- helpers ------------------------------------------------------------------------- */

async function startGateway(options = {}) {
  const gateway = createGateway({ ledgerFile:path.join(testStateRoot,`ledger-${++fixtureNumber}.json`), env: { GATEWAY_PROVIDER: 'mock', ...(options.env ?? {}) },
    provider: options.provider ?? new MockProvider({ chunkDelayMs: 1, chunkSize: 8 }),
    log: () => {}, ...options });
  await new Promise((r) => gateway.server.listen(0, '127.0.0.1', r));
  return { gateway, base: `http://127.0.0.1:${gateway.server.address().port}` };
}

async function stop(gateway) {
  await new Promise((r) => gateway.server.close(r));
}

async function newConversation(base, token) {
  const res = await fetch(`${base}/assistant/v1/conversations`, {
    method: 'POST', headers: token ? { 'x-device-token': token } : {}
  });
  assert.equal(res.status, 201, 'conversation creation must succeed');
  return (await res.json()).conversation_id;
}

/** Drain an SSE response into {event, data} pairs. */
async function collect(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const events = [];
  let buffer = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let index;
    while ((index = buffer.indexOf('\n\n')) >= 0) {
      const raw = buffer.slice(0, index);
      buffer = buffer.slice(index + 2);
      const name = raw.match(/^event: (.*)$/m)?.[1];
      const data = raw.match(/^data: (.*)$/m)?.[1];
      if (name) events.push({ event: name, data: data ? JSON.parse(data) : null });
    }
  }
  return events;
}

function turnRequest(base, id, body, token) {
  return fetch(`${base}/assistant/v1/conversations/${id}/turns`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { 'x-device-token': token } : {}) },
    body: JSON.stringify(body)
  });
}

function heldProvider() {
  let release; const barrier=new Promise(resolve=>{release=resolve;});
  return {name:'mock',paid:false,calls:0,release:()=>release(),
    async *stream(){this.calls++;yield {text:'开始'};await barrier;yield {text:'完成'};}};
}

/* ---------- FR05: concurrency --------------------------------------------------------------- */

describe('FR05 one in-flight turn per conversation', () => {
  it('refuses a second turn while the first is still streaming', async () => {
    const slow = heldProvider();
    const { gateway, base } = await startGateway({ provider: slow });
    try {
      const id = await newConversation(base);
      const first = await turnRequest(base, id, { client_turn_id: 'a', text: '第一轮' });
      // Give the first request time to be accepted but not to finish.

      const second = await turnRequest(base, id, { client_turn_id: 'b', text: '第二轮' });
      assert.equal(second.status, 409, 'a concurrent turn must be refused with 409, not silently accepted');
      const body = await second.json();
      assert.equal(body.error, 'TURN_IN_PROGRESS', `expected TURN_IN_PROGRESS, got ${body.error}`);
      slow.release();
      const response = first;
      const events = await collect(response);
      assert.ok(events.some((e) => e.event === 'assistant.done'), 'the first turn must still finish');
    } finally {
      slow.release();
      await stop(gateway);
    }
  });

  it('keeps user and assistant messages paired after a refused concurrent turn', async () => {
    const slow = heldProvider();
    const { gateway, base } = await startGateway({ provider: slow });
    try {
      const id = await newConversation(base);
      const first = await turnRequest(base, id, { client_turn_id: 'x', text: '甲' });

      assert.equal(first.status,200);
      assert.equal((await turnRequest(base, id, { client_turn_id: 'y', text: '乙' })).status,409);
      slow.release();
      await collect(first);
      const conversation = gateway.conversations.get(id);
      const roles = conversation.turns.map((t) => t.role);
      assert.deepEqual(roles, ['user', 'assistant'],
        `history must be one complete exchange, got ${JSON.stringify(roles)}`);
      assert.equal(conversation.turns[0].text, '甲', 'the rejected turn must not appear in history');
    } finally {
      slow.release();
      await stop(gateway);
    }
  });

  it('gives BUSY to a duplicate in-flight id instead of starting a second generation', async () => {
    const slow = heldProvider();
    const { gateway, base } = await startGateway({ provider: slow });
    try {
      const id = await newConversation(base);
      const first = await turnRequest(base, id, { client_turn_id: 'same', text: '同一轮' });

      const second = await turnRequest(base, id, { client_turn_id: 'same', text: '同一轮' });
      assert.equal(second.status, 409, 'the same id while in flight must not start another turn');
      slow.release();
      await collect(first);
      assert.equal(gateway.conversations.get(id).generation, 1, 'only one generation may have started');
    } finally {
      slow.release();
      await stop(gateway);
    }
  });
});

/* ---------- FR05: budget and replay --------------------------------------------------------- */

describe('FR05 budget must not block a free replay', () => {
  it('replays a completed turn after the budget is exhausted', async () => {
    const { gateway, base } = await startGateway({ ledger: { turns: 0, limit: 1 } });
    try {
      const id = await newConversation(base);
      const first = await turnRequest(base, id, { client_turn_id: 'once', text: '只问一次' });
      const firstEvents = await collect(first);
      const answer = firstEvents.find((e) => e.event === 'assistant.done').data.text;

      // The budget is now exhausted. A NEW turn must be refused...
      const fresh = await turnRequest(base, id, { client_turn_id: 'twice', text: '再问一次' });
      assert.equal(fresh.status, 429, 'a new turn must be refused once the budget is spent');

      // ...but replaying the completed one is free and must succeed.
      const replay = await turnRequest(base, id, { client_turn_id: 'once', text: '只问一次' });
      assert.equal(replay.status, 200, 'a replay of a completed turn must not be refused by the budget');
      const events = await collect(replay);
      assert.equal(events.find((e) => e.event === 'assistant.done').data.text, answer,
        'the replay must return the stored answer');
      assert.equal(events.find((e) => e.event === 'ready').data.replayed, true);
    } finally {
      await stop(gateway);
    }
  });
});

/* ---------- FR06: the real Bailian adapter's SSE parsing ------------------------------------ */

function fixtureFetch(bodyText, { status = 200, onAbort } = {}) {
  return async (url, init) => {
    if (onAbort) onAbort(init);
    const encoder = new TextEncoder();
    const bytes = encoder.encode(bodyText);
    return {
      ok: status >= 200 && status < 300,
      status,
      body: new ReadableStream({
        start(controller) {
          // Deliver in small slices so multi-byte characters and event boundaries are split.
          for (let i = 0; i < bytes.length; i += 7) controller.enqueue(bytes.slice(i, i + 7));
          controller.close();
        }
      })
    };
  };
}

function bailianWith(fetchImpl, options = {}) {
  const provider = new BailianChat({
    apiKey: 'test-key', model: 'test-model', baseUrl: 'https://example.invalid/v1/chat',
    ...options
  });
  provider.fetchImpl = fetchImpl;
  return provider;
}

async function drain(provider, messages = [{ role: 'user', text: '你好' }], signal) {
  let text = '';
  for await (const chunk of provider.stream(messages, signal)) text += chunk.text;
  return text;
}

describe('FR06 BailianChat SSE parsing', () => {
  it('parses CRLF-delimited SSE, which is what the standard allows', async () => {
    const body = 'data: {"choices":[{"delta":{"content":"你"}}]}\r\n\r\n'
               + 'data: {"choices":[{"delta":{"content":"好"}}]}\r\n\r\n'
               + 'data: [DONE]\r\n\r\n';
    const provider = bailianWith(fixtureFetch(body));
    assert.equal(await drain(provider), '你好', 'CRLF frames must be parsed, not silently dropped');
  });

  it('parses LF SSE as well', async () => {
    const body = 'data: {"choices":[{"delta":{"content":"a"}}]}\n\n'
               + 'data: {"choices":[{"delta":{"content":"b"}}]}\n\n'
               + 'data: [DONE]\n\n';
    assert.equal(await drain(bailianWith(fixtureFetch(body))), 'ab');
  });

  it('joins multiple data lines of one event', async () => {
    const body = 'data: {"choices":[{"delta":\ndata: {"content":"x"}}]}\n\n'
               + 'data: [DONE]\n\n';
    // Some gateways split a JSON object across data lines; the payload is the joined lines.
    const provider = bailianWith(fixtureFetch(body));
    const text = await drain(provider);
    assert.equal(text, 'x', `multi-line data must be joined, got ${JSON.stringify(text)}`);
  });

  it('survives UTF-8 split across chunk boundaries', async () => {
    // The fixture slices every 7 bytes, which cuts the 3-byte UTF-8 sequences.
    const body = 'data: {"choices":[{"delta":{"content":"汉字😀"}}]}\n\ndata: [DONE]\n\n';
    const text = await drain(bailianWith(fixtureFetch(body)));
    assert.equal(text, '汉字😀', `UTF-8 must not be corrupted, got ${JSON.stringify(text)}`);
  });

  it('reports an explicit error event instead of ending quietly', async () => {
    const body = 'data: {"error":{"message":"quota exceeded","type":"rate_limit"}}\n\n';
    const provider = bailianWith(fixtureFetch(body));
    await assert.rejects(() => drain(provider), (error) => error.code === 'UPSTREAM_ERROR',
      'an error event must surface as UPSTREAM_ERROR, not as an empty answer');
  });

  it('treats an EOF without [DONE] as a truncated answer', async () => {
    const body = 'data: {"choices":[{"delta":{"content":"半句"}}]}\n\n';
    const provider = bailianWith(fixtureFetch(body));
    await assert.rejects(() => drain(provider), (error) => error.code === 'UPSTREAM_TRUNCATED',
      'a stream that stops without a completion marker must not look like success');
  });

  it('maps HTTP status codes to codes the UI can act on', async () => {
    for (const [status, code] of [[401, 'UPSTREAM_UNAUTHORIZED'], [403, 'UPSTREAM_FORBIDDEN'],
      [429, 'UPSTREAM_RATE_LIMITED'], [500, 'UPSTREAM_HTTP']]) {
      const provider = bailianWith(fixtureFetch('', { status }));
      await assert.rejects(() => drain(provider), (error) => error.code === code,
        `HTTP ${status} must map to ${code}`);
    }
  });

  it('stops reading when the signal is aborted', async () => {
    const body = 'data: {"choices":[{"delta":{"content":"a"}}]}\n\n'
               + 'data: {"choices":[{"delta":{"content":"b"}}]}\n\n'
               + 'data: [DONE]\n\n';
    const controller = new AbortController();
    const provider = bailianWith(fixtureFetch(body));
    controller.abort();
    await assert.rejects(() => drain(provider, [{ role: 'user', text: 'x' }], controller.signal),
      (error) => error.name === 'AbortError' || error.code === 'ABORTED');
  });
});
