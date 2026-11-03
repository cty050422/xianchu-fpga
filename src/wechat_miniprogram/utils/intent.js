// Rule-based Chinese intent parser for the voice assistant. SHARED single
// implementation: the miniprogram uses it for instant local parsing and the
// gateway's /assistant/v1/intent endpoint loads this same file (createRequire)
// so both sides always agree.
//
// Deterministic instrument-related phrasings never touch a paid model; anything
// the rules cannot confidently classify falls through as `open_question` and
// MAY be routed to the text model by the caller (never automatically executed).
//
// Output schema (fixed):
//   { type, params, displayText, requiresConfirm, deviceRequired, alternatives? }
// `requiresConfirm` marks actions that would change the real instrument; the
// page must show them as a confirmation card and never auto-apply.

var BPM_MIN = 30, BPM_MAX = 180

function clampInt(text, min, max) {
  var n = parseInt(text, 10)
  if (!Number.isFinite(n) || n < min || n > max) return null
  return n
}

function parseBpm(text) {
  var patterns = [
    /(?:速度|节拍|拍速|节奏|bpm|BPM)[^0-9]{0,8}(\d{2,3})/,
    /(\d{2,3})\s*(?:BPM|bpm|拍每分钟|拍\/ ?分|拍)/
  ]
  for (var i = 0; i < patterns.length; i++) {
    var m = text.match(patterns[i])
    if (m) return clampInt(m[1], BPM_MIN, BPM_MAX)
  }
  return null
}

