import pickle
import os
import numpy as np
import policy as pol
from train import load_tiles, DATA, VAL_SETS, Scorer  # noqa: F401

s = pickle.load(open(os.path.join(DATA, 'scorer-alt.pkl'), 'rb'))
vals = {n: load_tiles(n) for n in VAL_SETS}
for n, d in vals.items():
    q, g = s.predict(d)
    fid = pol.frame_index(d['window'], d['mode'], d['ti'])
    nf = fid.max() + 1
    px = d['px'].astype(np.float64)
    raw = pol.frame_psnr(fid, px, d['p_P'], nf)
    cands = list(s.cands)
    G = np.stack([g[c] for c in cands], 1)
    best = np.argmax(G, 1)
    bg = G[np.arange(len(G)), best]
    use = (q < 28) & (bg > 2)
    truth = np.stack([d['p_' + c] for c in cands], 1)[np.arange(len(G)), best] - d['p_P']
    out = np.where(use, d['p_P'] + truth, d['p_P'])
    pp = pol.frame_psnr(fid, px, out, nf)
    delta = pp - raw
    print(f'== {n}: frames {nf}, switched {use.sum()}; per candidate (count, mean true gain, share < -1 dB):')
    for k, c in enumerate(cands):
        m = use & (best == k)
        if m.sum():
            print(f'   {c:8s} {m.sum():6d} {truth[m].mean():+.2f} {np.mean(truth[m] < -1):.2f}')
    bad = np.where(delta < -0.1)[0]
    for f in bad[:12]:
        m = (fid == f) & use
        print(f'   frame {f} raw {raw[f]:.2f} delta {delta[f]:+.2f} switched {m.sum()} '
              f'cands {[cands[b] for b in best[m]]} true {np.round(truth[m], 1).tolist()} pred {np.round(bg[m], 1).tolist()} '
              f'q {np.round(q[m], 1).tolist()} pP {np.round(d["p_P"][m], 1).tolist()} {d["window"][m][:1]} {d["mode"][m][:1]}')
