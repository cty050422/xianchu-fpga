import {randomBytes,timingSafeEqual} from 'node:crypto';
const fail=code=>Object.assign(new Error(code),{code});
function equal(a,b){if(typeof b!=='string')return false;const x=Buffer.from(a),y=Buffer.from(b);return x.length===y.length&&timingSafeEqual(x,y);}
export function createServiceAuth({legacyToken='',pairingCode='',clock=Date.now,pairingTtlMs=600000,tokenTtlMs=7200000,maxAttempts=5}={}){
  if(pairingCode&&!/^\d{6}$/.test(pairingCode))throw fail('INVALID_PAIR_CODE_CONFIG');
  const pairingExpires=clock()+pairingTtlMs,tokens=new Map();let attempts=0;
  function prune(){for(const [token,expires]of tokens)if(clock()>=expires)tokens.delete(token);}
  return {
    authorized(value){
      if(legacyToken&&equal(legacyToken,value))return true;
      if(!legacyToken&&!pairingCode)return true;
      prune();return typeof value==='string'&&tokens.has(value);
    },
    renew(value){
      prune();if(typeof value!=='string'||!tokens.has(value))throw fail('SESSION_EXPIRED_OR_RESTARTED');
      const expires=clock()+tokenTtlMs;tokens.set(value,expires);return {access_token:value,expires_at:expires};
    },
    pair(code){
      if(!pairingCode)throw fail('PAIR_NOT_ENABLED');
      if(clock()>=pairingExpires)throw fail('PAIR_CODE_EXPIRED');
      if(attempts>=maxAttempts)throw fail('PAIR_LOCKED');
      if(!equal(pairingCode,code)){attempts++;throw fail('PAIR_CODE_INVALID');}
      prune();if(tokens.size>=8)throw fail('PAIR_CLIENT_LIMIT');
      const token=randomBytes(32).toString('base64url'),expires=clock()+tokenTtlMs;
      tokens.set(token,expires);return {access_token:token,expires_at:expires};
    },
    status(){return {required:Boolean(legacyToken||pairingCode),pairing:Boolean(pairingCode)&&clock()<pairingExpires&&attempts<maxAttempts};}
  };
}
