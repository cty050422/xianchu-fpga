const signed16=(a,i)=>{const n=a[i]|(a[i+1]<<8);return n&32768?n-65536:n};
const signed8=n=>n>127?n-256:n;
const rod=(axis,d)=>Math.abs(d)<64?'·':axis==='X'?(d>0?'↓':'↑'):(d>0?'→':'←');
function decodeControl(a){
 if(!a||a.length!==31||a[0]!==1||a[1]>3||a[2]>6)return null;
 const u=i=>a[i]|(a[i+1]<<8),voices=a[10]&15,health=a[25],ratio=u(15),depth=u(17),dx=signed16(a,19),dy=signed16(a,21);
 const cents=ratio>0?Math.round(1200*Math.log2(ratio/32768)):0;
 const glide={rod:rod('X',dx),cents,active:!!voices&&!!(health&1)&&ratio!==32768};
 glide.label=a[1]===3?'谱定':!(health&1)?'失鲜':!voices?'待用':ratio===32768?'回中':(cents>=0?'+':'')+cents+'c';
 const vibrato={rod:rod('Y',dy),depth:Math.round(depth*100/2048),active:!!voices&&!!(health&2)&&depth>32};
 vibrato.label=!(health&2)?'失鲜':!voices?'待用':depth<=32?'关':vibrato.depth+'%';
 return {schema:1,mode:a[1],transport:a[2],length:a[3],session:u(4),request:u(6),preset:a[8],layout:a[9],voices,held:a[11],expression:a[12],step:a[13],target:a[14],ratio,depth,dx,dy,health,interrupted:!!(health&32),glide,vibrato,partials:a[23],wet:a[24],j2x:signed16(a,26),j2y:signed16(a,28),effect:a[30],scope:'fpga_final_control'};
}
function createWaveAssembler({now=Date.now}={}){
 let pending=null;
 return {reset(){pending=null},feed(a){
  if(!a||a.length!==38||a[0]!==1||a[1]!==1||a[5]!==8||a[4]>=8){pending=null;return null;}
  const id=a[2]|(a[3]<<8),index=a[4],time=now();
  if(index===0)pending={id,next:0,bytes:[],at:time};
  if(!pending||pending.id!==id||pending.next!==index||time-pending.at>2500){pending=null;return null;}
  pending.bytes.push(...Array.from(a.slice(6)));pending.next++;
  if(pending.next!==8)return null;
  const columns=[];for(let i=0;i<256;i+=2){const lo=signed8(pending.bytes[i]),hi=signed8(pending.bytes[i+1]);if(lo>hi){pending=null;return null;}columns.push([lo,hi]);}
  pending=null;return {id,columns,samples:1024,sampleRate:48000,windowMs:1024/48,at:time,scope:'quantized_final_digital_pcm'};
 }};
}
module.exports={decodeControl,createWaveAssembler,rod};
