const test=require('node:test'),assert=require('node:assert/strict');
const {createControlLease}=require('../../src/wechat_miniprogram/services/control_lease');
test('ARM identity may arrive before the first post-auth FPGA status',async()=>{
 let sends=0;const tasks=[];const c=createControlLease({setTimer:f=>(tasks.push(f),tasks.length),clearTimer:()=>{}});
 c.authorize(8,true);c.bind({generation:8,keepAlive:async()=>sends++});
 assert.equal(c.snapshot().authorized,true);assert.equal(tasks.length,1);await tasks.shift()();assert.equal(sends,1);c.close();
});
test('authenticated keepalive survives 30 minutes without re-ARM and page activity',async()=>{
 let time=0,sends=0,armed=0;const tasks=[];
 const c=createControlLease({now:()=>time,setTimer:f=>(tasks.push(f),tasks.length),clearTimer:()=>{}});
 c.bind({generation:7,keepAlive:async()=>{sends++},arm:()=>armed++});c.authorize(7,true);
 for(let i=0;i<360;i++){time+=5000;await tasks.shift()();}
 assert.equal(sends,360);assert.equal(armed,0);c.close();
});
test('old generation, expired authority and background never auto-arm',async()=>{
 let sends=0;const tasks=[];const c=createControlLease({setTimer:f=>(tasks.push(f),tasks.length),clearTimer:()=>{}});
 c.bind({generation:1,keepAlive:async()=>sends++});c.authorize(1,true);const old=tasks.shift();
 c.bind({generation:2,keepAlive:async()=>sends++});c.authorize(1,true);await old();assert.equal(sends,0);
 c.authorize(2,true);c.suspend();await tasks.pop()();assert.equal(sends,0);c.close();
});
