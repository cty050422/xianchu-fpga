"""Portable offline analysis. Never opens JTAG, serial, audio or network devices.

Examples:
  python demo_analysis.py gao capture.csv
  python demo_analysis.py wav raw_capture.wav --expected-f0 55
Outputs are new directories under build/analysis unless --out is supplied.
GAO event/accumulator rows are never interpreted as uniformly sampled audio.
"""
from __future__ import annotations

import argparse
import contextlib
import csv
from datetime import datetime
import hashlib
import html
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / 'models' / filename)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def normalize(label):
    return re.sub(r'\[.*?\]', '', re.split(r'[./\\]', label.strip().strip('"'))[-1]).strip()


def csv_contents(path):
    raw = Path(path).read_bytes()
    return raw.decode('utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig')


def capture_header(contents):
    table = list(csv.reader(contents.splitlines()))
    for i, row in enumerate(table):
        labels = {normalize(s) for s in row}
        if ({'gao_start', 'gao_accept'} <= labels or {'adsr_done', 'adsr_gate'} <= labels
                or {'ch_seq', 'ch_valid'} <= labels):
            if not any('=' in s for s in row):
                return table, i
    raise ValueError('No supported GAO bus header: export complete hexadecimal Core0/1/2 CSV.')


def decode(table, header, widths, signed):
    labels = table[header]
    positions, bit_columns = {}, {}
    for name, width in widths.items():
        matches = [i for i, label in enumerate(labels) if normalize(label) == name]
        if not matches:
            raise ValueError('Missing required grouped signal: ' + name)
        positions[name] = max(matches, key=lambda i: ':' in labels[i])
        bit_columns[name] = {int(match.group(1)): i for i, label in enumerate(labels)
                             if (match := re.fullmatch(re.escape(name) + r'\[(\d+)\]', label.strip()))}
    unknown_rows, bit_mismatches, bit_comparisons = 0, 0, 0
    decoded = []
    def token(value, width, is_signed=False):
        value = re.sub(r"^(?:0[xX]|[0-9]+'[hH])", '', value.strip())
        if not value or re.search('[xz?]', value, re.I):
            return None
        n = int(value, 16)
        if not 0 <= n < 1 << width:
            raise ValueError(f'Out-of-range unsigned {width}-bit hex token {value!r}')
        return n - (1 << width) if is_signed and n >= 1 << (width - 1) else n
    for line, raw in enumerate(table[header + 1:], header + 2):
        if not any(cell.strip() for cell in raw):
            continue
        if len(raw) != len(labels):
            raise ValueError(f'CSV column count differs at source line {line}')
        item = {'data_row_0based': len(decoded), 'source_line_1based': line, 'source_axis_token': raw[0]}
        for name, width in widths.items():
            v = token(raw[positions[name]], width, name in signed)
            item[name] = v
            if v is not None and width > 1 and set(bit_columns[name]) == set(range(width)):
                bits = [token(raw[bit_columns[name][bit]], 1) for bit in range(width)]
                if all(b is not None for b in bits):
                    bit_comparisons += 1
                    bit_mismatches += int(v % (1 << width) != sum(b << j for j, b in enumerate(bits)))
        item['row_has_unknown'] = int(any(item[n] is None for n in widths))
        unknown_rows += item['row_has_unknown']
        decoded.append(item)
    if not decoded:
        raise ValueError('No data rows in GAO export.')
    info = {'raw_data_rows': len(decoded), 'unknown_rows': unknown_rows,
            'unknown_policy': 'NaN in decoded CSV; original unknown tokens retained in raw source; never replaced by zero',
            'expanded_bus_comparisons': bit_comparisons, 'expanded_bus_mismatches': bit_mismatches,
            'source_header_line_1based': header + 1,
            'source_axis_header': labels[0], 'physical_time_axis_verified': False,
            'signals': {n: {'width': w, 'signed': n in signed, 'source_column_1based': positions[n] + 1}
                        for n, w in widths.items()}}
    return decoded, info


def write_rows(path, rows):
    if not rows:
        return
    with Path(path).open('w', newline='', encoding='utf-8-sig') as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows({k: 'NaN' if v is None else v for k, v in row.items()} for row in rows)


