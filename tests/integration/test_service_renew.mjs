import {test}from'node:test';import assert from'node:assert/strict';
import{createServiceAuth}from'../../src/assistant_gateway/service_auth.mjs';
test('authorized session extends without reusing six digit code; restart stays distinct',()=>{
 let now=0;const a=createServiceAuth({pairingCode:'123456',clock:()=>now});const t=a.pair('123456');
 now=7199000;const r=a.renew(t.access_token);assert.equal(r.access_token,t.access_token);assert(r.expires_at>t.expires_at);
 now=7201000;assert(a.authorized(t.access_token));assert.throws(()=>a.renew('other'));
 const b=createServiceAuth({pairingCode:'654321',clock:()=>now});assert.throws(()=>b.renew(t.access_token));
 now=r.expires_at;assert.throws(()=>a.renew(t.access_token));
});
