"""Reproducible selected RTL regression; never accesses hardware."""
from pathlib import Path
from datetime import datetime
import argparse,json,subprocess,os,xml.etree.ElementTree as ET,hashlib
from tool_paths import iverilog_exe, gowin_simlib

ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'src'
SIM=ROOT/'tests/rtl'

def run(tests=None):
    out=ROOT/'build'/'rtl'/datetime.now().strftime('%Y%m%d_%H%M%S')
    out.mkdir(parents=True)
    iv=iverilog_exe()
    vv=iv.with_name('vvp.exe')
    env=dict(os.environ);env['PATH']=str(iv.parent)+os.pathsep+env.get('PATH','')
    g=SRC/'gowin/narrative/narrative.gprj'
    files=list(dict.fromkeys(str((g.parent/e.attrib['path']).resolve()) for e in ET.parse(g).findall('.//File') if e.attrib.get('enable')=='1' and e.attrib['path'].endswith(('.sv','.v'))))
    prim=gowin_simlib()
    chosen=tests or ['instrument_display_top','tb_adsr_expressive','tb_adsr_stage_observer','tb_additive_interpolation',
        'tb_chorus_delay','tb_instrument_extension_core','tb_narrative_optimized_core','tb_audition','tb_display_trace_engine',
        'tb_display_capture','tb_display_reset','tb_display_labels','tb_display_scale']
    receipts=[]
    for top in chosen:
        tb=SIM/f'{top}.sv'
        args=[str(iv),'-g2012','-s',top,'-o',str(out/f'{top}.vvp'),*files]
        if prim.exists():args.append(str(prim))
        if top=='instrument_display_top':args[1:1]=['-s','GSR']
        if top!='instrument_display_top':
            if not tb.exists():
                receipts.append({'test':top,'status':'NOT_RUN','reason':'test source missing'});continue
            args += [str(SIM/'mcp3208_model.sv'),str(tb)]
        compile_run=subprocess.run(args,cwd=SIM,env=env,capture_output=True,timeout=180)
        (out/f'{top}_compile.log').write_bytes(compile_run.stdout+compile_run.stderr)
        r={'test':top,'compile_exit':compile_run.returncode,'evidence':'RTL_SIMULATION_ONLY'}
        if compile_run.returncode==0 and top!='instrument_display_top':
            try:
                p=subprocess.run([str(vv),'-i',str(out/f'{top}.vvp')],cwd=out,env=env,capture_output=True,timeout=1800)
                (out/f'{top}_run.log').write_bytes(p.stdout+p.stderr)
                r.update(run_exit=p.returncode,status='PASS' if p.returncode==0 else 'FAIL')
            except subprocess.TimeoutExpired as e:
                (out/f'{top}_run.log').write_bytes((e.stdout or b'')+(e.stderr or b''))
                r.update(status='FAIL',reason='timeout 1800s')
        else:r['status']='PASS' if compile_run.returncode==0 else 'FAIL'
        receipts.append(r);print(json.dumps(r),flush=True)
        (out/'results.json').write_text(json.dumps({'evidence':'RTL_SIMULATION_ONLY','tests':receipts},indent=2),encoding='utf-8')
    final={'evidence':'RTL_SIMULATION_ONLY','status':'PASS' if all(x['status']=='PASS' for x in receipts) else 'FAIL','tests':receipts}
    (out/'results.json').write_text(json.dumps(final,indent=2),encoding='utf-8')
    print(str(out),flush=True)
    return 0 if final['status']=='PASS' else 1

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('tests',nargs='*');a=p.parse_args();raise SystemExit(run(a.tests or None))
