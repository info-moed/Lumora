"""Offline policy simulation: per-tile candidate switching scored with exact frame PSNRs from per-tile PSNRs."""
import numpy as np


def frame_index(window, mode, ti):
    key = np.char.add(np.char.add(window.astype(str), mode.astype(str)), ti.astype(int).astype(str))
    _, inv = np.unique(key, return_inverse=True)
    return inv


def frame_psnr(fid, px, tile_psnr, nframes):
    mse = np.power(10.0, -np.asarray(tile_psnr, np.float64) / 10) * px
    s = np.bincount(fid, mse, minlength=nframes)
    n = np.bincount(fid, px, minlength=nframes)
    return 10 * np.log10(n / np.maximum(s, 1e-12))


def evaluate(fid, px, prim, chosen_psnr, changed, broken):
    """prim / chosen_psnr: per-tile PSNR of raw primary and of the policy output; changed: bool per tile."""
    nf = fid.max() + 1
    raw = frame_psnr(fid, px, prim, nf)
    pol = frame_psnr(fid, px, chosen_psnr, nf)
    d = pol - raw
    order = np.argsort(raw)
    worst = order[:max(1, nf // 10)]
    fixed = broken & (chosen_psnr - prim >= 1)
    return {
        'frames': int(nf),
        'raw': raw.mean(), 'gain': d.mean(), 'w10': d[worst].mean(),
        'drop%': 100 * np.mean(d < -0.1), 'max': max(0.0, -d.min()),
        'recall': 100 * (changed & broken).sum() / max(1, broken.sum()),
        'precision': 100 * (changed & broken).sum() / max(1, changed.sum()),
        'fixed': 100 * fixed.sum() / max(1, broken.sum()),
        'changed%': 100 * changed.mean(),
    }


def fmt(m):
    return (f"gain {m['gain']:+.3f} w10 {m['w10']:+.3f} drop {m['drop%']:.2f}% max {m['max']:.3f} "
            f"R/P/F {m['recall']:.0f}/{m['precision']:.0f}/{m['fixed']:.0f} changed {m['changed%']:.1f}%")
