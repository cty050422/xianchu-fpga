// Assembly contract confirmed by the performer: X+ down, Y+ right, both sticks.
// Existing score expressions allow EITHER sign; no per-step direction is encoded.
function axisDirections(joystick,axis){
  if(![1,2].includes(joystick)||!['X','Y'].includes(axis))return null
  return {joystick,axis,positive:axis==='X'?'↓':'→',negative:axis==='X'?'↑':'←'}
}
function expressionGuidance(status){
  const f=status.flags||0
  const mode=status.mode==null?((f&2)?1:0):status.mode
  if(!(f&2)||!(f&16)||(f&12)||![1,2].includes(mode))return {text:'普通演奏',cue:null}
  if(status.mappingReady===false)return {text:'曲谱需重传',cue:null}
  // Marker bit7 distinguishes v2 rest from a legacy single-target frame.
  const mask=status.extended?status.targetMask:(status.targetMask||(1<<(status.target&3)))
  if(!mask)return {text:'休止 · 保持松开',cue:null}
  if(status.expression===1)return {text:'滑音 · 摇杆1 X轴\n↓ + 升音　↑ − 降音',cue:axisDirections(1,'X')}
  if(status.expression===2)return {text:'颤音 · 摇杆1 Y轴\n→ +　← −　推住即可',cue:axisDirections(1,'Y')}
  return {text:status.expression===0?'按目标FSR演奏':'未知表达',cue:null}
}
const AXIS_LEGENDS=[
  {label:'摇杆1 X · 滑音',value:'↓ + 升音　↑ − 降音'},
  {label:'摇杆1 Y · 颤音',value:'→ +　← −　推住即可'},
  {label:'摇杆2 X · 分量',value:'↓ +　↑ −'},
  {label:'摇杆2 Y · 湿声',value:'→ +　← −'}
]
module.exports={axisDirections,expressionGuidance,AXIS_LEGENDS}
