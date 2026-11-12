"""Trains the learned artifact scorer (Lumora/Core/Interpolation/ArtifactScorer.swift) and writes its weights to
Lumora/Core/Interpolation/QCScorerWeights.swift.

Data: ~/Library/Caches/Lumora-Bench/qc-scorer/<set>.csv, built by QCScorerTrainingTests.test4_ScorerDataset with the
app's own feature code. Fitting uses only the train sets (train part of the story: SDR with the image model as primary,
SDR with the flow model as primary, HDR10 with the flow model); tree counts and the policy thresholds are chosen on
the validation sets (validation part of the story, plus its film-grain and UHD variants). Held-out data is never read.

    python3 scripts/qc_scorer/train.py            # train, report validation curves and the policy table, write weights
    python3 scripts/qc_scorer/train.py --dry-run  # same, without writing the Swift file

Standard library + numpy only.
"""
import base64
import csv
import json
import os
import pickle
import struct
import sys

import numpy as np

from gbdt import GBDT
import policy as pol

DATA = os.path.expanduser('~/Library/Caches/Lumora-Bench/qc-scorer')
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
WEIGHTS = os.path.join(REPO, 'Lumora/Core/Interpolation/QCScorerWeights.swift')

TRAIN_SETS = ['train', 'trainFlow', 'trainHDR']
VAL_SETS = ['val', 'valFlow', 'valHDR', 'valGrain', 'val4k']
# Candidate columns in the data -> names the Swift loader expects.
GAIN_CANDIDATES = {'Q': 'alternative', 'blend': 'blend', 'nearest': 'nearest', 'average': 'average'}
NOALT_CANDIDATES = {'blend': 'blend', 'nearest': 'nearest'}
# Features that describe the alternative model; zero when it is not installed (ArtifactScorer.assemble).
ALT_FEATURES = ['dPQ', 'dQBlend', 'dQNear', 'excessQ', 'novQ', 'novQ04', 'novQ10', 'disagreePQ', 'maxPQ', 'maxNovQ',
                'flMag0', 'flMag1', 'flErr', 'flErrFrac', 'flOcc', 'flMax', 'frDPQ', 'frFlErr', 'relDPQ', 'nbDPQ']
FRAME_FEATURES = ['corrAB', 'frDAB', 'meanTileDiff', 'frNovP04', 'frFlErr', 'frDPQ']
NOALT_FRAME_ZERO = ['frFlErr', 'frDPQ']

QUALITY_CLIP = (10.0, 50.0)
GAIN_CLIP = (-15.0, 15.0)
GAIN_TRAIN_BELOW = 36.0      # gain models learn from tiles where the primary is below this PSNR (where they're used)


def read_csv(path, string_cols):
    with open(path, newline='') as fh:
        r = csv.reader(fh)
        header = next(r)
        rows = list(r)
    out = {}
    for j, h in enumerate(header):
        col = [row[j] for row in rows]
        if h in string_cols:
            out[h] = np.array(col)
        else:
            out[h] = np.array([float(v) if v != '' else np.nan for v in col], dtype=np.float32)
    return out, header


def load_tiles(name):
    cache = os.path.join(DATA, f'{name}.npz')
    src = os.path.join(DATA, f'{name}.csv')
    if os.path.exists(cache) and os.path.getmtime(cache) >= os.path.getmtime(src):
        with np.load(cache) as z:
            d = {k: z[k] for k in z.files}
        return d
    d, _ = read_csv(src, {'set', 'window', 'mode', 'stratum', 'primary'})
    if os.environ.get('QC_SCORER_CACHE') == '1':           # opt-in: the cache is as large as the CSVs
        np.savez(cache, **d)
    return d


def load_frames(name):
    d, _ = read_csv(os.path.join(DATA, f'{name}-frames.csv'), {'set', 'window', 'mode', 'stratum', 'primary'})
    return d


def feature_names():
    src = open(os.path.join(REPO, 'Lumora/Core/Interpolation/ArtifactScorer.swift')).read()
    start = src.index('static let featureNames = [')
    body = src[start:src.index(']', start)]
    return [s.split('"')[1] for s in body.split(',') if '"' in s]


