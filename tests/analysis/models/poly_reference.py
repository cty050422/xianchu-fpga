#!/usr/bin/env python3
"""Independent integer reference for poly_additive_engine (T1.3).

Re-derives the engine contract from the design constants alone:
  * sine table   : round(sin(2*pi*i/1024) * 32767)  - verified against the RTL ROM by
                   check_sine_table.py (0 mismatches), here recomputed independently
  * Q0.8 weights : PartialGains donor tables (255 = 255/256, symmetric truncation)
  * phases       : 32-bit accumulators, partial k advances by k * base_inc, sample n uses
                   the phase AFTER n increments; index = phase >> 22 before the increment
  * Nyquist guard: partial used only while k*base < NYQUIST_LIMIT, sticky guard_closed
  * mask crossfade: per-voice from/to/alpha, alpha steps +MASK_FADE_STEP per sample
  * gain chain   : musical pressure curve -> envelope multiply (rounding) -> energy
                   compensation ramp (+-1 per sample) -> GAIN_STEP ramp -> shift-add chain
  * output       : sat16(sum >>> LEVEL_SHIFT), then donor gain chain, clamp16

The model shares NO code with the RTL: every operation is re-implemented here from the
written contract, and the DUT bench compares sample-by-sample against this output.

Emits (next to this file, in 09_最终优化/证据/golden/):
  stimulus_poly.mem  one line per sample: {v3..v0: gate env expr inc preset}{accept}{ptarget}{force}
  expected_poly.mem  one line per sample: v0 v1 v2 v3 signed 16-bit hex
"""
import math
import os

PARTIALS = 32
LEVEL_SHIFT = 4
GAIN_STEP = 4
MASK_FADE_STEP = 4
NYQUIST_LIMIT = 0x7000_0000
ENERGY_COMPENSATION = True
SINE_INTERPOLATION = True

WEIGHTS = {
    0: 0x0F1010101111121213131415161717181A1B1C1E202224272B30353D485A7ACD,
    1: 0x0310031103120313041504160418051B051D06210626072C09360B470F6A1AFF,
    2: 0x091E1E1F092020210A2223240B2526270C2A2B2C0E303234113B3F441756678D,
    3: 0x020202020203030303030304040404050506060708090A0C0E11151B25378DFF,
}

def w(preset, k0):
    return (WEIGHTS[preset] >> (8 * k0)) & 0xFF

ECO = {
    0: {3:240,4:231,5:225,6:220,7:217,8:215,9:213,10:211,11:210,12:208,13:207,14:206,15:206,
        16:205,17:204,18:203,19:203,20:202,21:202,22:201,23:201,24:201,25:200,26:200,27:200,
        28:199,29:199,30:199,31:199,32:198},
    1: {3:237,4:236,5:229,6:229,7:225,8:225,9:222,10:222,11:220,12:220,13:219,14:219,15:218,
        16:218,17:217,18:217,19:216,20:216,21:216,22:216,23:215,24:215,25:215,26:215,27:214,
        28:214,29:214,30:214,31:214,32:214},
    2: {3:230,4:228,5:215,6:206,7:199,8:198,9:193,10:189,11:185,12:185,13:182,14:179,15:177,
        16:176,17:174,18:173,19:171,20:171,21:169,22:168,23:166,24:166,25:165,26:164,27:163,
        28:163,29:162,30:161,31:160,32:160},
    3: {3:252,4:250,5:249,6:248,7:248,8:247,9:247,10:247,11:247,12:247,13:247,14:247,15:247,
        16:247,17:247,18:247,19:247,20:247,21:246,22:246,23:246,24:246,25:246,26:246,27:246,
        28:246,29:246,30:246,31:246,32:246},
}

SINE = [round(math.sin(2 * math.pi * i / 1024) * 32767) for i in range(1024)]

def apply_gain(value, weight):
    product = value * weight
    return -((-product) >> 8) if product < 0 else (product >> 8)

def sat16(v):
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)

def musical_layer_gain(pressure):
    upper = (pressure - 32768) & 0xFFFF
    if not (pressure >> 15) & 1:
        wide = pressure + (pressure << 1)
        mapped = (wide >> 2) & 0xFFFF
    else:
        wide = upper + (upper << 2)
        mapped = (24576 + (wide >> 2)) & 0xFFFF
    product = mapped * 28671
    q15 = (4096 + (product >> 16)) & 0xFFFF
    return (q15 >> 7) & 0xFF

def gain_scale(bank, gain):
    ext = bank - 65536 if bank >= 32768 else bank  # sign-extend 16-bit, value unchanged
    scaled = 0
    for b in range(8):
        if (gain >> b) & 1:
            scaled += ext >> (8 - b)
    return scaled

def clamp16(v):
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)

