"""Bundle committed sources and matching FPGA/S3 outputs; no old build logs.

python tools/make_release.py --version 1.0.0 --fpga build/fpga/TIMESTAMP --s3 build/s3/TIMESTAMP
The working tree must be committed and clean. Output: dist/xianchu-fpga-vVERSION.zip.
"""
from pathlib import Path
import argparse,subprocess,json,hashlib,shutil,zipfile
from verify_release import verify
R=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',default='1.0.0');p.add_argument('--fpga',type=Path,required=True);p.add_argument('--s3',type=Path,required=True);a=p.parse_args()
    dirty=subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=R,text=True)
    if dirty:raise SystemExit('Commit source changes before packaging')
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip()
    listed=subprocess.check_output(['git','ls-files','-z'],cwd=R).decode('utf-8').split('\0');listed=[s for s in listed if s]
    out=R/'dist';out.mkdir(exist_ok=True);stage=R/'build/release'/('xianchu-fpga-v'+a.version)
    if stage.exists():raise SystemExit('Release staging directory already exists; use a new version or archive the old staging directory')
    stage.mkdir(parents=True)
    for name in listed:
        src=R/name;dst=stage/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
    fpga=a.fpga.resolve();s3=a.s3.resolve()
    fm=json.loads((fpga/'manifest.json').read_text(encoding='utf-8'));sm=json.loads((s3/'manifest.json').read_text(encoding='utf-8'))
    assert fm['inputs_stable'] and sm['inputs_stable'] and sm['exit_code']==0
    assert fm['timing_violations']=={'Setup':0,'Hold':0}
    for row in fm['inputs']:
        assert sha(R/row['path'])==row['sha256'],'FPGA source no longer matches build: '+row['path']
    for name,digest in sm['inputs'].items():assert sha(R/'src/firmware/arduino/XianChu_Link_R3'/name)==digest,'S3 source no longer matches build: '+name
    (stage/'fpga').mkdir();(stage/'s3').mkdir();(stage/'validation').mkdir()
    for name in ['XianChu.fs','XianChu.rao']:shutil.copy2(fpga/name,stage/'fpga'/name)
    for row in sm['artifacts']:
        assert sha(s3/row['name'])==row['sha256'];shutil.copy2(s3/row['name'],stage/'s3'/row['name'])
    for obj,name in [(fm,'fpga-build.json'),(sm,'s3-build.json')]:
        (stage/'validation'/name).write_text(json.dumps(obj,indent=2),encoding='utf-8')
    summary=R/'docs/validation.json'
    if not summary.is_file():raise SystemExit('Write docs/validation.json from actual completed tests before packaging')
    files=[{'path':f.relative_to(stage).as_posix(),'bytes':f.stat().st_size,'sha256':sha(f)} for f in sorted(stage.rglob('*')) if f.is_file()]
    manifest={'project':'xianchu-fpga','version':a.version,'source_commit':commit,'hardware_validation':'NOT_RUN','files':files}
    (stage/'MANIFEST.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    if verify(stage):raise SystemExit('Staged release verification failed')
    dest=out/('xianchu-fpga-v'+a.version+'.zip')
    with zipfile.ZipFile(dest,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for f in sorted(stage.rglob('*')):
            if f.is_file():z.write(f,stage.name+'/'+f.relative_to(stage).as_posix())
    (out/(dest.name+'.sha256')).write_text(sha(dest)+'  '+dest.name+'\n',encoding='ascii')
    print(json.dumps({'archive':str(dest),'bytes':dest.stat().st_size,'sha256':sha(dest),'files':len(files)},ensure_ascii=False))
if __name__=='__main__':main()