def concat(ds):
    keys = ds[0].keys()
    return {k: np.concatenate([d[k] for d in ds]) for k in keys}


def matrix(d, names, noalt=False):
    x = np.stack([d[n] for n in names], 1).astype(np.float32)
    if noalt:
        for n in ALT_FEATURES:
            x[:, names.index(n)] = 0
    return np.nan_to_num(x)


def fit_cut(log):
    """Shot-change test: logistic regression on frame statistics, fake shot changes vs real frame pairs."""
    pos = concat([load_frames(n) for n in ['trainCuts', 'trainHDRCuts'] if os.path.exists(os.path.join(DATA, f'{n}-frames.csv'))])
    neg = concat([load_frames(n) for n in TRAIN_SETS])
    vpos = load_frames('valCuts')
    vneg = concat([load_frames(n) for n in VAL_SETS])
    result = {}
    for tag, zero in [('alt', []), ('noalt', NOALT_FRAME_ZERO)]:
        def X(d):
            x = np.stack([d[n] for n in FRAME_FEATURES], 1).astype(np.float64)
            for n in zero:
                x[:, FRAME_FEATURES.index(n)] = 0
            return np.nan_to_num(x)
        x = np.concatenate([X(pos), X(neg)])
        y = np.concatenate([np.ones(len(pos['t'])), np.zeros(len(neg['t']))])
        mu, sd = x.mean(0), x.std(0) + 1e-9
        z = (x - mu) / sd
        w = np.zeros(z.shape[1])
        b = 0.0
        cw = np.where(y > 0, 0.5 / y.mean(), 0.5 / (1 - y.mean()))
        for _ in range(3000):                        # L2-regularized logistic regression, gradient descent
            p = 1 / (1 + np.exp(-(z @ w + b)))
            gw = z.T @ ((p - y) * cw) / len(y) + 1e-2 * w
            gb = np.sum((p - y) * cw) / len(y)
            w -= 0.5 * gw
            b -= 0.5 * gb
        wr = w / sd
        br = b - np.sum(w * mu / sd)
        def score(d):
            return X(d) @ wr + br
        real = np.concatenate([score(neg), score(vneg)])
        # Threshold: well above every real frame pair of train and validation (holding a real frame is judder).
        thr = float(max(real.max() + 2.0, 0.0))
        tp_train = float(np.mean(score(pos) > thr))
        tp_val = float(np.mean(score(vpos) > thr))
        log(f'[cut {tag}] weights {np.round(wr, 3).tolist()} bias {br:.3f} threshold {thr:.2f}: '
            f'fake shot changes caught train {100 * tp_train:.1f}% val {100 * tp_val:.1f}%, '
            f'real pairs flagged train {100 * np.mean(score(neg) > thr):.2f}% val {100 * np.mean(score(vneg) > thr):.2f}%')
        result[tag] = [float(v) for v in wr] + [float(br), thr]
    return result


