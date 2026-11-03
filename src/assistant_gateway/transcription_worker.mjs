import {parentPort,workerData}from'node:worker_threads';
import {inspectMusicAudio}from'./performance_audio.mjs';import {transcribeMono,parseMidi}from'./transcription.mjs';
try{
 const b=Buffer.from(workerData.bytes);let output;
 if(workerData.kind==='midi')output=parseMidi(b,{quantizeMs:workerData.quantizeMs||0});
 else{
 const info=inspectMusicAudio(b,workerData.mime);if(info.durationMs>30000)throw Object.assign(Error('TRANSCRIPTION_LIMIT'),{code:'TRANSCRIPTION_LIMIT'});
 let mono,rate;
 if(info.mime==='audio/wav'){
  let at=12,dataAt=0,size=0;while(at+8<=b.length){const n=b.readUInt32LE(at+4);if(b.toString('ascii',at,at+4)==='data'){dataAt=at+8;size=n;break}at+=8+n+(n&1)}rate=info.sampleRate;mono=new Float32Array(size/(info.channels*2));
  for(let i=0;i<mono.length;i++){let n=0;for(let c=0;c<info.channels;c++)n+=b.readInt16LE(dataAt+(i*info.channels+c)*2)/32768;mono[i]=n/info.channels}
 }else{
  const {MPEGDecoder}=await import('mpg123-decoder');const decoder=new MPEGDecoder();await decoder.ready;
  try{const d=decoder.decode(new Uint8Array(b));if(d.errors.length||!d.samplesDecoded)throw Error('MP3_DECODE');rate=d.sampleRate;mono=new Float32Array(d.samplesDecoded);for(const ch of d.channelData)for(let i=0;i<mono.length;i++)mono[i]+=ch[i]/d.channelData.length}finally{decoder.free()}
 }
 output=transcribeMono(mono,rate);
 }
 parentPort.postMessage({ok:true,output});
}catch(e){parentPort.postMessage({ok:false,error:e.code||'TRANSCRIPTION_FAILED'})}
