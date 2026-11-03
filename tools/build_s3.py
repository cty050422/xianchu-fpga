"""Clean Arduino CLI build; does not select a port or upload.

arduino-cli must be in PATH or ARDUINO_CLI. Optionally set ARDUINO_CLI_CONFIG.
Install esp32:esp32@3.3.12 and the libraries listed in docs/build.md first.
"""
from pathlib import Path
from datetime import datetime
import os,subprocess,shutil,json,hashlib
ROOT=Path(__file__).resolve().parents[1]
SKETCH=ROOT/'src/firmware/arduino/XianChu_Link_R3'
PROFILE='esp32:esp32:esp32s3:FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,PSRAM=opi,USBMode=hwcdc,CDCOnBoot=cdc'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    cli=os.environ.get('ARDUINO_CLI') or shutil.which('arduino-cli') or shutil.which('arduino-cli.exe')
    if not cli:raise SystemExit('Install arduino-cli or set ARDUINO_CLI')
    config=os.environ.get('ARDUINO_CLI_CONFIG');base=[cli]+(['--config-file',config] if config else [])
    name=datetime.now().strftime('%Y%m%d_%H%M%S');out=ROOT/'build/s3'/name;out.mkdir(parents=True)
    sources={p.name:sha(p) for p in SKETCH.iterdir() if p.suffix in {'.ino','.h','.cpp'}}
    # ASCII staging avoids Windows compiler failures on localized user directories.
    stage=Path(os.environ.get('XIANCHU_BUILD_ROOT') or Path(os.environ.get('TEMP','/tmp'))/'XianChu/build')/('s3_'+name)
    if not str(stage).isascii():raise SystemExit('Set XIANCHU_BUILD_ROOT to an ASCII-only path')
    sketch=stage/'XianChu_Link_R3';sketch.mkdir(parents=True,exist_ok=False)
    scratch=stage/'tmp';scratch.mkdir()
    for n in sources:shutil.copy2(SKETCH/n,sketch/n)
    command=base+['compile','--jobs','8','--fqbn',PROFILE,'--build-path',str(stage/'objects'),str(sketch)]
    print('Clean S3 build; progress log: '+str(out/'build.log'),flush=True)
    env={**os.environ,'TEMP':str(scratch),'TMP':str(scratch)}
    with (out/'build.log').open('wb') as log:result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,env=env)
    stable=sources=={n:sha(SKETCH/n) for n in sources}
    artifacts=[]
    if result.returncode==0 and stable:
        for f in sorted((stage/'objects').glob('*.bin')):
            shutil.copy2(f,out/f.name);artifacts.append({'name':f.name,'bytes':f.stat().st_size,'sha256':sha(f)})
        if len(artifacts)!=5:raise RuntimeError('Expected app, merged, bootloader, partitions and boot_app0 binaries')
    receipt={'fqbn':PROFILE,'clean_build':True,'inputs':sources,'inputs_stable':stable,
             'exit_code':result.returncode,'artifacts':artifacts,'hardware_validation':'NOT_RUN'}
    (out/'manifest.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    if result.returncode or not stable:raise RuntimeError('S3 build failed or inputs changed')
    print(json.dumps({'output':str(out),'artifacts':artifacts}),flush=True)
if __name__=='__main__':main()
