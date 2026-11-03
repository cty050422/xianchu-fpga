// Pure configuration builder: caller owns reading its LOCAL file. No I/O here.
export function beijingConfig(input={}){
  const c={GATEWAY_PROVIDER:'mock',ASR_MODE:'mock',TTS_MODE:'mock',GATEWAY_AUDIO_MODE:'mock',GATEWAY_ALLOW_PAID_CHAT:'0',GATEWAY_ALLOW_PAID_AUDIO:'0',GATEWAY_DAILY_TURN_LIMIT:'100',BAILIAN_API_KEY:'',BAILIAN_MODEL:'qwen3.8-flash',BAILIAN_BASE_URL:'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',BAILIAN_MAX_TOKENS:'512',BAILIAN_ENABLE_THINKING:'0',BAILIAN_ASR_MODEL:'qwen3-asr-flash',BAILIAN_ASR_URL:'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',BAILIAN_TTS_MODEL:'qwen3-tts-flash',BAILIAN_TTS_URL:'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',BAILIAN_TTS_VOICE:'Cherry',BAILIAN_AUDIO_HOSTS:'dashscope-result-bj.oss-cn-beijing.aliyuncs.com',BAILIAN_TTS_UPGRADE_HTTP:'1'};
  for(const key of Object.keys(c))if(input[key]!==undefined)c[key]=String(input[key]);
  if(!['mock','bailian'].includes(c.GATEWAY_PROVIDER)||!['mock','bailian'].includes(c.ASR_MODE)||!['mock','bailian'].includes(c.TTS_MODE))throw Error('UNKNOWN_PROVIDER_MODE');
  if(c.GATEWAY_PROVIDER==='bailian'&&c.GATEWAY_ALLOW_PAID_CHAT!=='1')throw Error('PAID_CHAT_NOT_ENABLED');
  if((c.ASR_MODE==='bailian'||c.TTS_MODE==='bailian')&&c.GATEWAY_ALLOW_PAID_AUDIO!=='1')throw Error('PAID_AUDIO_NOT_ENABLED');
  if([c.GATEWAY_PROVIDER,c.ASR_MODE,c.TTS_MODE].includes('bailian')&&!c.BAILIAN_API_KEY.trim())throw Error('API_KEY_REQUIRED');
  if(!/^\d+$/.test(c.GATEWAY_DAILY_TURN_LIMIT)||Number(c.GATEWAY_DAILY_TURN_LIMIT)>1000)throw Error('INVALID_DAILY_LIMIT');
  if(!/^\d+$/.test(c.BAILIAN_MAX_TOKENS)||Number(c.BAILIAN_MAX_TOKENS)<64||Number(c.BAILIAN_MAX_TOKENS)>2048)throw Error('INVALID_MAX_TOKENS');
  for(const key of ['BAILIAN_BASE_URL','BAILIAN_ASR_URL','BAILIAN_TTS_URL']){let u;try{u=new URL(c[key])}catch{throw Error('BEIJING_ENDPOINT_REQUIRED')};if(u.protocol!=='https:'||u.username||u.password||u.port||!(/^(dashscope\.aliyuncs\.com|[\w-]+\.cn-beijing\.maas\.aliyuncs\.com)$/.test(u.hostname)))throw Error('BEIJING_ENDPOINT_REQUIRED');}
  return c;
}
