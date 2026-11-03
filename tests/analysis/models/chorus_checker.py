"""Read-only extraction of unchanged Core1 decoder and arithmetic checker."""
from pathlib import Path
import csv,hashlib,json,re
import numpy as np
ROOT=Path(__file__).resolve().parents[1]

SIGNED={'ch_dry':16,'ch_newer':16,'ch_older':16,'ch_wet':16,'ch_wet_mix':17,'ch_sum':17,'ch_expected':16,'ch_output':16}

GROUPS={'D':0,'M':32,'W':64}

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest().upper()

def read(p):return json.loads(Path(p).read_text(encoding='utf-8-sig'))

def read_gao(path,schema):
    with Path(path).open(encoding='utf-8-sig',newline='') as f:rows=list(csv.reader(f))
    keys=list(schema['fields']);header=None
    for i,row in enumerate(rows):
        names=[re.sub(r'\[.*?\]','',re.split(r'[./\\]',x.strip().strip('"'))[-1]) for x in row]
        if 'ch_seq' in names and 'ch_dry' in names:
            if not set(keys).issubset(names):raise ValueError('Wrong Core1 schema/version; missing '+','.join(set(keys)-set(names)))
            header=i;break
    if header is None:raise ValueError('No Core1 grouped-bus header')
    col={k:names.index(k) for k in keys};values=[];prefix=0;started=False
    for i,row in enumerate(rows[header+1:],header+2):
        if not any(x.strip() for x in row):continue
        if len(row)<len(names):raise ValueError(f'Truncated CSV row {i}')
        d={}
        for k,j in col.items():
            tok=re.sub(r'^0[xX]','',row[j].strip())
            d[k]=int(tok,16) if re.fullmatch(r'[0-9a-fA-F]+',tok or '!') else None
        if not started and d['ch_valid'] in (None,0):
            if d['ch_valid'] is None and d['ch_seq'] is None and d['ch_dry'] is None:
                prefix+=1;continue  # GAO startup row may already contain optimized constants.
            if any(v not in (None,0,schema['tag']) for k,v in d.items() if k not in ('ch_tag','ch_center','ch_filtered','ch_adc7')):
                raise ValueError('Nonempty data before valid prefix')
            prefix+=1;continue
        started=True
        for k,v in d.items():
            if v is None or not 0<=v<(1<<schema['fields'][k]):raise ValueError(f'Unknown/out-of-range {k} at row {i}')
            if k in SIGNED and v>=(1<<(SIGNED[k]-1)):d[k]=v-(1<<SIGNED[k])
        values.append(d)
    if not values and prefix:
        raise ValueError('当前CSV没有有效快照，可能是等待触发时导出的空缓冲；GAO按F1开始、F3强制触发，完成后重新导出。若仍全零，请核对FS/RAO及GAO状态。')
    capture_depth=int(schema.get('capture_depth',4096))
    if len(values)!=capture_depth:raise ValueError(f'Need exactly {capture_depth} valid samples after the startup prefix; found {len(values)}')
    return {k:np.array([d[k] for d in values],dtype=np.int64) for k in keys},prefix

def check_gao(path,group,root=ROOT):
    schema=read(root/'01_design/gao_schema.json');v,prefix=read_gao(path,schema);n=len(v['ch_seq'])
    checks={};checks['contract_tag']=bool(np.all(v['ch_tag']==schema['tag']))
    checks['valid_ready_test']=bool(np.all((v['ch_valid']==1)&(v['ch_ready']==1)&(v['ch_test']==1)&(v['ch_mode']==2)))
    checks['actual_group_gain']=bool(np.all(v['ch_gain']==GROUPS[group]) and np.all(v['ch_target']==GROUPS[group]))
    checks['control_health']=bool(np.all(v['ch_center_valid']==1) and np.all(v['ch_stale']==0))
    center,filtered=v['ch_center'],v['ch_filtered']
    target=np.select([filtered<=center-600,filtered<=center-250,filtered>=center+600,filtered>=center+250],[0,16,64,48],default=32)
    checks['controller_mapping']=bool(np.all(target==v['ch_target']))
    checks['sequence']=bool(np.all((np.diff(v['ch_seq'])%(1<<32))==1))
    checks['lfo_step']=bool(np.all(np.diff(v['ch_lfo'])%(1<<26)==699))
    phase=v['ch_lfo'];ramp=(phase%(1<<25))//(1<<11)
    q=np.where(phase<(1<<25),ramp,64*256-ramp)
    delay=1024+q//256;frac=q%256
    checks['delay_geometry']=bool(np.all(delay==v['ch_delay']) and np.all(v['ch_rd']==(v['ch_wr']-delay)%2048))
    checks['write_pointer']=bool(np.all(np.diff(v['ch_wr'])%2048==1))
    checks['fraction_register']=bool(np.all(v['ch_frac'][1:]==frac[:-1]))
    wet=v['ch_newer']+((v['ch_older']-v['ch_newer'])*v['ch_frac']//256)
    mix=wet*v['ch_gain']//256;total=v['ch_dry']+mix;out=np.clip(total,-32768,32767)
    checks['interpolation']=bool(np.all(wet==v['ch_wet']))
    checks['wet_multiply']=bool(np.all(mix==v['ch_wet_mix']))
    checks['mix_sum']=bool(np.all(total==v['ch_sum']))
    checks['actual_registered_output']=bool(np.all(out==v['ch_expected']) and np.all(out==v['ch_output']))
    clip=(total>32767)|(total<-32768)
    checks['clip_flag_counter']=bool(np.all(v['ch_clip']==clip) and np.all(v['ch_clips'][1:]==np.minimum(65535,v['ch_clips'][:-1]+clip[:-1])))
    ix={int(s):i for i,s in enumerate(v['ch_seq'])};residual=[]
    for j in range(1,n):
        source=(int(v['ch_seq'][j])-1-int(delay[j-1]))%(1<<32)
        if source in ix and (source-1)%(1<<32) in ix:
            residual.extend([int(v['ch_newer'][j]-v['ch_dry'][ix[source]]),int(v['ch_older'][j]-v['ch_dry'][ix[(source-1)%(1<<32)]])])
    checks['ram_history']=len(residual)>=256 and all(x==0 for x in residual)
    checks['nonzero_signal']=bool(np.any(v['ch_dry']) and np.any(v['ch_wet']))
    checks['wet_presence']=bool(not np.any(mix)) if group=='D' else bool(np.any(mix))
    result={'status':'PASS' if all(checks.values()) else 'FAIL','checks':checks,'group':group,
            'observed_gains':sorted(set(map(int,v['ch_gain']))),'observed_targets':sorted(set(map(int,v['ch_target']))),
            'adc7_range':[int(v['ch_adc7'].min()),int(v['ch_adc7'].max())],
            'control_stale_rows':int(np.sum(v['ch_stale'])),'samples':n,'excluded_prefix':prefix,
            'ram_comparisons':len(residual),'max_mix_error_lsb':int(np.max(np.abs(out-v['ch_output']))),
            'clipped_samples':int(np.sum(clip)),'clip_counter_end':int(v['ch_clips'][-1]),
            'delay_ms_range':[(float(delay.min())+1)/48,(float(delay.max())+2)/48],
            'nominal_lfo_hz':699*48000/(1<<26),'source_csv':str(Path(path).resolve()),'source_sha256':sha(path),
            'scope':'Effect arithmetic, control health, adjacent RAM history; not analog output or full LFO period','programmed_image_verified':False}
    return result,v
