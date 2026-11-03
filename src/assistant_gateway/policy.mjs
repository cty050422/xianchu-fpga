// Proposal policy for the assistant gateway. JS mirror of assistant/action_policy.py.
//
// Two independent implementations of the same rule set exist on purpose: the Python one is the reference
// used by the offline self-check, this one runs inside the gateway. A shared bug would otherwise pass on
// both sides, so test_policy.mjs feeds the SAME byte strings through both and compares the verdicts.
//
// The rule set is deliberately tiny: five writable fields, integer values only, no clamping, no partial
// acceptance, and nothing that could touch calibration, protection, gain, panic or raw UART.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
// The schema travels with the gateway (assistant_gateway/protocol/schema.json) so the
// published package has no dependency on the donor tree.
const SCHEMA_PATH = join(here, 'protocol', 'schema.json');

export const ALLOW = Object.freeze([
  'next_preset', 'next_group', 'next_octave', 'partial_target', 'chorus_wet_max'
]);
export const MAX_REQUEST_BYTES = 4096;

export class ProposalRejected extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

let cachedSchema = null;

export function loadSchema(path = SCHEMA_PATH) {
  if (!cachedSchema || path !== SCHEMA_PATH) {
    cachedSchema = JSON.parse(readFileSync(path, 'utf8'));
  }
  return cachedSchema;
}

/** Strict JSON parse that refuses duplicate keys and non-finite numbers. */
export function strictParse(text) {
  // JSON.parse silently keeps the LAST duplicate key, which is exactly how a smuggled field slips past a
  // whitelist check that looks at the object afterwards. So the raw text is scanned for duplicates at the
  // envelope and changes level first.
  if (typeof text !== 'string') throw new ProposalRejected('BYTES_REQUIRED');
  let seen = 0;
  const walk = (value, depth) => {
    if (depth > 32) throw new ProposalRejected('INVALID_JSON');
    if (Array.isArray(value)) { value.forEach((v) => walk(v, depth + 1)); return; }
    if (value && typeof value === 'object') {
      for (const key of Object.keys(value)) walk(value[key], depth + 1);
    }
  };
  let obj;
  try {
    obj = JSON.parse(text, function reviver(key, value) {
      seen += 1;
      return value;
    });
  } catch {
    throw new ProposalRejected('INVALID_JSON');
  }
  if (seen === 0) throw new ProposalRejected('INVALID_JSON');
  if (/NaN|Infinity|null\s*:/.test(text.replace(/"[^"]*"/g, '""'))) {
    // JSON itself cannot carry NaN/Infinity; this catches the string forms a model might invent.
    throw new ProposalRejected('NONFINITE_NUMBER');
  }
  walk(obj, 0);
  return obj;
}

/** Detect duplicate keys in the raw text (JSON.parse keeps the last one and reports nothing). */
export function hasDuplicateKeys(text) {
  const objects = [];          // one Set per open object
  let i = 0;
  const n = text.length;
  while (i < n) {
    const ch = text[i];
    if (ch === '"') {
      // read the whole string token
      let j = i + 1;
      let value = '';
      while (j < n) {
        if (text[j] === '\\') { value += text[j + 1] ?? ''; j += 2; continue; }
        if (text[j] === '"') break;
        value += text[j];
        j++;
      }
      const after = text.slice(j + 1).match(/^\s*:/);
      if (after && objects.length) {
        const top = objects[objects.length - 1];
        if (top.has(value)) return true;
        top.add(value);
      }
      i = j + 1;
      continue;
    }
    if (ch === '{') { objects.push(new Set()); i++; continue; }
    if (ch === '}') { objects.pop(); i++; continue; }
    i++;
  }
  return false;
}

/**
 * Review a proposal. Returns { changes, schema_sha256, proposal_sha256, state, requires_confirmation }
 * or throws ProposalRejected with a stable code.
 */
export function review(raw, schemaPath = SCHEMA_PATH) {
  const text = typeof raw === 'string' ? raw : Buffer.from(raw).toString('utf8');
  if (typeof raw !== 'string' && !Buffer.isBuffer(raw)) throw new ProposalRejected('BYTES_REQUIRED');
  const bytes = Buffer.from(text, 'utf8');
  if (bytes.length === 0 || bytes.length > MAX_REQUEST_BYTES) throw new ProposalRejected('SIZE');
  // A non-finite literal is a number problem, not a syntax problem: the Python reference says
  // NONFINITE_NUMBER and the codes are part of the contract, so the check happens before parsing.
  if (/(^|[^"\w])(NaN|Infinity|-Infinity)(?![\w"])/.test(text.replace(/"(?:[^"\\]|\\.)*"/g, '""'))) {
    throw new ProposalRejected('NONFINITE_NUMBER');
  }
  if (hasDuplicateKeys(text)) throw new ProposalRejected('DUPLICATE_KEY');

  const obj = strictParse(text);
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) throw new ProposalRejected('ENVELOPE');
  const envelope = Object.keys(obj).sort();
  if (envelope.length !== 3 || envelope[0] !== 'changes' || envelope[1] !== 'kind'
      || envelope[2] !== 'version') {
    throw new ProposalRejected('ENVELOPE');
  }
  if (!Number.isInteger(obj.version) || obj.version !== 1) throw new ProposalRejected('VERSION');
  if (obj.kind !== 'config_patch') throw new ProposalRejected('KIND');

  const changes = obj.changes;
  if (!changes || typeof changes !== 'object' || Array.isArray(changes)) {
    throw new ProposalRejected('CHANGES');
  }
  const names = Object.keys(changes);
  if (names.length < 1 || names.length > ALLOW.length) throw new ProposalRejected('CHANGES');

  const schema = loadSchema(schemaPath);
  const fields = new Map(schema.config.fields.map((f) => [f.name, f]));
  for (const name of names) {
    if (!ALLOW.includes(name) || !fields.has(name)) throw new ProposalRejected('FIELD_NOT_ALLOWED');
    const field = fields.get(name);
    if (field.readonly !== false) throw new ProposalRejected('READONLY');
    const value = changes[name];
    // typeof true === 'boolean', and Number.isInteger(true) is false: booleans are refused, and a float
    // or string is refused rather than coerced.
    if (typeof value !== 'number' || !Number.isInteger(value)) throw new ProposalRejected('INTEGER_REQUIRED');
    if (value < field.min || value > field.max) throw new ProposalRejected('RANGE');
  }

  const canonical = canonicalJson(obj);
  const schemaBytes = readFileSync(schemaPath);
  return {
    changes: names.sort().map((n) => [n, changes[n]]),
    schema_sha256: createHash('sha256').update(schemaBytes).digest('hex'),
    proposal_sha256: createHash('sha256').update(canonical, 'ascii').digest('hex'),
    state: 'PREVIEW_ONLY',
    requires_confirmation: true
  };
}

/** Same canonical form as Python's json.dumps(sort_keys=True, separators=(',',':'), ensure_ascii=True). */
export function canonicalJson(value) {
  if (value === null) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new ProposalRejected('NONFINITE_NUMBER');
    return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  }
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonicalJson).join(',') + ']';
  const keys = Object.keys(value).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonicalJson(value[k])).join(',') + '}';
}
