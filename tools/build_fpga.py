"""Build the integrated Tang Mega 60K image, then check source stability and STA.

Set GOWIN_IDE_BIN to the installed IDE/bin directory. No hardware is accessed.
Outputs: build/fpga/<timestamp>/XianChu.fs, XianChu.rao and manifest.json.
"""
from pathlib import Path
from datetime import datetime,timezone
import subprocess,json,hashlib,re,shutil,xml.etree.ElementTree as ET
from tool_paths import gowin_exe,english_cache

ROOT=Path(__file__).resolve().parents[1];SRC=ROOT/'src'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def entry(p):return {'path':p.relative_to(ROOT).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)}

def main():
    g=SRC/'gowin/narrative/narrative.gprj';tcl=SRC/'gowin/run_narrative_all.tcl'
    inputs={g,tcl,Path(__file__).resolve(),Path(__file__).with_name('tool_paths.py').resolve()}
    inputs.update((g.parent/x.attrib['path']).resolve() for x in ET.parse(g).findall('.//File') if x.attrib.get('enable')=='1')
    assert all(p.is_file() and p.is_relative_to(ROOT) for p in inputs),'Missing or external project input'
    before=[entry(p) for p in sorted(inputs)]
    name=datetime.now().strftime('%Y%m%d_%H%M%S');out=ROOT/'build/fpga'/name;out.mkdir(parents=True)
    stage=english_cache('build')/('public_'+name);stage.mkdir(parents=True,exist_ok=False)
    for source in inputs:
        if source.is_relative_to(SRC):
            target=stage/source.relative_to(SRC);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
    tool=gowin_exe('gw_sh.exe');started=datetime.now(timezone.utc)
    (out/'inputs.json').write_text(json.dumps(before,indent=2),encoding='utf-8')
    print('Building FPGA; progress log: '+str(out/'build.log'),flush=True)
    with (out/'build.log').open('wb') as log:
        result=subprocess.run([str(tool),str(stage/tcl.relative_to(SRC))],cwd=stage,stdout=log,stderr=subprocess.STDOUT)
    stable=before==[entry(p) for p in sorted(inputs)]
    (out/'status.json').write_text(json.dumps({'exit_code':result.returncode,'inputs_stable':stable}),encoding='utf-8')
    if result.returncode or not stable:raise RuntimeError('Build failed or inputs changed; see build.log')
    impl=stage/'gowin/narrative/impl';fs=impl/'pnr/ao_0.fs'
    if not fs.is_file() or fs.stat().st_mtime<started.timestamp():raise RuntimeError('Fresh GAO-enabled bitstream missing')
    report=impl/'pnr/narrative.rpt.txt';timing=impl/'pnr/narrative_tr_content.html'
    text=report.read_text(encoding='utf-8',errors='replace')
    flat=re.sub(r'\s+',' ',re.sub('<[^>]*>',' ',timing.read_text(encoding='utf-8',errors='replace')))
    violations={k:int(re.search('Numbers of '+k+r' Violated Endpoints\s+(\d+)',flat)[1]) for k in ['Setup','Hold']}
    if any(violations.values()):raise RuntimeError('Timing violations: '+str(violations))
    resources={}
    for name in ['Logic','Register','CLS','DSP','BSRAM']:
        m=re.search(r'^\s*'+name+r'\s*\|\s*([\d.]+)/([\d.]+)',text,re.M)
        if not m:raise RuntimeError('Missing resource '+name)
        resources[name]={'used':float(m[1]),'total':float(m[2])}
    shutil.copy2(fs,out/'XianChu.fs');shutil.copy2(g.parent/'narrative.rao',out/'XianChu.rao')
    for f in [report,timing,impl/'pnr/narrative.pin.html']:
        if f.is_file():shutil.copy2(f,out/f.name)
    manifest={'schema':1,'top':'instrument_display_top','device':'GW5AT-LV60PG484AC1/I0',
              'generated_at':datetime.now(timezone.utc).isoformat(),'tool_version':tool.parents[2].name,
              'tool_sha256':sha(tool),'inputs_stable':stable,'inputs':before,'resources':resources,
              'timing_violations':violations,'hardware_validation':'NOT_RUN',
              'outputs':[entry(out/n) for n in ['XianChu.fs','XianChu.rao']]}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps({'output':str(out),'timing_violations':violations,'resources':resources}),flush=True)

if __name__=='__main__':main()
