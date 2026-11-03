"""Offline cursor-readout register. Never connects to a scope, FPGA or serial port."""
from pathlib import Path
from datetime import datetime
import argparse
import csv
import hashlib
import html
import json
import math
import shutil
import statistics
import sys

ROOT = Path(__file__).resolve().parents[2]
FIELDS = ['trial_id', 'zone', 'image', 'image_sha256', 'delta_ms',
          'timebase_ms_div', 'cursor_readout_resolution_ms', 'definition_confirmed',
          'disposition', 'note', 'registered_at']


def stamp():
    return datetime.now().strftime('%Y%m%d_%H%M%S_%f')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def positive(value, name):
    try:
        result = float(value)
    except (ValueError, TypeError):
        raise ValueError(name + '必须填写数值') from None
    if not math.isfinite(result) or result <= 0:
        raise ValueError(name + '必须是有限正数')
    return result


def validate(profile):
    for field in ('instrument', 'input_node', 'output_node', 'ground_reference',
                  'probe_input', 'probe_output', 'condition', 'input_event', 'output_event'):
        if not str(profile.get(field) or '').strip():
            raise ValueError('请先填写测量条件：' + field)
    positive(profile.get('output_threshold_v'), '输出起音门槛/V')
    levels = profile.get('input_threshold_v_by_zone', {})
    for zone in range(4):
        value = levels.get(str(zone))
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError('四区输入电压门槛必须在采集前填写，区域' + str(zone + 1))
    if profile.get('input_direction') not in ('rising', 'falling'):
        raise ValueError('输入越阈方向只能为rising或falling')


