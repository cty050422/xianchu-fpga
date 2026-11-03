"""Native C++ tests for the S3 protocol, authorization, OLED and BLE relay.

Requires g++ (CXX can override). Does not use ESP32 or any physical interface.
"""
from pathlib import Path
from datetime import datetime
import os,shutil,subprocess,json,hashlib
R=Path(__file__).resolve().parents[1];S=R/'src/firmware/arduino/XianChu_Link_R3'
def main():
    compiler=os.environ.get('CXX') or shutil.which('g++')
    if not compiler:raise SystemExit('g++ missing; set CXX to your host compiler')
    out=R/'build/cpp'/datetime.now().strftime('%Y%m%d_%H%M%S');out.mkdir(parents=True)
    env={**os.environ,'PATH':str(Path(compiler).parent)+os.pathsep+os.environ.get('PATH','')}
    tests=sorted((S/'test').glob('test_*.cpp'))+sorted((R/'tests/integration').glob('test_*.cpp'))
    results=[]
    for source in tests:
        exe=out/(source.stem+('.exe' if os.name=='nt' else ''))
        args=[compiler,'-std=c++17','-Wall','-Wextra','-O2','-I',str(S),str(source),'-o',str(exe)]
        c=subprocess.run(args,capture_output=True,env=env,timeout=90)
        (out/(source.stem+'_compile.log')).write_bytes(c.stdout+c.stderr)
        result={'test':source.relative_to(R).as_posix(),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'compile_exit':c.returncode}
        if c.returncode==0:
            p=subprocess.run([str(exe)],cwd=out,capture_output=True,env=env,timeout=90)
            (out/(source.stem+'_run.log')).write_bytes(p.stdout+p.stderr);result['run_exit']=p.returncode
        results.append(result);print(json.dumps(result),flush=True)
    passed=all(r.get('run_exit')==0 for r in results)
    (out/'results.json').write_text(json.dumps({'scope':'native C++ only','passed':passed,'results':results},indent=2),encoding='utf-8')
    raise SystemExit(0 if passed else 1)
if __name__=='__main__':main()
