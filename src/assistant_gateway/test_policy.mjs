// Cross-check the JS policy against the Python reference on the SAME byte strings.
//
// Both implementations are independent, so agreement is evidence and disagreement is a bug in one of them.
// The case list is the interesting part: duplicate keys, booleans posing as integers, floats, strings,
// unknown fields, NaN, out-of-range values, a mixed patch where one field is good and one is bad, and the
// happy paths.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { existsSync } from 'node:fs';

import { review, ProposalRejected, ALLOW } from './policy.mjs';

const here = dirname(fileURLToPath(import.meta.url));

/** Locate a Python interpreter; the cross-check must run, not silently skip. */
function findPython() {
  const candidates = [
    process.env.PYTHON_BIN,
    'python3',
    'python'
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (candidate.includes('/') || candidate.includes('\\')) {
      if (existsSync(candidate)) return candidate;
      continue;
    }
    try {
      execFileSync(candidate, ['--version'], { stdio: 'ignore' });
      return candidate;
    } catch { /* try the next one */ }
  }
  throw new Error('NO_PYTHON_INTERPRETER: the policy cross-check needs one');
}

const py = findPython();

const cases = [
  // [name, raw json text, expected code or null for accept]
  ['accept single field', '{"version":1,"kind":"config_patch","changes":{"chorus_wet_max":8}}', null],
  ['accept several', '{"version":1,"kind":"config_patch","changes":{"next_preset":1,"partial_target":16}}', null],
  ['accept boundary min', '{"version":1,"kind":"config_patch","changes":{"next_octave":0}}', null],
  ['accept boundary max', '{"version":1,"kind":"config_patch","changes":{"chorus_wet_max":64}}', null],
  ['reject duplicate key', '{"version":1,"kind":"config_patch","changes":{"chorus_wet_max":8,"chorus_wet_max":9}}', 'DUPLICATE_KEY'],
  ['reject bool as int', '{"version":1,"kind":"config_patch","changes":{"next_preset":true}}', 'INTEGER_REQUIRED'],
  ['reject float', '{"version":1,"kind":"config_patch","changes":{"next_preset":1.5}}', 'INTEGER_REQUIRED'],
  ['reject string', '{"version":1,"kind":"config_patch","changes":{"next_preset":"1"}}', 'INTEGER_REQUIRED'],
  ['reject null value', '{"version":1,"kind":"config_patch","changes":{"next_preset":null}}', 'INTEGER_REQUIRED'],
  ['reject unknown field', '{"version":1,"kind":"config_patch","changes":{"volume":10}}', 'FIELD_NOT_ALLOWED'],
  ['reject readonly field', '{"version":1,"kind":"config_patch","changes":{"note_zone0":60}}', 'FIELD_NOT_ALLOWED'],
  ['reject NaN', '{"version":1,"kind":"config_patch","changes":{"next_preset":NaN}}', 'NONFINITE_NUMBER'],
  ['reject out of range high', '{"version":1,"kind":"config_patch","changes":{"next_preset":99}}', 'RANGE'],
  ['reject out of range low', '{"version":1,"kind":"config_patch","changes":{"chorus_wet_max":-1}}', 'RANGE'],
  ['reject mixed good and bad', '{"version":1,"kind":"config_patch","changes":{"next_preset":1,"chorus_wet_max":999}}', 'RANGE'],
  ['reject empty changes', '{"version":1,"kind":"config_patch","changes":{}}', 'CHANGES'],
  ['reject extra envelope key', '{"version":1,"kind":"config_patch","changes":{"next_preset":1},"confirmed":true}', 'ENVELOPE'],
  ['reject wrong version', '{"version":2,"kind":"config_patch","changes":{"next_preset":1}}', 'VERSION'],
  ['reject wrong kind', '{"version":1,"kind":"command","changes":{"next_preset":1}}', 'KIND'],
  ['reject not json', 'not json at all', 'INVALID_JSON'],
  ['reject array envelope', '[1,2,3]', 'ENVELOPE'],
  ['reject confirmed flag inside changes', '{"version":1,"kind":"config_patch","changes":{"confirmed":true}}', 'FIELD_NOT_ALLOWED']
];

function jsVerdict(text) {
  try {
    review(Buffer.from(text, 'utf8'));
    return null;
  } catch (error) {
    if (error instanceof ProposalRejected) return error.code;
    throw error;
  }
}

function pyVerdict(text) {
  // The reference implementation is asked through its own module, one process per case: it is a test,
  // not a hot path, and this keeps the two implementations genuinely separate.
  const script = `
import sys, json
sys.path.insert(0, ${JSON.stringify(here)})
from action_policy import review, ProposalRejected
raw = sys.stdin.buffer.read()
try:
    review(raw)
    print("ACCEPT")
except ProposalRejected as exc:
    print(str(exc))
except Exception as exc:
    print("OTHER:" + type(exc).__name__)
`;
  const output = execFileSync(py, ['-c', script], { input: Buffer.from(text, 'utf8') })
    .toString('utf8').trim();
  return output === 'ACCEPT' ? null : output;
}

describe('proposal policy: JS and Python agree', () => {
  for (const [name, text, expected] of cases) {
    it(name, () => {
      const js = jsVerdict(text);
      assert.equal(js, expected, `JS verdict for ${name}`);
      const pv = pyVerdict(text);
      assert.equal(pv, expected, `Python verdict for ${name}`);
      assert.equal(js, pv, `${name}: the two implementations must agree`);
    });
  }

  it('the allow list has exactly the five documented fields', () => {
    assert.deepEqual([...ALLOW].sort(),
      ['chorus_wet_max', 'next_group', 'next_octave', 'next_preset', 'partial_target']);
  });
});