def initialize(profile, image, capture_root=None):
    profile = dict(profile)
    validate(profile)
    image = Path(image).resolve()
    if not image.is_file() or image.suffix.lower() != '.fs':
        raise ValueError('请选择本次实际手动烧录的.fs文件')
    dest = Path(capture_root or ROOT / 'build/measurements/scope') / ('SCREEN_' + stamp())
    dest.mkdir(parents=True)
    profile.update(bitstream_sha256=sha(image), profile_frozen_before_capture=True)
    (dest / 'profile.json').write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding='utf-8')
    meta = {'schema': 'SCOPE_SCREEN_V1', 'evidence': 'OSCILLOSCOPE_SCREENSHOT_MANUAL_CURSOR',
            'expected_local_bitstream': str(image), 'bitstream_sha256': sha(image),
            'profile_sha256': sha(dest / 'profile.json'),
            'programmed_identity': 'OPERATOR_DECLARATION_NOT_FPGA_READBACK',
            'created_at': datetime.now().isoformat(), 'planned_valid_per_zone': 25}
    (dest / 'session.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
    with (dest / 'readings.csv').open('w', encoding='utf-8-sig', newline='') as f:
        csv.DictWriter(f, fieldnames=FIELDS).writeheader()
    return dest


def frozen(session):
    session = Path(session)
    meta = read(session / 'session.json')
    if meta.get('schema') != 'SCOPE_SCREEN_V1':
        raise ValueError('不是截图光标读数批次')
    if sha(session / 'profile.json') != meta['profile_sha256']:
        raise ValueError('本批次测量条件已被改动，请新建批次，不要混合阈值')
    profile = read(session / 'profile.json')
    validate(profile)
    return meta, profile


def register(session, image, zone, delta_ms, timebase_ms_div, resolution_ms,
             definition_confirmed=False, disposition='valid', note=''):
    session, image = Path(session), Path(image)
    frozen(session)
    if zone not in range(4):
        raise ValueError('区域必须为0至3，对应实物区域1至4')
    if disposition not in ('valid', 'invalid'):
        raise ValueError('试次类型必须为valid或invalid')
    if disposition == 'valid' and not definition_confirmed:
        raise ValueError('请核对两路波形、起止光标与预定阈值，再确认该试次有效')
    if disposition == 'invalid' and not note.strip():
        raise ValueError('无效试次需保留原因')
    delta = positive(delta_ms, '光标Δt/ms') if disposition == 'valid' else ''
    timebase = positive(timebase_ms_div, '时基/ms每格')
    resolution = positive(resolution_ms, 'Δt显示末位分辨率/ms')
    if image.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.bmp', '.tif', '.tiff'):
        raise ValueError('请选择原始示波器截图或照片')
    from PIL import Image
    with Image.open(image) as im:
        im.verify()
    digest = sha(image)
    with (session / 'readings.csv').open(encoding='utf-8-sig', newline='') as f:
        old = list(csv.DictReader(f))
    if digest in {r['image_sha256'] for r in old}:
        raise ValueError('这张图片已经登记，不能重复计作新试次')
    name = f'z{zone + 1}_{len(old) + 1:03d}_{stamp()}{image.suffix.lower()}'
    target = session / 'screenshots' / name
    target.parent.mkdir(exist_ok=True)
    shutil.copy2(image, target)
    if sha(target) != digest:
        raise ValueError('图片复制校验失败')
    row = dict(zip(FIELDS, [str(len(old) + 1), str(zone), target.relative_to(session).as_posix(),
                           digest, delta, timebase, resolution, str(bool(definition_confirmed)).lower(),
                           disposition, note, datetime.now().isoformat()]))
    with (session / 'readings.csv').open('a', encoding='utf-8', newline='') as f:
        csv.DictWriter(f, fieldnames=FIELDS).writerow(row)
    return row


def stats(values):
    values = sorted(values)
    at = (len(values) - 1) * .95
    lo, hi = math.floor(at), math.ceil(at)
    return {'n': len(values), 'min_ms': values[0], 'median_ms': statistics.median(values),
            'p95_ms': values[lo] + (values[hi] - values[lo]) * (at - lo),
            'max_ms': values[-1], 'range_ms': values[-1] - values[0]}


def analyze(session, out):
    session, out = Path(session).resolve(), Path(out).resolve()
    meta, profile = frozen(session)
    if out.exists():
        raise ValueError('结果目录已存在，请使用新的目录')
    out.mkdir(parents=True)
    valid, rejected, seen = [], [], set()
    with (session / 'readings.csv').open(encoding='utf-8-sig', newline='') as f:
        rows = list(csv.DictReader(f))
    for row in rows:
        try:
            image = (session / row['image']).resolve()
            if not image.is_relative_to(session) or sha(image) != row['image_sha256']:
                raise ValueError('原始图片缺失、变动或路径越界')
            if row['image_sha256'] in seen:
                raise ValueError('图片重复')
            seen.add(row['image_sha256'])
            if row['disposition'] != 'valid':
                raise ValueError('操作员标记无效：' + row['note'])
            if row['definition_confirmed'] != 'true':
                raise ValueError('未确认光标符合固定起止判据')
            zone = int(row['zone'])
            if zone not in range(4):
                raise ValueError('区域错误')
            value = positive(row['delta_ms'], 'Δt/ms')
            resolution = positive(row['cursor_readout_resolution_ms'], '末位分辨率/ms')
            valid.append({**row, 'zone': zone, 'delta_ms': value,
                          'cursor_readout_resolution_ms': resolution})
        except (ValueError, KeyError, OSError) as exc:
            rejected.append({**row, 'reason': str(exc)})
    by_zone = {str(z + 1): stats([r['delta_ms'] for r in valid if r['zone'] == z])
               for z in range(4) if any(r['zone'] == z for r in valid)}
    values = [r['delta_ms'] for r in valid]
    complete = len(by_zone) == 4 and all(v['n'] >= 25 for v in by_zone.values())
    result = {'schema': meta['schema'], 'evidence': meta['evidence'],
              'scope': '固定FSR调理电压越阈值至模拟音频越过固定幅度门槛',
              'record_validation_status': 'NOT_RUN' if not valid else 'PASS',
              'planned_100_complete': complete,
              'planned_100_status': 'NOT_RUN' if not rows else ('PASS' if complete else 'BLOCKED'),
              'statistics': stats(values) if values else {}, 'by_zone': by_zone,
              'valid': len(valid), 'invalid': len(rejected),
              'all_observed_le_5ms': max(values) <= 5 if values else None,
              'all_observed_le_10ms': max(values) <= 10 if values else None,
              'bitstream_sha256': meta['bitstream_sha256'],
              'profile_sha256': meta['profile_sha256'],
              'readings_sha256': sha(session / 'readings.csv'),
              'interpretation': '数值人工抄自示波器光标读数；脚本校验归档和统计，不自动识别图片起音。显示末位不等于整机测量精度。观测最大值不是理论最坏情况。'}
    for name, data in [('valid_readings', valid), ('rejected_readings', rejected)]:
        with (out / (name + '.csv')).open('w', encoding='utf-8-sig', newline='') as f:
            keys = list(dict.fromkeys(k for r in data for k in r)) or FIELDS
            writer = csv.DictWriter(f, fieldnames=keys)
            writer.writeheader()
            writer.writerows(data)
    (out / 'scope_screenshot_summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    chart = ''
    if values:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(10, 4.6))
        for z in range(4):
            points = [(i + 1, r['delta_ms']) for i, r in enumerate(valid) if r['zone'] == z]
            if points:
                ax.scatter(*zip(*points), label=f'Zone {z + 1}', s=30)
        ax.axhline(5, c='#ce9a36', ls='--', label='5 ms reference')
        ax.axhline(10, c='#ad4e4e', ls='--', label='10 ms reference')
        ax.set(xlabel='Recorded trial', ylabel='Latency / ms', title='Oscilloscope cursor readouts - manual transcription')
        ax.grid(alpha=.2)
        ax.legend(ncol=3)
        fig.tight_layout()
        fig.savefig(out / 'scope_readouts.png', dpi=180)
        fig.savefig(out / 'scope_readouts.svg')
        plt.close(fig)
        chart = '<img style="max-width:100%" src="scope_readouts.png">'
    table = ''.join('<tr><td>' + str(z) + '</td>' + ''.join(f'<td>{v[k]:.4g}</td>' for k in ['n','min_ms','median_ms','p95_ms','max_ms','range_ms']) + '</tr>' for z, v in by_zone.items())
    gallery = ''.join(f'<figure><a href="{(session / r["image"]).as_uri()}"><img style="max-width:900px;width:100%" src="{(session / r["image"]).as_uri()}"></a><figcaption>区域{r["zone"] + 1}，试次{r["trial_id"]}，Δt={r["delta_ms"]:g} ms；{html.escape(r["note"])}</figcaption></figure>' for r in valid)
    report = '<!doctype html><meta charset="utf-8"><title>示波器延迟实测</title><style>body{max-width:1100px;margin:36px auto;font:16px system-ui;line-height:1.8;color:#20343c}table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ccd5d7;padding:8px;text-align:right}aside{padding:18px;background:#edf3f5}</style><h1>示波器延迟实测</h1>'
    report += f'<p>有效{len(valid)}次，无效{len(rejected)}次。单位ms。正式100次计划完成：{complete}。</p><aside>{html.escape(result["interpretation"])}</aside>' + chart
    report += '<table><tr><th>区域</th><th>次数</th><th>最小</th><th>中位数</th><th>P95</th><th>最大</th><th>极差</th></tr>' + table + '</table><h2>测量条件</h2><pre>' + html.escape(json.dumps(profile, ensure_ascii=False, indent=2)) + '</pre><h2>原始截图</h2>' + gallery
    (out / 'report.html').write_text(report, encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(analyze(args.session, args.out), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