function parse(text) {
  var t = String(text || '').trim()
  if (!t) return { type: 'invalid', params: {}, displayText: '没有识别到内容', requiresConfirm: false, deviceRequired: false }
  var extended=parseControl(t)
  if(extended)return extended

  // ---- guide control -----------------------------------------------------
  if (/(开始|启动|继续|开).{0,6}(引导|指引|练习|练习模式)/.test(t) || /^(?:开始|启动)练习$/.test(t))
    return { type: 'start_guide', params: {}, displayText: '开始 LED 引导（需 FPGA 确认）', requiresConfirm: true, deviceRequired: true }
  if (/(停止|停|结束|暂停|关).{0,6}(引导|指引|练习|练习模式)/.test(t))
    return { type: 'stop_guide', params: {}, displayText: '停止 LED 引导（需 FPGA 确认）', requiresConfirm: true, deviceRequired: true }

  // ---- BPM ----------------------------------------------------------------
  var bpm = parseBpm(t)
  if (bpm !== null && /(改|调|变|设|设置|换|降到|升到|到|成|为)/.test(t))
    return { type: 'set_bpm', params: { bpm: bpm }, displayText: '把练习速度改为 ' + bpm + ' BPM（重新编译后需确认上传）', requiresConfirm: true, deviceRequired: true }
  if (bpm !== null && /^(?:速度)?\s*\d{2,3}\s*(?:BPM|bpm|拍)/.test(t))
    return { type: 'set_bpm', params: { bpm: bpm }, displayText: '把练习速度改为 ' + bpm + ' BPM（重新编译后需确认上传）', requiresConfirm: true, deviceRequired: true }

  // ---- status query -------------------------------------------------------
  if (/(什么状态|状态怎么|现在状态|当前状态|连接了吗|还连着|校准了吗|校准状态|引导中|指引状态|引导状态)/.test(t) || /^(?:状态|连接状态|校准|引导状态)$/.test(t))
    return { type: 'query_status', params: {}, displayText: '查询连接 / 校准 / 引导状态', requiresConfirm: false, deviceRequired: false }

  // ---- timbre suggestions --------------------------------------------------
  // Asking what a timbre/effect means is conversation, not a control request.
  if (/^(?:什么是|请解释|解释一下|介绍一下|请介绍|为什么|为何|如何理解|怎么理解|讲讲)/.test(t) || /(?:有什么区别|的区别|是什么意思|是什么[?？]?$)/.test(t))
    return { type: 'open_question', params: { text: t }, displayText: '音乐问题（不会触碰乐器）', requiresConfirm: false, deviceRequired: false }
  if (/(拨弦|弹拨|弹拨类|拨弦类)/.test(t))
    return { type: 'suggest_preset', params: { preset: 0 }, displayText: '建议切换下一音为拨弦类音色（仅影响下一次上音）', requiresConfirm: true, deviceRequired: true }
  if (/(吹管|管乐|吹奏)/.test(t))
    return { type: 'suggest_preset', params: { preset: 1 }, displayText: '建议切换下一音为吹管类音色（仅影响下一次上音）', requiresConfirm: true, deviceRequired: true }

  // ---- partial / chorus suggestions ---------------------------------------
  var pm = t.match(/(?:分量|泛音|谐波|加法)[^0-9]{0,6}(\d{1,2})/)
  if (pm) {
    var partials = clampInt(pm[1], 2, 32)
    if (partials === null) return { type: 'invalid', params: {}, displayText: '分量数量必须在 2–32 之间', requiresConfirm: false, deviceRequired: false }
    return { type: 'suggest_partials', params: { value: partials }, displayText: '建议把加法分量上限设为 ' + partials + '（字段16）', requiresConfirm: true, deviceRequired: true }
  }
  if (/合唱/.test(t)) {
    var cm = t.match(/(\d{1,3})/)
    if (/(关|不要|去掉|零)/.test(t)) return { type: 'suggest_chorus', params: { wet: 0 }, displayText: '建议关闭合唱（湿度 0）', requiresConfirm: true, deviceRequired: true }
    if (cm) {
      var wet = clampInt(cm[1], 0, 64)
      if (wet !== null) return { type: 'suggest_chorus', params: { wet: wet }, displayText: '建议把合唱湿度上限设为 ' + wet + '（字段17）', requiresConfirm: true, deviceRequired: true }
    }
    if (/(开|加|来点)/.test(t)) return { type: 'suggest_chorus', params: { wet: 32 }, displayText: '建议开启适度合唱（湿度上限 32）', requiresConfirm: true, deviceRequired: true }
  }

  // ---- song select ---------------------------------------------------------
  var selm = t.match(/(?:选择|选用|切换到?|换成|播放|来一首|来首|弹|练习一下)(?:一首)?(.{1,24}?)(?:吧|呢|这首)?$/)
  if (selm && selm[1] && !/怎么|如何|是什么|为什么/.test(selm[1])) {
    return { type: 'select', params: { q: selm[1].trim() }, displayText: '在曲库中匹配「' + selm[1].trim() + '」，匹配后仍需你确认上传', requiresConfirm: true, deviceRequired: false }
  }

  // ---- song search ----------------------------------------------------------
  var params = {}
  var m = t.match(/(?:慢速|慢一点|慢些|慢的|放慢)/)
  if (m) { params.bpmMax = 90; params.speedLabel = '慢速' }
  m = t.match(/(?:快速|快一点|快些|快的|加速)/)
  if (m) { params.bpmMin = 110; params.speedLabel = '快速' }
  m = t.match(/难度\s*([1-5])|简单|入门|中等|困难|难一点/)
  if (m) {
    if (/[1-5]/.test(m[1])) params.difficulty = parseInt(m[1], 10)
    else if (/简单|入门/.test(m[0])) params.maxDifficulty = 2
    else if (/中等/.test(m[0])) params.difficulty = 3
    else params.difficulty = 4
  }
  m = t.match(/(?:节奏|表达|保持|音阶|琶音|旋律|耐力|分段|综合|入门|慢速|快速|儿歌|古典|原创)/)
  if (m && t.indexOf('找') >= 0 || t.indexOf('搜') >= 0 || t.indexOf('来点') >= 0 || t.indexOf('推荐') >= 0) {
    var tagm = t.match(/(?:节奏|表达|保持|音阶|琶音|旋律|耐力|分段|综合|入门|儿歌|古典|原创)练习?/)
    if (tagm) params.tag = tagm[0].replace(/练习$/, '')
  }
  var searchm = t.match(/(?:找|搜索|搜一下|查一下|查找|来点|推荐|有没有).{0,4}?(?:一(?:首|个|点))?(.{0,20}?)(?:的)?(?:练习|曲子|曲目|曲谱|歌)?(?:吧|呢)?$/)
  if (/(找|搜索|搜一下|查一下|查找|来点|推荐|有没有)/.test(t)) {
    var q = ''
    if (searchm && searchm[1]) q = searchm[1].trim()
    if (q && !params.tag && !params.speedLabel && !params.difficulty && !params.maxDifficulty && !params.bpmMax && !params.bpmMin) q = q
    else if (q && (params.tag || params.speedLabel)) q = '' // "找一首慢速练习" → speed search, not title search
    params.q = q
    var desc = []
    if (q) desc.push('标题/标签含「' + q + '」')
    if (params.speedLabel) desc.push(params.speedLabel)
    if (params.tag) desc.push('标签「' + params.tag + '」')
    if (params.difficulty) desc.push('难度' + params.difficulty)
    if (params.maxDifficulty) desc.push('难度≤' + params.maxDifficulty)
    return { type: 'search', params: params, displayText: '在曲库中搜索：' + (desc.join('、') || '全部'), requiresConfirm: false, deviceRequired: false }
  }

  // Nothing matched with confidence → open question for the text model.
  return { type: 'open_question', params: { text: t }, displayText: '这句我会交给文字助手解释（不会触碰乐器）', requiresConfirm: false, deviceRequired: false }
}

