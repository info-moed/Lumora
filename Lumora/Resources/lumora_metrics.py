"""
Lumora's perceptual metrics helper: ColorVideoVDP (JOD) and PU21-PSNR for SDR and HDR (PQ).

Reads the reference and distorted videos as 10-bit 4:2:0 Y4M streams from named pipes (no files written),
converts BT.2020/BT.709 Y'CbCr to the display-encoded RGB the metric expects, and scores a few 1-second
windows spread across the chunk (ColorVideoVDP needs consecutive frames for its temporal model).
Prints one JSON object: {"cvvdp": {"mean": .., "worst": ..}, "puPsnr": {...}}.

Install (Model Lab does this):  pip install cvvdp
VERIFY: display names and the predict() signature against the installed cvvdp version.
"""
import argparse, json, sys
import numpy as np

def read_y4m(path):
    f = open(path, "rb")
    header = f.readline().decode().split()
    w = int(next(t[1:] for t in header if t.startswith("W")))
    h = int(next(t[1:] for t in header if t.startswith("H")))
    fr = next(t[1:] for t in header if t.startswith("F")).split(":")
    fps = float(fr[0]) / float(fr[1])
    ysz, csz = w * h, (w // 2) * (h // 2)
    def frames():
        while True:
            line = f.readline()
            if not line:
                return
            y = np.frombuffer(f.read(ysz * 2), dtype="<u2").reshape(h, w)
            u = np.frombuffer(f.read(csz * 2), dtype="<u2").reshape(h // 2, w // 2)
            v = np.frombuffer(f.read(csz * 2), dtype="<u2").reshape(h // 2, w // 2)
            yield y, u, v
    return w, h, fps, frames()

def to_rgb(y, u, v, hdr):
    kr, kb = (0.2627, 0.0593) if hdr else (0.2126, 0.0722)
    kg = 1 - kr - kb
    Y = (y.astype(np.float32) - 64) / 876
    Cb = (np.repeat(np.repeat(u, 2, 0), 2, 1).astype(np.float32) - 512) / 896
    Cr = (np.repeat(np.repeat(v, 2, 0), 2, 1).astype(np.float32) - 512) / 896
    R = Y + 2 * (1 - kr) * Cr
    B = Y + 2 * (1 - kb) * Cb
    G = (Y - kr * R - kb * B) / kg
    return np.clip(np.stack([R, G, B], -1), 0, 1)

def pq_to_nits(e):
    m1, m2, c1, c2, c3 = 0.1593017578125, 78.84375, 0.8359375, 18.8515625, 18.6875
    p = np.power(np.clip(e, 0, 1), 1 / m2)
    return 10000 * np.power(np.maximum(p - c1, 0) / (c2 - c3 * p), 1 / m1)

def pu21(nits):
    # PU21 (Mantiuk & Azimi 2021), banding-glare parameters
    p = [0.353487901, 0.3734658629, 8.277049286e-05, 0.9062562627, 0.09150303166, 0.9099517204, 596.3148142]
    L = np.clip(nits, 0.005, 10000)
    return p[6] * (((p[0] + p[1] * L ** p[3]) / (1 + p[2] * L ** p[3])) ** p[4] - p[5])

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--ref"); a.add_argument("--dist"); a.add_argument("--hdr", default="1")
    a.add_argument("--metrics", default="cvvdp"); a.add_argument("--windows", type=int, default=3)
    a.add_argument("--total-frames", type=int, default=0)
    args = a.parse_args()
    hdr = args.hdr == "1"
    wanted = set(args.metrics.split(","))
    w, h, fps, ref = read_y4m(args.ref)
    _, _, _, dist = read_y4m(args.dist)

    # Keep only a few 1-second windows (memory stays bounded for 4K/8K chunks). Both pipes are read in
    # lockstep, so neither producer stalls and nothing outside the windows is kept.
    win = max(8, int(round(fps)))
    n = args.total_frames
    starts = sorted(set(int(i * max(0, n - win) / max(1, args.windows - 1)) for i in range(args.windows))) if n > win else [0]
    keep = set(i for s in starts for i in range(s, s + win))
    frames_r, frames_d = {}, {}
    for i, (fr, fd) in enumerate(zip(ref, dist)):
        if i in keep:
            frames_r[i], frames_d[i] = fr, fd
    n = min(n, i + 1) if frames_r else 0
    starts = [s for s in starts if s in frames_r]
    out = {}

    if "puPsnr" in wanted:
        vals = []
        for s in starts:
            for i in range(s, s + win):
                if i not in frames_r: break
                r = to_rgb(*frames_r[i], hdr); d = to_rgb(*frames_d[i], hdr)
                if hdr:
                    r, d = pu21(pq_to_nits(r)), pu21(pq_to_nits(d))
                else:
                    r, d = pu21(np.power(r, 2.4) * 100), pu21(np.power(d, 2.4) * 100)
                mse = float(np.mean((r - d) ** 2))
                vals.append(10 * np.log10((256.0 ** 2) / max(mse, 1e-10)))
        if vals:
            out["puPsnr"] = {"mean": float(np.mean(vals)), "worst": float(np.percentile(vals, 5))}

    if "cvvdp" in wanted:
        import torch, pycvvdp
        dev = torch.device("mps") if torch.backends.mps.is_available() else torch.device("cpu")
        display = "standard_hdr_pq" if hdr else "standard_4k"
        try:
            metric = pycvvdp.cvvdp(display_name=display, device=dev)
        except Exception:
            dev = torch.device("cpu"); metric = pycvvdp.cvvdp(display_name=display, device=dev)
        jods = []
        for s in starts:
            if s not in frames_r: continue
            idx = [i for i in range(s, s + win) if i in frames_r]
            R = np.stack([to_rgb(*frames_r[i], hdr) for i in idx])   # F,H,W,C display-encoded (PQ or gamma)
            D = np.stack([to_rgb(*frames_d[i], hdr) for i in idx])
            jod, _ = metric.predict(torch.from_numpy(D), torch.from_numpy(R), dim_order="FHWC", frames_per_second=fps)
            jods.append(float(jod))
        if jods:
            out["cvvdp"] = {"mean": float(np.mean(jods)), "worst": float(np.min(jods))}

    json.dump(out, sys.stdout)

if __name__ == "__main__":
    main()
