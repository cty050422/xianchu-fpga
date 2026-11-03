"""Strict read-only validation of the integrated interpolated 32-term GAO export.

Use the historical checker for historical 66-clock streams. This checker requires
the explicit new interpolation/phase taps and the precise 99-edge done protocol.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import re

WIDTHS={"sample_ce":1,"gao_start":1,"gao_accept":1,"gao_done":1,"busy":1,
    "stage":1,"gao_overrun":1,"gao_index":6,"gao_term":24,"gao_sum_before":24,
    "gao_sum_after":24,"partials_active":6,"used_count":6,"base_latch":32,
    "inc_running":32,"amp_shift":5,"gao_phase":32,"gao_level_shift":4,
    "gao_pcm":16,"gao_target_mask":32,"gao_test_mode":1,"gao_single":1,
    "gao_interpolated":1,"gao_mask_fade":1,"gao_reset_n":1,"gao_pll_locked":1,
    "gao_overrun_count":16,"gao_trigger32":1,"gao_target_accept":1,"gao_steady":1}
SIGNED={"gao_term","gao_sum_before","gao_sum_after","gao_pcm"}
BUILD_BASE=0x004b17e5


def normalized(name):
    return re.sub(r"\[.*?\]", "", re.split(r"[./\\]",name.strip().strip('"'))[-1]).strip()


def parse_capture(path: Path,radix="hex",clock_hz=12288000):
    contents=path.read_text(encoding="utf-8-sig")
    raw=list(csv.reader(contents.splitlines()))
    header=-1
    for i,row in enumerate(raw):
        names=[normalized(s) for s in row]
        if "gao_start" in names and "gao_accept" in names and not any("=" in s for s in row):
            header=i;break
    if header<0:raise ValueError("GAO named-bus header missing")
    labels=raw[header];positions={}
    for name in WIDTHS:
        matches=[i for i,s in enumerate(labels) if normalized(s)==name]
        if not matches:raise ValueError("Missing new GAO signal "+name)
        # Prefer grouped bus over expanded individual bit columns.
        positions[name]=max(matches,key=lambda i:1 if ":" in labels[i] else 0)
    cycle_col=next((i for i,s in enumerate(labels) if s.strip().lower()=="cycle"),None)
    time_col=next((i for i,s in enumerate(labels) if "time unit:" in s.lower()),None)
    time_scale=None
    if time_col is not None:
        unit=labels[time_col].lower().split(":",1)[1].strip()
        time_scale={"ns":1e-9,"us":1e-6,"ms":1e-3,"s":1}.get(unit)
        if time_scale is None:raise ValueError("Unsupported export time unit "+unit)
    rows=[];clock_axis=[];unknown=0
    for raw_row in raw[header+1:]:
        if not any(s.strip() for s in raw_row):continue
        values={}
        for key,col in positions.items():
            token=raw_row[col].strip() if col<len(raw_row) else ""
            token=re.sub(r"^(?:0x|[0-9]+'[hH])","",token)
            if not token or re.search(r"[xz?]",token,re.I):
                values[key]=None;continue
            try:v=int(token,16 if radix=="hex" else 10)
            except ValueError as e:raise ValueError(f"Invalid {key} token {token!r}") from e
            width=WIDTHS[key]
            if not 0<=v<2**width:raise ValueError(f"{key} exceeds unsigned {width}-bit export")
            if key in SIGNED and v>=2**(width-1):v-=2**width
            values[key]=v
        unknown+=any(v is None for v in values.values())
        rows.append(values)
        if cycle_col is not None:clock_axis.append(float(raw_row[cycle_col]))
        elif time_col is not None:clock_axis.append(float(raw_row[time_col])*time_scale*clock_hz)
    if len(rows)<256:raise ValueError("Fewer than 256 raw clock rows")
    if clock_axis:
        for a,b in zip(clock_axis,clock_axis[1:]):
            if abs((b-a)-1)>0.02:raise ValueError("Export has missing rows, decimation, or incorrect clock period")
    return rows,{"unknown_rows":unknown,"explicit_clock_axis":bool(clock_axis),
                 "simulation_marker":"SIMULATION_NOT_HARDWARE" in contents}


def coefficient(i):
    x=32767*math.sin(2*math.pi*(i%1024)/1024)
    return math.floor(x+.5) if x>=0 else math.ceil(x-.5)


def expected_term(phase_after,increment,k):
    phase=(phase_after-increment)&0xffffffff
    index=phase>>22;fraction=(phase>>14)&255
    a=coefficient(index);b=coefficient(index+1)
    value=a+(((b-a)*fraction+128)>>8)
    return value>>(k.bit_length()-1)


def check_rows(rows,metadata):
    errors=[];transactions=[];terms=[]
    def require(test,message):
        if not test:errors.append(message)
    starts=[i for i,r in enumerate(rows) if r["gao_start"]==1]
    require(len(starts)>=2,"Need at least two start events to verify the 256-clock cadence")
    require(all(b-a==256 for a,b in zip(starts,starts[1:])),"Sample start cadence is not exactly 256 clocks")
    require(not any(r["gao_overrun"] not in (0,None) or r["gao_overrun_count"] not in (0,None) for r in rows),"Overrun flag/count present")
    complete=0;last_phase={};trailing_incomplete=0
    constants={"gao_test_mode":1,"gao_single":0,"gao_interpolated":1,"gao_mask_fade":1,
        "gao_reset_n":1,"gao_pll_locked":1,"gao_steady":1,"partials_active":32,
        "gao_target_mask":0xffffffff,"base_latch":BUILD_BASE,"gao_level_shift":4,
        "gao_overrun":0,"gao_overrun_count":0}
    for number,start in enumerate(starts):
        boundary=starts[number+1] if number+1<len(starts) else len(rows)
        segment=rows[start:boundary]
        done=[start+j for j,r in enumerate(segment) if r["gao_done"]==1]
        if not done and boundary-start<100 and number==len(starts)-1:
            trailing_incomplete+=1;continue
        prefix=f"start row {start}: "
        require(len(done)==1,prefix+"expected exactly one completion")
        if len(done)!=1:continue
        finish=done[0];frame=rows[start:finish+1]
        if any(any(v is None for v in r.values()) for r in frame):
            require(False,prefix+"unknown/missing token inside transaction");continue
        require(finish-start==99,prefix+"registered done must be 99 clocks after start (98 computation clocks)")
        for key,value in constants.items():
            require(all(r[key]==value for r in frame),prefix+f"unexpected {key}")
        require(rows[start]["gao_trigger32"]==1,prefix+"unqualified trigger")
        require(all(r["gao_target_accept"]==r["gao_accept"] for r in frame),prefix+"qualified/raw accept mismatch")
        accepted=[i for i in range(start,finish+1) if rows[i]["gao_accept"]==1]
        require(len(accepted)==32,prefix+"expected exactly 32 accepted terms")
        require([rows[i]["gao_index"] for i in accepted]==list(range(1,33)),prefix+"term index omission/duplication/order")
        require(accepted==list(range(start+3,start+97,3)),prefix+"expected a term every 3 clocks at offsets 3..96")
        require(rows[start]["busy"]==0 and all(rows[i]["busy"]==1 for i in range(start+1,min(start+99,len(rows)))) and rows[finish]["busy"]==0,prefix+"busy interval mismatch")
        total=0
        for term_number,i in enumerate(accepted,1):
            r=rows[i];k=r["gao_index"]
            require(1<=k<=32,prefix+"invalid harmonic index")
            if not 1<=k<=32:continue
            require(r["inc_running"]==k*BUILD_BASE,prefix+f"term {k} wrong phase increment")
            require(r["amp_shift"]==k.bit_length()-1,prefix+f"term {k} wrong weight shift")
            require(r["used_count"]==term_number-1,prefix+f"term {k} wrong accepted count")
            expected=expected_term(r["gao_phase"],r["inc_running"],k)
            require(r["gao_term"]==expected,prefix+f"term {k} lookup/interpolation arithmetic differs")
            require(r["gao_sum_before"]==total,prefix+f"term {k} accumulator discontinuity")
            total+=r["gao_term"]
            require(r["gao_sum_after"]==total,prefix+f"term {k} accumulator arithmetic differs")
            require(-(2**23)<=total<2**23,prefix+"24-bit sum overflow")
            if k in last_phase:
                require(r["gao_phase"]==(last_phase[k]+k*BUILD_BASE)&0xffffffff,prefix+f"term {k} phase is not continuous")
            last_phase[k]=r["gao_phase"]
            terms.append({"start_row":start,"accept_row":i,"harmonic":k,"term":r["gao_term"],
                "expected_term":expected,"sum_before":r["gao_sum_before"],"sum_after":r["gao_sum_after"]})
        expected_pcm=max(-32768,min(32767,total>>4))
        require(rows[finish]["gao_pcm"]==expected_pcm,prefix+"final sum to output PCM differs")
        require(rows[finish]["used_count"]==32,prefix+"final used_count is not32")
        transactions.append({"start_row":start,"done_row":finish,"done_observation_clocks":finish-start,
            "computation_clocks":finish-start-1,"accepted_terms":len(accepted),"sum":total,
            "expected_pcm":expected_pcm,"observed_pcm":rows[finish]["gao_pcm"]})
        complete+=1
    require(complete>=2,"Fewer than two complete 32-term transactions")
    return {"status":"PASS" if not errors else "FAIL","evidence_kind":"SIMULATION_NOT_HARDWARE" if metadata["simulation_marker"] else "PHYSICAL_GAO_UNVERIFIED_IDENTITY",
        "hardware_identity":"NOT_VERIFIED_BY_CSV","errors":errors,"complete_transactions":complete,
        "trailing_incomplete_transactions":trailing_incomplete,"raw_rows":len(rows),
        "unknown_rows":metadata["unknown_rows"],"sample_period_clocks":256,
        "done_observation_clocks":99,"computation_clocks":98,"clock_hz":12288000,
        "computation_us":98/12288000*1e6,"transactions":transactions,"terms":terms}


def analyze(path: Path,radix="hex",clock_hz=12288000):
    rows,metadata=parse_capture(path,radix,clock_hz)
    result=check_rows(rows,metadata)
    result["source_file"]=str(path.resolve());result["source_sha256"]=hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument("csv",type=Path);p.add_argument("--output",type=Path)
    p.add_argument("--radix",choices=["hex","decimal"],default="hex")
    args=p.parse_args()
    try:result=analyze(args.csv,args.radix)
    except (ValueError,OSError) as e:result={"status":"FAIL","errors":[str(e)]}
    if args.output:
        args.output.mkdir(parents=True,exist_ok=True)
        (args.output/"gao_upgrade_result.json").write_text(json.dumps(result,indent=2),encoding="utf-8")
        if result.get("terms"):
            with (args.output/"gao_upgrade_terms.csv").open("w",newline="",encoding="utf-8") as f:
                w=csv.DictWriter(f,fieldnames=list(result["terms"][0]));w.writeheader();w.writerows(result["terms"])
    print(json.dumps({k:v for k,v in result.items() if k not in ("terms","transactions")},indent=2))
    raise SystemExit(0 if result["status"]=="PASS" else 1)


if __name__=="__main__":main()
