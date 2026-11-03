const{test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const{createAuditionSession}=require('../../src/wechat_miniprogram/services/audition_session');
const A=require('../../src/wechat_miniprogram/utils/audition_score');
test('page change does not STOP global FPGA demonstration',()=>{
 let page;const file=path.resolve(__dirname,'../../src/wechat_miniprogram/pages/audition/audition.js');let stops=0;
 vm.runInNewContext(fs.readFileSync(file,'utf8'),{Page:p=>page=p,require:require('node:module').createRequire(file)});
 page.session={pause:()=>{stops++;return Promise.resolve()}};page.onHide();page.onUnload();assert.equal(stops,0);
});
test('finite offline mode is explicit and cannot claim playback on GATT write alone',async()=>{
 let state={hardwareMode:'real',freshness:'fresh',connectionRevision:1,lastStatus:{flags:16},observer:{schema:1}},calls=[];
 const hub={snapshot:()=>state,subscribe:()=>()=>{},auditionCommand:async(op,p)=>{calls.push([op,p]);if(op===30&&p[0])state.lastStatus.flags=112;return {ok:true}}};
 const session=createAuditionSession({hub,setTimer:()=>1,clearTimer:()=>{}});
 await session.play(A.compileTimeline([{startMs:0,endMs:300,notes:[60]}]),0,0,{offline:true});
 assert.equal(calls.find(x=>x[0]===30)[1][0],2);assert.equal(session.snapshot().phase,'playing');await session.stop();
});
