"""Exploration: how much of the per-tile oracle headroom each candidate set holds (train/val only)."""
import sys
import numpy as np
from qcdata import load

CANDS = ['img', 'flow', 'imgFlip', 'flowFlip', 'imgTTA', 'flowTTA', 'blend', 'nearest', 'flickerFix']


def frame_ids(d):
    key = np.char.add(np.char.add(d['window'], d['mode']), d['ti'].astype(int).astype(str))
    _, inv = np.unique(key, return_inverse=True)
    return inv


def frame_psnr(fid, px, tile_psnr):
    mse = np.power(10.0, -tile_psnr.astype(np.float64) / 10) * px
    s = np.bincount(fid, mse)
    n = np.bincount(fid, px)
    return 10 * np.log10(n / np.maximum(s, 1e-12))


def report(split):
    d = load(split)
    fid = frame_ids(d)
    px = d['qc_px'].astype(np.float64)  # sampled pixels; proportional to real pixels per tile
    prim = d['p_img'] if d['primary'][0] == 'img' else d['p_flow']
    base = frame_psnr(fid, px, prim)
    order = np.argsort(base)
    worst = order[:max(1, len(order) // 10)]
    print(f'{split}: frames {len(base)} raw {base.mean():.2f}')
    sets = {
        'free (prim,blend,nearest)': ['blend', 'nearest'],
        '+flow': ['flow'],
        '+flow,blend,nearest': ['flow', 'blend', 'nearest'],
        '+imgFlip': ['imgFlip'],
        '+imgTTA': ['imgTTA'],
        '+flowTTA': ['flowTTA'],
        '+flow,flowTTA': ['flow', 'flowTTA'],
        '+flow,flowTTA,blend,nearest': ['flow', 'flowTTA', 'blend', 'nearest'],
        'oracle6': ['img', 'flow', 'imgFlip', 'flowFlip', 'blend', 'nearest'],
        'all': [c for c in CANDS if c != 'flickerFix'] + ['flickerFix'],
    }
    for name, cs in sets.items():
        stack = [prim] + [np.nan_to_num(d['p_' + c], nan=-1) for c in cs]
        best = np.max(np.stack(stack), axis=0)
        fp = frame_psnr(fid, px, best)
        print(f'  {name:32s} gain {fp.mean() - base.mean():+.2f}  w10 {(fp[worst] - base[worst]).mean():+.2f}')
    # Whole-frame choice of each candidate.
    for c in CANDS:
        v = d['p_' + c]
        if np.isnan(v).all():
            continue
        ok = ~np.isnan(v)
        fp = frame_psnr(fid[ok], px[ok], v[ok])
        print(f'  whole-frame {c:10s} {fp.mean() - base[np.unique(fid[ok])].mean():+.2f}')
    # Broken tiles: which candidate is best
    br = d['broken'] > 0
    print('  broken', br.sum(), 'best:', {c: int((d['best'][br] == c).sum()) for c in np.unique(d['best'][br])})
    for c in ['flow', 'flowTTA', 'imgTTA', 'blend', 'nearest']:
        g = d['p_' + c] - prim
        print(f'  tile gain {c:8s} p10 {np.nanpercentile(g, 10):+.2f} p50 {np.nanpercentile(g, 50):+.2f} p90 {np.nanpercentile(g, 90):+.2f} '
              f' share>+1dB {np.nanmean(g > 1):.3f} share<-1dB {np.nanmean(g < -1):.3f}')


for s in sys.argv[1:]:
    report(s)