def plotting():
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plt.rcParams.update({'font.family': 'sans-serif', 'font.sans-serif': ['Microsoft YaHei', 'DejaVu Sans'],
                         'axes.unicode_minus': False, 'font.size': 11})
    return plt


def check_gao(source, out, kind='auto', group='auto'):
    import numpy as np
    contents = csv_contents(source)
    table, header = capture_header(contents)
    labels = {normalize(s) for s in table[header]}
    observed = 'partial32' if 'gao_accept' in labels else ('adsr' if 'adsr_done' in labels else 'chorus')
    if kind != 'auto' and kind != observed:
        raise ValueError(f'Selected {kind}, but CSV contains {observed} signals.')
    kind = observed
    if kind == 'partial32':
        checker = module('additive_checker', 'check_additive_gao_upgrade.py')
        widths, signed = checker.WIDTHS, checker.SIGNED
    elif kind == 'adsr':
        checker = module('adsr_checker', 'check_gao_current_model.py')
        widths = {'adsr_done': 1, 'adsr_gate': 1, **dict(checker.BUSES)}
        optional = {'adsr_model': 8, **dict(checker.STAGE_BUSES), 'adsr_stage_done': 1, 'adsr_capture_done': 1}
        widths.update({k: v for k, v in optional.items() if k in labels})
        signed = set()
    else:
        checker = module('chorus_checker', 'chorus_checker.py')
        schema = json.loads((HERE / '01_design/gao_schema.json').read_text('utf-8'))
        widths, signed = schema['fields'], set(checker.SIGNED)
    rows, decode_info = decode(table, header, widths, signed)
    write_rows(out / 'decoded_signals.csv', rows)
    write_json(out / 'decode_info.json', decode_info)
    values = [{k: row[k] for k in widths} for row in rows]
    active = [r for r in values if any(v is not None and v != 0 for v in r.values())]
    if not active:
        raise ValueError('All-zero/unknown GAO buffer: no completed capture. Start capture, wait for completion, then export again.')
    simulation = 'SIMULATION_NOT_HARDWARE' in (str(source) + contents).upper() or 'RTL_SIMULATION' in contents.upper()
    result = {'kind': kind, 'data_evidence': 'SIMULATION_NOT_HARDWARE' if simulation else 'GAO_EXPORT_UNVERIFIED_BOARD_IDENTITY',
              'hardware_identity_verified': False, 'decode': decode_info,
              'scope': 'Captured digital arithmetic and event records; not DAC analog measurement or key-to-audio latency'}
    plt = plotting()
    if kind == 'partial32':
        try:
            full = checker.analyze(source)
        except (ValueError, OSError) as exc:
            full = {'status': 'FAIL', 'errors': [str(exc)]}
        metadata = {'unknown_rows': decode_info['unknown_rows'], 'explicit_clock_axis': False, 'simulation_marker': simulation}
        scoped = checker.check_rows(values, metadata)
        # Independent scope: original rows stay unchanged; no clock axis is rewritten.
        # Check_rows checks row ordering and arithmetic; nominal times are not measurements.
        for key in ('clock_hz', 'computation_us', 'sample_period_clocks', 'computation_clocks', 'done_observation_clocks'):
            scoped.pop(key, None)
        for transaction in scoped.get('transactions', []):
            transaction['start_to_done_row_difference'] = transaction.pop('done_observation_clocks')
            transaction.pop('computation_clocks', None)
        scoped['scope'] = 'Row-order arithmetic/cadence only. Does not validate original time labels or physical duration.'
        result.update(status=full['status'], full_export_check=full, row_order_arithmetic=scoped,
                      time_axis_status='FAIL' if any('clock period' in e or 'decimation' in e for e in full.get('errors', []))
                      else ('PASS' if full['status'] == 'PASS' and decode_info['source_axis_header'].lower().startswith('time unit:') else 'NOT_RUN'),
                      arithmetic_status=scoped['status'])
        write_rows(out / 'partial32_terms.csv', scoped.get('terms', []))
        terms = scoped.get('terms', [])
        if terms:
            first = terms[0]['start_row']
            sample = [t for t in terms if t['start_row'] == first]
            fig, axes = plt.subplots(3, 1, figsize=(10, 9), constrained_layout=True)
            axes[0].stem([t['harmonic'] for t in sample], [t['term'] for t in sample])
            axes[0].set(xlabel='分量编号', ylabel='分量值 / LSB', title='GAO：首轮有效分量')
            axes[1].plot([t['harmonic'] for t in sample], [t['sum_after'] for t in sample], 'o-', label='捕获累加值')
            axes[1].plot([t['harmonic'] for t in sample], np.cumsum([t['term'] for t in sample]), 'x', label='按捕获分量重新求和')
            axes[1].set(xlabel='分量编号', ylabel='累加值 / LSB'); axes[1].legend()
            axes[2].plot([t['term'] - t['expected_term'] for t in terms], '.-')
            axes[2].set(xlabel='有效计算事件序号', ylabel='分量整数误差 / LSB', ylim=(-1, 1))
            fig.suptitle('GAO内部计算事件；横轴为事件顺序，不作为PCM频谱或实测时间轴')
            for ax in axes: ax.grid(True)
            fig.savefig(out / 'gao_analysis.png', dpi=180); plt.close(fig)
    elif kind == 'adsr':
        target = out / 'adsr_model_result.json'
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                checker.main(source, target)
        except SystemExit as exc:
            if not target.exists(): write_json(target, {'status': 'FAIL', 'problems': [str(exc)]})
        model = json.loads(target.read_text('utf-8'))
        result.update(status=model['status'], model_check=model,
                      limitations=['Stage counters and four release latches are not a continuous ADSR envelope.',
                                   'Recording and GAO are independent captures unless synchronization is separately established.'])
        if model.get('observed_levels') is not None:
            fig, axes = plt.subplots(1, 2, figsize=(11, 4.5), constrained_layout=True)
            axes[0].plot([0, 255, 767, 1023], model['observed_levels'], 'o', label='捕获锁存点')
            axes[0].plot([0, 255, 767, 1023], model['expected_levels'], 'x', label='定点参考')
            axes[0].set(xlabel='释放后包络更新序号', ylabel='包络 / Q16', title='仅展示四个锁存点'); axes[0].legend()
            stage = model.get('stage_timing') or {}
            axes[1].bar(['Attack', 'Decay', 'Release'], [stage.get(n + '_samples', 0) for n in ['attack', 'decay', 'release']])
            axes[1].set(ylabel='状态更新次数', title='片内阶段计数；不是按键至模拟输出延迟')
            for ax in axes: ax.grid(True)
            fig.savefig(out / 'gao_analysis.png', dpi=180); plt.close(fig)
    else:
        gains = sorted({r['ch_gain'] for r in values if r['ch_valid'] == 1 and r['ch_gain'] is not None})
        if group == 'auto':
            group = next((g for g, v in checker.GROUPS.items() if gains == [v]), None)
            if group is None: raise ValueError(f'Cannot classify one fixed D/M/W gain from valid snapshots: {gains}')
        model, v = checker.check_gao(source, group, HERE)
        result.update(status=model['status'], model_check=model,
                      gain_denominator=256, limitations=['D/M/W mean dry plus 0%, 12.5%, 25% wet contribution; W is not pure wet.',
                                                       'Separate captures are not phase aligned; this window does not prove a full LFO cycle.'])
        fig, axes = plt.subplots(2, 1, figsize=(11, 6.5), constrained_layout=True)
        n = min(400, len(v['ch_seq']))
        axes[0].plot(v['ch_dry'][:n], label='干支路'); axes[0].plot(v['ch_output'][:n], label='实际输出')
        axes[0].set(xlabel='有效音频快照序号', ylabel='PCM / LSB', title=f'Core1 {group}：干支路与混合输出'); axes[0].legend()
        expected = np.clip(v['ch_dry'] + v['ch_wet'] * v['ch_gain'] // 256, -32768, 32767)
        axes[1].plot(v['ch_output'] - expected, '.')
        axes[1].set(xlabel='有效音频快照序号', ylabel='混合整数误差 / LSB', ylim=(-1, 1))
        for ax in axes: ax.grid(True)
        fig.savefig(out / 'gao_analysis.png', dpi=180); plt.close(fig)
    if decode_info['expanded_bus_mismatches']:
        result['status'] = 'FAIL'
        result['decode_failure'] = 'Grouped buses disagree with expanded bit columns.'
    return result


def analyze_wav(source, out, expected_f0=None, channel=1):
    import numpy as np
    from scipy.io import wavfile
    fs, raw = wavfile.read(source)
    if raw.ndim not in (1, 2) or not len(raw): raise ValueError('Empty or unsupported WAV shape.')
    if raw.dtype.kind == 'i': y = raw.astype(float) / float(1 << (8 * raw.dtype.itemsize - 1))
    elif raw.dtype.kind == 'u': y = (raw.astype(float) - 128) / 128
    elif raw.dtype.kind == 'f': y = raw.astype(float)
    else: raise ValueError('Unsupported WAV sample format.')
    channels = 1 if y.ndim == 1 else y.shape[1]
    if not 1 <= channel <= channels: raise ValueError('Requested audio channel is absent.')
    y = y if y.ndim == 1 else y[:, channel - 1]
    if not np.all(np.isfinite(y)): raise ValueError('Nonfinite audio samples.')
    duration = len(y) / fs
    if duration < 2: raise ValueError('At least 2 seconds of real WAV data required.')
    length = min(round(3 * fs), len(y))
    start_candidates = range(round(.5 * fs), max(round(.5 * fs) + 1, len(y) - length - round(.25 * fs) + 1), max(1, round(.25 * fs)))
    candidates = []
    for first in start_candidates:
        z = y[first:first + length]
        if len(z) != length: continue
        block = max(1, round(.1 * fs)); blocks = z[:len(z) // block * block].reshape(-1, block)
        levels = np.sqrt(np.mean((blocks - blocks.mean(axis=1, keepdims=True)) ** 2, axis=1))
        candidates.append((first, float(levels.mean()), float(levels.std(ddof=1) / max(levels.mean(), 1e-12))))
    if not candidates:
        candidates = [(0, float(np.sqrt(np.mean(y[:length] ** 2))), 1.0)]
    maximum = max(t[1] for t in candidates)
    eligible = [t for t in candidates if t[1] >= maximum * .5 and t[1] > 1e-6]
    first, level, cv = min(eligible or candidates, key=lambda t: t[2])
    x = y[first:first + length]; centered = x - x.mean(); window = np.hanning(length)
    nfft = 1 << int(np.ceil(np.log2(4 * length)))
    mag = abs(np.fft.rfft(centered * window, nfft)) / window.sum(); mag[1:-1] *= 2
    freq = np.fft.rfftfreq(nfft, 1 / fs); db = 20 * np.log10(np.maximum(mag, 1e-12))
    peak = float(np.max(abs(y))); rms = float(np.sqrt(np.mean(y ** 2)))
    clipping = int(np.sum(abs(x) >= 1 - 1 / 32768)); resolution = fs / length
    result = {'kind': 'wav', 'status': 'PASS' if rms > 1e-6 else 'FAIL',
              'data_evidence': 'EXISTING_WAV_UNVERIFIED_CAPTURE_CHAIN', 'hardware_identity_verified': False,
              'scope': 'Analysis of supplied PCM recording; no FPGA oscillator count, DAC SNR, or analog latency inferred.',
              'sample_rate_hz': int(fs), 'channels': channels, 'analysis_channel': channel,
              'duration_s': duration, 'original_dtype': str(raw.dtype), 'peak_fs': peak,
              'peak_dbfs': float(20 * np.log10(max(peak, 1e-12))), 'rms_dbfs': float(20 * np.log10(max(rms, 1e-12))),
              'analysis_window_start_s': first / fs, 'analysis_window_seconds': length / fs,
              'window_stability_cv': cv, 'stable_window': cv < .15 and level > 1e-6,
              'window_near_fullscale_samples': clipping, 'observation_bin_hz': resolution,
              'zero_padded_fft_grid_hz': fs / nfft, 'nfft': nfft, 'normalization_applied': False,
              'spectral_observation_status': 'NOT_APPLICABLE' if expected_f0 is None else 'NOT_RUN',
              'limitations': ['FFT is computed by the computer from WAV; Core2 accumulator events are not audio PCM.',
                              'Zero padding refines the display grid, not the observation resolution.',
                              'Recording-chain response and input processing are included in measured amplitudes.']}
    harmonics = []
    if expected_f0 is not None:
        if not 5 <= expected_f0 < fs / 66: raise ValueError('Expected f0 must resolve 32 harmonics below Nyquist.')
        grid = np.linspace(expected_f0 - 2, expected_f0 + 2, 2001)
        score = sum(np.interp(k * grid, freq, mag) ** 2 / k for k in range(1, 9))
        chosen = int(np.argmax(score)); f0 = float(grid[chosen]); boundary = chosen in (0, len(grid) - 1)
        for k in range(1, 33):
            expected = k * f0; half = min(f0 * .12, max(1.5, 3 * resolution))
            ids = np.flatnonzero(abs(freq - expected) <= half)
            index = int(ids[np.argmax(mag[ids])]); side = (abs(freq - expected) >= max(6, 6 * resolution)) & (abs(freq - expected) <= f0 * .4)
            background = float(20 * np.log10(max(float(np.median(mag[side])), 1e-12)))
            prominence = float(db[index] - background); error = float(freq[index] - expected)
            detected = bool(db[index] >= -70 and prominence >= 8 and abs(error) <= max(2 * resolution, .002 * expected))
            harmonics.append({'harmonic': k, 'expected_hz': expected, 'peak_hz': float(freq[index]),
                              'frequency_error_hz': error, 'level_dbfs': float(db[index]),
                              'local_background_dbfs': background, 'prominence_db': prominence, 'detected': detected})
        count = sum(t['detected'] for t in harmonics)
        observed = count == 32 and result['stable_window'] and not boundary and clipping == 0 and rms > 1e-6
        result.update(expected_f0_hz=expected_f0, estimated_f0_hz=f0, f0_search_boundary=boundary,
                      detected_harmonics=count, all32_spectral_observation=observed,
                      spectral_observation_status='PASS' if observed else 'FAIL',
                      detection_criteria={'min_dbfs': -70, 'min_prominence_db': 8,
                                          'source': 'Existing partial32 analysis screening; not contest thresholds'})
        write_rows(out / 'harmonics.csv', harmonics)
    keep = freq <= min(fs / 2, max(2200, 35 * (expected_f0 or 55)))
    write_rows(out / 'fft.csv', [{'frequency_hz': float(f), 'amplitude_dbfs': float(a)} for f, a in zip(freq[keep], db[keep])])
    block = max(1, round(.01 * fs)); n = len(y) // block
    rr = np.sqrt(np.mean(y[:n * block].reshape(n, block) ** 2, axis=1))
    times = (np.arange(n) + .5) * block / fs
    write_rows(out / 'rms.csv', [{'time_s': float(t), 'rms_dbfs': float(20 * np.log10(max(v, 1e-12)))} for t, v in zip(times, rr)])
    plt = plotting(); fig, axes = plt.subplots(3, 1, figsize=(12, 10), constrained_layout=True)
    stride = max(1, len(y) // 50000)
    axes[0].plot(np.arange(0, len(y), stride) / fs, y[::stride], lw=.6)
    axes[0].axvspan(first / fs, (first + length) / fs, color='orange', alpha=.2)
    axes[0].set(xlabel='时间 / s', ylabel='录音幅度 / FS', title='原始录音；橙色为分析窗口')
    axes[1].plot(freq[keep], db[keep], lw=.8)
    if harmonics: axes[1].scatter([t['peak_hz'] for t in harmonics], [t['level_dbfs'] for t in harmonics], s=13, color='orange')
    axes[1].set(xlabel='频率 / Hz', ylabel='幅度 / dBFS', ylim=(-110, 0), xlim=(0, float(freq[keep][-1])),
                title='电脑端Hann FFT' + (f'；55Hz测试假设下检出 {result["detected_harmonics"]}/32 谐波' if expected_f0 == 55 else ''))
    axes[2].plot(times, 20 * np.log10(np.maximum(rr, 1e-12)))
    axes[2].set(xlabel='时间 / s', ylabel='10ms RMS / dBFS', title='录音包络；原始音频未归一化、降噪或修改')
    for ax in axes: ax.grid(True)
    fig.savefig(out / 'audio_analysis.png', dpi=180); plt.close(fig)
    return result


def finish_report(out, result):
    write_json(out / 'analysis.json', result)
    pictures = ''.join(f'<p><img src="{p.name}" style="max-width:100%"></p>' for p in out.glob('*.png'))
    title = '离线分析：' + result.get('kind', 'unknown')
    text = html.escape(json.dumps({k: v for k, v in result.items() if k not in ['full_export_check', 'row_order_arithmetic']}, ensure_ascii=False, indent=2))
    (out / 'report.html').write_text('<!doctype html><meta charset="utf-8"><title>' + title + '</title><body style="max-width:1100px;margin:30px auto;font-family:Microsoft YaHei,sans-serif"><h1>' + title + '</h1><p>来源和校验结果按本次输入记录；本工具不连接硬件。</p>' + pictures + '<pre style="white-space:pre-wrap">' + text + '</pre></body>', encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    gao = sub.add_parser('gao', help='Offline hexadecimal Core0/1/2 CSV analysis')
    gao.add_argument('input', type=Path); gao.add_argument('--out', type=Path)
    gao.add_argument('--kind', choices=['auto', 'partial32', 'adsr', 'chorus'], default='auto')
    gao.add_argument('--group', choices=['auto', 'D', 'M', 'W'], default='auto')
    wav = sub.add_parser('wav', help='Existing WAV waveform, Hann FFT and RMS')
    wav.add_argument('input', type=Path); wav.add_argument('--out', type=Path)
    wav.add_argument('--expected-f0', type=float, help='Set 55 only for the 55Hz/32-partial steady test tone')
    wav.add_argument('--channel', type=int, default=1)
    sub.add_parser('selfcheck', help='Import dependencies and read-only model provenance check')
    args = parser.parse_args(argv)
    if args.command == 'selfcheck':
        import numpy, scipy, matplotlib
        module('additive_check', 'check_additive_gao_upgrade.py'); module('adsr_check', 'check_gao_current_model.py'); module('chorus_check', 'chorus_checker.py')
        records = json.loads((HERE / 'models/provenance.json').read_text('utf-8'))
        for r in records:
            file = HERE / 'models' / r['file']
            if sha(file) != r.get('copy_sha256', r['source_sha256']).upper(): raise ValueError('Model checksum differs: ' + str(file))
        print('PASS: offline analysis dependencies and unchanged/extracted model checksums; no hardware opened.')
        return 0
    source = args.input.resolve()
    if not source.is_file(): parser.error('Input file does not exist: ' + str(source))
    out = args.out.resolve() if args.out else PACKAGE / 'build' / 'analysis' / (datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '_' + args.command)
    out.mkdir(parents=True, exist_ok=False)
    (out / 'raw').mkdir(); copy = out / 'raw' / source.name; shutil.copy2(source, copy)
    if sha(source) != sha(copy): raise ValueError('Raw copy checksum differs.')
    provenance = {'input_file': str(source), 'raw_copy': str(copy), 'source_sha256': sha(source),
                  'raw_copy_sha256': sha(copy), 'created_at': datetime.now().isoformat(),
                  'analysis_script_sha256': sha(Path(__file__)), 'hardware_identity_verified': False,
                  'source_profile': 'Input provenance only. CSV/WAV does not authenticate programmed image.'}
    package_json = PACKAGE / 'package.json'
    if package_json.exists(): provenance['package_json_sha256'] = sha(package_json)
    write_json(out / 'provenance.json', provenance)
    try:
        result = check_gao(source, out, args.kind, args.group) if args.command == 'gao' else analyze_wav(source, out, args.expected_f0, args.channel)
    except (ValueError, OSError, KeyError, IndexError, TypeError) as exc:
        result = {'kind': args.command, 'status': 'FAIL', 'errors': [str(exc)], 'raw_retained': True}
    result['provenance'] = provenance
    finish_report(out, result)
    print(json.dumps({'status': result['status'], 'kind': result['kind'], 'arithmetic_status': result.get('arithmetic_status'),
                      'time_axis_status': result.get('time_axis_status'), 'spectral_observation_status': result.get('spectral_observation_status'),
                      'errors': result.get('errors', []), 'output': str(out)}, ensure_ascii=False, indent=2))
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
