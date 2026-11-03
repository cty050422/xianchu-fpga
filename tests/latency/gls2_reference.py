"""Decode GLS2 latched GAO records. Reads files only; never accesses a board."""
import argparse,csv,hashlib,html,io,json,math,re,statistics,sys
from pathlib import Path
NAMES=['magic','trial_id','meta','t0','t1','tv','t2a','t2','t3','t4','sample_tag','frame_id','pcm','adc','threshold','bank_budget','conflicts','sample_budget','config','build_id']
STAGES=['t0_t1','t1_tv','tv_t2','t2_t3','t3_t4','total']
STATUS={0:'OK',1:'multiple/overlap',2:'owner/event mismatch',3:'disabled/mute',4:'timeout',5:'target superseded/not serialized'}
CLOCK=50_000_000/2*29/59
def number(value,radix):
 s=value.strip().strip('"').replace('_','')
 if s.lower().startswith('0x'):
  if re.search('[xz?]',s[2:],re.I):raise ValueError('unknown/X/Z value: '+s)
  return int(s,16)
 if re.search('[xz?]',s,re.I):raise ValueError('unknown/X/Z value: '+s)
 m=re.fullmatch(r"\d*'([hdb])([0-9a-fA-F+-]+)",s)
 if m:return int(m[2],{'h':16,'d':10,'b':2}[m[1]])
 return int(s,radix)
def word_names(w):
 d={'latency_'+n:v for n,v in zip(NAMES,w) if n!='meta'}
 d.update(latency_valid_mask=w[2]&255,latency_status=(w[2]>>8)&255,
          latency_generation=(w[2]>>16)&255,latency_zone=(w[2]>>24)&3,latency_slot=(w[2]>>26)&3)
 return d
def decode(w):
 if len(w)!=20 or any(v<0 or v>0xffffffff for v in w):raise ValueError('20 unsigned words required')
 d=dict(zip(NAMES,w));meta=d.pop('meta')
 d.update(status=(meta>>8)&255,valid_mask=meta&255,generation=(meta>>16)&255,zone=(meta>>24)&3,slot=(meta>>26)&3)
 if d['magic']!=0x474c5332 or d['build_id']!=0x20261028:raise ValueError('wrong GLS2/build identity')
 d['valid']=d['status']==0;d['invalid_reason']=STATUS.get(d['status'],'unknown status')
 if d['status'] not in STATUS:raise ValueError('unknown status')
 d['pcm']=d['pcm']-(1<<32)if d['pcm']&(1<<31)else d['pcm']
 d['adc_code']=d['adc']&4095;d['cal_zero']=(d['adc']>>12)&4095
 d['on_threshold']=d['threshold']&4095
 d['bank_last_cycles']=d['bank_budget']&65535;d['bank_max_cycles']=d['bank_budget']>>16
 d['preset']=d['config']&3;d['effect_mode']=(d['config']>>2)&3
 d['partial_target']=(d['config']>>4)&63;d['wet_q8']=(d['config']>>10)&255
 if not d['valid']:return d
 if d['valid_mask']!=127:raise ValueError('incomplete valid mask')
 # Durations are unsigned modular differences; valid trials are <=50ms.
 rel={n:(d[n]-d['t0'])&0xffffffff for n in ['t0','t1','tv','t2a','t2','t3','t4']}
 chain=[rel[n]for n in ['t0','t1','tv','t2','t3','t4']]
 if chain!=sorted(chain) or not 0<=rel['t2a']<=rel['t2'] or rel['t4']>614400:raise ValueError('timestamp order/timeout')
 if rel['t4']-rel['t3']!=254:raise ValueError('stereo frame interval must be 254 clocks')
 # Zero is legitimate when 32-bit sample/frame counters wrap. The complete
 # valid_mask and the RTL equality binding establish presence, not nonzero IDs.
 if abs(d['pcm'])<128:raise ValueError('target PCM below threshold128')
 if max(0,d['adc_code']-d['cal_zero'])*16<d['on_threshold']:raise ValueError('T0 ADC threshold not met')
 if d['sample_budget']!=256 or not 0<d['bank_last_cycles']<=d['bank_max_cycles']<256:raise ValueError('bank budget')
 if d['conflicts']:raise ValueError('sample busy conflict')
 for a,b in [('t0','t1'),('t1','tv'),('tv','t2'),('t2','t3'),('t3','t4')]:d[a+'_'+b+'_cycles']=rel[b]-rel[a]
 d['total_cycles']=rel['t4'];d['t0_t2a_cycles']=rel['t2a']
 return d
