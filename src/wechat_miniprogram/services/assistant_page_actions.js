// Presentation adapter. All device writes go through private confirmed plans.
var createActions=require('./assistant_actions').createAssistantActions
var compiler=require('../utils/score_compiler')
function createAssistantPageActions(env){
  function current(page,g){return !page.disposed&&g===page.commandGeneration}
  function errorText(error){return error&&error.message||error&&error.code||'操作未完成'}
  function displayPlan(page,plan){page.pendingAssistantPlan=plan;page.setData({proposal:plan,searchNote:'',lastAction:''});page.refreshSelectedSong()}
  return {
    actionService:function(){if(!this.assistantActions)this.assistantActions=createActions({hub:env.hub(),catalog:env.catalog(),storage:env.storage()});return this.assistantActions},
    refreshSelectedSong:function(){
      var selected=this.actionService().selected()
      this.setData({selectedSongTitle:selected&&selected.title||'',selectedBpm:selected&&selected.bpm||0,selectedSegment:selected?(selected.segmentIndex||0)+1:0,selectedSegments:selected&&selected.segments||0,canNextSegment:!!selected&&(selected.segmentIndex||0)+1<selected.segments})
    },
    onAssistantHide:function(){this.commandGeneration=(this.commandGeneration||0)+1;this.pendingAssistantPlan=null;if(this.assistantActions)this.assistantActions.discard();if(!this.disposed)this.setData({proposal:null})},
    handleText:function(text){
      if(this.data.actionBusy)return Promise.resolve()
      var page=this,voice=env.voice(),g=this.commandGeneration=(this.commandGeneration||0)+1
      if(this.assistantActions)this.assistantActions.discard()
      this.pendingAssistantPlan=null;this.setData({lastAction:'',errorText:'',proposal:null})
      return voice.askIntent(text).then(function(out){
        if(!current(page,g))return
        var intent=out.intent,p=intent.params||{}
        page.setData({intentType:intent.type,intentText:intent.displayText,searchResults:[],searchNote:'',replyText:''})
        switch(intent.type){
          case 'invalid':page.setData({replyText:p.reason||intent.displayText||'无法识别这项操作'});break
          case 'help':page.setData({replyText:'选曲、下载到手机或乐器、分段、速度、音色、效果、音量、音高映射、练习模式和成绩。\n例如：下载《玛丽有只小羊羔》到乐器。'});break
          case 'search':return page.runSearch(p)
          case 'select':return page.runSelect(p.q,'select')
          case 'download_song':return page.runSelect(p.q,'device')
          case 'cache_song':return page.runSelect(p.q,'phone')
          case 'select_result':return page.selectSearchResult(p.index,p.target)
          case 'set_bpm':return page.proposeBpm(p.bpm)
          case 'change_bpm':{var s=page.actionService().selected();return s?page.proposeBpm(s.bpm+p.delta):page.showActionError('请先选择曲目')}
          case 'upload_segment':return page.proposeSegment(p.index)
          case 'step_segment':{var selected=page.actionService().selected();return selected?page.proposeSegment((selected.segmentIndex||0)+p.delta):page.showActionError('请先选择曲目')}
          case 'query_status':return page.replyStatus()
          case 'query_score':return page.replyScore()
          case 'start_guide':return page.proposeGuide(1)
          case 'start_challenge':return page.proposeGuide(2)
          case 'free_play':case 'stop_guide':return page.proposeGuide(0)
          case 'suggest_preset':return page.proposeConfig('preset',p.preset)
          case 'suggest_partials':return page.proposeConfig('partials',p.value)
          case 'suggest_chorus':return page.proposeConfig('chorus',p.wet)
          case 'set_effect':return displayPlan(page,page.actionService().prepareEffect(p.mode))
          case 'set_volume':return page.proposeConfig('volume',p.percent)
          case 'set_group':return page.proposeConfig('group',p.group)
          case 'set_octave':return page.proposeConfig('octave',p.octave)
          case 'set_notes':return displayPlan(page,page.actionService().prepareConfig(p.notes.concat([{field:22,value:0}]),{title:'演奏区音高',detail:p.notes.map(function(n){return n.field+'区 '+compiler.noteName(n.value)}).join(' · ')+'\n新按下的音生效 · 标准八度'}))
          case 'set_threshold':return displayPlan(page,page.actionService().prepareConfig([{field:p.field,value:p.value}],{title:(p.field-4)+'区触发阈值',detail:p.value+' 归一化压力 · 零点后ADC增量×16'}))
          case 'favorite':return page.setSelectedFavorite(p.enabled)
          case 'list_favorites':return page.showFavorites()
          default:return page.askChat(text)
        }
      }).catch(function(error){if(current(page,g))page.showActionError(errorText(error))})
    },
    showActionError:function(text){this.setData({errorText:String(text),phaseLabel:'未完成'})},
    runSearch:function(params){
      var page=this,g=this.commandGeneration,client=env.catalog()
      if(!client)return this.showActionError('请先连接曲库服务')
      this.resultTarget='select';this.setData({searchNote:'搜索中'})
      return client.list(Object.assign({pageSize:20},params||{})).then(function(result){
        if(!current(page,g))return
        var songs=result.data.songs||[];page.resultSongs=songs
        page.setData({searchResults:songs,searchNote:(result.offline?'离线缓存 · ':'')+(songs.length? songs.length+'首':'没有找到曲目')})
      }).catch(function(e){if(current(page,g))page.showActionError(errorText(e))})
    },
    runSelect:function(query,target){
      var page=this,g=this.commandGeneration,api=this.actionService(),s=api.selected(),client=env.catalog()
      target=target||'select';this.resultTarget=target
      if(!query){if(!s)return this.showActionError('请先选择曲目');return target==='phone'?this.cacheSong(s.songId):this.previewSongForConfirm(s.songId,{bpm:s.bpm,segmentIndex:s.segmentIndex||0})}
      if(!client)return this.showActionError('请先连接曲库服务')
      return client.list({q:query,pageSize:20}).then(function(result){
        if(!current(page,g))return
        var songs=result.data.songs||[],exact=songs.filter(function(song){return song.title===query});if(exact.length===1)songs=exact
        if(result.offline)songs=songs.filter(function(song){return String(song.title||'').indexOf(query)>=0})
        page.resultSongs=songs
        if(songs.length!==1){page.setData({searchResults:songs,searchNote:(result.offline?'离线缓存 · ':'')+(songs.length?'选择曲目':'没有找到「'+query+'」')});return}
        return target==='phone'?page.cacheSong(songs[0].songId):page.previewSongForConfirm(songs[0].songId)
      }).catch(function(e){if(current(page,g))page.showActionError(errorText(e))})
    },
    selectSearchResult:function(index,target){
      var songs=this.resultSongs||this.data.searchResults||[],song=songs[index]
      if(!song)return this.showActionError('请先搜索，再选择列表中的曲目')
      return (target||this.resultTarget)==='phone'?this.cacheSong(song.songId):this.previewSongForConfirm(song.songId)
    },
    onSearchResultTap:function(event){if(this.data.actionBusy)return;this.commandGeneration=(this.commandGeneration||0)+1;var id=event.currentTarget.dataset.id,songs=this.resultSongs||this.data.searchResults||[],index=songs.findIndex(function(s){return s.songId===id});return this.selectSearchResult(index,this.resultTarget)},
    cacheSong:function(songId){
      var page=this,g=this.commandGeneration;this.setData({phaseLabel:'下载曲谱中'})
      return this.actionService().download(songId).then(function(result){if(current(page,g))page.setData({lastAction:(result.source==='cache'?'已读取离线缓存：':'已下载到手机：')+result.entry.score.title,phaseLabel:'完成',proposal:null,searchResults:[]})}).catch(function(e){if(current(page,g))page.showActionError(errorText(e))})
    },
    previewSongForConfirm:function(songId,params){
      var page=this,g=this.commandGeneration;this.setData({phaseLabel:'读取曲谱中'})
      return this.actionService().prepareSong(songId,params).then(function(plan){if(!current(page,g))return;displayPlan(page,plan);page.setData({phaseLabel:'待确认',searchResults:[]})}).catch(function(e){if(current(page,g))page.showActionError(errorText(e))})
    },
    proposeBpm:function(bpm){
      var page=this,g=this.commandGeneration,selected=this.actionService().selected()
      if(!selected){this.setData({proposal:{kind:'bpm',title:'练习速度',detail:'请先选择曲目',disabled:true}});return Promise.resolve()}
      if(!Number.isInteger(bpm)||bpm<compiler.BPM_MIN||bpm>compiler.BPM_MAX)return this.showActionError('速度范围为30–180 BPM')
      return this.actionService().prepareSelected({bpm:bpm}).then(function(plan){if(current(page,g))displayPlan(page,plan)}).catch(function(e){if(current(page,g))page.showActionError(errorText(e))})
    },
    proposeSegment:function(index){
      var page=this,g=this.commandGeneration
      return this.actionService().prepareSelected({segmentIndex:index}).then(function(plan){if(current(page,g))displayPlan(page,plan)}).catch(function(e){if(current(page,g))page.showActionError(errorText(e))})
    },
    proposeGuide:function(mode){displayPlan(this,this.actionService().prepareMode(typeof mode==='boolean'?(mode?1:0):mode))},
    proposeConfig:function(kind,value){
      var fields={preset:20,partials:16,chorus:17,volume:18,group:21,octave:22},names={preset:'音色',partials:'加法分量',chorus:'合唱上限',volume:'音量',group:'音组',octave:'八度'},sets=[{field:fields[kind],value:kind==='volume'?64-Math.round(value*64/100):value}]
      if(kind==='volume'&&(!Number.isInteger(value)||value<0||value>100))throw Object.assign(new Error('音量范围为0–100%'),{code:'OUT_OF_RANGE'})
      var detail=kind==='preset'?['拨弦','吹管','钟声','合成贝斯'][value]+' · 新按下的音生效':kind==='volume'?value+'%':kind==='chorus'?Math.round(value*100/64)+'% · 实际强度由摇杆2调节':String(value)
      if(kind==='group'){var notes=value?[67,69,71,72]:[60,62,64,67];sets=notes.map(function(n,i){return {field:i+1,value:n}}).concat(sets,[{field:22,value:0}]);detail=(value?'B组':'A组')+' · 标准八度 · 新按下的音生效'}
      if(kind==='octave')detail=(value?'高八度':'标准八度')+' · 新按下的音生效'
      displayPlan(this,this.actionService().prepareConfig(sets,{title:names[kind],detail:detail}))
    },
    onDownloadSelected:function(){return this.handleText('下载这首到乐器')},
    onNextSegment:function(){return this.handleText('下一段')},
    setSelectedFavorite:function(enabled){var s=this.actionService().selected(),catalog=env.catalog();if(!s)return this.showActionError('请先选择曲目');if(catalog.favorites.has(s.songId)!==enabled)catalog.favorites.toggle(s.songId);this.setData({lastAction:(enabled?'已收藏：':'已取消收藏：')+s.title})},
    showFavorites:function(){
      var page=this,g=this.commandGeneration,client=env.catalog(),all=client.favorites.list(),ids=all.slice(0,60),cached=client.cached(),offline=false
      if(!ids.length){this.setData({searchResults:[],searchNote:'暂无收藏曲目'});return Promise.resolve()}
      return Promise.all(ids.map(function(id){return client.detail(id).then(function(entry){if(entry.fromCache)offline=true;return {songId:id,title:entry.score.title,bpm:entry.score.bpm,difficulty:entry.score.difficulty,adaptation:entry.adaptation}}).catch(function(){offline=true;return cached.find(function(s){return s.songId===id})||{songId:id,title:id,unavailable:true}})})).then(function(songs){if(!current(page,g))return;page.resultSongs=songs;page.resultTarget='select';page.setData({searchResults:songs,searchNote:(offline?'含离线或未读取条目 · ':'')+'收藏 '+all.length+'首'+(all.length>60?'（显示前60首）':'')})})
    },
    replyStatus:function(){
      var s=env.hub().snapshot(),status=s.lastStatus,available=s.freshness==='fresh'
      this.setData({replyText:(s.isSimulator?'演示设备\n':'')+'连接：'+({disconnected:'未连接',real:'已连接',simulator:'演示设备'}[s.hardwareMode])+'\n状态：'+(available?'实时':s.freshness==='stale'?'已失鲜，以下为上次状态':'无数据')+(status?'\n校准：'+(status.flags&16?'已校准':'未校准')+'\n曲谱：'+(s.activeScore?s.activeScore.title:status.flags&1?'已载入（编号'+status.song+'）':'未载入')+'\n模式：'+(status.flags&2?(status.mode===2?'节奏挑战':'引导练习'):status.flags&16?'自由演奏':'待校准')+(Number.isInteger(status.preset)?'\n下一音色：'+['拨弦','吹管','钟声','合成贝斯'][status.preset]:'')+(Number.isInteger(status.effectMode)?'\n效果：'+['干声','回声','合唱','合唱与回声'][status.effectMode]:''):'')})
    },
    replyScore:function(){var s=env.hub().snapshot(),r=s.lastStatus;if(!r)return this.setData({replyText:'暂无练习成绩'});this.setData({replyText:(s.isSimulator?'演示成绩\n':'')+(s.freshness!=='fresh'?'上次状态\n':'')+'命中 '+r.hits+' · 错按 '+r.wrong+' · 漏拍 '+r.misses})},
    onConfirmProposal:function(){
      var page=this,plan=this.pendingAssistantPlan,api=this.actionService(),g=this.commandGeneration
      if(!plan||plan.disabled||this.data.actionBusy||api.isBusy())return Promise.resolve()
      this.pendingAssistantPlan=null;this.setData({actionBusy:true,proposal:null,lastAction:'',phaseLabel:'正在执行',actionProgress:''})
      return api.execute(plan,{onProgress:function(done,total){if(current(page,g))page.setData({actionProgress:done+'/'+total,phaseLabel:'下载 '+done+'/'+total})}}).then(function(result){
        if(!current(page,g))return
        var label=result.confirmation==='draft'?'未连接乐器，已存草稿':result.isSimulator?'演示设备 · ':''
        if(result.confirmation!=='draft'){
          if(plan.kind==='song')label+='FPGA已确认提交：'+result.title+' · 第'+(result.segmentIndex+1)+'/'+result.segments+'段'
          else if(plan.kind==='mode')label+='FPGA已确认引导'+(result.status.flags&2?(result.status.mode===2?'挑战启动':'启动'):'停止')
          else label+='FPGA已确认：'+plan.title
        }
        page.refreshSelectedSong();page.setData({lastAction:label,phaseLabel:result.confirmation==='draft'?'草稿已保存':'完成',actionProgress:''})
      }).catch(function(e){if(current(page,g))page.setData({lastAction:'未确认：'+errorText(e),phaseLabel:'未完成',actionProgress:''})}).finally(function(){if(!page.disposed)page.setData({actionBusy:false})})
    },
    onDismissProposal:function(){this.commandGeneration=(this.commandGeneration||0)+1;this.pendingAssistantPlan=null;if(this.assistantActions)this.assistantActions.discard();this.setData({proposal:null,phaseLabel:'已取消'})},
    onEditProposal:function(){this.onDismissProposal();this.setData({textInput:this.data.transcript})}
  }
}
module.exports={createAssistantPageActions:createAssistantPageActions}