class Scorer:
    """The fitted ensembles for one configuration (with or without the alternative model):
    quality (the primary's tile PSNR), and per candidate the mean gain and a pessimistic gain (20% quantile)."""

    RISK_TAU = 0.2

    def __init__(self, tag, names, cands, noalt):
        self.tag, self.names, self.cands, self.noalt = tag, names, cands, noalt
        self.models = {}
        self.log = []

    def fit(self, tr, va, log):
        xt, xv = matrix(tr, self.names, self.noalt), matrix(va, self.names, self.noalt)
        rng = np.random.default_rng(7)
        pt, pv = tr['p_P'], va['p_P']
        # Hard tiles all, plus a third of the rest (keeps fitting fast; the easy tiles are very alike).
        keep = (pt < GAIN_TRAIN_BELOW) | (rng.random(len(pt)) < 0.35)
        keep_v = (pv < GAIN_TRAIN_BELOW) | (np.random.default_rng(8).random(len(pv)) < 0.35)
        hard_t, hard_v = pt < GAIN_TRAIN_BELOW, pv < GAIN_TRAIN_BELOW
        jobs = [('quality', None, 'l2', keep, keep_v)]
        for c in self.cands:
            jobs.append((f'gain.{c}', c, 'l2', hard_t, hard_v))
            jobs.append((f'risk.{c}', c, 'quantile', keep, keep_v))
        for key, c, loss, st, sv in jobs:
            if key in self.models:
                continue
            if c is None:
                yt, yv = np.clip(pt, *QUALITY_CLIP), np.clip(pv, *QUALITY_CLIP)
            else:
                yt, yv = np.clip(tr['p_' + c] - pt, *GAIN_CLIP), np.clip(va['p_' + c] - pv, *GAIN_CLIP)
            log(f'[{self.tag}] {key}: {st.sum()} training tiles, loss {loss}')
            m = GBDT(depth=4, trees=400 if loss == 'l2' else 250, lr=0.06 if loss == 'l2' else 0.1, lam=50, min_leaf=300,
                     subsample=0.7, seed=len(self.models) + 1, loss=loss, tau=self.RISK_TAU)
            m.fit(xt[st], yt[st], xv=xv[sv], yv=yv[sv], log_every=50)
            best = min(m.history, key=lambda h: h[2])
            m.trees = m.trees[:best[0]]
            line = (f'    {self.tag} {key}: validation curve (trees:train/val loss) '
                    + ' '.join(f'{n}:{a:.3f}/{b:.3f}' for n, a, b in m.history) + f' -> keep {best[0]} trees')
            log(line)
            self.log.append(line)
            self.models[key] = m

    def predict(self, d):
        x = matrix(d, self.names, self.noalt)
        cs = list(self.cands)
        return (self.models['quality'].predict(x), np.stack([self.models[f'gain.{c}'].predict(x) for c in cs], 1),
                np.stack([self.models[f'risk.{c}'].predict(x) for c in cs], 1))


def decide(q, G, R, fid, p, refine=False):
    """The run-time policy (ArtifactScorer.decide), vectorized where possible. p = (ceiling, margin, floor, budget).
    A tile is a candidate when its predicted primary PSNR is below the ceiling, the best predicted gain (among
    alternatives whose pessimistic gain is above the floor) exceeds the margin. Per frame, candidates are taken in
    order of expected benefit while the frame's pessimistic total stays within `budget` of its predicted error."""
    ceiling, margin, floor, budget = p
    n = len(q)
    Gm = np.where(R > floor, G, -99.0)
    best = np.argmax(Gm, 1)
    g = Gm[np.arange(n), best]
    r = R[np.arange(n), best]
    cand = (q < ceiling) & (g > margin)
    m = np.power(10.0, -q.astype(np.float64) / 10)
    benefit = m * (1 - np.power(10.0, -g / 10))
    worst = m * (1 - np.power(10.0, -r / 10))
    nf = fid.max() + 1
    allowed = budget * np.bincount(fid, m, minlength=nf)
    use = np.zeros(n, bool)
    idx = np.where(cand)[0]
    order = idx[np.lexsort((idx, -benefit[idx], fid[idx]))]
    acc = np.zeros(nf)
    for i in order:
        f = fid[i]
        if acc[f] + worst[i] >= -allowed[f]:
            acc[f] += worst[i]
            use[i] = True
    choice = best.copy()
    if refine is not False:
        rb = np.argmax(R, 1)
        rv = R[np.arange(n), rb]
        ref = (~use) & (rv > refine)
        choice[ref] = rb[ref]
        use |= ref
    return use, choice


def simulate(d, pre, cands, p, refine=False):
    q, G, R = pre
    fid = pol.frame_index(d['window'], d['mode'], d['ti'])
    use, choice = decide(q, G, R, fid, p, refine)
    P = np.stack([d['p_' + c] for c in cands], 1)
    out = np.where(use, P[np.arange(len(P)), choice], d['p_P'])
    broken = d['broken'] > 0 if not np.isnan(d['broken']).all() else np.zeros(len(out), bool)
    return pol.evaluate(fid, d['px'].astype(np.float64), d['p_P'], out, use, broken)