def key(s):
 s=s.strip().strip('"').replace('\\','/')
 m=re.search(r'((?:latency|budget)_\w+|record_word_\d+)(\[\d+(?::\d+)?\])?',s)
 return ''.join(x or ''for x in m.groups())if m else s.lower()
def read_csv(path,radix=16,allow_record_words=True):
 raw=Path(path).read_bytes();text=None
 encodings=['utf-16','utf-8-sig','gb18030']if raw.startswith((b'\xff\xfe',b'\xfe\xff'))else['utf-8-sig','utf-16','gb18030']
 for enc in encodings:
  try:text=raw.decode(enc);break
  except UnicodeError:pass
 if text is None:raise ValueError('CSV text encoding')
 lines=text.splitlines();start=next((i for i,s in enumerate(lines)if 'latency_t0' in s or 'record_word_0' in s),None)
 if start is None:raise ValueError('missing GAO header; export all configured buses')
 if not allow_record_words and 'record_word_0' in lines[start]:raise ValueError('simulation-only record format cannot be hardware evidence')
 sample='\n'.join(lines[start:]);delim='\t'if '\t' in lines[start]else ','
 reader=csv.DictReader(io.StringIO(sample),delimiter=delim);records={}
 for line,row in enumerate(reader,start+2):
  if not any(v for v in row.values()):continue
  row={key(k):v for k,v in row.items()if k is not None}
  def get(name):
   if name in row:return number(row[name],radix)
   buses=[k for k in row if re.fullmatch(re.escape(name)+r'\[\d+:0\]',k)]
   if buses:return number(row[buses[0]],radix)
   bits={int(re.search(r'\[(\d+)\]',k)[1]):v for k,v in row.items() if re.fullmatch(re.escape(name)+r'\[\d+\]',k)}
   if bits:
    if set(bits)!=set(range(max(bits)+1)):raise ValueError('missing bit in '+name)
    vals={i:number(v,2)for i,v in bits.items()}
    if any(v not in (0,1)for v in vals.values()):raise ValueError('invalid bit')
    return sum(v<<i for i,v in vals.items())
   raise ValueError('missing '+name)
  # Hardware exports must retain the completion pulse. Simulation format is
  # deliberately distinct and must be explicitly classified by the CLI caller.
  if 'latency_trigger' in row and get('latency_trigger')!=1:continue
  elif 'latency_trigger' not in row and 'record_word_0' not in row:raise ValueError('missing completion trigger')
  if 'record_word_0' in row:w=[get(f'record_word_{i}')for i in range(20)]
  else:
   d={n:get('latency_'+n)for n in NAMES if n!='meta'}
   meta=get('latency_valid_mask')|(get('latency_status')<<8)|(get('latency_generation')<<16)|(get('latency_zone')<<24)|(get('latency_slot')<<26)
   w=[meta if n=='meta'else d[n]for n in NAMES]
  record=decode(w);trial=(row.get('boot_id','0'),record['trial_id'])
  if trial in records and records[trial]['raw_words']!=w:raise ValueError('changed duplicate trial '+str(trial))
  record.update(raw_words=w,csv_line=line)
  if 'boot_id' in row:record['boot_id']=row['boot_id']
  records.setdefault(trial,record)
 if not records:raise ValueError('no completed trial: trigger was not captured')
 return list(records.values())
def percentile(xs,p):
 s=sorted(xs);x=(len(s)-1)*p;lo=math.floor(x);hi=math.ceil(x)
 return s[lo]+(s[hi]-s[lo])*(x-lo)
