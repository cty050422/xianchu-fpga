import{Worker}from'node:worker_threads';
let running=false;
export function runTranscription(bytes,mime,kind='audio',timeoutMs=20000,quantizeMs=0){
 if(running)return Promise.reject(Object.assign(Error('TRANSCRIPTION_BUSY'),{code:'TRANSCRIPTION_BUSY'}));
 running=true;
 return new Promise((resolve,reject)=>{
  let w;try{w=new Worker(new URL('./transcription_worker.mjs',import.meta.url),{execArgv:[],workerData:{bytes,mime,kind,quantizeMs},resourceLimits:{maxOldGenerationSizeMb:128}})}catch(e){running=false;reject(e);return}let done=false;
  const end=(error,value)=>{if(done)return;done=true;running=false;clearTimeout(timer);w.terminate();error?reject(Object.assign(Error(error),{code:error})):resolve(value)};
  const timer=setTimeout(()=>end('TRANSCRIPTION_TIMEOUT'),timeoutMs);
  w.on('message',m=>end(m.ok?null:m.error,m.output));w.on('error',()=>end('TRANSCRIPTION_FAILED'));w.on('exit',()=>{if(!done)end('TRANSCRIPTION_FAILED')});
 })
}