function result(type,params,confirm,device){return {type:type,params:params||{},displayText:type,requiresConfirm:!!confirm,deviceRequired:!!device}}
function ordinal(s){if(/^\d+$/.test(s))return Number(s);var n={'一':1,'二':2,'两':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9,'十':10};if(n[s])return n[s];var m=s.match(/^([一二三四五六七八九]?)十([一二三四五六七八九]?)$/);return m?(m[1]?n[m[1]]:1)*10+(m[2]?n[m[2]]:0):NaN}
function midi(s){var m=s.match(/^([A-Ga-g])([#b]?)([0-8])$/);if(!m)return null;var n=(Number(m[3])+1)*12+{C:0,D:2,E:4,F:5,G:7,A:9,B:11}[m[1].toUpperCase()]+(m[2]==='#'?1:m[2]==='b'?-1:0);return n>=36&&n<=96?n:null}
function parseControl(text){
  var t=text.replace(/[。！!？?]+$/,'').trim().replace(/^(?:(?:请|麻烦|帮我|给我|替我)\s*)+/,''),m
  if(/(?:不要|别|暂不|先不).{0,3}(?:关闭|停止|取消)/.test(t))return result('invalid',{reason:'未更改当前设置'})
  if(/(?:不要|别|不想|暂不|先不).{0,5}(?:下载|上传|开始|启动|切换)/.test(t))return result('invalid',{reason:'已取消操作'})
  if(/^(?:什么是|请解释|解释一下|介绍一下|请介绍|为什么|为何|如何理解|怎么理解|讲讲|(?:我想)?了解|(?:我想)?知道)/.test(t)||/(?:有什么区别|的区别|怎么做|有什么用|是什么意思|是什么)$/.test(t))return result('open_question',{text:text})
  if(/不要|别|暂(?:时)?不|先不|不想|不用/.test(t)&&!/^不要合唱$/.test(t))return result('invalid',{reason:'未执行操作'})
  if(/^(?:帮助|功能|能做什么|你能做什么|操作列表)$/.test(t))return result('help')
  if(/^(?:看看|查看|查询|显示)?(?:成绩|练习成绩|当前成绩)$/.test(t))return result('query_score')
  if(/^(?:当前|现在)(?:曲目|曲子|音色|效果|模式|在练什么)$/.test(t))return result('query_status')
  if(/^(?:我的|查看)?收藏$/.test(t))return result('list_favorites')
  if(/^(?:取消收藏|不再收藏)(?:这首|当前曲目)?$/.test(t))return result('favorite',{enabled:false})
  if(/^收藏(?:这首|当前曲目)?$/.test(t))return result('favorite',{enabled:true})
  if(/^(?:下一段|继续下载下一段|上传下一段)$/.test(t))return result('step_segment',{delta:1},true,true)
  if(/^上一段$/.test(t))return result('step_segment',{delta:-1},true,true)
  if((m=t.match(/^(?:上传|下载)(?:第)?([\d一二两三四五六七八九十]+)段$/))){var seg=ordinal(m[1]);return Number.isInteger(seg)&&seg>0&&seg<=64?result('upload_segment',{index:seg-1},true,true):result('invalid',{reason:'分段编号无效'})}
  if((m=t.match(/^(?:选|选择|下载|上传|就)?(?:择)?第?([\d一二两三四五六七八九十]+)首(?:吧)?$/))){var index=ordinal(m[1]);return index>0&&index<=60?result('select_result',{index:index-1,target:/下载|上传/.test(t)?'device':'select'},true,false):result('invalid',{reason:'曲目编号无效'})}
  if(/下载|上传|缓存/.test(t)&&!/(?:如何|怎么|为什么)/.test(t)){
    var quoted=t.match(/[《「“]([^》」”]+)[》」”]/)
    var q=quoted?quoted[1]:t.replace(/^.*?(?:在线下载|下载|上传|缓存)/,'').replace(/(?:到|至)(?:手机|本地|缓存|乐器|设备|FPGA|fpga)$/,'').replace(/^(?:曲谱|曲目)\s*/,'').replace(/(?:的曲谱|曲谱)$/,'').trim()
    if(/^(?:这首|这首歌|这首曲子|当前|当前曲目|当前歌曲|所选曲目|它)$/.test(q))q=''
    if(q.length>80||/https?:\/\/|[\\/]/.test(q))return result('invalid',{reason:'请使用曲库中的曲目名称'})
    return result(/缓存|到手机|到本地/.test(t)?'cache_song':'download_song',{q:q},!/缓存|到手机|到本地/.test(t),!/缓存|到手机|到本地/.test(t))
  }
  // An explicit title or song-shaped argument wins over words such as
  // “吹管/钟声/回声” inside that title. Plain timbre controls still fall through.
  if((m=t.match(/^(?:我想)?(?:选择|选用|切换到?|换成|播放|来一首|来首|练习|弹)(?:一首)?(.{1,80}?)(?:吧)?$/))){
    var named=m[1].trim(),title=named.match(/^[《「“]([^》」”]+)[》」”]$/)
    if(title||/(?:练习|练习曲|曲目|曲子|歌曲|之歌|曲)$/.test(named))return result('select',{q:title?title[1]:named},true,false)
  }
  if(/^(?:慢一点|放慢一点|放慢|慢一些)$/.test(t))return result('change_bpm',{delta:-10},true,true)
  if(/^(?:快一点|加快一点|加快|快一些)$/.test(t))return result('change_bpm',{delta:10},true,true)
  if(/^(?:(?:开始|启动|进入|切换到|切到))?(?:节奏)?挑战(?:模式)?$/.test(t))return result('start_challenge',{},true,true)
  if(/^(?:切换到|进入|切到)?自由演奏(?:模式)?$/.test(t))return result('free_play',{},true,true)
  if(/^(?:停止|结束|暂停)(?:演奏|挑战|练习|当前练习)$/.test(t))return result('stop_guide',{},true,true)
  if((m=t.match(/(?:音量|响度)(?:设为|设置为|调到|改成|调成)?\s*(\d{1,3})\s*[%％]$/)))return Number(m[1])<=100?result('set_volume',{percent:Number(m[1])},true,true):result('invalid',{reason:'音量范围为0–100%'})
  if(/^静音$/.test(t))return result('set_volume',{percent:0},true,true)
  if(/^(?:取消静音|恢复原音量)$/.test(t))return result('set_volume',{percent:100},true,true)
  if((m=t.match(/^(?:切换到|切到|使用|改为|换成)?([ABab])组$/)))return result('set_group',{group:m[1].toUpperCase()==='B'?1:0},true,true)
  if(/^(?:切换到|切到|使用|改为|恢复)?(?:标准|正常)八度$/.test(t))return result('set_octave',{octave:0},true,true)
  if(/^(?:切换到|切到|使用|改为)?(?:高八度|升高八度)$/.test(t))return result('set_octave',{octave:1},true,true)
  if((m=t.match(/^四区(?:音高)?(?:设为|改为|设置为)\s*(.+)$/))){var parts=m[1].trim().split(/[\s,，、]+/),values=parts.map(midi);return parts.length===4&&values.every(function(x){return x!==null})?result('set_notes',{notes:values.map(function(x,i){return {field:i+1,value:x}})},true,true):result('invalid',{reason:'需要四个C2–C7范围内的音名'})}
  if((m=t.match(/^([1-4一二三四])区(?:音高)?(?:设为|改为|设置为)\s*(\S+)$/))){var note=midi(m[2]);return note!==null?result('set_notes',{notes:[{field:ordinal(m[1]),value:note}]},true,true):result('invalid',{reason:'音高范围为C2–C7'})}
  if((m=t.match(/^([1-4一二三四])区(?:触发)?(?:门限|阈值)(?:设为|改为|设置为|调到)?\s*(\d+)$/))){var threshold=Number(m[2]);return threshold>=16&&threshold<=4095?result('set_threshold',{field:ordinal(m[1])+4,value:threshold},true,true):result('invalid',{reason:'触发阈值范围为16–4095归一化压力'})}
  if((m=t.match(/合唱(?:强度|上限|湿度)?(?:设为|调到|改为)?\s*(\d{1,3})[%％]$/)))return Number(m[1])<=100?result('suggest_chorus',{wet:Math.round(Number(m[1])*64/100)},true,true):result('invalid',{reason:'合唱上限范围为0–100%'})
  if(!/\d|上限|湿度|强度/.test(t)&&/(?:效果|开启|使用|切换|换成|切到|改为|设为)/.test(t)&&/合唱|回声|干声|原声/.test(t))return result('set_effect',{mode:/合唱/.test(t)&&/回声/.test(t)?3:/回声/.test(t)?1:/合唱/.test(t)?2:0},true,true)
  if(/(?:关闭|取消)(?:所有)?效果$/.test(t))return result('set_effect',{mode:0},true,true)
  if(/(?:换|切|使用|设|用).{0,5}钟声/.test(t))return result('suggest_preset',{preset:2},true,true)
  if(/(?:换|切|使用|设|用).{0,5}(?:合成)?贝[斯司]/.test(t))return result('suggest_preset',{preset:3},true,true)
  if((m=t.match(/^(?:我想)?(?:选(?:择|曲)?|练习|弹)(?:一首)?(.{1,80}?)(?:吧)?$/))&&!/音色|效果|八度|^[ABab]组$/.test(m[1]))return result('select',{q:m[1].replace(/[《》「」“”]/g,'').trim()},true,false)
  return null
}
module.exports = { parse, parseBpm, BPM_MIN: BPM_MIN, BPM_MAX: BPM_MAX }