DROP_LIMIT, MAX_LIMIT = 0.5, 0.2      # half of the objective's limits (1% / 0.3 dB): headroom for held-out data


def choose_policy(scorer, vals, preds, log):
    """Grid on the validation sets. s=1: the best gain on the worst 10% of frames (plus a little recall) that keeps
    every validation set within DROP_LIMIT / MAX_LIMIT. s=0: a stricter point (lower ceiling, higher margin and floor,
    smaller budget) that is also within the limits."""
    cands = list(scorer.cands)
    grid = [(c, m, f, b) for c in [26, 30, 34] for m in [0.5, 1, 2] for f in [-3, -1.5, -0.75] for b in [0.0025, 0.005, 0.01, 0.02]]
    rows = []
    for p in grid:
        ms = {n: simulate(vals[n], preds[n], cands, p) for n in vals}
        ok = all(m['drop%'] <= DROP_LIMIT and m['max'] <= MAX_LIMIT for m in ms.values())
        rows.append((p, ok, ms))

    def score(ms):
        return np.mean([ms[n]['w10'] + ms[n]['gain'] for n in ms]) + 0.003 * ms.get('val', {'recall': 0})['recall']
    feasible = [r for r in rows if r[1]]
    if not feasible:
        log(f'[{scorer.tag}] no policy within the limits on validation; disabled')
        return None, rows
    strict = max(feasible, key=lambda r: score(r[2]))[0]
    loose = None
    for shrink in range(1, 6):
        p0 = (strict[0] - 2 * shrink, strict[1] + 0.5 * shrink, max(strict[2], -0.75), strict[3] / (1 + shrink))
        ms = {n: simulate(vals[n], preds[n], cands, p0) for n in vals}
        if all(m['drop%'] <= DROP_LIMIT and m['max'] <= MAX_LIMIT for m in ms.values()):
            loose = p0
            break
    loose = loose or (strict[0] - 10, strict[1] + 3, 0.0, strict[3] / 8)
    params = [loose[0], strict[0], loose[1], strict[1], loose[2], strict[2], loose[3], strict[3]]
    # Exhaustive also refines tiles where an alternative is better with high confidence (pessimistic gain > R dB).
    mid = tuple(loose[k] + 0.5 * (strict[k] - loose[k]) for k in range(4))
    refine = 99.0
    for rr in [0.5, 1.0, 1.5, 2.0, 3.0]:
        ms = {n: simulate(vals[n], preds[n], cands, strict, refine=rr) for n in vals}
        if all(m['drop%'] <= DROP_LIMIT and m['max'] <= MAX_LIMIT for m in ms.values()):
            refine = rr
            break
    params.append(refine)
    _ = mid
    return params, rows


def at(params, s):
    return tuple(params[2 * k] + (params[2 * k + 1] - params[2 * k]) * s for k in range(4))


def ensemble_bytes(name, m):
    out = struct.pack('<I', len(name)) + name.encode() + struct.pack('<IIf', m.depth, len(m.trees), m.base)
    for feats, thr, leaves in m.trees:
        for f, t in zip(feats, thr):
            out += struct.pack('<If', int(f), float(min(t, 3.0e38)))
        out += struct.pack(f'<{len(leaves)}f', *[float(v) for v in leaves])
    return out