def read_budget_csv(path,radix=16,require_identity=False):
 raw=Path(path).read_bytes();text=raw.decode('utf-16'if raw.startswith((b'\xff\xfe',b'\xfe\xff'))else'utf-8-sig');lines=text.splitlines()
 first=next((i for i,s in enumerate(lines)if 'budget_bank_cycles' in s),None)
 if first is None:raise ValueError('missing live budget header')
 reader=csv.DictReader(io.StringIO('\n'.join(lines[first:])),delimiter='\t'if'\t'in lines[first]else',')
 rows=[]
 for row in reader:
  d={key(k):v for k,v in row.items()if k is not None}
  def get(n):
   matches=[v for k,v in d.items()if k==n or re.fullmatch(re.escape(n)+r'\[31:0\]',k)]
   if not matches:raise ValueError('missing '+n)
   return number(matches[0],radix)
  bank,conflicts,samples,state=[get('budget_'+s)for s in ['bank_cycles','conflicts','samples','state']]
  if require_identity and (get('latency_build_id')!=0x20261028 or get('latency_magic')!=0x474c5332):raise ValueError('wrong live budget identity: perform a qualified onset first')
  if samples==0:continue
  last,maximum=bank&65535,bank>>16
  if not 0<last<=maximum<256:raise ValueError('live bank budget violated')
  if conflicts:raise ValueError('live sample conflict')
  rows.append({'bank_last_cycles':last,'bank_max_cycles':maximum,'conflicts':conflicts,'completed_samples':samples,
   'voice_gate_mask':state&15,'gated_voices':(state&15).bit_count(),'partials_active':(state>>4)&63,'effect_mode':(state>>10)&3,'wet_q8':(state>>12)&255,
   'budget_cycles':256,'utilization':maximum/256,'remaining_cycles':256-maximum})
 if not rows:raise ValueError('no completed bank samples')
 # Report the state actually captured, not a manually supplied workload name.
 return rows[-1]
def append_unique(rows,new_rows,boot_id,seen):
 for row in new_rows:
  identity=(str(row.get('boot_id',boot_id)),row['trial_id'])
  if identity in seen:raise ValueError('duplicate trial across captures '+str(identity)+'; use a new session after reset')
  row['boot_id']=identity[0];seen.add(identity);rows.append(row)
def summarize(rows,clock):
 groups={}
 for r in rows:
  # Never silently pool changed timbre/effect/partial/wet/threshold settings.
  k=f"zone{r['zone']+1}_preset{r['preset']}_fx{r['effect_mode']}_partial{r['partial_target']}_wet{r['wet_q8']}_on{r['on_threshold']}"
  groups.setdefault(k,[]).append(r)
 result={}
 for k,rs in groups.items():
  valid=[r for r in rs if r['valid']];entry={'valid':len(valid),'invalid':len(rs)-len(valid),'planned25_complete':len(valid)>=25,'segments_us':{}}
  if valid:
   for field in STAGES:
    xs=[r[field+'_cycles']/clock*1e6 for r in valid]
    entry['segments_us'][field]={'min':min(xs),'median':statistics.median(xs),'p95':percentile(xs,.95),'max':max(xs),'range':max(xs)-min(xs)}
  result[k]=entry
 return result
def render_report(summary,path):
 table=''
 for group,g in summary['groups'].items():
  cells=''.join(f'<td>{g["segments_us"].get(s,{}).get("median",0):.3f}</td>'for s in STAGES)
  table+=f'<tr><td>{html.escape(group)}</td><td>{g["valid"]}/{g["invalid"]}</td>{cells}</tr>'
 path.write_text('''<!doctype html><meta charset="utf-8"><title>内部阶段延迟</title><style>body{font:16px system-ui;max-width:1200px;margin:40px auto;color:#18363a}table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:12px;border-bottom:1px solid #c9d7d4;text-align:right}td:first-child{text-align:left}h1{font-size:30px}aside{padding:20px;background:#eef5f2;line-height:1.8}</style><h1>内部阶段与实时预算</h1>'''+f'<p>数据类型：{summary["evidence_type"]}；时钟依据：{summary["clock_hz"]:.6f} Hz；单位 µs</p><table><tr><th>区域 / 条件</th><th>有效/无效</th><th>T0→T1</th><th>T1→Tv</th><th>Tv→T2</th><th>T2→T3</th><th>T3→T4</th><th>总计</th></tr>'+table+'</table><aside>各格为中位数。T0从ADC结果满足条件开始，不含此前模拟输入等待扫描；T4是匹配的PT8211数字立体声帧完成，不是DAC模拟响应。Tv/T2a/T2采用同步观察边沿，含不超过一拍的观察量化；T1已补偿注册应答的一拍。示波器端到端数据另列，不能跨试次相减。32分量模块与声部核并行，不能将各自忙碌周期直接相加。未满每组25次仍可分析，但不是正式组完成。</aside>',encoding='utf-8')
