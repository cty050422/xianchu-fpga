"""Verify Core0 release CSV using its captured, versioned Q16 model identifier.

Usage: python check_gao_current_model.py <board_core0.csv> <report.json>
This checks data consistency; it cannot authenticate the programmed FPGA image.
"""
import csv
import hashlib
import json
import pathlib
import sys

FIELDS = ("adsr_done", "adsr_gate", "adsr_preset[1:0]",
          "adsr_event_count[7:0]", "adsr_start[15:0]",
          "adsr_256[15:0]", "adsr_768[15:0]", "adsr_1024[15:0]")
BUSES = (("adsr_preset", 2), ("adsr_event_count", 8),
         ("adsr_start", 16), ("adsr_256", 16),
         ("adsr_768", 16), ("adsr_1024", 16))
RELEASE_STEP = {0: 4, 1: 8, 2: 4, 3: 64}
MODEL_NAMES = {1: "CURVE_SHIFT9_TRUNCATE_V1", 2: "CURVE_SHIFT9_FRACTION_SAVING_V1",4:"MUSICAL_SHIFT12_FRACTION_SAVING"}
MUSICAL_RELEASE={0:4,1:8,2:1,3:16}
MUSICAL_SUSTAIN={0:24576,1:36864,2:24576,3:32768}
STAGE_FIELDS = ("adsr_attack_count[15:0]", "adsr_decay_count[15:0]",
                "adsr_release_count[15:0]", "adsr_stage_valid[2:0]",
                "adsr_stage_overflow[2:0]", "adsr_stage_done",
                "adsr_captured_preset[1:0]", "adsr_capture_done")
STAGE_BUSES = (("adsr_attack_count", 16), ("adsr_decay_count", 16),
               ("adsr_release_count", 16), ("adsr_stage_valid", 3),
               ("adsr_stage_overflow", 3), ("adsr_captured_preset", 2))
ATTACK_STEP = {0: 512, 1: 256, 2: 2048, 3: 2048}
DECAY_STEP = {0: 8, 1: 16, 2: 4, 3: 64}
BALANCED_SUSTAIN = {0: 32768, 1: 32768, 2: 28672, 3: 28672}


def expected_landmarks(start, step, model=1):
    if model not in MODEL_NAMES:
        raise ValueError(f"Unsupported ADSR model: {model}")
    values = {0: start}
    level = start
    remainder = 0
    for sample in range(1, 1024):
        shift=12 if model==4 else 9
        numerator = level + (remainder if model in (2,4) else 0)
        level = max(0, level - step - (numerator >> shift))
        remainder = (numerator & ((1<<shift)-1)) if model in (2,4) and level else 0
        if sample in (255, 767, 1023):
            values[sample] = level
    return [values[key] for key in (0, 255, 767, 1023)]


def segment_samples(start, target, step, model):
    level, remainder, count = start, 0, 0
    while True:
        count += 1
        shift=12 if model==4 else 9
        numerator = max(0, level-target) + (remainder if model in (2,4) else 0)
        delta = step + (numerator >> shift)
        if step == 0 or level <= target or level-target <= delta:
            return count
        level -= delta
        remainder = numerator & ((1<<shift)-1) if model in (2,4) else 0
        if count > 65535:
            raise ValueError("Reference segment exceeds observer range")


