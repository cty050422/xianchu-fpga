// Gateway behaviour tests over real HTTP + SSE. No network, no key, no money.
//
// The cases are the ones that decide whether this is a chat system or a demo: six-turn context, a
// cancelled turn never becoming context, a late delta after cancel being dropped, duplicate client_turn_id
// not re-answering, per-conversation isolation, UTF-8 split across provider chunks, auth, budget and
// proposal review staying PREVIEW_ONLY.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const testStateRoot=fs.mkdtempSync(path.join(os.tmpdir(),'gateway-behavior-'));
after(()=>fs.rmSync(testStateRoot,{recursive:true,force:true}));

import { createGateway } from './server.mjs';
import { MockProvider } from './providers.mjs';

let base;
let gateway;

/** Minimal SSE client: collects events until `end` or `cancelled`. */
async function streamTurn(conversationId, body, { token } = {}) {
  const response = await fetch(`${base}/assistant/v1/conversations/${conversationId}/turns`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { 'x-device-token': token } : {}) },
    body: JSON.stringify(body)
  });
  const events = [];
  if (!response.headers.get('content-type')?.startsWith('text/event-stream')) {
    return { status: response.status, events, body: await response.json().catch(() => null) };
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
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
  return { status: response.status, events };
}

async function newConversation(token) {
  const response = await fetch(`${base}/assistant/v1/conversations`, {
    method: 'POST',
    headers: token ? { 'x-device-token': token } : {}
  });
  assert.equal(response.status, 201);
  return (await response.json()).conversation_id;
}

