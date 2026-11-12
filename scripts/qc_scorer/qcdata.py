"""Loads the QC benchmark dataset (tiles.csv per split) into numpy arrays, cached as .npz.

The dataset is built by `scripts/qc-bench.sh dataset` under ~/Library/Caches/Lumora-Bench/qc-dataset.
Only the standard library and numpy are used.
"""
import csv
import os

import numpy as np

DATASET = os.path.expanduser('~/Library/Caches/Lumora-Bench/qc-dataset')
CACHE = os.path.expanduser('~/Library/Caches/Lumora-Bench/qc-scorer')
STRING_COLUMNS = {'split', 'window', 'mode', 'stratum', 'primary', 'best'}


def load(split):
    os.makedirs(CACHE, exist_ok=True)
    src = os.path.join(DATASET, split, 'tiles.csv')
    cached = os.path.join(CACHE, f'harness-{split}.npz')
    if os.path.exists(cached) and os.path.getmtime(cached) >= os.path.getmtime(src):
        with np.load(cached, allow_pickle=False) as z:
            return {k: z[k] for k in z.files}
    with open(src, newline='') as fh:
        reader = csv.reader(fh)
        header = next(reader)
        rows = list(reader)
    data = {}
    for j, name in enumerate(header):
        column = [r[j] for r in rows]
        if name in STRING_COLUMNS:
            data[name] = np.array(column)
        else:
            data[name] = np.array([float(x) if x != '' else np.nan for x in column], dtype=np.float32)
    np.savez(cached, **data)
    return data


if __name__ == '__main__':
    import sys
    for s in sys.argv[1:]:
        d = load(s)
        print(s, len(d['tx']))
