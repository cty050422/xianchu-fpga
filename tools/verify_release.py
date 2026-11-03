"""Verify an extracted release against MANIFEST.json, without hardware access."""
from pathlib import Path
import hashlib,json,sys
def verify(root):
    root=Path(root).resolve();manifest=json.loads((root/'MANIFEST.json').read_text(encoding='utf-8'))
    errors=[]
    for row in manifest['files']:
        p=(root/row['path']).resolve()
        if not p.is_relative_to(root):errors.append('Unsafe path '+row['path']);continue
        if not p.is_file():errors.append('Missing '+row['path']);continue
        if p.stat().st_size!=row['bytes'] or hashlib.sha256(p.read_bytes()).hexdigest()!=row['sha256']:errors.append('Changed '+row['path'])
    print(json.dumps({'files':len(manifest['files']),'errors':errors,'hardware_validation':manifest['hardware_validation']},ensure_ascii=False))
    return 1 if errors else 0
if __name__=='__main__':raise SystemExit(verify(sys.argv[1] if len(sys.argv)>1 else Path(__file__).resolve().parents[1]))
