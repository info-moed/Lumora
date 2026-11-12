import pickle
import os
import sys
import numpy as np
import policy as pol
from train import load_tiles, DATA, VAL_SETS, matrix, Scorer  # noqa: F401

s = pickle.load(open(os.path.join(DATA, 'scorer-alt.pkl'), 'rb'))
qm = pickle.load(open(os.path.join(DATA, sys.argv[1] if len(sys.argv) > 1 else 'quant-0.2.pkl'), 'rb'))
vals = {n: load_tiles(n) for n in VAL_SETS}
pre = {}
for n, d in vals.items():
    x = matrix(d, s.names)
    pre[n] = (s.quality.predict(x), np.stack([s.gains[c].predict(x) for c in s.cands], 1), np.stack([qm[c].predict(x) for c in s.cands], 1),
              np.stack([d['p_' + c] for c in s.cands], 1), pol.frame_index(d['window'], d['mode'], d['ti']))
rows = []
for ceiling in [26, 30, 34]:
    for margin in [1, 2, 3]:
        for floor in [-3, -2, -1, -0.5, 0]:
            res = {}
            for n, d in vals.items():
                q, G, Q20, P, fid = pre[n]
                Gm = np.where(Q20 > floor, G, -99)
                best = np.argmax(Gm, 1)
                bg = Gm[np.arange(len(G)), best]
                use = (q < ceiling) & (bg > margin)
                out = np.where(use, P[np.arange(len(P)), best], d['p_P'])
                res[n] = pol.evaluate(fid, d['px'].astype(np.float64), d['p_P'], out, use, d['broken'] > 0)
            ok = all(m['drop%'] <= 1.0 and m['max'] <= 0.3 for m in res.values())
            print(f'ceil {ceiling} margin {margin} floor {floor:4.1f} {"OK" if ok else "  "} ' + ' | '.join(
                f'{n} {m["gain"]:+.3f}/{m["w10"]:+.2f}/{m["drop%"]:.1f}/{m["max"]:.2f}/R{m["recall"]:.0f}/P{m["precision"]:.0f}' for n, m in res.items()), flush=True)