def write_weights(names, scorers, policies, cut, summary):
    blob = struct.pack('<I', 0x51435331) + struct.pack('<I', len(names))
    for n in names:
        blob += struct.pack('<I', len(n)) + n.encode()
    ens = []
    for s in scorers:
        if policies.get(s.tag) is None:
            continue
        ens.append((f'quality.{s.tag}', s.models['quality']))
        for c in s.cands:
            ens.append((f'gain.{s.cands[c]}.{s.tag}', s.models[f'gain.{c}']))
            ens.append((f'risk.{s.cands[c]}.{s.tag}', s.models[f'risk.{c}']))
    blob += struct.pack('<I', len(ens))
    for n, m in ens:
        blob += ensemble_bytes(n, m)
    b64 = base64.b64encode(blob).decode()
    lines = [b64[i:i + 116] for i in range(0, len(b64), 116)]

    def arr(v):
        return '[' + ', '.join(f'{x:.6g}' for x in v) + ']'
    pol_lines = ',\n'.join(f'        "{k}": {arr(v)}' for k, v in policies.items() if v is not None)
    cut_lines = ',\n'.join(f'        "{k}": {arr(v)}' for k, v in cut.items() if policies.get(k) is not None)
    swift = f'''// Generated by scripts/qc_scorer/train.py. Do not edit by hand.

enum QCScorerWeights {{
    static let trained = "{summary}"
    /// Tree ensembles (base64 of the little-endian format read by QCScorerModel).
    static let trees = """
{chr(10).join(lines)}
"""
    /// Policy per configuration: [ceiling, margin, floor, budget] each at sensitivity 0 then 1, then the exhaustive
    /// refinement margin (see ArtifactScorer.decide).
    static let policies: [String: [Float]] = [
{pol_lines}
    ]
    /// Shot-change logistic regression: weights for ArtifactScorer.frameFeatureNames, bias, decision threshold.
    static let cut: [String: [Float]] = [
{cut_lines}
    ]
}}
'''
    open(WEIGHTS, 'w').write(swift)


FIXTURE = os.path.join(REPO, 'Tests/LumoraTests/Resources/qc-scorer-fixture.json')
_frames_cache = {}


def load_frames_cached(name):
    if name not in _frames_cache:
        d = load_frames(name)
        _frames_cache[name] = {(str(d['window'][i]), str(d['mode'][i]), int(d['ti'][i])):
                               [float(d[n][i]) for n in FRAME_FEATURES] for i in range(len(d['t']))}
    return _frames_cache[name]


def r6(v):
    return float(f'{float(v):.4g}')


def write_fixture(scorers, policies, vals, summary):
    """A small regression fixture from validation frames (numbers only, no pictures): Swift/Python prediction parity
    rows, and whole frames (every tile) on which QCScorerTests replays the policy exactly."""
    rng = np.random.default_rng(11)
    parity, frames = [], []
    for s in scorers:
        if policies.get(s.tag) is None:
            continue
        d = vals['val']
        idx = rng.choice(len(d['t']), 120 if s.tag == 'alt' else 40, replace=False)
        x = np.array([[r6(v) for v in row] for row in matrix({k: v[idx] for k, v in d.items()}, s.names, s.noalt)], np.float32)
        cs = list(s.cands)
        q = s.models['quality'].predict(x)
        G = np.stack([s.models[f'gain.{c}'].predict(x) for c in cs], 1)
        R = np.stack([s.models[f'risk.{c}'].predict(x) for c in cs], 1)
        for i in range(len(idx)):
            parity.append({'tag': s.tag, 'x': [r6(v) for v in x[i]], 'quality': float(q[i]),
                           'gains': {s.cands[c]: float(G[i, k]) for k, c in enumerate(cs)},
                           'risks': {s.cands[c]: float(R[i, k]) for k, c in enumerate(cs)}})
    s = next(sc for sc in scorers if sc.tag == 'alt')
    p1 = at(policies['alt'], 1)
    for name, count in [('val', 1), ('valHDR', 1), ('val4k', 1)]:
        if name not in vals:
            continue
        d = vals[name]
        fid = pol.frame_index(d['window'], d['mode'], d['ti'])
        pre = s.predict(d)
        use, _ = decide(*pre, fid, p1)
        nsw = np.bincount(fid, use, minlength=fid.max() + 1)
        picks = list(np.argsort(-nsw)[:count])
        others = np.maximum.reduce([d['p_Q'], d['p_blend'], d['p_nearest']])
        broken = (d['p_P'] < 30) & (others - d['p_P'] >= 2)
        for f in picks:
            sel = np.where(fid == f)[0]
            sub = {k: v[sel] for k, v in d.items()}
            x = matrix(sub, s.names, False)
            key = (str(d['window'][sel[0]]), str(d['mode'][sel[0]]), int(d['ti'][sel[0]]))
            frames.append({'name': f'{name} {key[0]} {key[1]} #{key[2]}', 'hasAlternative': True,
                           'frame': load_frames_cached(name)[key],
                           'tiles': [{'x': [r6(v) for v in x[i]], 'px': float(sub['px'][i]),
                                      'psnr': {c: round(float(sub['p_' + c][i]), 3) for c in ['P', 'Q', 'blend', 'nearest', 'average']},
                                      'broken': bool(broken[sel][i])} for i in range(len(sel))]})
    with open(FIXTURE, 'w') as fh:
        json.dump({'trained': summary, 'parity': parity, 'frames': frames}, fh, separators=(',', ':'))


