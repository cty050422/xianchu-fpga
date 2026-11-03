"""Read-only Core2 checker for model 0x52. Never accepts historical single-owner CSV.

python check_poly_gao.py capture.csv result.json [--radix hex|dec]
Export ALL grouped buses, unfiltered rows. Board identity remains an external gate.
"""
import argparse,csv,json,math,re,hashlib
from pathlib import Path
WIDTHS={'gao_model':8,'gao_lane':1,'gao_voice':2,'gao_generation':8,'gao_sample':16,
 'gao_index':6,'busy':1,'gao_accept':1,'gao_done':1,'gao_overrun':1,'gao_alpha':9,
 'gao_from':1,'gao_to':1,'gao_phase18':18,'gao_weight':8,'gao_gain':8,
 'gao_term':24,'gao_sum_before':24,'base_latch':32,'gao_pcm':16}
SIGNED={'gao_term','gao_sum_before','gao_pcm'}
def label(s):return re.sub(r'\[.*?\]','',re.split(r'[./\\]',s.strip().strip('"'))[-1])
def coeff(i):
 x=32767*math.sin(2*math.pi*(i%1024)/1024)
 return math.floor(x+.5) if x>=0 else math.ceil(x-.5)
def gain_scale(bank,g):return sum(bank>>(8-i) for i in range(8) if g>>i&1)
def verify_rows(rows):
 errors=[];groups={};complete=[];truncated=[]
 for i,r in enumerate(rows):
  if r['gao_model']!=0x52:raise ValueError('Expected model 0x52; use the historical checker for historical CSV')
  if r['gao_overrun']:errors.append(f'overrun at row {i}')
  if r['gao_voice']//2!=r['gao_lane']:errors.append(f'lane/voice mismatch at row {i}')
  if r['gao_accept'] or r['gao_done']:
   key=tuple(r[k] for k in ['gao_sample','gao_lane','gao_voice','gao_generation'])
   groups.setdefault(key,[]).append((i,r))
 for key,events in groups.items():
  accepts=[(i,r) for i,r in events if r['gao_accept']];done=[(i,r) for i,r in events if r['gao_done']]
  indices=[r['gao_index'] for _,r in accepts]
  if indices!=list(range(1,33)) or len(done)!=1:
   truncated.append({'tag':key,'indices':indices,'done':len(done)});continue
  before=len(errors);f=t=0;alpha=accepts[0][1]['gao_alpha'];gain=accepts[0][1]['gao_gain'];base=accepts[0][1]['base_latch'];guard=False
  if alpha>256:errors.append(f'{key}: alpha exceeds unity')
  for j,(i,r) in enumerate(accepts):
   if j and i-accepts[j-1][0]!=3:errors.append(f'{key}: term cadence is not three clocks')
   if (r['gao_alpha'],r['gao_gain'],r['base_latch'])!=(alpha,gain,base):errors.append(f'{key}: torn frame parameters')
   phase=r['gao_phase18'];idx=phase>>8;frac=phase&255
   sine=coeff(idx)+((coeff(idx+1)-coeff(idx))*frac>>8)
   product=sine*r['gao_weight'];term=abs(product)//256*(1 if product>=0 else -1)
   if r['gao_term']!=term:errors.append(f'{key}: term {j+1} arithmetic mismatch')
   expected=f+((t-f)*alpha>>8)
   if r['gao_sum_before']!=expected:errors.append(f'{key}: prefix sum before term {j+1} mismatch')
   guard=guard or ((base*(j+1))&0xffffffff)>=0x70000000
   if not guard:
    if r['gao_from']:f+=term
    if r['gao_to']:t+=term
  dr=done[0][1];total=f+((t-f)*alpha>>8);bank=max(-32768,min(32767,total>>4));raw=gain_scale(bank,gain)
  # gao_pcm exposes the diagnostic raw low 16 bits; actual DAC has later stages.
  expected_pcm=((raw+32768)&65535)-32768
  if dr['gao_sum_before']!=total or dr['gao_pcm']!=expected_pcm:errors.append(f'{key}: final gain/sum mismatch')
  complete.append({'sample':key[0],'lane':key[1],'voice':key[2],'generation':key[3],
   'terms':32,'base_increment':base,'alpha':alpha,'gain':gain,'prefix_sum':total,'diagnostic_pcm':dr['gao_pcm'],'valid':before==len(errors)})
 if not complete:errors.append('No complete 32-term voice group; export more raw rows')
 return {'status':'FAIL' if errors else 'PASS','complete_groups':complete,'censored_boundary_groups':truncated,
  'errors':errors,'scope':'Selected lane/frame tagged arithmetic only; not a simultaneous 4-voice capture, DAC level or physical latency proof',
  'hardware_programmed_identity_verified':False}
def load(path,radix):
 raw=list(csv.reader(path.read_text(encoding='utf-8-sig').splitlines()));header=next((i for i,r in enumerate(raw) if 'gao_model' in [label(x) for x in r]),None)
 if header is None:raise ValueError('Missing model0x52 grouped bus header')
 labels=raw[header];positions={}
 for k in WIDTHS:
  ids=[i for i,s in enumerate(labels) if label(s)==k]
  if not ids:raise ValueError('Missing signal '+k)
  positions[k]=max(ids,key=lambda i:':' in labels[i])
 rows=[]
 for ix,r in enumerate(raw[header+1:],header+2):
  if not any(s.strip() for s in r):continue
  values={}
  for k,w in WIDTHS.items():
   token=r[positions[k]].strip();token=re.sub(r"^(?:0x|\d+'[hH])",'',token)
   if re.search('[xz?]',token,re.I):raise ValueError(f'Unknown value row {ix}, {k}')
   v=int(token,16 if radix=='hex' else 10)
   if not 0<=v<1<<w:raise ValueError(f'Width error row {ix}, {k}')
   values[k]=v-(1<<w) if k in SIGNED and v>=(1<<(w-1)) else v
  rows.append(values)
 return rows
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('csv',type=Path);p.add_argument('report',type=Path);p.add_argument('--radix',choices=['hex','dec'],default='hex');a=p.parse_args()
 try:r=verify_rows(load(a.csv,a.radix))
 except (ValueError,IndexError,StopIteration) as e:r={'status':'FAIL','errors':[str(e)],'hardware_programmed_identity_verified':False}
 r.update(csv_sha256=hashlib.sha256(a.csv.read_bytes()).hexdigest().upper(),csv=str(a.csv.resolve()))
 a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(r,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(r,ensure_ascii=False));return r['status']!='PASS'
if __name__=='__main__':raise SystemExit(main())
