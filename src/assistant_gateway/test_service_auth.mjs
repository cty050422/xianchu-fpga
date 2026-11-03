import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServiceAuth} from './service_auth.mjs';
test('short-code pairing is bounded, expiring and does not expose credentials in public state',()=>{
  let now=1000;const a=createServiceAuth({legacyToken:'legacy-fixture',pairingCode:'123456',clock:()=>now,pairingTtlMs:100,tokenTtlMs:200,maxAttempts:2});
  assert.equal(a.authorized(''),false);
  assert.throws(()=>a.pair('000000'),{code:'PAIR_CODE_INVALID'});
  const p=a.pair('123456');assert.ok(p.access_token.length>=32);assert.equal(a.authorized(p.access_token),true);
  assert.equal(a.status().pairing,true);assert.equal(JSON.stringify(a.status()).includes('123456'),false);assert.equal(JSON.stringify(a.status()).includes(p.access_token),false);
  now=1101;assert.throws(()=>a.pair('123456'),{code:'PAIR_CODE_EXPIRED'});assert.equal(a.authorized(p.access_token),true);
  now=1201;assert.equal(a.authorized(p.access_token),false);
});
test('wrong attempts lock pairing without disabling preexisting authorised clients',()=>{
  const a=createServiceAuth({legacyToken:'legacy-fixture',pairingCode:'123456',maxAttempts:2});
  const p=a.pair('123456');for(let i=0;i<2;i++)assert.throws(()=>a.pair('999999'),{code:'PAIR_CODE_INVALID'});
  assert.throws(()=>a.pair('123456'),{code:'PAIR_LOCKED'});assert.equal(a.authorized(p.access_token),true);assert.equal(a.authorized('legacy-fixture'),true);
});
test('legacy localhost mode remains compatible but cannot pair accidentally',()=>{
  const a=createServiceAuth({});assert.equal(a.authorized(''),true);assert.throws(()=>a.pair('123456'),{code:'PAIR_NOT_ENABLED'});
});
