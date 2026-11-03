// Durable budget / idempotency tests (F15).
//
// These are the cases that decide whether the gateway can be left running: a
// restart must not hand out a fresh quota, a corrupt ledger must not look like
// an unused one, a new local day must reset the quota, and a retry after a
// restart must be answered from the on-disk record without calling the provider.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { createGateway } from './server.mjs';
import { MockProvider } from './providers.mjs';
import { FileLedger, localDay } from './ledger_store.mjs';

let workdir;

function tempLedger(name) {
  return path.join(workdir, name);
}

async function start(ledgerFile, limit) {
  const provider = new MockProvider();
  const gateway = createGateway({ provider, ledgerFile, env: { GATEWAY_DAILY_TURN_LIMIT: String(limit) } });
  await new Promise((resolve) => gateway.server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${gateway.server.address().port}`;
  return { gateway, base, provider };
}

async function stop(gateway) {
  await new Promise((resolve) => gateway.server.close(resolve));
}

async function collect(response) {
  const events = [];
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
  return events;
}

async function newConversation(base) {
  const response = await fetch(`${base}/assistant/v1/conversations`, { method: 'POST' });
  return (await response.json()).conversation_id;
}

function turn(base, conversationId, body) {
  return fetch(`${base}/assistant/v1/conversations/${conversationId}/turns`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
  });
}

before(() => { workdir = fs.mkdtempSync(path.join(os.tmpdir(), 'gw-ledger-')); });
after(() => { fs.rmSync(workdir, { recursive: true, force: true }); });

describe('persistent budget ledger', () => {
  it('keeps the used turns across a restart', async () => {
    const file = tempLedger('budget.json');
    const first = await start(file, 3);
    const id = await newConversation(first.base);
    await collect(await turn(first.base, id, { client_turn_id: 'a', text: '第一问' }));
    const healthA = await (await fetch(`${first.base}/assistant/v1/healthz`)).json();
    assert.equal(healthA.limits.turns_used, 1);
    assert.equal(healthA.limits.persistent, true);
    await stop(first.gateway);

    const second = await start(file, 3);
    const healthB = await (await fetch(`${second.base}/assistant/v1/healthz`)).json();
    assert.equal(healthB.limits.turns_used, 1, '重启后不得把已用额度清零');
    await stop(second.gateway);
  });

  it('refuses new turns after a restart when the quota is spent', async () => {
    const file = tempLedger('spent.json');
    const first = await start(file, 1);
    const id = await newConversation(first.base);
    await collect(await turn(first.base, id, { client_turn_id: 'one', text: '唯一一次' }));
    await stop(first.gateway);

    const second = await start(file, 1);
    const id2 = await newConversation(second.base);
    const refused = await turn(second.base, id2, { client_turn_id: 'two', text: '还想再问' });
    assert.equal(refused.status, 429, '重启不得恢复预算');
    assert.equal((await refused.json()).error, 'BUDGET_EXHAUSTED');
    await stop(second.gateway);
  });

  it('answers a retried turn from the on-disk record after a restart, without paying again', async () => {
    const file = tempLedger('replay.json');
    const first = await start(file, 5);
    const id = await newConversation(first.base);
    const events = await collect(await turn(first.base, id, { client_turn_id: 'k1', text: '记住这句话' }));
    const answer = events.find((e) => e.event === 'assistant.done').data.text;
    const usedAfterFirst = first.provider.calls ?? null;
    await stop(first.gateway);

    const second = await start(file, 5);
    const callsBefore = second.provider.calls;
    const replay = await turn(second.base, id, { client_turn_id: 'k1', text: '记住这句话' });
    assert.equal(replay.status, 200);
    const replayEvents = await collect(replay);
    const done = replayEvents.find((e) => e.event === 'assistant.done');
    assert.equal(done.data.text, answer, '重启后的重试必须返回同一答案');
    assert.equal(replayEvents.find((e) => e.event === 'ready').data.restored_after_restart, true);
    assert.equal(second.provider.calls, callsBefore, '重放不得再次调用供应商');
    const health = await (await fetch(`${second.base}/assistant/v1/healthz`)).json();
    assert.equal(health.limits.turns_used, 1, '重放不额外计费');
    assert.equal(typeof usedAfterFirst, 'object');
    await stop(second.gateway);
  });

  it('rolls the quota over on a new local day', () => {
    const file = tempLedger('rollover.json');
    const day1 = new Date('2026-10-23T10:00:00+08:00').getTime();
    const ledger = new FileLedger({ file, limit: 2, now: () => day1 });
    ledger.consume();
    ledger.consume();
    assert.equal(ledger.turns, 2);
    const day2 = new Date('2026-10-24T00:30:00+08:00').getTime();
    const next = new FileLedger({ file, limit: 2, now: () => day2 });
    assert.equal(next.turns, 0, '新的一天应重新计算额度');
    assert.equal(localDay(day2), '2026-10-24');
    assert.equal(localDay(day1), '2026-10-23');
  });

  it('fails closed on a corrupt ledger instead of granting a new budget', () => {
    const file = tempLedger('corrupt.json');
    fs.writeFileSync(file, '{ not json');
    assert.throws(() => new FileLedger({ file, limit: 10 }), /LEDGER_CORRUPT/);
    fs.writeFileSync(file, JSON.stringify({ version: 1, turns: -5, day: '2026-10-23' }));
    assert.throws(() => new FileLedger({ file, limit: 10 }), /LEDGER_CORRUPT/);
  });

  it('writes the ledger atomically and never leaves a partial file', () => {
    const file = tempLedger('atomic.json');
    const ledger = new FileLedger({ file, limit: 4 });
    ledger.consume();
    const written = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(written.turns, 1);
    const leftovers = fs.readdirSync(path.dirname(file)).filter((name) => name.endsWith('.tmp'));
    assert.deepEqual(leftovers, [], '不得遗留临时文件');
  });
});

describe('audit shared-ledger admission',()=>{
 it('cannot overspend through two independently opened ledger instances',()=>{
  const file=tempLedger('shared.json'); const a=new FileLedger({file,limit:1}),b=new FileLedger({file,limit:1});
  a.consume(); assert.throws(()=>b.consume(),/BUDGET_EXHAUSTED/);
  assert.equal(new FileLedger({file,limit:1}).turns,1);
 });
 it('fails closed on a syntactically valid but corrupt ledger day',()=>{
  const file=tempLedger('bad-day.json');
  fs.writeFileSync(file,JSON.stringify({version:1,day:'not-a-day',turns:2,limit:2,replays:{}}));
  assert.throws(()=>new FileLedger({file,limit:2}),/LEDGER_CORRUPT/);
 });
});