def inc_for(freq):
    return round(freq * (1 << 32) / 48000) & 0xFFFFFFFF

# ---- scenario -----------------------------------------------------------------
# notes: voice -> list of (start, end, freq, preset, pressure, env_hold, release_step)
MODE = __import__('sys').argv[1] if len(__import__('sys').argv) > 1 else 'golden'
if MODE == '5s':
    SCEN_LEN = 240000
    NOTES = {
        0: [(100, 200000, 55.0, 0, 0xE000, 0xB000, 0x0200)],
        1: [(400, 210000, 110.0, 1, 0x6000, 0x9000, 0x0200)],
        2: [(800, 225000, 220.0, 2, 0xC000, 0xA000, 0x0200)],
        3: [(1200, 235000, 330.0, 3, 0x8000, 0x8000, 0x0200)],
    }
    PTARGET = [(0, 32)]
    FORCE_FREE_AT = -1
else:
    SCEN_LEN = 1100
    NOTES = {
        0: [(10, 510, 55.0, 0, 0xE000, 0xB000, 0x0200), (700, 900, 55.0, 2, 0xE000, 0xB000, 0x0200),
            (950, 1100, 55.0, 3, 0xE000, 0xB000, 0x0200)],
        1: [(60, 560, 110.0, 1, 0x6000, 0x9000, 0x0200)],
        2: [(120, 620, 220.0, 2, 0xC000, 0xA000, 0x0200)],
        3: [(180, 680, 660.0, 3, 0x8000, 0x8000, 0x0200)],  # 660 Hz * 32 > 21 kHz: guard bites
    }
    PTARGET = [(0, 32), (250, 16), (400, 8), (720, 32)]
    FORCE_FREE_AT = 900

def env_at(voice, n):
    """(env, pressure, gated) for sample n: full while gated, linear release tail after."""
    for (s, e, freq, preset_n, press_n, hold, rel) in NOTES[voice]:
        if s <= n < e:
            return hold, press_n, True
    env, press = 0, 0
    for (s, e, freq, preset_n, press_n, hold, rel) in NOTES[voice]:
        if n >= e:
            tail = max(0, hold - rel * (n - e))
            if tail > env:
                env, press = tail, press_n
    return env, press, False

