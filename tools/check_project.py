"""Fast, offline source-package checks. No vendor tools or hardware required."""
from pathlib import Path
import json,re,xml.etree.ElementTree as ET,hashlib
R=Path(__file__).resolve().parents[1]
def main():
    errors=[]
    required=['README.md','LICENSE','NOTICE.md','docs/hardware.md','docs/build.md','docs/usage.md','docs/architecture.md','docs/testing.md','docs/protocol.md','third_party/fonts/OFL.txt']
    for f in required:
        if not (R/f).is_file():errors.append('Missing '+f)
    g=R/'src/gowin/narrative/narrative.gprj';tree=ET.parse(g);count=0
    for e in tree.findall('.//File'):
        if e.attrib.get('enable')!='1':continue
        p=(g.parent/e.attrib['path']).resolve();count+=1
        if not p.is_relative_to(R) or not p.is_file():errors.append('Unresolvable project input '+e.attrib['path'])
    config=json.loads((R/'src/wechat_miniprogram/project.config.json').read_text(encoding='utf-8'))
    if config.get('appid')!='touristappid':errors.append('Public configuration must not contain a private AppID')
    # Do not confuse a declared source compatibility marker with programmed identity.
    ino=(R/'src/firmware/arduino/XianChu_Link_R3/XianChu_Link_R3.ino').read_text(encoding='utf-8')
    if 'XC-LINK-R3-LIVE-20261101' not in ino:errors.append('Unexpected bridge baseline marker')
    for folder in ['src','tests','tools','docs']:
        for p in (R/folder).rglob('*'):
            if not p.is_file() or 'node_modules' in p.parts or p.suffix not in {'.py','.js','.mjs','.json','.md','.sv','.v','.h','.cpp','.cmd','.cst'}:continue
            s=p.read_text(encoding='utf-8',errors='replace')
            if p.resolve()==Path(__file__).resolve():continue  # scanner patterns are not private data
            if re.search(r'(?:[CD]:[/\\](?:Users[/\\]px|user[/\\]Desktop)|codex-runtimes|docs/workbuddy/)',s,re.I):errors.append('Private local reference '+p.relative_to(R).as_posix())
            if re.search(r'\bsk-[A-Za-z0-9_-]{20,}\b|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',s):errors.append('Possible secret '+p.relative_to(R).as_posix())
    print(json.dumps({'enabled_fpga_inputs':count,'errors':errors},ensure_ascii=False,indent=2))
    raise SystemExit(1 if errors else 0)
if __name__=='__main__':main()