def main():
    dry = '--dry-run' in sys.argv
    report = []

    def log(s):
        print(s, flush=True)
        report.append(s)
    names = feature_names()
    tr = concat([load_tiles(n) for n in TRAIN_SETS])
    vals = {n: load_tiles(n) for n in VAL_SETS if os.path.exists(os.path.join(DATA, f'{n}.csv'))}
    va = concat([vals[n] for n in ['val', 'valFlow', 'valHDR'] if n in vals])
    log(f'training tiles {len(tr["t"])} ({", ".join(TRAIN_SETS)}), validation tiles {sum(len(v["t"]) for v in vals.values())} ({", ".join(vals)})')
    policies, scorers = {}, []
    for tag, cands, noalt in [('alt', GAIN_CANDIDATES, False), ('noalt', NOALT_CANDIDATES, True)]:
        pkl = os.path.join(DATA, f'models-{tag}.pkl')
        s = Scorer(tag, names, cands, noalt)
        if os.path.exists(pkl) and '--refit' not in sys.argv:
            with open(pkl, 'rb') as fh:
                s.models, s.log = pickle.load(fh)
            for line in s.log:
                log(line + ' (cached)')
        s.fit(tr, va, log)
        with open(pkl, 'wb') as fh:
            pickle.dump((s.models, s.log), fh)
        preds = {n: s.predict(vals[n]) for n in vals}
        p, rows = choose_policy(s, vals, preds, log)
        policies[tag] = p
        scorers.append(s)
        log(f'[{tag}] policy grid on validation (ceiling, margin, floor, budget): per set gain/w10/drop%/max/recall/precision')
        for pp, ok, ms in rows:
            log(f'  {pp} {"ok" if ok else "  "} ' + ' | '.join(
                f'{n} {m["gain"]:+.3f}/{m["w10"]:+.2f}/{m["drop%"]:.1f}/{m["max"]:.2f}/{m["recall"]:.0f}/{m["precision"]:.0f}' for n, m in ms.items()))
        if p:
            log(f'[{tag}] chosen policy {[round(v, 4) for v in p]}')
            for sv in [0, 0.5, 1]:
                for n in vals:
                    log(f'    s={sv}: {n:9s} ' + pol.fmt(simulate(vals[n], preds[n], list(cands), at(p, sv))))
            for n in vals:
                log(f'    exhaustive s=0.5: {n:9s} ' + pol.fmt(simulate(vals[n], preds[n], list(cands), at(p, 0.5), refine=p[8])))
        imp = np.zeros(len(names))
        for m in s.models.values():
            imp += m.importance(len(names))
        log(f'[{tag}] feature use (splits): ' + ', '.join(f'{names[i]} {int(imp[i])}' for i in np.argsort(-imp) if imp[i] > 0))
    cut = fit_cut(log)
    summary = f'trained on {"+".join(TRAIN_SETS)}; policy from {"+".join(vals)}'
    if not dry:
        write_weights(names, scorers, policies, cut, summary)
        write_fixture(scorers, policies, vals, summary)
        log(f'wrote {WEIGHTS} and {FIXTURE}')
    with open(os.path.join(DATA, 'train-report.txt'), 'w') as fh:
        fh.write('\n'.join(report) + '\n')


if __name__ == '__main__':
    main()
