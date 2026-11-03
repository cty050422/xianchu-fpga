import re, math
txt = open('01_源码/rtl/sine_table_1024.sv', encoding='utf-8').read()
pat = re.compile(r"rom\[\s*(\d+)\]\s*=\s*(-?)16'sd(\d+)")
pairs = pat.findall(txt)
rtl = {int(i): (1 if s == '' else -1) * int(v) for i, s, v in pairs}
print('entries:', len(rtl))
bad = 0
for i in range(1024):
    ref = round(math.sin(2*math.pi*i/1024) * 32767)
    if rtl[i] != ref:
        bad += 1
        if bad <= 5:
            print('mismatch', i, rtl[i], ref)
print('mismatches:', bad)
