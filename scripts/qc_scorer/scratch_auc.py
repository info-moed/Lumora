import numpy as np
from qcdata import load
from exp_existing import FEATS, matrix
d = load('train')
x = matrix(d)
br = d['broken'] > 0


def auc(s, y):
    o = np.argsort(s, kind='stable')
    r = np.empty(len(s))
    r[o] = np.arange(len(s))
    npos = y.sum()
    return (r[y].sum() - npos * (npos - 1) / 2) / (npos * (len(y) - npos))


for st in ['low', 'medium', 'high', 'extreme']:
    for m in ['30->60', '15->60']:
        s = (d['stratum'] == st) & (d['mode'] == m)
        print(st, m, f'{br[s].mean() * 100:.2f}%', {c: int(((d['best'] == c) & br & s).sum()) for c in ['blend', 'nearest', 'flow', 'flowFlip', 'imgFlip']})
for j, f in enumerate(FEATS):
    print(f'{f:16s} AUC {auc(x[:, j], br):.3f}')
print('p_img of broken pcts', np.percentile(d['p_img'][br], [10, 50, 90]))
others = np.maximum.reduce([d['p_' + c] for c in ['flow', 'imgFlip', 'flowFlip', 'blend', 'nearest']])
print('gain of best other on broken', np.percentile((others - d['p_img'])[br], [10, 50, 90]))
lowp = d['p_img'] < 30
print('tiles p_img<30:', lowp.mean(), 'of which broken', br[lowp].mean())
for c in ['flow', 'blend', 'nearest']:
    g = d['p_' + c] - d['p_img']
    print(c, 'on p<30 tiles gain pcts', np.percentile(g[lowp], [10, 25, 50, 75, 90]))
