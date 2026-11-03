const {test}=require('node:test'),assert=require('node:assert/strict')
const intent=require('../utils/intent')
test('assistant understands catalog destinations, ordinals, segments and device controls',()=>{
  const cases=[
    ['在线下载《玛丽有只小羊羔》到乐器','download_song',{q:'玛丽有只小羊羔'}],
    ['请帮我在线下载《玛丽有只小羊羔》到乐器','download_song',{q:'玛丽有只小羊羔'}],
    ['选玛丽有只小羊羔','select',{q:'玛丽有只小羊羔'}],
    ['下载玛丽有只小羊羔到手机','cache_song',{q:'玛丽有只小羊羔'}],
    ['下载这首到FPGA','download_song',{q:''}],
    ['选第二首','select_result',{index:1}],
    ['下载第2首','select_result',{index:1,target:'device'}],
    ['上传第2段','upload_segment',{index:1}],
    ['下一段','step_segment',{delta:1}],
    ['慢一点','change_bpm',{delta:-10}],
    ['开始挑战','start_challenge',{}],['自由演奏','free_play',{}],
    ['帮我开始挑战','start_challenge',{}],
    ['看看成绩','query_score',{}],['收藏这首','favorite',{enabled:true}],['我的收藏','list_favorites',{}],
    ['换成钟声音色','suggest_preset',{preset:2}],['使用合成贝斯','suggest_preset',{preset:3}],
    ['效果设为回声','set_effect',{mode:1}],['效果设为合唱加回声','set_effect',{mode:3}],
    ['音量设为50%','set_volume',{percent:50}],['静音','set_volume',{percent:0}],
    ['切到B组','set_group',{group:1}],['恢复标准八度','set_octave',{octave:0}],
    ['1区设为C4','set_notes',{notes:[{field:1,value:60}]}],
    ['四区设为C4 D4 E4 G4','set_notes',{notes:[{field:1,value:60},{field:2,value:62},{field:3,value:64},{field:4,value:67}]}]
    ,['1区触发阈值设为512','set_threshold',{field:5,value:512}]
  ]
  for(const [text,type,params]of cases){const r=intent.parse(text);assert.equal(r.type,type,text);for(const [k,v]of Object.entries(params))assert.deepEqual(r.params[k],v,text+' '+k)}
})
test('music explanations, negated downloads, invalid notes and fake file commands never become device writes',()=>{
  for(const text of ['合唱是怎么做出来的？','开始挑战有什么用？','钟声和吹管的区别是什么'])assert.equal(intent.parse(text).type,'open_question',text)
  for(const text of ['不要下载玛丽到乐器','不要关闭合唱','不要把音量设为50%','别用吹管音色','音量设为120%','1区设为C9','上传第0段','1区触发阈值设为0'])assert.equal(intent.parse(text).type,'invalid',text)
  assert.equal(intent.parse('下载钟声练习到乐器').type,'download_song','title containing a timbre is still a song')
  assert.notEqual(intent.parse('执行 rm -rf').type,'download_song')
})

test('explicit song titles and song suffixes take precedence over timbre and effect controls',()=>{
  for(const [text,q]of [['切换到吹管练习','吹管练习'],['换成钟声练习','钟声练习'],['切换到《合成贝斯练习》','合成贝斯练习'],['换成《回声》','回声']]){
    const out=intent.parse(text);assert.equal(out.type,'select',text);assert.equal(out.params.q,q)
  }
  assert.equal(intent.parse('切换到吹管音色').type,'suggest_preset')
})
