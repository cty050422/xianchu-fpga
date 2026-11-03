"""Regenerate the small device glyph subsets from an explicitly supplied OFL font.

Requires Pillow 13.0.0. Font input is never taken from a system font directory.
Pixel resources are under SIL OFL 1.1; see third_party/fonts/OFL.txt.
"""
from pathlib import Path
import argparse,hashlib,json,re
from PIL import Image,ImageDraw,ImageFont

ROOT=Path(__file__).resolve().parents[1]
S3=ROOT/'src/firmware/arduino/XianChu_Link_R3'
EXPECTED='2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b'
PHRASES=['弦触云声','自由演奏','引导练习','节奏挑战','曲谱示范','拨弦','吹管','钟声','合成贝斯','高八度','原八度','谱定演奏','未选曲','进行中','已暂停','本曲完成','松开压力键','准备开始','待开始','声部一','声部二','声部三','声部四','数字波形','声部与输出','片内数字显示','对数幅度','实时合成数字观察','数字段延迟']

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('font',type=Path);a=p.parse_args()
    digest=hashlib.sha256(a.font.read_bytes()).hexdigest()
    if digest!=EXPECTED:raise SystemExit('Unexpected font hash; use the pinned font in third_party/fonts/README.md')
    font=ImageFont.truetype(str(a.font),14);small=ImageFont.truetype(str(a.font),8)
    def rows(ch):
        im=Image.new('1',(16,16));d=ImageDraw.Draw(im)
        if ch in '↔↕':
            if ch=='↔':
                d.line((2,8,13,8),fill=1);d.line((5,5,2,8,5,11),fill=1);d.line((10,5,13,8,10,11),fill=1)
            else:
                d.line((8,2,8,13),fill=1);d.line((5,5,8,2,11,5),fill=1);d.line((5,10,8,13,11,10),fill=1)
        else:
            l,t,r,b=font.getbbox(ch);d.text(((16-(r-l))//2-l,(16-(b-t))//2-t),ch,font=font,fill=1)
        return [sum(int(im.getpixel((x,y)))<<(15-x) for x in range(16)) for y in range(16)]
    def c_array(name,chars,decl):
        return decl+'{\n'+''.join(' {'+','.join(f'0x{v:04x}' for v in rows(c))+'}, // '+c+'\n' for c in chars)+'};'
    changed=[]
    # Preserve firmware numeric IDs and every drawing/control function.
    for filename,array in [('oled_guide_glyphs.h','cnGlyphs'),('oled_status.h','glyphs')]:
        f=S3/filename;s=f.read_text(encoding='utf-8')
        pattern=r'static const uint16_t '+array+r'\[\d+\]\[16\]=\{(.*?)\n\};'
        m=re.search(pattern,s,re.S);assert m,filename
        chars=re.findall(r'\},\s*//\s*(\S)',m[1]);assert len(chars)==(20 if filename.startswith('oled_guide') else 49)
        decl=f'static const uint16_t {array}[{len(chars)}][16]='
        s=s[:m.start()]+c_array(array,chars,decl)+s[m.end():]
        if filename=='oled_status.h':
            s,n=re.subn(r'static const uint16_t extraGlyphs\[7\]\[16\]=\{.*?\};',lambda m:c_array('extraGlyphs','已静音分量测试','static const uint16_t extraGlyphs[7][16]='),s,flags=re.S);assert n==1
        s=re.sub(r'^//.*(?:SimHei|Original raster|Additional six|Generated bitmap|XianChu UI glyph subset).*\n','',s,flags=re.M)
        f.write_text('// XianChu UI glyph subset: Noto Sans CJK SC, SIL OFL 1.1.\n'+s,encoding='utf-8');changed.append(f)
    f=S3/'performance_glyphs.h';s=f.read_text(encoding='utf-8')
    codes=[int(x) for x in re.search(r'codes\[\]=\{([^}]+)\}',s)[1].split(',')]
    s,n=re.subn(r'static const uint16_t glyphs\[\]\[16\]=\{.*?\};',lambda m:c_array('glyphs',[chr(x) for x in codes],'static const uint16_t glyphs[][16]='),s,flags=re.S);assert n==1
    s=s.replace('// Chinese bitmap glyphs only; no font binary redistributed.','// XianChu UI glyph subset: Noto Sans CJK SC, SIL OFL 1.1.')
    f.write_text(s,encoding='utf-8');changed.append(f)
    f=ROOT/'src/rtl/oled_glyph_rom.sv';s=f.read_text(encoding='utf-8')
    def replace_glyph(m):
        return m[1]+'{'+','.join(f"16'h{v:04x}" for v in reversed(rows(m[3])))+'}; // '+m[3]
    s,n=re.subn(r"(7'd\d+: word=)\{([^\n]+)\}; // ([\u4e00-\u9fff])[^\n]*",replace_glyph,s);assert n==51,n
    # Former font-derived Latin J/X/Y and axis icons are redrawn from OFL glyphs.
    for i,ch in [(46,'J'),(47,'X'),(48,'Y'),(49,'↔'),(50,'↕'),(51,'+')]:
        s,n=re.subn(rf"7'd{i}: word=\{{[^\n]+\}};[^\n]*",lambda m:f"7'd{i}: word={{"+','.join(f"16'h{v:04x}" for v in reversed(rows(ch)))+'}; // '+ch,s);assert n==1
    s=re.sub(r'// GENERATED[^\n]*','// XianChu UI glyph subset: Noto Sans CJK SC, SIL OFL 1.1.',s)
    f.write_text(s,encoding='utf-8');changed.append(f)
    chars=sorted(set(''.join(PHRASES)));words=[0]*2048
    for i,c in enumerate(chars,1):words[i*16:i*16+16]=rows(c)
    f=ROOT/'src/rtl/dashboard_zh_font.sv'
    f.write_text('// XianChu UI glyph subset: Noto Sans CJK SC, SIL OFL 1.1.\nmodule dashboard_zh_font(input logic clk,input logic[6:0]glyph,input logic[3:0]row,output logic[15:0]bits);\n(* syn_ramstyle="block_ram" *)logic[15:0]rom[0:2047];\ninitial begin\n'+''.join(f"rom[{i}]=16'h{v:04x};\n" for i,v in enumerate(words))+'end\nalways_ff@(posedge clk)bits<=rom[{glyph,row}];\nendmodule\n',encoding='utf-8');changed.append(f)
    f=ROOT/'src/rtl/vga_font8x8.sv';s=f.read_text(encoding='utf-8')
    for i in range(95):
        im=Image.new('1',(8,8));d=ImageDraw.Draw(im);ch=chr(i+32);width=d.textlength(ch,font=small)
        d.text(((8-width)/2,6),ch,font=small,fill=1,anchor='ls')
        word=sum(int(im.getpixel((x,y)))<<(7-x+y*8) for y in range(8) for x in range(8))
        s,n=re.subn(rf"(7'd{i}: word = )64'h[0-9A-Fa-f]+",lambda m:m[1]+f"64'h{word:016x}",s);assert n==1
    s=re.sub(r'// GENERATED[^\n]*','// XianChu ASCII subset: Noto Sans CJK SC, SIL OFL 1.1.',s)
    f.write_text(s,encoding='utf-8');changed.append(f)
    out=ROOT/'build/fonts';out.mkdir(parents=True,exist_ok=True)
    sheet=Image.new('RGB',(640,((len(chars)+19)//20)*44),'white');d=ImageDraw.Draw(sheet)
    for i,c in enumerate(chars):
        im=Image.new('1',(16,16))
        for y,v in enumerate(rows(c)):
            for x in range(16):im.putpixel((x,y),bool(v&(1<<(15-x))))
        sheet.paste(im.resize((32,32)),((i%20)*32,(i//20)*44))
    sheet.save(out/'glyphs.png')
    (out/'manifest.json').write_text(json.dumps({'font_sha256':digest,'outputs':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in changed}},indent=2),encoding='utf-8')
    print('Regenerated',len(changed),'glyph resources; audio/control logic unchanged')

if __name__=='__main__':main()
