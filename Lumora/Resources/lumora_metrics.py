"""
Lumora's perceptual metrics helper: ColorVideoVDP (JOD) and PU21-PSNR for SDR and HDR (PQ or HLG).

Reads the reference and distorted videos as 10-bit 4:2:0 Y4M streams from named pipes (no files written),
converts BT.2020/BT.709 Y'CbCr to the display-encoded RGB the metric expects, and scores a few 1-second
windows spread across the chunk (ColorVideoVDP needs consecutive frames for its temporal model).
Prints one JSON object:
  {"cvvdp": {"mean": .., "worst": ..}, "puPsnr": {...}, "display": "standard_hdr_pq", "device": "mps"}

Display models (ColorVideoVDP's own, all a 30-inch 4K screen seen from twice its height): SDR = standard_4k
(BT.709, 200 cd/m2 peak, office light), PQ = standard_hdr_pq and HLG = standard_hdr_hlg (BT.2020, 1500 cd/m2 peak,
dim room). Display-encoded float input in 0..1 is decoded by the display model's own EOTF (sRGB for SDR, PQ or HLG).

Install (Model Lab does this, wheels only):  pip install --no-deps cvvdp==0.5.7  plus its dependencies.
Checked against cvvdp 0.5.7: pycvvdp.cvvdp(display_name=, device=) and predict(test, reference, dim_order=,
frames_per_second=) -> (JOD tensor, stats).
"""
import argparse, json, sys, time
import numpy as np

DISPLAYS = {"sdr": "standard_4k", "pq": "standard_hdr_pq", "hlg": "standard_hdr_hlg"}


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
    """Limited-range 10-bit Y'CbCr -> non-linear R'G'B' in 0..1 (BT.2020 matrix for HDR, BT.709 for SDR)."""
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


def hlg_to_nits(e, peak=1000.0):
    """BT.2100 HLG: inverse OETF to scene light, then the OOTF for a display of the given peak (gamma 1.2 at 1000)."""
    a, b, c = 0.17883277, 0.28466892, 0.55991073
    e = np.clip(e, 0, 1)
    scene = np.where(e <= 0.5, e * e / 3, (np.exp((e - c) / a) + b) / 12)
    ys = 0.2627 * scene[..., 0] + 0.6780 * scene[..., 1] + 0.0593 * scene[..., 2]
    gamma = 1.2 + 0.42 * np.log10(peak / 1000)
    return peak * np.power(np.maximum(ys, 1e-12), gamma - 1)[..., None] * scene


def pu21(nits):
    # PU21 (Mantiuk & Azimi 2021), banding-glare parameters
    p = [0.353487901, 0.3734658629, 8.277049286e-05, 0.9062562627, 0.09150303166, 0.9099517204, 596.3148142]
    L = np.clip(nits, 0.005, 10000)
    return p[6] * (((p[0] + p[1] * L ** p[3]) / (1 + p[2] * L ** p[3])) ** p[4] - p[5])


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--ref"); a.add_argument("--dist")
    a.add_argument("--hdr", default="0", help="0 = SDR BT.709, 1 or pq = HDR10 (PQ), hlg = HLG")
    a.add_argument("--metrics", default="cvvdp"); a.add_argument("--windows", type=int, default=3)
    a.add_argument("--total-frames", type=int, default=0)
    a.add_argument("--threads", type=int, default=0)
    a.add_argument("--device", default="auto", help="auto (MPS when available), mps or cpu")
    args = a.parse_args()
    t0 = time.monotonic()
    timing = {}
    mode = {"0": "sdr", "1": "pq", "pq": "pq", "hlg": "hlg"}[args.hdr]
    hdr = mode != "sdr"
    wanted = set(args.metrics.split(","))
    w, h, fps, ref = read_y4m(args.ref)
    _, _, _, dist = read_y4m(args.dist)

    # Keep only a few 1-second windows (memory stays bounded for 4K/8K chunks). Both pipes are read in
    # lockstep, so neither producer stalls and nothing outside the windows is kept. Windows never overlap: a
    # 2-second chunk is scored as its two seconds, not as six overlapping windows over the same frames.
    win = max(8, int(round(fps)))
    n = args.total_frames
    if n > win:
        k = max(1, min(args.windows, n // win))
        starts = sorted(set(int(round(i * (n - win) / (k - 1))) for i in range(k))) if k > 1 else [(n - win) // 2]
    else:
        starts = [0]
    keep = set(i for s in starts for i in range(s, s + win))
    frames_r, frames_d = {}, {}
    for i, (fr, fd) in enumerate(zip(ref, dist)):
        if i in keep:
            frames_r[i], frames_d[i] = fr, fd
    starts = [s for s in starts if s in frames_r]
    out = {}
    timing["read"] = time.monotonic() - t0

    if "puPsnr" in wanted:
        # PQ and SDR decode each channel on its own, so EOTF + PU21 is one curve: a 16-bit lookup table (finer than
        # the 10-bit source) replaces the per-pixel powers. HLG's OOTF mixes channels, so it is computed directly.
        lut = None
        if mode != "hlg":
            v = np.linspace(0, 1, 65536, dtype=np.float64)
            lut = pu21(pq_to_nits(v) if mode == "pq" else np.power(v, 2.4) * 100).astype(np.float32)
        def encode(rgb):
            if lut is None:
                return pu21(hlg_to_nits(rgb))
            return lut[np.rint(rgb * 65535).astype(np.uint16)]
        vals = []
        for s in starts:
            for i in range(s, s + win):
                if i not in frames_r: break
                r = encode(to_rgb(*frames_r[i], hdr)); d = encode(to_rgb(*frames_d[i], hdr))
                mse = float(np.mean((r - d) ** 2))
                vals.append(10 * np.log10((256.0 ** 2) / max(mse, 1e-10)))
        if vals:
            out["puPsnr"] = {"mean": float(np.mean(vals)), "worst": float(np.percentile(vals, 5))}
        timing["puPsnr"] = time.monotonic() - t0 - timing["read"]

    if "cvvdp" in wanted:
        t1 = time.monotonic()
        import torch, pycvvdp
        if args.threads > 0:
            torch.set_num_threads(args.threads)
        display = DISPLAYS[mode]
        use_mps = args.device in ("auto", "mps") and torch.backends.mps.is_available()
        devices = ([torch.device("mps")] if use_mps else []) + [torch.device("cpu")]
        jods, used = [], None
        for dev in devices:
            try:
                metric = pycvvdp.cvvdp(display_name=display, device=dev, quiet=True)
                jods = []
                for s in starts:
                    idx = [i for i in range(s, s + win) if i in frames_r]
                    R = np.stack([to_rgb(*frames_r[i], hdr) for i in idx])   # F,H,W,C display-encoded (PQ, HLG or gamma)
                    D = np.stack([to_rgb(*frames_d[i], hdr) for i in idx])
                    with torch.no_grad():
                        jod, _ = metric.predict(torch.from_numpy(D), torch.from_numpy(R), dim_order="FHWC",
                                                frames_per_second=fps)
                    jods.append(float(jod))
                used = dev.type
                break
            except Exception as e:      # an operator MPS lacks: run the same windows on the CPU instead
                print(f"ColorVideoVDP on {dev.type} failed ({e}); retrying on the CPU", file=sys.stderr)
        if jods:
            out["cvvdp"] = {"mean": float(np.mean(jods)), "worst": float(np.min(jods))}
            out["display"], out["device"] = display, used
            out["windows"] = len(jods)
        timing["cvvdp"] = time.monotonic() - t1

    out["seconds"] = {k: round(v, 2) for k, v in timing.items()}
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
