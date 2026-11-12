import pickle
import os
import sys
import numpy as np
import policy as pol
from gbdt import GBDT
from train import load_tiles, DATA, VAL_SETS, TRAIN_SETS, concat, matrix, GAIN_CLIP, Scorer  # noqa: F401

tau = float(sys.argv[1]) if len(sys.argv) > 1 else 0.25
s = pickle.load(open(os.path.join(DATA, 'scorer-alt.pkl'), 'rb'))
tr = concat([load_tiles(n) for n in TRAIN_SETS])
vals = {n: load_tiles(n) for n in VAL_SETS}
va = concat([vals[n] for n in ['val', 'valFlow', 'valHDR']])
xt, xv = matrix(tr, s.names), matrix(va, s.names)
selt, selv = tr['p_P'] < 36, va['p_P'] < 36
qm = {}
for c in s.cands:
    yt = np.clip(tr['p_' + c] - tr['p_P'], *GAIN_CLIP)
    yv = np.clip(va['p_' + c] - va['p_P'], *GAIN_CLIP)
    m = GBDT(depth=4, trees=250, lr=0.1, lam=50, min_leaf=300, subsample=0.7, seed=3, loss='quantile', tau=tau)
    m.fit(xt[selt], yt[selt], xv=xv[selv], yv=yv[selv], log_every=50)
    best = min(m.history, key=lambda h: h[2])
    m.trees = m.trees[:best[0]]
    print(c, 'keep', best[0], flush=True)
    qm[c] = m
pickle.dump(qm, open(os.path.join(DATA, f'quant-{tau}.pkl'), 'wb'))
for n, d in vals.items():
    x = matrix(d, s.names)
    q = s.quality.predict(x)
    G = np.stack([qm[c].predict(x) for c in s.cands], 1)
    P = np.stack([d['p_' + c] for c in s.cands], 1)
    fid = pol.frame_index(d['window'], d['mode'], d['ti'])
    broken = d['broken'] > 0
    best = np.argmax(G, 1)
    bg = G[np.arange(len(G)), best]
    for ceiling in [24, 28, 32, 40]:
        for margin in [0, 0.5, 1, 2, 3]:
            use = (q < ceiling) & (bg > margin)
            out = np.where(use, P[np.arange(len(P)), best], d['p_P'])
            m = pol.evaluate(fid, d['px'].astype(np.float64), d['p_P'], out, use, broken)
            print(f'{n:8s} ceil {ceiling} margin {margin}: ' + pol.fmt(m), flush=True)
