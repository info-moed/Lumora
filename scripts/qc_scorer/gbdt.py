"""A tiny, deterministic gradient-boosted regression tree ensemble in numpy (squared loss, histogram splits).

Kept deliberately simple so the app can evaluate it with a few lines of Swift: every tree is a complete binary tree of
fixed depth, stored as arrays of (feature, threshold) per internal node plus leaf values. A sample goes left when
feature < threshold (NaN goes right, but the app never produces NaN features).
"""
import numpy as np


class Binner:
    def __init__(self, x, bins=64):
        self.edges = []
        for j in range(x.shape[1]):
            col = x[:, j]
            qs = np.unique(np.quantile(col, np.linspace(0, 1, bins + 1)[1:-1]))
            self.edges.append(qs.astype(np.float32))

    def transform(self, x):
        out = np.empty(x.shape, dtype=np.uint8)
        for j, e in enumerate(self.edges):
            # bin k holds values in [e[k-1], e[k]); "x < e[k]" is the split test for bin <= k.
            out[:, j] = np.searchsorted(e, x[:, j], side='right')
        return out


class GBDT:
    def __init__(self, depth=3, trees=200, lr=0.08, lam=50.0, min_leaf=200, subsample=0.7, seed=1, loss='l2', tau=0.5):
        self.depth, self.ntrees, self.lr, self.lam, self.min_leaf = depth, trees, lr, lam, min_leaf
        self.subsample, self.seed, self.loss, self.tau = subsample, seed, loss, tau
        self.trees = []          # (features[int, 2^d-1], thresholds[float, 2^d-1], leaves[float, 2^d])
        self.base = 0.0
        self.history = []

    def fit(self, x, y, w=None, xv=None, yv=None, wv=None, log_every=50, patience=0, quiet=False):
        """patience: stop after that many checkpoints (every log_every trees) without a better validation loss."""
        rng = np.random.default_rng(self.seed)
        n, nf = x.shape
        w = np.ones(n, np.float64) if w is None else w.astype(np.float64)
        self.binner = Binner(x)
        xbT = np.ascontiguousarray(self.binner.transform(x).T)     # one contiguous row of bins per feature
        ar = np.arange(n)
        nb = 65
        self.base = float(np.sum(w * y) / np.sum(w))
        if self.loss == 'logistic':
            p0 = min(max(self.base, 1e-4), 1 - 1e-4)
            self.base = float(np.log(p0 / (1 - p0)))
        if self.loss == 'quantile':
            self.base = float(np.quantile(y, self.tau))
        pred = np.full(n, self.base)
        pv = None if xv is None else np.full(len(xv), self.base)
        nint = 2 ** self.depth - 1
        for it in range(self.ntrees):
            if self.loss == 'logistic':
                p = 1 / (1 + np.exp(-pred))
                g = (p - y) * w
                h = np.maximum(p * (1 - p), 1e-6) * w
            elif self.loss == 'quantile':
                g = np.where(pred >= y, 1 - self.tau, -self.tau) * w
                h = w.copy()
            else:
                g = (pred - y) * w
                h = w.copy()
            # Histograms come from the sampled rows only; bins route exactly like the float thresholds
            # (x < edges[b]  <=>  bin(x) <= b).
            rows = np.nonzero(rng.random(n) < self.subsample)[0] if self.subsample < 1 else np.arange(n)
            gs, hs = g[rows], h[rows]
            ns = np.zeros(len(rows), np.int64)
            feats = np.zeros(nint, np.int32)
            thr = np.full(nint, np.inf, np.float32)
            tbin = np.full(nint, 255, np.int32)
            cols = None
            for level in range(self.depth):
                first = 2 ** level - 1
                count = 2 ** level
                local = ns - first
                best_gain = np.full(count, -np.inf)
                best_f = np.zeros(count, np.int32)
                best_b = np.zeros(count, np.int32)
                if cols is None:
                    cols = [xbT[j][rows] for j in range(nf)]
                for j in range(nf):
                    idx = local * nb + cols[j]
                    G = np.bincount(idx, gs, minlength=count * nb).reshape(count, nb)
                    H = np.bincount(idx, hs, minlength=count * nb).reshape(count, nb)
                    GL = np.cumsum(G, axis=1)[:, :-1]
                    HL = np.cumsum(H, axis=1)[:, :-1]
                    GT = G.sum(1, keepdims=True)
                    HT = H.sum(1, keepdims=True)
                    GR, HR = GT - GL, HT - HL
                    gain = GL ** 2 / (HL + self.lam) + GR ** 2 / (HR + self.lam) - GT ** 2 / (HT + self.lam)
                    gain[(HL < self.min_leaf * self.subsample) | (HR < self.min_leaf * self.subsample)] = -np.inf
                    nbins = len(self.binner.edges[j])
                    gain[:, nbins:] = -np.inf
                    b = np.argmax(gain, axis=1)
                    v = gain[np.arange(count), b]
                    better = v > best_gain
                    best_gain[better] = v[better]
                    best_f[better] = j
                    best_b[better] = b[better]
                for k in range(count):
                    ni = first + k
                    if np.isfinite(best_gain[k]) and best_gain[k] > 0:
                        feats[ni] = best_f[k]
                        thr[ni] = self.binner.edges[best_f[k]][best_b[k]]
                        tbin[ni] = best_b[k]
                    else:
                        feats[ni] = 0
                        thr[ni] = np.inf      # everything goes left
                        tbin[ni] = 255
                # route: left child = 2i+1, right = 2i+2
                right = xbT[feats[ns], rows] > tbin[ns]
                ns = 2 * ns + 1 + right
            node = np.zeros(n, np.int64)
            for level in range(self.depth):
                node = 2 * node + 1 + (xbT[feats[node], ar] > tbin[node])
            leaf = node - nint
            leaf_s = ns - nint
            G = np.bincount(leaf_s, gs, minlength=nint + 1)
            H = np.bincount(leaf_s, hs, minlength=nint + 1)
            leaves = (-G / (H + self.lam) * self.lr).astype(np.float32)
            if self.loss == 'quantile':
                # Refit each leaf to the tau-quantile of the residuals that reach it (sampled rows only).
                r = (y[rows] - pred[rows])
                for k in range(nint + 1):
                    sel = leaf_s == k
                    if sel.sum() >= self.min_leaf * self.subsample:
                        leaves[k] = np.float32(self.lr * np.quantile(r[sel], self.tau))
                    else:
                        leaves[k] = 0
            self.trees.append((feats, thr, leaves))
            pred += leaves[leaf]
            if pv is not None:
                pv += self.predict_tree(xv, len(self.trees) - 1)
            if log_every and (it % log_every == log_every - 1 or it == self.ntrees - 1):
                tr, va = self.metric(pred, y, w), (np.nan if pv is None else self.metric(pv, yv, wv))
                self.history.append((it + 1, tr, va))
                if not quiet:
                    print(f'    tree {it + 1:4d}  loss train {tr:.4f}  val {va:.4f}', flush=True)
                if patience and pv is not None:
                    best = min(range(len(self.history)), key=lambda k: self.history[k][2])
                    if len(self.history) - 1 - best >= patience:
                        break
        return self

    def metric(self, pred, y, w=None):
        w = np.ones(len(y)) if w is None else w
        if self.loss == 'logistic':
            p = np.clip(1 / (1 + np.exp(-pred)), 1e-6, 1 - 1e-6)
            return float(-np.sum(w * (y * np.log(p) + (1 - y) * np.log(1 - p))) / np.sum(w))
        if self.loss == 'quantile':
            d = y - pred
            return float(np.sum(w * np.maximum(self.tau * d, (self.tau - 1) * d)) / np.sum(w))
        return float(np.sqrt(np.sum(w * (pred - y) ** 2) / np.sum(w)))

    def predict_tree(self, x, k):
        feats, thr, leaves = self.trees[k]
        n = len(x)
        node = np.zeros(n, np.int64)
        for _ in range(self.depth):
            right = ~(x[np.arange(n), feats[node]] < thr[node])
            node = 2 * node + 1 + right
        return leaves[node - (2 ** self.depth - 1)]

    def predict(self, x, ntrees=None):
        p = np.full(len(x), self.base)
        for k in range(len(self.trees) if ntrees is None else ntrees):
            p += self.predict_tree(x, k)
        return p

    def importance(self, nf):
        imp = np.zeros(nf)
        for feats, thr, _ in self.trees:
            for f, t in zip(feats, thr):
                if np.isfinite(t):
                    imp[f] += 1
        return imp