def main():
 p=argparse.ArgumentParser();p.add_argument('csv',nargs='+',type=Path);p.add_argument('--radix',type=int,choices=[2,8,10,16],default=16)
 p.add_argument('--evidence-type',choices=['hardware-gao','rtl-simulation'],required=True)
 p.add_argument('--mode',choices=['latency','budget'],default='latency')
 p.add_argument('--out',type=Path,required=True);p.add_argument('--clock-hz',type=float,default=CLOCK);p.add_argument('--session',type=Path)
 a=p.parse_args()
 if not math.isfinite(a.clock_hz)or a.clock_hz<=0:raise SystemExit('invalid clock')
 session=json.loads(a.session.read_text('utf-8-sig'))if a.session else {}
 if a.evidence_type=='hardware-gao' and (not session.get('programmed_fs_sha256')or session.get('operator_confirmed')is not True):raise SystemExit('hardware analysis requires confirmed session.json with programmed FS SHA256')
 if a.evidence_type=='hardware-gao' and not session.get('boot_id'):raise SystemExit('session boot_id required; do not reset inside one session')
 if a.evidence_type=='hardware-gao':
  fs=Path(__file__).resolve().parent.parent/'firmware/FPGA_LATENCY_GAO.fs'
  if not fs.is_file():raise SystemExit('expected packaged diagnostic FS missing')
  if hashlib.sha256(fs.read_bytes()).hexdigest().upper()!=session['programmed_fs_sha256'].upper():raise SystemExit('session FS does not match packaged diagnostic')
 allrows=[];errors=[];seen={};trial_seen=set();hashes=[]
 for f in a.csv:
  try:
   sha=hashlib.sha256(f.read_bytes()).hexdigest().upper();hashes.append({'file':str(f),'sha256':sha})
   if sha in seen:raise ValueError('duplicate input capture '+str(seen[sha]))
   seen[sha]=f
   rows=read_csv(f,a.radix,allow_record_words=a.evidence_type!='hardware-gao')if a.mode=='latency'else[read_budget_csv(f,a.radix,require_identity=a.evidence_type=='hardware-gao')]
   for row in rows:row['source_file']=str(f)
   if a.mode=='latency':append_unique(allrows,rows,session.get('boot_id','unspecified'),trial_seen)
   else:allrows+=rows
  except (ValueError,OSError)as e:errors.append({'file':str(f),'error':str(e)})
 a.out.mkdir(parents=True,exist_ok=True)
 summary={'schema':'GLS2','evidence_type':a.evidence_type,'clock_hz':a.clock_hz,'clock_basis':'nominal crystal PLL ratio'if a.clock_hz==CLOCK else'user supplied; see session',
  'mode':a.mode,'session':session,'inputs':hashes,'errors':errors,'groups':summarize(allrows,a.clock_hz)if a.mode=='latency'else{},'budget_results':allrows if a.mode=='budget'else[],
  'physical_latency_verified':False,'hardware_run':a.evidence_type=='hardware-gao' and bool(allrows)and not errors}
 (a.out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
 (a.out/'trials.json').write_text(json.dumps(allrows,ensure_ascii=False,indent=2),encoding='utf-8')
 if allrows and a.mode=='latency':
  fields=['source_file','boot_id','trial_id','zone','slot','generation','status','valid','invalid_reason','preset','effect_mode','partial_target','wet_q8','adc_code','cal_zero','on_threshold','pcm','sample_tag','frame_id',*[s+'_cycles'for s in STAGES],'t0_t2a_cycles','bank_last_cycles','bank_max_cycles','conflicts']
  with(a.out/'trials.csv').open('w',newline='',encoding='utf-8-sig')as h:
   writer=csv.DictWriter(h,fieldnames=fields,extrasaction='ignore');writer.writeheader();writer.writerows(allrows)
 if a.mode=='latency':render_report(summary,a.out/'report.html')
 else:(a.out/'report.html').write_text('<meta charset="utf-8"><h1>实时预算</h1><p>实际捕获状态；每采样周期256拍。不是端到端延迟。</p><pre>'+html.escape(json.dumps(summary,ensure_ascii=False,indent=2))+'</pre>',encoding='utf-8')
 print(json.dumps({'records':len(allrows),'errors':errors,'report':str(a.out/'report.html')},ensure_ascii=False))
 return 1 if errors or not allrows else 0
if __name__=='__main__':sys.exit(main())
