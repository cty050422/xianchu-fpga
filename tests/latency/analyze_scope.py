"""Offline scope CSV extraction. No hardware access, no manually marked events."""
from pathlib import Path
import argparse,csv,hashlib,json,re,sys,copy,math
from collections import Counter
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest().upper()
def read(p):return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def csv_voltage(path,profile):
    cols=profile['csv_columns'];rows=list(csv.reader(Path(path).open(encoding='utf-8-sig',newline='')));header=None
    for i,r in enumerate(rows):
        if all(v in [x.strip() for x in r] for v in cols.values()):header=i;break
    if header is None:raise ValueError('CSV column names not found; configure once for your oscilloscope export')
    h=[x.strip() for x in rows[header]];indices=[h.index(cols[k]) for k in ('time','input','output')];data=[]
    for r in rows[header+1+int(profile.get('csv_data_skip_rows_after_header',0)):]:
        if not any(v.strip() for v in r):continue
        try:data.append([float(r[j]) for j in indices])
        except (ValueError,IndexError):raise ValueError('Non-numeric/truncated waveform row')
    a=np.asarray(data,dtype=float)
    if a.ndim!=2 or len(a)<100 or not np.all(np.isfinite(a)):raise ValueError('Insufficient/nonfinite waveform data')
    a[:,0]*=profile['time_scale_to_seconds']
    a[:,1]*=profile['input_scale_to_volts'];a[:,2]*=profile['output_scale_to_volts']
    dt=np.diff(a[:,0]);step=float(np.median(dt))
    if step<=0 or np.any(dt<=0) or np.max(abs(dt-step))>step*.02:raise ValueError('Nonmonotonic or nonuniform time axis / missing samples')
    expected=profile['sample_rate_hz']
    if not expected or abs(1/step-expected)/expected>.02:raise ValueError('Sample rate differs from recorded profile')
    return a,step
def first_confirmed(mask,start,count):
    runs=np.convolve(mask.astype(int),np.ones(count,dtype=int),mode='valid')==count
    runs[:max(0,start)]=False
    hit=np.flatnonzero(runs)
    if not len(hit):raise ValueError('No confirmed event above predetermined threshold')
    return int(hit[0])
def validate_profile(p):
    for k in ('instrument','input_node','output_node','ground_reference','probe_input','probe_output','condition','bitstream_sha256','sample_rate_hz','output_threshold_v','input_direction','baseline_seconds','confirm_samples'):
        if p.get(k) in (None,'','待确认'):raise ValueError(f'Profile field not configured before collection: {k}')
    if not re.fullmatch('[0-9A-Fa-f]{64}',p['bitstream_sha256']):raise ValueError('Expected image must be a complete SHA-256')
    if p['input_direction'] not in ('rising','falling') or p['output_threshold_v']<=0 or p['baseline_seconds']<=0 or int(p['confirm_samples'])<1:raise ValueError('Invalid event definition')
    if p.get('profile_frozen_before_capture') is not True:raise ValueError('Profile must be fixed and saved before formal collection')
    thresholds=[p['input_threshold_v']] if p.get('input_threshold_v') is not None else [p.get('input_threshold_v_by_zone',{}).get(str(z)) for z in range(4)]
    if any(not isinstance(x,(float,int)) or not math.isfinite(x) for x in thresholds):raise ValueError('Configure input threshold once, or all four per-zone thresholds, before capture')
def trial(raw,profile,zone=None):
    profile=copy.deepcopy(profile)
    if profile.get('input_threshold_v') is None:
        profile['input_threshold_v']=profile.get('input_threshold_v_by_zone',{}).get(str(zone))
    validate_profile(profile);a,dt=csv_voltage(raw,profile);t,vin,vout=a.T
    base=int(np.ceil(profile['baseline_seconds']/dt));confirm=int(profile['confirm_samples'])
    if base<20 or base>=len(t)//2:raise ValueError('Insufficient pre-event baseline')
    high=vin>=profile['input_threshold_v'] if profile['input_direction']=='rising' else vin<=profile['input_threshold_v']
    if np.any(high[:base]):raise ValueError('Input already over threshold during baseline')
    t0=first_confirmed(high,base,confirm)
    crossings=np.flatnonzero(np.diff(high.astype(int))==1)+1
    distinct=[i for i in crossings if i>=base and i+confirm<=len(high) and np.all(high[i:i+confirm])]
    if len(distinct)!=1:raise ValueError('Multiple input events; retain one press per waveform')
    baseline=float(np.median(vout[:base]));rms=float(np.sqrt(np.mean((vout[:base]-baseline)**2)))
    mask=abs(vout-baseline)>=profile['output_threshold_v']
    if np.any(np.convolve(mask[:base].astype(int),np.ones(confirm,dtype=int),mode='valid')==confirm):raise ValueError('Output not quiet before input event')
    # Search from baseline end, so a pre-input output is flagged rather than silently ignored.
    t1=first_confirmed(mask,base,confirm)
    if t1<t0:raise ValueError('Output event precedes input; wrong trigger/quiet condition')
    delay=float((t[t1]-t[t0])*1000)
    if delay>100:raise ValueError('Event outside fixed 100ms trial window')
    return {'latency_ms':delay,'t0_s':float(t[t0]),'t_out_s':float(t[t1]),'baseline_output_v':baseline,'input_threshold_used_v':profile['input_threshold_v'],
            'baseline_rms_v':rms,'sample_interval_us':dt*1e6,'confirmation_span_us':(confirm-1)*dt*1e6,
            'time_quantization_bound_us':2*dt*1e6,'raw_sha256':sha(raw)},a
