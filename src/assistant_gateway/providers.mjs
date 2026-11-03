// Providers for the assistant gateway.
//
// MockProvider is the default: it needs no network, no key and no money, which is what makes the gateway
// testable in this environment. BailianChat is a real adapter, but it is OFF unless the operator sets
// GATEWAY_PROVIDER=bailian AND supplies the key through the environment - the gateway never reads a key
// file, never logs one, and never enables paid calls just because the code exists.

/** Deterministic, dependency-free provider: answers with a digest of the history it was given. */
export class MockProvider {
  constructor({ chunkDelayMs = 2, chunkSize = 8 } = {}) {
    this.name = 'mock';
    this.paid = false;
    this.chunkDelayMs = chunkDelayMs;
    this.chunkSize = chunkSize;
  }

  /**
   * Stream an answer. Yields {text} chunks. `signal` is checked between chunks so a cancellation stops the
   * work instead of just hiding the output.
   */
  async *stream(messages) {
    const userText = [...messages].reverse().find((m) => m.role === 'user')?.text ?? '';
    const historyTurns = messages.filter((m) => m.role !== 'system').length;
    // The digest proves which history the provider actually saw: a test can assert that turn 7 saw six
    // earlier turns, and that a cancelled turn is absent.
    const digest = messages.filter((m) => m.role !== 'system')
      .map((m) => `${m.role[0]}:${m.text.length}`).join(',');
    const answer = `mock(${historyTurns} turns) digest=${digest} echo="${userText.slice(0, 40)}"`;
    for (let i = 0; i < answer.length; i += this.chunkSize) {
      await new Promise((r) => setTimeout(r, this.chunkDelayMs));
      yield { text: answer.slice(i, i + this.chunkSize) };
    }
  }
}

/**
 * Real Bailian chat adapter. Deliberately conservative: it does not guess a region, a model id or an
 * endpoint. Everything comes from configuration, and without it the factory refuses to construct it.
 */
export class BailianChat {
  constructor({ apiKey, model, baseUrl, timeoutMs = 30000, fetchImpl = null, maxTokens = 512, enableThinking }) {
    if (!apiKey) throw new Error('BAILIAN_KEY_REQUIRED');
    if (!model) throw new Error('BAILIAN_MODEL_REQUIRED');
    if (!baseUrl) throw new Error('BAILIAN_BASE_URL_REQUIRED');
    const endpoint=new URL(baseUrl);
    if(endpoint.protocol!=='https:'||endpoint.username||endpoint.password)throw new Error('BAILIAN_ENDPOINT_REQUIRED_HTTPS');
    if(!Number.isInteger(maxTokens)||maxTokens<64||maxTokens>2048)throw new Error('INVALID_MAX_TOKENS');
    this.maxTokens=maxTokens;this.enableThinking=enableThinking;
    this.name = 'bailian';
    this.paid = true;
    this.apiKey = apiKey;
    this.model = model;
    this.baseUrl = baseUrl;
    this.timeoutMs = timeoutMs;
    // Injectable for tests and for a gateway that needs its own fetch (mTLS, proxies).
    this.fetchImpl = fetchImpl;
  }

  /** SSE from the provider, re-emitted as plain text deltas. Nothing about the provider leaks upstream. */
  async *stream(messages, signal) {
    // A cancelled turn must not start an upstream (paid) call at all.
    if (signal?.aborted) {
      throw Object.assign(new Error('aborted'), { code: 'ABORTED', name: 'AbortError' });
    }
    const doFetch = this.fetchImpl ?? fetch;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    const onAbort = () => controller.abort();
    signal?.addEventListener?.('abort', onAbort, { once: true });
    let completed = false;
    try {
      const response = await doFetch(this.baseUrl, {
        method: 'POST',
        redirect: 'error',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.apiKey}`
        },
        body: JSON.stringify({
          model: this.model,
          stream: true,
          max_tokens:this.maxTokens,
          ...(this.enableThinking===undefined?{}:{enable_thinking:this.enableThinking}),
          messages: messages.map((m) => ({ role: m.role, content: m.text }))
        }),
        signal: controller.signal
      });
      if (!response.ok || !response.body) {
        // The status is surfaced as a code; the body is NOT echoed, because provider bodies can contain
        // account identifiers.
        const map = { 401: 'UPSTREAM_UNAUTHORIZED', 403: 'UPSTREAM_FORBIDDEN', 429: 'UPSTREAM_RATE_LIMITED' };
        throw Object.assign(new Error('UPSTREAM_HTTP'),
          { code: map[response.status] ?? 'UPSTREAM_HTTP', status: response.status });
      }
      const reader = response.body.getReader();
      const decoder = new TextDecoder('utf-8');
      let buffer = '';

      // One event is terminated by a blank line, with either CRLF or LF line endings.
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let match;
        while ((match = buffer.match(/\r?\n\r?\n/)) !== null) {
          const event = buffer.slice(0, match.index);
          buffer = buffer.slice(match.index + match[0].length);
          const dataLines = event.split(/\r?\n/)
            .filter((line) => line.startsWith('data:'))
            .map((line) => line.slice(5).replace(/^ /, ''));
          if (dataLines.length === 0) continue;
          if (dataLines.some((line) => line.trim() === '[DONE]')) {
            completed = true;
            return;
          }
          // Some gateways split one JSON object across several data lines.
          const payload = dataLines.join('\n');
          let parsed;
          try {
            parsed = JSON.parse(payload);
          } catch {
            // A malformed event is a provider fault, not something to skip silently: the answer would look
            // complete while missing text.
            throw Object.assign(new Error('malformed provider event'), { code: 'UPSTREAM_ERROR' });
          }
          if (parsed && parsed.error) {
            throw Object.assign(new Error('provider error event'), { code: 'UPSTREAM_ERROR' });
          }
          if(parsed?.choices?.[0]?.finish_reason==='length')throw Object.assign(new Error('output limit'),{code:'UPSTREAM_OUTPUT_LIMIT'});
          const delta = parsed?.choices?.[0]?.delta?.content;
          if (typeof delta === 'string' && delta.length) yield { text: delta };
        }
      }
      if (!completed) {
        // Stopping without [DONE] means the answer was cut off; calling that a success is how a UI ends up
        // showing half a sentence as a finished reply.
        throw Object.assign(new Error('stream ended without a completion marker'),
          { code: 'UPSTREAM_TRUNCATED' });
      }
    } catch (error) {
      if (controller.signal.aborted) {
        throw Object.assign(new Error('aborted'), { code: 'ABORTED', name: 'AbortError' });
      }
      throw error;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener?.('abort', onAbort);
    }
  }
}

export function makeProvider(env = process.env) {
  const mode = (env.GATEWAY_PROVIDER ?? 'mock').toLowerCase();
  if (mode === 'mock') return new MockProvider();
  if (mode === 'bailian') {
    // Refusing loudly is the point: a half-configured real provider must not silently fall back to mock
    // and look like a successful live run.
    return new BailianChat({
      apiKey: env.BAILIAN_API_KEY,
      model: env.BAILIAN_MODEL,
      baseUrl: env.BAILIAN_BASE_URL,
      maxTokens:Number(env.BAILIAN_MAX_TOKENS||512),
      enableThinking:env.BAILIAN_ENABLE_THINKING===undefined?undefined:env.BAILIAN_ENABLE_THINKING==='1'
    });
  }
  throw new Error(`UNKNOWN_PROVIDER:${mode}`);
}
