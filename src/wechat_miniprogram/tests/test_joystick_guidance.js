const {test}=require('node:test')
const assert=require('node:assert/strict')
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm')
const {createRequire}=require('node:module')
function page(){
  let p,writes=0;const f=path.resolve(__dirname,'../pages/index/index.js')
  vm.runInNewContext(fs.readFileSync(f,'utf8'),{require:createRequire(f),Page:x=>p=x,console,
    wx:new Proxy({},{get:()=>()=>{writes++;throw Error('Display must not write')}}),setTimeout,clearTimeout})
  p.data=structuredClone(p.data);p.setData=x=>Object.assign(p.data,x)
  return {p,writes:()=>writes}
}
function status(expression,extra={}){return {song:1,flags:0xb3,step:2,target:0,targetMask:1,expression,
  extended:true,mode:1,mappingReady:true,preset:0,effectMode:2,hits:3,wrong:2,misses:1,partials:16,wet:128,commandResult:0,...extra}}
test('guided bend follows assembled J1 X positive down and negative up',()=>{
  const {p,writes}=page();p.applyStatus(status(1))
  assert.match(p.data.expressionText,/摇杆1.*X/)
  assert.match(p.data.expressionText,/↓.*\+.*升音/)
  assert.match(p.data.expressionText,/↑.*[−-].*降音/)
  assert.equal(writes(),0)
})
test('challenge vibrato follows assembled J1 Y positive right and negative left, with hold semantics',()=>{
  const {p,writes}=page();p.applyStatus(status(2,{flags:0xd3,mode:2}))
  assert.match(p.data.expressionText,/摇杆1.*Y/)
  assert.match(p.data.expressionText,/→.*\+/)
  assert.match(p.data.expressionText,/←.*[−-]/)
  assert.match(p.data.expressionText,/推住/)
  assert.equal(p.data.performanceMode,2);assert.equal(writes(),0)
})
test('switching gesture to ordinary, rest, free or fault clears old directional cue',()=>{
  const {p}=page()
  for(const next of [status(0),status(1,{targetMask:0}),status(1,{flags:0x91,mode:0}),
    status(1,{flags:0xbb}),status(1,{flags:0xb7}),status(1,{flags:0xa3}),status(1,{mappingReady:false})]){
    p.applyStatus(status(1));p.applyStatus(next)
    assert.doesNotMatch(p.data.expressionText,/[↑↓→←↔↕]/)
  }
})
test('both joystick axis legends use exactly the user-confirmed assembly orientation',()=>{
  const {axisDirections}=require('../utils/joystick_guidance')
  for(const j of [1,2]){
    assert.deepEqual(axisDirections(j,'X'),{joystick:j,axis:'X',positive:'↓',negative:'↑'})
    assert.deepEqual(axisDirections(j,'Y'),{joystick:j,axis:'Y',positive:'→',negative:'←'})
  }
  assert.equal(axisDirections(0,'X'),null);assert.equal(axisDirections(1,'Z'),null)
})
