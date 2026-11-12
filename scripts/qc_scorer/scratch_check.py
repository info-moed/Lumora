import numpy as np
from train import load_tiles
from qcdata import load
d = load_tiles('train')
h = load('train')
for w in ['train-000', 'train-001']:
    for mode in ['30->60', '15->60']:
        for ti in range(3):
            a = (d['window'] == w) & (d['mode'] == mode) & (d['ti'] == ti)
            b = (h['window'] == w) & (h['mode'] == mode) & (h['ti'] == ti)
            if a.sum() == 0:
                continue
            print(w, mode, ti, a.sum(), b.sum(), 'max|P-img|', np.abs(d['p_P'][a] - h['p_img'][b]).max(),
                  'max|Qhalf - flowfull| med', np.median(np.abs(d['p_Q'][a] - h['p_flow'][b])),
                  'blend', np.abs(d['p_blend'][a] - h['p_blend'][b]).max(), 'broken', d['broken'][a].sum(), h['broken'][b].sum())
print({k: (float(np.nanmin(d[k])), float(np.nanmax(d[k]))) for k in ['dPQ', 'novP04', 'flMag0', 'flErr', 'corrAB'] if k in d})
