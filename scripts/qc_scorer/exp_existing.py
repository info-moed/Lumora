"""Experiment on the harness's own features (train -> val): how well can a small GBDT pick per-tile candidates?"""
import sys
import numpy as np
from qcdata import load
from gbdt import GBDT
import policy

FEATS = ['edge', 'luma', 'd_ab', 'grad_a', 'grad_p', 'd_alt', 'd_blend', 'd_near', 'excess', 'dmax_alt',
         'qc_s0', 'qc_s05', 'qc_s1', 'qc_alt_s05', 'fc_count', 'fl_mask', 'fl_occ', 'fl_mag0', 'fl_mag1', 'fl_err',
         'fl_errfrac', 'fl_errfrac_vis', 'fl_max', 't15']
FREE = ['edge', 'luma', 'd_ab', 'grad_a', 'grad_p', 'd_blend', 'd_near', 'excess', 'qc_s0', 'qc_s05', 'qc_s1', 't15']
feats = FEATS


def matrix(d):
    d['t15'] = (d['mode'] == '15->60').astype(np.float32) + np.abs(d['t'] - 0.5)
    return np.stack([np.nan_to_num(d[f]) for f in feats], 1).astype(np.float32)


if __name__ == '__main__':
    CANDS = sys.argv[1].split(',') if len(sys.argv) > 1 else ['flow', 'blend', 'nearest']
    tr, va = load('train'), load('val')
    xt, xv = matrix(tr), matrix(va)
    models = {}
    for c in CANDS:
        yt = np.clip(tr['p_' + c] - tr['p_img'], -12, 12)
        yv = np.clip(va['p_' + c] - va['p_img'], -12, 12)
        print('candidate', c)
        models[c] = GBDT(depth=4, trees=150, lr=0.1, lam=100, min_leaf=300).fit(xt, yt, xv=xv, yv=yv)
    pv = np.stack([models[c].predict(xv) for c in CANDS], 1)
    fid = policy.frame_index(va['window'], va['mode'], va['ti'])
    px = va['qc_px'].astype(np.float64)
    prim = va['p_img']
    cp = np.stack([va['p_' + c] for c in CANDS], 1)
    broken = va['broken'] > 0
    for margin in [0, 0.5, 1, 2, 3, 4, 6, 8]:
        best = np.argmax(pv, 1)
        bp = pv[np.arange(len(pv)), best]
        use = bp > margin
        out = np.where(use, cp[np.arange(len(cp)), best], prim)
        m = policy.evaluate(fid, px, prim, out, use, broken)
        print(f'margin {margin:4.1f} ', policy.fmt(m))
