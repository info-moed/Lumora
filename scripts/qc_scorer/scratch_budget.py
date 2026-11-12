import pickle
import os
import sys
import numpy as np
import policy as pol
from train import load_tiles, DATA, VAL_SETS, matrix, Scorer  # noqa: F401

s = pickle.load(open(os.path.join(DATA, 'scorer-alt.pkl'), 'rb'))
qm = pickle.load(open(os.path.join(DATA, 'quant-0.2.pkl'), 'rb'))
vals = {n: load_tiles(n) for n in VAL_SETS}
pre = {}
for n, d in vals.items():
    x = matrix(d, s.names)
    pre[n] = (s.quality.predict(x), np.stack([s.gains[c].predict(x) for c in s.cands], 1), np.stack([qm[c].predict(x) for c in s.cands], 1),
              np.stack([d['p_' + c] for c in s.cands], 1), pol.frame_index(d['window'], d['mode'], d['ti']))


def decide(q, G, Q20, fid, ceiling, margin, floor, eps, qbias):
    best = np.argmax(np.where(Q20 > floor, G, -99), 1)
    g = G[np.arange(len(G)), best]
    g20 = Q20[np.arange(len(G)), best]
    cand = (q < ceiling) & (g > margin) & (g20 > floor)
    m = np.power(10.0, -(q + qbias) / 10)          # predicted tile MSE (biased toward optimistic quality = smaller risk budget)
    benefit = m * (1 - np.power(10.0, -g / 10))
    worst = m * (1 - np.power(10.0, -g20 / 10))     # negative when the pessimistic gain is a loss
    use = np.zeros(len(q), bool)
    nf = fid.max() + 1
    M = np.bincount(fid, m, minlength=nf) / np.bincount(fid, minlength=nf)
    order = np.lexsort((-benefit, fid))
    acc = np.zeros(nf)
    cnt = np.bincount(fid, minlength=nf).astype(float)
    for i in order:
        if not cand[i]:
            continue
        f = fid[i]
        if (acc[f] + worst[i]) / cnt[f] >= -eps * M[f]:
            acc[f] += worst[i]
            use[i] = True
    return use, best


for ceiling in [26, 30, 34]:
    for margin in [0.5, 1, 2]:
        for floor in [-3, -1.5]:
            for eps in [0.005, 0.01, 0.02]:
                res = {}
                for n, d in vals.items():
                    q, G, Q20, P, fid = pre[n]
                    use, best = decide(q, G, Q20, fid, ceiling, margin, floor, eps, 0)
                    out = np.where(use, P[np.arange(len(P)), best], d['p_P'])
                    res[n] = pol.evaluate(fid, d['px'].astype(np.float64), d['p_P'], out, use, d['broken'] > 0)
                ok = all(m['drop%'] <= 1.0 and m['max'] <= 0.3 for m in res.values())
                print(f'ceil {ceiling} margin {margin} floor {floor} eps {eps} {"OK" if ok else "  "} ' + ' | '.join(
                    f'{n} {m["gain"]:+.3f}/{m["w10"]:+.2f}/{m["drop%"]:.1f}/{m["max"]:.2f}/R{m["recall"]:.0f}/P{m["precision"]:.0f}' for n, m in res.items()), flush=True)
