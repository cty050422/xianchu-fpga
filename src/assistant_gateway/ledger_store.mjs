// Durable budget and replay ledger for the assistant gateway.
//
// The in-memory counter was a real hole: restarting the process reset the daily
// turn budget to zero, so a user (or a looping client) could spend without
// limit, and a client that lost the answer could not be answered from the
// idempotency record after a restart.
//
// Design choices:
//   * the ledger is a small JSON file written atomically (tmp + rename), so a
//     crash cannot leave a half-written counter;
//   * the day is the local Asia/Shanghai date, matching how the user counts a
//     "day"; a stored ledger from another day rolls the counter to zero but
//     keeps the replay records;
//   * a corrupt or unreadable ledger FAILS CLOSED: the gateway refuses to start
//     rather than silently granting a fresh budget;
//   * replay records are capped and evicted oldest-first, so the file cannot
//     grow without bound.

import fs from 'node:fs';
import path from 'node:path';

const LEDGER_VERSION = 1;
const MAX_REPLAY_RECORDS = 256;

export function localDay(nowMs = Date.now()) {
  const shifted = new Date(nowMs + 8 * 60 * 60 * 1000);
  return shifted.toISOString().slice(0, 10);
}

function defaultState(limit, day) {
  return { version: LEDGER_VERSION, day, turns: 0, limit, replays: {} };
}

export class FileLedger {
  constructor({ file, limit = 200, now = () => Date.now() } = {}) {
    if (!file) throw new Error('LEDGER_FILE_REQUIRED');
    if (!Number.isSafeInteger(limit) || limit < 0 || limit > 10000) throw new Error('INVALID_TURN_BUDGET');
    this.file = file;
    this.now = now;
    this.configuredLimit = limit;
    this.state = this.load(limit);
  }

  load(limit) {
    const today = localDay(this.now());
    let raw;
    try {
      raw = fs.readFileSync(this.file, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') return defaultState(limit, today);
      throw Object.assign(new Error('LEDGER_UNREADABLE'), { code: 'LEDGER_UNREADABLE', cause: error });
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      // Fail closed: an unreadable ledger must not look like an unused budget.
      throw Object.assign(new Error('LEDGER_CORRUPT'), { code: 'LEDGER_CORRUPT', cause: error });
    }
    if (!parsed || parsed.version !== LEDGER_VERSION || typeof parsed.turns !== 'number' ||
        !Number.isSafeInteger(parsed.turns) || parsed.turns < 0 ||
        typeof parsed.day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(parsed.day) ||
        !Number.isFinite(Date.parse(parsed.day+'T00:00:00Z')) ||
        new Date(parsed.day+'T00:00:00Z').toISOString().slice(0,10) !== parsed.day ||
        !parsed.replays || typeof parsed.replays !== 'object' || Array.isArray(parsed.replays)) {
      throw Object.assign(new Error('LEDGER_CORRUPT'), { code: 'LEDGER_CORRUPT' });
    }
    const state = {
      version: LEDGER_VERSION,
      day: typeof parsed.day === 'string' ? parsed.day : today,
      turns: parsed.turns,
      limit,
      replays: parsed.replays && typeof parsed.replays === 'object' ? parsed.replays : {}
    };
    return this.rollover(state, today);
  }

  rollover(state, today) {
    if (state.day >= today) return state; // A backwards clock cannot grant a new quota.
    // A new local day starts a new budget; replay records stay so a retry of
    // yesterday's turn is still answered instead of being charged again.
    state.day = today;
    state.turns = 0;
    return state;
  }

  touch() {
    this.state = this.load(this.configuredLimit);
    return this.state;
  }

  get limit() { return this.state.limit; }

  get turns() { return this.touch().turns; }

  transaction(change) {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const lock = this.file + '.lock';
    try { fs.mkdirSync(lock); }
    catch (error) {
      if (error.code === 'EEXIST') throw Object.assign(new Error('LEDGER_BUSY'),{code:'LEDGER_BUSY'});
      throw error;
    }
    try {
      this.state = this.load(this.configuredLimit);
      const result = change(this.state);
      this.save();
      return result;
    } finally { fs.rmdirSync(lock); }
  }

  set turns(value) {
    this.transaction(state => {
      if (!Number.isSafeInteger(value) || value < state.turns || value > state.limit)
        throw Object.assign(new Error('INVALID_TURN_BUDGET'),{code:'INVALID_TURN_BUDGET'});
      state.turns = value;
    });
  }

  consume() {
    return this.transaction(state => {
      if (state.turns >= state.limit)
        throw Object.assign(new Error('BUDGET_EXHAUSTED'),{code:'BUDGET_EXHAUSTED'});
      return ++state.turns;
    });
  }

  remember(conversationId, clientTurnId, text, answer) {
    if (!conversationId || !clientTurnId) return;
    return this.transaction(state => {
    const key = `${conversationId}:${clientTurnId}`;
    state.replays[key] = { text, answer, at: this.now() };
    const keys = Object.keys(state.replays);
    if (keys.length > MAX_REPLAY_RECORDS) {
      keys.sort((a, b) => (state.replays[a].at || 0) - (state.replays[b].at || 0));
      for (const stale of keys.slice(0, keys.length - MAX_REPLAY_RECORDS)) delete state.replays[stale];
    }
    });
  }

  recall(conversationId, clientTurnId) {
    if (!conversationId || !clientTurnId) return null;
    const state = this.touch();
    const record = state.replays[`${conversationId}:${clientTurnId}`];
    return record || null;
  }

  snapshot() {
    const state = this.touch();
    return { day: state.day, turns: state.turns, limit: state.limit,
      replays: Object.keys(state.replays).length };
  }

  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.${process.pid}.tmp`;
    const fd = fs.openSync(tmp, 'w', 0o600);
    try { fs.writeFileSync(fd, JSON.stringify(this.state)); fs.fsyncSync(fd); }
    finally { fs.closeSync(fd); }
    fs.renameSync(tmp, this.file);
  }
}

export function openLedger(options) {
  return new FileLedger(options);
}