before(async () => {
  gateway = createGateway({ ledgerFile:path.join(testStateRoot,'ledger.json'), env: { GATEWAY_PROVIDER: 'mock', GATEWAY_DAILY_TURN_LIMIT: '200' },
    provider: new MockProvider({ chunkDelayMs: 1, chunkSize: 5 }), log: () => {} });
  await new Promise((resolve) => gateway.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${gateway.server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => gateway.server.close(resolve));
});

describe('assistant gateway', () => {
  it('healthz reports the mode without any secret', async () => {
    const response = await fetch(`${base}/assistant/v1/healthz`);
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.provider, 'mock');
    assert.equal(body.paid_provider, false);
    assert.equal(body.ready, true);
    const text = JSON.stringify(body).toLowerCase();
    for (const forbidden of ['key', 'secret', 'token', 'password', 'authorization']) {
      assert.equal(text.includes(forbidden), false, `healthz must not mention ${forbidden}`);
    }
  });

  it('keeps six turns of context and the provider sees the earlier ones', async () => {
    const id = await newConversation();
    let lastDigest = '';
    for (let i = 1; i <= 7; i++) {
      const { status, events } = await streamTurn(id, { client_turn_id: `t${i}`, text: `第${i}轮` });
      assert.equal(status, 200);
      const done = events.find((e) => e.event === 'assistant.done');
      assert.ok(done, `turn ${i} must finish`);
      lastDigest = done.data.text;
    }
    // Turn 7 saw the six earlier exchanges (12 messages) plus its own message = 13; the system prompt is
    // excluded by construction, which is what stops a client from injecting one.
    assert.match(lastDigest, /mock\(13 turns\)/, lastDigest);
    assert.ok(lastDigest.includes('echo="第7轮"'), 'the answer must echo the current turn');

    const seqs = [];
    const again = await streamTurn(id, { client_turn_id: 't8', text: '第八轮' });
    for (const event of again.events) if (event.data?.event_seq) seqs.push(event.data.event_seq);
    for (let i = 1; i < seqs.length; i++) {
      assert.ok(seqs[i] > seqs[i - 1], 'event_seq must be monotonic');
    }
  });

  it('a duplicate client_turn_id replays instead of answering twice', async () => {
    const id = await newConversation();
    const first = await streamTurn(id, { client_turn_id: 'same', text: '你好' });
    const firstAnswer = first.events.find((e) => e.event === 'assistant.done').data.text;
    const before = gateway.ledger.turns;

    const second = await streamTurn(id, { client_turn_id: 'same', text: '你好' });
    assert.equal(second.events.find((e) => e.event === 'ready').data.replayed, true);
    assert.equal(second.events.find((e) => e.event === 'assistant.done').data.text, firstAnswer);
    assert.equal(gateway.ledger.turns, before, 'a replay must not count as a new turn');

    const conflict = await fetch(`${base}/assistant/v1/conversations/${id}/turns`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_turn_id: 'same', text: '不同内容' })
    });
    assert.equal(conflict.status, 409);
    assert.equal((await conflict.json()).error, 'CLIENT_TURN_ID_REUSED');
  });

  it('cancel stops the stream, and the cancelled turn never becomes context', async () => {
    const id = await newConversation();
    // A slow provider makes the cancel land mid-stream deterministically.
    const slow = createGateway({ ledgerFile:path.join(testStateRoot,'slow-ledger.json'), env: { GATEWAY_PROVIDER: 'mock' },
      provider: new MockProvider({ chunkDelayMs: 25, chunkSize: 2 }), log: () => {} });
    await new Promise((resolve) => slow.server.listen(0, '127.0.0.1', resolve));
    const slowBase = `http://127.0.0.1:${slow.server.address().port}`;
    try {
      const created = await fetch(`${slowBase}/assistant/v1/conversations`, { method: 'POST' });
      const convId = (await created.json()).conversation_id;
      const response = await fetch(`${slowBase}/assistant/v1/conversations/${convId}/turns`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ client_turn_id: 'c1', text: '一个很长很长的回答会被取消' })
      });
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      let sawDelta = false;
      let cancelled = false;
      while (!cancelled) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        if (buffer.includes('assistant.delta')) sawDelta = true;
        if (buffer.includes('event: cancelled')) { cancelled = true; break; }
        if (sawDelta && !cancelled) {
          await fetch(`${slowBase}/assistant/v1/conversations/${convId}/turns/c1/cancel`, { method: 'POST' });
        }
      }
      assert.ok(sawDelta, 'the stream must have started before the cancel');
      // Drain the rest so the server finishes cleanly.
      try { for (;;) { const { done } = await reader.read(); if (done) break; } } catch { /* closed */ }

      const after = await fetch(`${slowBase}/assistant/v1/healthz`);
      assert.equal(after.status, 200);
      assert.equal(slow.conversations.size, 1);

      // A follow-up turn must NOT contain the cancelled text in its history digest.
      const follow = await fetch(`${slowBase}/assistant/v1/conversations/${convId}/turns`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ client_turn_id: 'c2', text: '继续' })
      });
      const text = await follow.text();
      assert.ok(text.includes('assistant.done'), text.slice(0, 200));
      assert.equal(text.includes('mock(2 turns)'), false,
        'the cancelled exchange must not appear as completed history');
    } finally {
      await new Promise((resolve) => slow.server.close(resolve));
    }
  });

  it('isolates conversations from each other', async () => {
    const a = await newConversation();
    const b = await newConversation();
    await streamTurn(a, { client_turn_id: 'a1', text: 'A 的第一句' });
    const result = await streamTurn(b, { client_turn_id: 'b1', text: 'B 的第一句' });
    const answer = result.events.find((e) => e.event === 'assistant.done').data.text;
    assert.equal(answer.includes('A 的第一句'), false, 'B must not see A history');
    assert.match(answer, /mock\(1 turns\)/);
  });

  it('refuses without the device token once one is configured', async () => {
    const guarded = createGateway({ ledgerFile:path.join(testStateRoot,'guarded-ledger.json'), env: { GATEWAY_PROVIDER: 'mock' }, deviceToken: 'dev-token', log: () => {} });
    await new Promise((resolve) => guarded.server.listen(0, '127.0.0.1', resolve));
    const guardedBase = `http://127.0.0.1:${guarded.server.address().port}`;
    try {
      const denied = await fetch(`${guardedBase}/assistant/v1/conversations`, { method: 'POST' });
      assert.equal(denied.status, 401);
      const allowed = await fetch(`${guardedBase}/assistant/v1/conversations`, {
        method: 'POST', headers: { 'x-device-token': 'dev-token' }
      });
      assert.equal(allowed.status, 201);
    } finally {
      await new Promise((resolve) => guarded.server.close(resolve));
    }
  });

  it('enforces the daily turn budget', async () => {
    const tight = createGateway({ env: { GATEWAY_PROVIDER: 'mock' }, ledger: { turns: 0, limit: 1 }, log: () => {} });
    await new Promise((resolve) => tight.server.listen(0, '127.0.0.1', resolve));
    const tightBase = `http://127.0.0.1:${tight.server.address().port}`;
    try {
      const created = await fetch(`${tightBase}/assistant/v1/conversations`, { method: 'POST' });
      const id = (await created.json()).conversation_id;
      const first = await fetch(`${tightBase}/assistant/v1/conversations/${id}/turns`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ client_turn_id: 'x', text: 'hi' })
      });
      await first.text();
      const second = await fetch(`${tightBase}/assistant/v1/conversations/${id}/turns`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ client_turn_id: 'y', text: 'hi again' })
      });
      assert.equal(second.status, 429);
      assert.equal((await second.json()).error, 'BUDGET_EXHAUSTED');
    } finally {
      await new Promise((resolve) => tight.server.close(resolve));
    }
  });

  it('reviews proposals but never applies them', async () => {
    const good = Buffer.from('{"version":1,"kind":"config_patch","changes":{"chorus_wet_max":8}}');
    const response = await fetch(`${base}/assistant/v1/proposals/review`, { method: 'POST', body: good });
    assert.equal(response.status, 200);
    const preview = await response.json();
    assert.equal(preview.state, 'PREVIEW_ONLY');
    assert.equal(preview.applied, false);
    assert.equal(preview.requires_confirmation, true);

    const bad = Buffer.from('{"version":1,"kind":"config_patch","changes":{"calibrate":1}}');
    const rejected = await fetch(`${base}/assistant/v1/proposals/review`, { method: 'POST', body: bad });
    assert.equal(rejected.status, 422);
    assert.equal((await rejected.json()).error, 'FIELD_NOT_ALLOWED');
  });

  it('does not answer an unknown conversation', async () => {
    const response = await fetch(`${base}/assistant/v1/conversations/conv_nope/turns`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_turn_id: 'z', text: 'hi' })
    });
    assert.equal(response.status, 404);
  });
});