def analyze(plan,out,allow_simulation=False):
    plan=Path(plan);out=Path(out)
    if out.exists():raise ValueError('Output folder exists; choose a new path')
    with plan.open(encoding='utf-8-sig',newline='') as f:rows=list(csv.DictReader(f))
    valid=[];invalid=[];seen=set();seen_raw=set();conditions=set();versions=set();profiles=set();evidence=set()
    out.mkdir(parents=True)
    for r in rows:
        if not r.get('raw_csv','').strip():continue
        try:
            key=r['trial_id'].strip()
            if not key or key in seen:raise ValueError('Empty/duplicate trial_id')
            seen.add(key);z=int(r['zone'])
            if z not in range(4):raise ValueError('zone must be 0..3')
            raw=(plan.parent/r['raw_csv']).resolve();meta=(plan.parent/r['profile_json']).resolve();p=read(meta)
            ev=r.get('evidence','')
            if ev!='REAL_OSCILLOSCOPE_CAPTURE' and not (allow_simulation and ev=='SIMULATION_NOT_HARDWARE'):raise ValueError('Wrong evidence type')
            if r['condition']!=p['condition']:raise ValueError('Condition/profile mismatch')
            if r.get('raw_sha256','').upper()!=sha(raw):raise ValueError('Missing/changed raw waveform SHA-256')
            if sha(raw) in seen_raw:raise ValueError('Duplicate raw waveform is not a new trial')
            seen_raw.add(sha(raw))
            if r.get('profile_sha256','').upper()!=sha(meta):raise ValueError('Missing/changed frozen profile SHA-256')
            result,a=trial(raw,p,z)
            conditions.add(p['condition']);versions.add(p['bitstream_sha256'].upper());profiles.add(sha(meta));evidence.add(ev)
            v={**r,**result};valid.append(v)
            fig,axes=plt.subplots(2,1,figsize=(9,5),sharex=True)
            for ax,y,label in zip(axes,a.T[1:],('ADC input (V)','Analog audio output (V)')):
                ax.plot(a[:,0]*1000,y,lw=.7);ax.set_ylabel(label);ax.axvline(result['t0_s']*1000,c='tab:green');ax.axvline(result['t_out_s']*1000,c='tab:red');ax.grid(True,alpha=.3)
            axes[0].axhline(result['input_threshold_used_v'],c='gray',ls='--');axes[1].axhline(result['baseline_output_v']+p['output_threshold_v'],c='gray',ls='--');axes[1].set_xlabel('Time (ms)')
            fig.suptitle(f'{key}: {result["latency_ms"]:.3f} ms | {ev}');fig.tight_layout();fig.savefig(out/f'{len(valid):03d}_check.png',dpi=130);plt.close(fig)
        except (ValueError,KeyError,TypeError,OSError) as exc:invalid.append({**r,'reason':str(exc)})
    mixed=len(conditions)>1 or len(versions)>1 or len(profiles)>1 or len(evidence)>1
    counts=Counter(int(v['zone']) for v in valid);sufficient=all(counts[z]>=25 for z in range(4))
    values=[v['latency_ms'] for v in valid]
    stats={k:float(v) for k,v in zip(('min_ms','median_ms','p95_ms','max_ms','range_ms'),(np.min(values),np.median(values),np.percentile(values,95),np.max(values),np.ptp(values)))} if values else {}
    status='NOT_RUN' if not values and not invalid else ('BLOCKED' if mixed or not sufficient else ('PASS' if max(values)<=10 else 'FAIL'))
    result={'status':status,'scope':'Predefined ADC input voltage crossing to analog audio output threshold; excludes mechanical onset',
            'evidence':next(iter(evidence)) if len(evidence)==1 else 'MIXED_OR_NONE','valid_per_zone':dict(counts),'invalid_count':len(invalid),
            'mixed_conditions':mixed,'statistics':stats,'observed_le_10ms':bool(values and max(values)<=10),'observed_le_5ms':bool(values and max(values)<=5),
            'formal_100_trial_complete':sufficient and not mixed,'official_5ms_determinism_proven':False,'plan_sha256':sha(plan)}
    for name,data in (('valid_trials',valid),('invalid_trials',invalid)):
        with (out/f'{name}.csv').open('w',encoding='utf-8-sig',newline='') as f:
            if data:
                w=csv.DictWriter(f,fieldnames=list(dict.fromkeys(k for r in data for k in r)));w.writeheader();w.writerows(data)
    (out/'scope_summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    if values:
        fig,ax=plt.subplots(figsize=(9,4));ax.scatter(range(1,len(values)+1),values,s=12);ax.axhline(5,c='orange',ls='--',label='5 ms reference');ax.axhline(10,c='red',ls='--',label='10 ms reference');ax.set(xlabel='Valid trial',ylabel='Latency (ms)',title=result['evidence']);ax.legend();fig.tight_layout();fig.savefig(out/'scope_comparison.png',dpi=160);plt.close(fig)
    return result
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('plan',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    try:
        r=analyze(a.plan,a.out);print(json.dumps(r,ensure_ascii=False,indent=2));sys.exit(0 if r['status']=='PASS' else 2)
    except (ValueError,OSError) as e:print('FAIL: '+str(e),file=sys.stderr);sys.exit(2)
if __name__=='__main__':main()