def main(source, target):
    lines = source.read_text(encoding="utf-8-sig").splitlines()
    header_index = next((i for i, line in enumerate(lines)
                         if line.startswith("time unit:")), None)
    if header_index is None:
        raise SystemExit("GAO time/header row missing")
    parsed = list(csv.reader(lines[header_index:]))
    header = [item.strip() for item in parsed[0]]
    missing = [field for field in FIELDS if field not in header]
    if missing:
        raise SystemExit(f"Missing ADSR columns: {missing}")
    model_column = "adsr_model[7:0]" in header
    stage_columns = any(field in header for field in STAGE_FIELDS)
    if stage_columns and any(field not in header for field in STAGE_FIELDS):
        raise SystemExit("Partial stage timing columns; use the matching complete Core0 export")
    fields = FIELDS + (("adsr_model[7:0]",) if model_column else ())
    buses = BUSES + ((("adsr_model", 8),) if model_column else ())
    if stage_columns:
        if not model_column:
            raise SystemExit("Stage timing exports require captured adsr_model")
        fields += STAGE_FIELDS
        buses += STAGE_BUSES
    indices = {field: header.index(field) for field in fields}
    valid, excluded_prefix, invalid_after_data = [], 0, 0
    bit_mismatch = 0
    for row in parsed[1:]:
        try:
            sample_index = int(row[0].strip())
            values = tuple(int(row[indices[field]].strip(), 16) for field in fields)
        except (ValueError, IndexError):
            if valid:
                invalid_after_data += 1
            else:
                excluded_prefix += 1
            continue
        for name, width in buses:
            bus = values[fields.index(f"{name}[{width-1}:0]")]
            try:
                bits = sum(int(row[header.index(f"{name}[{bit}]")].strip(), 16) << bit
                           for bit in range(width))
            except (ValueError, IndexError):
                bit_mismatch += 1
                continue
            bit_mismatch += int(bus != bits)
        valid.append((sample_index, values))

    problems = []
    model = 1  # Only the legacy format omits the explicit model field.
    stage_report = None
    if len(valid) != 1024:
        problems.append(f"expected 1024 valid samples, found {len(valid)}")
    if invalid_after_data:
        problems.append(f"{invalid_after_data} invalid rows inside/after valid capture")
    if bit_mismatch:
        problems.append(f"{bit_mismatch} bus/bit disagreements")
    if valid:
        times = [sample for sample, _ in valid]
        if times != list(range(1, len(valid) + 1)):
            problems.append("capture indices are not continuous from 1")
        preset_values = {values[2] for _, values in valid}
        gate_values = {values[1] for _, values in valid}
        event_values = {values[3] for _, values in valid}
        starts = {values[4] for _, values in valid}
        middle_256 = {values[5] for _, values in valid}
        middle_768 = {values[6] for _, values in valid}
        if model_column:
            captured_models = {values[8] for _, values in valid}
            if len(captured_models) != 1 or next(iter(captured_models)) not in MODEL_NAMES:
                problems.append(f"unsupported or changing ADSR model: {captured_models}")
                model = None
            else:
                model = next(iter(captured_models))
        if len(preset_values) != 1 or next(iter(preset_values)) not in RELEASE_STEP:
            problems.append(f"preset must stay at a supported value 0..3: {preset_values}")
        if gate_values != {0}:
            problems.append(f"gate not stably released: {gate_values}")
        if len(event_values) != 1 or next(iter(event_values)) == 0:
            problems.append(f"event count is not stable/nonzero: {event_values}")
        if len(starts) != 1 or next(iter(starts)) == 0:
            problems.append(f"start level invalid: {starts}")
        if len(middle_256) != 1 or len(middle_768) != 1:
            problems.append("release landmarks changed during capture")
        first_done = next((i for i, (_, values) in enumerate(valid) if values[0]), None)
        if not stage_columns:
            if first_done != 128 or any(values[0] != int(i >= 128)
                                        for i, (_, values) in enumerate(valid)):
                problems.append(f"adsr_done trigger shape differs; first high at {first_done}")
            if any(values[7] != 0 for _, values in valid[:128]):
                problems.append("final release latch was nonzero before done")
        else:
            trigger_idx = fields.index("adsr_capture_done")
            if any(values[trigger_idx] != int(i >= 128)
                   for i, (_, values) in enumerate(valid)):
                problems.append("adsr_capture_done trigger shape differs from 128 pretrigger samples")
            if any(values[0] != 1 for _, values in valid[128:]):
                problems.append("release landmarks are not complete after combined trigger")
        observed = list(valid[-1][1][4:8])
        preset = valid[-1][1][2]
        release_table=MUSICAL_RELEASE if model==4 else RELEASE_STEP
        sustain_table=MUSICAL_SUSTAIN if model==4 else BALANCED_SUSTAIN
        expected = (expected_landmarks(observed[0], release_table[preset], model)
                    if preset in RELEASE_STEP and model in MODEL_NAMES else None)
        if expected is not None and observed != expected:
            problems.append(f"release model mismatch: observed {observed}, expected {expected}")
        if any(list(values[4:7]) != observed[:3] or
               (values[7] != observed[3] and i >= 128)
               for i, (_, values) in enumerate(valid)):
            problems.append("latched release values are not stable after trigger")
        if stage_columns and len(valid)>128:
            # Stage snapshots may still change before the combined trigger.
            snapshots=[dict(zip(fields,values)) for _,values in valid[128:]]
            final=snapshots[-1]
            stable_fields=STAGE_FIELDS[:-1]
            if any(any(row[name] != final[name] for name in stable_fields) for row in snapshots):
                problems.append("stage timing snapshots changed after combined trigger")
            a=final[STAGE_FIELDS[0]];d=final[STAGE_FIELDS[1]];r=final[STAGE_FIELDS[2]]
            stage_valid=final[STAGE_FIELDS[3]]
            if final[STAGE_FIELDS[4]] != 0:
                problems.append("stage timing counter overflow; duration is censored")
            if final[STAGE_FIELDS[5]] != 1 or not (stage_valid & 4):
                problems.append("release stage has not completed")
            if (stage_valid & 2) and not (stage_valid & 1):
                problems.append("completed decay without completed attack in this epoch")
            if final[STAGE_FIELDS[6]] != preset:
                problems.append("timing epoch preset differs from release landmark preset")
            if preset in ATTACK_STEP and model in MODEL_NAMES:
                a_max=(65535+ATTACK_STEP[preset]-1)//ATTACK_STEP[preset]
                expected_d=segment_samples(65535,sustain_table[preset],DECAY_STEP[preset],model)
                expected_r=segment_samples(observed[0],0,release_table[preset],model)
                if not 0 <= a <= a_max or ((stage_valid & 1) and a == 0):
                    problems.append(f"attack residence count outside possible range: {a}, max {a_max}")
                if (stage_valid & 2) and d != expected_d:
                    problems.append(f"completed decay count mismatch: {d} vs {expected_d}")
                if (stage_valid & 4) and r != expected_r:
                    problems.append(f"completed release count mismatch: {r} vs {expected_r}")
                stage_report={"attack_samples":a,"decay_samples":d,"release_samples":r,
                    "complete_mask":stage_valid,"overflow_mask":final[STAGE_FIELDS[4]],
                    "expected_decay_samples_from_full_scale":expected_d,
                    "expected_release_samples_from_captured_start":expected_r,
                    "attack_max_samples_from_zero":a_max,
                    "attack_matches_zero_start":bool(stage_valid & 1) and a==a_max,
                    "attack_start_level_observed":False,
                    "duration_ms_at_nominal_48khz":{"attack":a/48,"decay":d/48,"release":r/48},
                    "physical_latency_measured":False,
                    "limitations":"Attack initial level is not captured; only its valid range is checked. Counts are ADSR state updates, not physical input latency."}
    else:
        preset, first_done, observed, expected = None, None, None, None

    result = {"evidence": "GAO_CAPTURE_BOARD_IDENTITY_NOT_VERIFIED",
              "source_csv": str(source.resolve()),
              "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest().upper(),
              "valid_rows": len(valid), "excluded_prefix_rows": excluded_prefix,
              "invalid_after_data_rows": invalid_after_data,
              "bus_bit_mismatches": bit_mismatch, "first_done_high_row_zero_based": first_done,
              "preset": preset, "observed_levels": observed,
              "model_id": model, "model_name": MODEL_NAMES.get(model),
              "model_source": "captured_adsr_model" if model_column else "legacy_csv_without_model_field",
              "stage_timing": stage_report,
              "expected_levels": expected, "hardware_programmed_identity_verified": False,
              "problems": problems, "status": "PASS" if not problems else "FAIL"}
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{result['status']}: preset={preset}, rows={len(valid)}, levels={observed}")
    if problems:
        for problem in problems:
            print(problem)
        raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
