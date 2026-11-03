// Shared non-secret configuration for the gateway, music entry and PC probe.
export const DEFAULT_SERVICE_PORT=8893;
export function servicePort(env=process.env){
  const raw=String(env.XIANCHU_RECORDING_PORT||env.GATEWAY_PORT||DEFAULT_SERVICE_PORT);
  if(!/^\d+$/.test(raw)||Number(raw)<1024||Number(raw)>65535)throw Error('INVALID_SERVICE_PORT');
  return Number(raw);
}
export function gatewayUrl(env=process.env){
  if(!env.XIANCHU_GATEWAY_URL)return 'http://127.0.0.1:'+servicePort(env);
  const u=new URL(env.XIANCHU_GATEWAY_URL);
  if(!['http:','https:'].includes(u.protocol)||u.username||u.password||u.search||u.hash||u.pathname!=='/')throw Error('INVALID_GATEWAY_URL');
  return u.origin;
}
