"""Convert Gowin Groups/Data exports to a table, preserving the original separately."""
import csv
import io
from pathlib import Path


def normalize(source, destination):
    raw = Path(source).read_bytes()
    encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    rows = list(csv.reader(io.StringIO(raw.decode(encoding))))
    start = next((i + 1 for i, r in enumerate(rows) if len(r) == 1 and r[0].strip() == 'Data:'), None)
    if start is None:
        start = next((i for i, r in enumerate(rows) if any(v.strip() == 'latency_trigger' for v in r)), None)
    if start is None:
        raise ValueError('未找到真实Data表头')
    header = [v.strip() for v in rows[start]]
    data, skipped = [], 0
    for row in rows[start + 1:]:
        if not any(v.strip() for v in row):
            continue
        if len(row) != len(header):
            raise ValueError('数据行列数与表头不一致')
        values = [v.strip() for v in row]
        # Some exports begin with one wholly uninitialized display row.
        # Only that leading row is ignored; partial or later unknowns remain errors.
        if not data and skipped == 0 and all(v.upper() in ('X', 'Z', '') for v in values[1:]):
            skipped += 1
            continue
        data.append(values)
    with Path(destination).open('w', newline='', encoding='utf-8-sig') as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(data)
    return {'data_rows': len(data), 'leading_uninitialized_rows': skipped,
            'transform': 'Data table extraction and whitespace trimming only; bus values unchanged'}
