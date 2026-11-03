// Conversation state for the assistant gateway.
//
// Rules that matter for correctness rather than for looks:
//   * history keeps only COMPLETED turns: a cancelled turn never becomes context, or the model would
//     "remember" something the user never received;
//   * each conversation carries a generation counter; a delta from a cancelled generation is dropped, so a
//     late upstream chunk cannot appear after the user cancelled;
//   * a repeated client_turn_id returns the stored answer instead of generating (and paying) again;
//   * the system prompt is built server-side; a client cannot inject a system role.

export const MAX_TURNS = 12;
export const MAX_CHARS = 4000;
export const MAX_ANSWER_CHARS = 4000;

let counter = 0;

export class Conversation {
  constructor(id, limits) {
    this.id = id;
    this.createdAt = Date.now();
    this.limits = limits;
    this.turns = [];            // completed turns only: {role, text, generation}
    this.seen = new Map();      // client_turn_id -> {text, answer}
    this.pending = null;        // the in-flight user turn, dropped if cancelled
    this.generation = 0;
    this.cancelled = new Set(); // generations that were cancelled
    this.seq = 0;
  }

  nextSeq() { return ++this.seq; }

  /** Start a turn. Returns {generation, replay} where replay is set for a duplicate client_turn_id. */
  begin(clientTurnId, text) {
    if (clientTurnId && this.seen.has(clientTurnId)) {
      const prior = this.seen.get(clientTurnId);
      if (prior.text === text) return { generation: null, replay: prior.answer };
      throw Object.assign(new Error('CLIENT_TURN_ID_REUSED'), { code: 'CLIENT_TURN_ID_REUSED' });
    }
    // One in-flight turn per conversation. Without this, a second begin overwrote `pending` and the first
    // completion left an assistant message whose user message had vanished (FR05).
    if (this.pending) {
      throw Object.assign(new Error('TURN_IN_PROGRESS'), { code: 'TURN_IN_PROGRESS' });
    }
    // maxTurns counts EXCHANGES, not rows: counting rows halved the usable context and made a seven-turn
    // conversation fail with a limit error that looked like a budget problem.
    if (this.completedExchanges() >= this.limits.maxTurns) {
      throw Object.assign(new Error('TURN_LIMIT'), { code: 'TURN_LIMIT' });
    }
    if (typeof text !== 'string' || text.length === 0 || text.length > this.limits.maxChars) {
      throw Object.assign(new Error('TEXT_LIMIT'), { code: 'TEXT_LIMIT' });
    }
    this.generation += 1;
    // The user turn is held as PENDING, not appended: if this turn is cancelled it must leave no trace in
    // the history, or the next request would send the model a message the user cancelled.
    this.pending = { role: 'user', text, generation: this.generation, clientTurnId };
    return { generation: this.generation, replay: null };
  }

  completedExchanges() { return this.turns.filter((t) => t.role === 'assistant').length; }

  /** Release a pending turn that will not run (budget refusal, write error, disconnect). */
  abandonPending(generation) {
    if (this.pending && (generation === undefined || this.pending.generation === generation)) {
      this.pending = null;
    }
  }

  isCancelled(generation) { return this.cancelled.has(generation); }

  cancel(generation) {
    // Cancelling is idempotent, affects only this conversation, and drops the pending user turn.
    this.cancelled.add(generation);
    if (this.pending && this.pending.generation === generation) this.pending = null;
  }

  complete(generation, answer, clientTurnId, text) {
    if (this.cancelled.has(generation)) { this.pending = null; return false; }
    if (this.pending && this.pending.generation === generation) {
      this.turns.push({ role: 'user', text: this.pending.text, generation });
      this.pending = null;
    }
    this.turns.push({ role: 'assistant', text: answer, generation });
    if (clientTurnId) this.seen.set(clientTurnId, { text, answer });
    return true;
  }

  /** The messages a provider sees: system built here, then completed turns in order. */
  messages(systemPrompt) {
    const rows = this.turns.map((t) => ({ role: t.role, text: t.text }));
    // The in-flight user message is included for the CURRENT request only; it never enters `turns` unless
    // the turn completes.
    if (this.pending) rows.push({ role: 'user', text: this.pending.text });
    return [{ role: 'system', text: systemPrompt }, ...rows];
  }

  snapshot() {
    return {
      conversation_id: this.id,
      turns: this.turns.filter((t) => t.role === 'assistant' || t.generation).length,
      completed_turns: this.turns.filter((t) => t.role === 'assistant').length,
      generation: this.generation,
      limits: this.limits
    };
  }
}

export function newConversation(limits = { maxTurns: MAX_TURNS, maxChars: MAX_CHARS }) {
  counter += 1;
  const id = `conv_${Date.now().toString(36)}_${counter.toString(36)}`;
  return new Conversation(id, limits);
}