def build():
    lines_stim = []
    lines_exp = []
    phases = [[0] * PARTIALS for _ in range(4)]
    preset_latch = [0, 0, 0, 0]
    generation = [0, 0, 0, 0]
    fade_from = [0, 0, 0, 0]
    fade_to = [0, 0, 0, 0]
    fade_alpha = [256, 256, 256, 256]
    energy = [256, 256, 256, 256]
    gain = [0, 0, 0, 0]
    partials_last = [0, 0, 0, 0]
    prev_accept = [0, 0, 0, 0]

    for n in range(SCEN_LEN):
        ptarget = 32
        for (s, v) in PTARGET:
            if n >= s:
                ptarget = v
        force = 1 if (FORCE_FREE_AT <= n < FORCE_FREE_AT + 8) else 0
        nmask = 0xFFFFFFFF if ptarget >= 32 else ((1 << ptarget) - 1)

        # per-voice stimulus for this sample
        stim_v = []
        accept_bits = 0
        for v in range(4):
            hold_or_env, press, gated = env_at(v, n)
            env = hold_or_env
            inc = 0
            preset_field = 0
            if gated:
                note = [t for t in NOTES[v] if t[0] <= n < t[1]][0]
                inc = inc_for(note[2])
                preset_field = note[3]
                accept = 1 if n == note[0] else 0
            else:
                accept = 0
            stim_v.append((gated, env, press, inc, preset_field))
            if accept:
                accept_bits |= 1 << v
        # stimulus line: v3..v0 packed {gate env expr inc preset}
        packed = 0
        for v in range(3, -1, -1):
            g, e, p, i, pr = stim_v[v]
            packed = (packed << 67) | (g << 66) | (e << 50) | (p << 34) | (i << 2) | pr
        packed = (packed << 4) | accept_bits
        packed = (packed << 6) | ptarget
        packed = (packed << 1) | force
        lines_stim.append(f"{packed:070X}")

        # ---- reference computation for sample n (inputs = line n) ----
        # events in line n were pulsed BEFORE this sample: apply them first
        for v in range(4):
            if (accept_bits >> v) & 1:
                preset_latch[v] = stim_v[v][4]
                generation[v] = (generation[v] + 1) & 0xFF
        pcm_out = []
        for v in range(4):
            g, env, press, inc, preset_field = stim_v[v]
            # 2) target from the OLD energy value (RTL comb sees pre-edge state)
            pg = musical_layer_gain(press)
            env_pg = ((pg * env) + 32768) >> 16
            target = 0 if force else ((env_pg * energy[v]) + 128) >> 8
            # 3) energy compensation ramp (uses partials of the LAST finished sample)
            if ENERGY_COMPENSATION:
                eco = ECO[preset_latch[v]].get(partials_last[v], 256)
                if energy[v] < eco:
                    energy[v] += 1
                elif energy[v] > eco:
                    energy[v] -= 1
            # 4) gain ramp with GAIN_STEP toward the target computed above
            if env == 0:
                gain[v] = 0
            elif gain[v] < target:
                gain[v] = min(target, gain[v] + GAIN_STEP)
            elif gain[v] > target:
                gain[v] = max(target, gain[v] - GAIN_STEP)
            # 5) fade update
            if fade_alpha[v] == 256:
                fade_from[v] = fade_to[v]
                if nmask != fade_to[v]:
                    fade_to[v] = nmask
                    fade_alpha[v] = 0
            elif 256 - fade_alpha[v] <= MASK_FADE_STEP:
                fade_alpha[v] = 256
            else:
                fade_alpha[v] += MASK_FADE_STEP
            # 6) weights from the LATCHED preset (events apply after this sample)
            weights = WEIGHTS[preset_latch[v]]
            # 7) sum 32 partials
            acc_from = 0
            acc_to = 0
            used = 0
            guard = inc >= NYQUIST_LIMIT
            inc_run = inc
            for k0 in range(PARTIALS):
                k = k0 + 1
                use = (((fade_alpha[v] != 256) and ((fade_from[v] >> k0) & 1)) or
                       ((fade_alpha[v] != 0) and ((fade_to[v] >> k0) & 1))) \
                      and not guard and (inc_run < NYQUIST_LIMIT)
                if not guard and inc_run < NYQUIST_LIMIT:
                    idx = phases[v][k0] >> 22
                    val = SINE[idx]
                    if SINE_INTERPOLATION:
                        frac = (phases[v][k0] >> 14) & 255
                        val += ((SINE[(idx+1) % 1024] - val) * frac) >> 8
                    wq8 = (weights >> (8 * k0)) & 0xFF  # partial k0+1 -> bits [8(k0+1)-1 -: 8]
                    scaled = apply_gain(val, wq8)
                    if (fade_from[v] >> k0) & 1: acc_from += scaled
                    if (fade_to[v] >> k0) & 1: acc_to += scaled
                    if use: used += 1
                phases[v][k0] = (phases[v][k0] + inc_run) & 0xFFFFFFFF
                guard = guard or (inc_run >= NYQUIST_LIMIT)
                inc_run = (inc_run + inc) & 0xFFFFFFFF
            # A true crossfade of the two sums; the previous union-of-masks
            # model turned partials fully on/off despite advancing alpha.
            acc = acc_from + (((acc_to-acc_from)*fade_alpha[v]) >> 8)
            assert -8388608 <= acc < 8388608, f"acc overflow voice {v} sample {n}"
            bank = sat16(acc >> LEVEL_SHIFT)
            pcm = clamp16(gain_scale(bank, gain[v]))
            pcm_out.append(pcm)
            partials_last[v] = used
        # voice3 first: $readmemh puts the leftmost hex at the MSB, and the DUT packs
        # voice0 at lane_pcm[15:0] (LSB end)
        lines_exp.append("".join(f"{(p & 0xFFFF):04X}" for p in reversed(pcm_out)))
    return lines_stim, lines_exp

def main():
    stim, exp = build()
    out = os.path.join(os.path.dirname(__file__), '..', '证据', 'golden')
    os.makedirs(out, exist_ok=True)
    if MODE == '5s':
        # three golden windows (entry / mid-sustain / final release); the bench
        # computes its own stimulus, so only expected values are shipped
        wins = [(0, 2000), (119000, 121000), (238000, 240000)]
        exp_w = []
        for a, b in wins:
            exp_w.append(f"@{a:08x}")
            exp_w.extend(exp[a:b])
        with open(os.path.join(out, 'expected_5s_windows.mem'), 'w') as f:
            f.write("\n".join(exp_w) + "\n")
        with open(os.path.join(out, 'expected_poly_5s.meta'), 'w') as f:
            f.write("windows " + " ".join(f"{a}:{b}" for a, b in wins) + "\n")
        print(f"mode={MODE} samples={len(stim)} windows={len(wins)} -> {out}")
        return
    with open(os.path.join(out, 'stimulus_poly.mem'), 'w') as f:
        f.write("\n".join(stim) + "\n")
    with open(os.path.join(out, 'expected_poly.mem'), 'w') as f:
        f.write("\n".join(exp) + "\n")
    print(f"mode={MODE} samples={len(stim)} -> {out}")

if __name__ == '__main__':
    main()
