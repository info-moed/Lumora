"""
Convert Real-ESRGAN (BSD-3-Clause) weights to Core ML for Lumora's AI upscaler.

  pip install torch coremltools numpy
  # download the weights from https://github.com/xinntao/Real-ESRGAN/releases
  python convert_realesrgan_coreml.py --model x4plus --weights RealESRGAN_x4plus.pth

The .mlpackage is written to ~/Library/Application Support/Lumora/Models/ (change it with --out-dir). Its file name
and tile size match Lumora/Resources/upscale_models.json; Lumora reads the tile size from the model itself, so a
different --tile also works.

No BasicSR or realesrgan package is needed: the two network layouts (RRDBNet and SRVGGNetCompact) are written out
below and must load every tensor of the official checkpoint (strict), so a layout mistake fails loudly. The weights
are read as plain tensors only (a tampered .pth can't run code), checked against the SHA-256 of the official release
files, and the converted model is compared with PyTorch on a real-looking test picture before it is saved.
"""
import argparse, hashlib, os, sys
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
# Load checkpoints as plain tensors only: a tampered .pkl/.pth can't run code during unpickling.
_torch_load = torch.load
def _weights_only_load(*args, **kwargs):
    kwargs["weights_only"] = True
    return _torch_load(*args, **kwargs)
torch.load = _weights_only_load
import coremltools as ct


# --- Network layouts (same module names and order as the official checkpoints) -----------------------------------

class ResidualDenseBlock(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        return self.conv5(torch.cat((x, x1, x2, x3, x4), 1)) * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, nf, gc):
        super().__init__()
        self.rdb1, self.rdb2, self.rdb3 = ResidualDenseBlock(nf, gc), ResidualDenseBlock(nf, gc), ResidualDenseBlock(nf, gc)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    """ESRGAN generator (x4plus, x2plus, x4plus_anime_6B). The x2 model folds 2x2 pixels into channels first."""
    def __init__(self, scale=4, nf=64, nb=23, gc=32):
        super().__init__()
        self.scale = scale
        self.conv_first = nn.Conv2d(3 * (4 if scale == 2 else 1), nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2)

    def forward(self, x):
        if self.scale == 2:
            b, c, h, w = x.shape
            x = x.view(b, c, h // 2, 2, w // 2, 2).permute(0, 1, 3, 5, 2, 4).reshape(b, c * 4, h // 2, w // 2)
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN's small VGG-style network (AnimeVideo v3, general x4v3): convs + PReLU, pixel shuffle, plus a
    nearest-neighbor copy of the input."""
    def __init__(self, nf=64, nc=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        layers = [nn.Conv2d(3, nf, 3, 1, 1), nn.PReLU(nf)]
        for _ in range(nc):
            layers += [nn.Conv2d(nf, nf, 3, 1, 1), nn.PReLU(nf)]
        layers.append(nn.Conv2d(nf, 3 * upscale * upscale, 3, 1, 1))
        self.body = nn.ModuleList(layers)
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        return self.upsampler(out) + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


# name: (network, output file, default tile, official weights file, SHA-256 of that file)
MODELS = {
    "x4plus": (lambda: RRDBNet(scale=4), "RealESRGAN_x4plus.mlpackage", 256, "RealESRGAN_x4plus.pth",
               "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1"),
    "x2plus": (lambda: RRDBNet(scale=2), "RealESRGAN_x2plus.mlpackage", 512, "RealESRGAN_x2plus.pth",
               "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb"),
    "x4plus-anime": (lambda: RRDBNet(scale=4, nb=6), "RealESRGAN_x4plus_anime_6B.mlpackage", 256,
                     "RealESRGAN_x4plus_anime_6B.pth", "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da"),
    "animevideov3": (lambda: SRVGGNetCompact(nc=16), "RealESR_AnimeVideoV3.mlpackage", 384, "realesr-animevideov3.pth",
                     "b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d"),
    "general-x4v3": (lambda: SRVGGNetCompact(nc=32), "RealESR_GeneralX4v3.mlpackage", 384, "realesr-general-x4v3.pth",
                     "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292"),
}


class Clamp(nn.Module):
    def __init__(self, n):
        super().__init__()
        self.n = n

    def forward(self, x):
        return self.n(x).clamp(0, 1)


def test_picture(size):
    """Edges, gradients, fine texture and flat areas — closer to video than uniform noise, which no real frame looks like."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / size
    rng = np.random.default_rng(7)
    r = 0.5 + 0.4 * np.sin(12 * x + 3 * y) * (x > 0.3)
    g = np.clip(0.2 + 0.6 * y + 0.08 * rng.standard_normal((size, size)), 0, 1)
    b = 0.5 + 0.45 * np.sign(np.sin(40 * x)) * np.sign(np.sin(40 * y)) * (y > 0.5)
    img = np.stack([r, g, b])[None].astype(np.float32)
    return np.clip(img, 0, 1)


def check_catalog():
    """Every recipe here has a matching entry (file, tile, scale) in Lumora/Resources/upscale_models.json and back."""
    import json
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Lumora", "Resources", "upscale_models.json")
    catalog = {e["file"]: e for e in json.load(open(path))}
    problems = []
    for name, (make, out_name, tile, _, _) in MODELS.items():
        e = catalog.pop(out_name, None)
        if e is None:
            problems.append("{}: {} isn't in upscale_models.json".format(name, out_name))
            continue
        net = make()
        scale = net.scale if hasattr(net, "scale") else net.upscale
        if e["tile"] != tile or e["scale"] != scale:
            problems.append("{}: catalog tile/scale {}/{} != converter {}/{}".format(name, e["tile"], e["scale"], tile, scale))
        if "--model " + name not in e.get("notes", ""):
            problems.append("{}: catalog notes don't name --model {}".format(name, name))
    problems += ["{} in upscale_models.json has no converter recipe".format(f) for f in catalog]
    for line in problems:
        print(line)
    print("catalog check:", "OK ({} models)".format(len(MODELS)) if not problems else "{} problem(s)".format(len(problems)))
    return 1 if problems else 0


def main():
    if "--check-catalog" in sys.argv[1:]:
        sys.exit(check_catalog())
    p = argparse.ArgumentParser()
    p.add_argument("--check-catalog", action="store_true", help="only compare the recipes with upscale_models.json")
    p.add_argument("--model", required=True, choices=MODELS.keys())
    p.add_argument("--weights", required=True)
    p.add_argument("--tile", type=int, help="square input tile in pixels (default: the size in upscale_models.json)")
    p.add_argument("--out-dir", default=os.path.expanduser("~/Library/Application Support/Lumora/Models"))
    p.add_argument("--allow-unknown-weights", action="store_true",
                   help="convert a checkpoint whose SHA-256 differs from the official release file (fine-tunes)")
    a = p.parse_args()

    make, out_name, tile, official_name, official_sha = MODELS[a.model]
    tile = a.tile or tile
    if tile % 4:
        sys.exit("--tile must be a multiple of 4")
    digest = hashlib.sha256(open(a.weights, "rb").read()).hexdigest()
    print("SHA-256", digest, os.path.basename(a.weights))
    if digest != official_sha:
        msg = "{} is not the official {} (expected SHA-256 {})".format(a.weights, official_name, official_sha)
        if not a.allow_unknown_weights:
            sys.exit(msg + ". Pass --allow-unknown-weights to convert it anyway.")
        print("warning:", msg)

    net = make()
    sd = torch.load(a.weights, map_location="cpu")
    sd = sd.get("params_ema", sd.get("params", sd))
    net.load_state_dict(sd, strict=True)
    net.eval()
    wrapped = Clamp(net).eval()

    with torch.no_grad():
        traced = torch.jit.trace(wrapped, torch.rand(1, 3, tile, tile))
    mlmodel = ct.convert(traced,
                         inputs=[ct.TensorType(name="input", shape=(1, 3, tile, tile), dtype=np.float16)],
                         outputs=[ct.TensorType(name="output", dtype=np.float16)],
                         compute_precision=ct.precision.FLOAT16,
                         minimum_deployment_target=ct.target.macOS15)
    mlmodel.short_description = "Real-ESRGAN {} (BSD-3-Clause, xinntao/Real-ESRGAN), {}x{} tile".format(a.model, tile, tile)
    mlmodel.user_defined_metadata["weights_sha256"] = digest

    # Core ML (fp16) against PyTorch (fp32) on the same picture. fp16 costs a little; a wrong layout costs everything.
    x = test_picture(tile)
    with torch.no_grad():
        ref = wrapped(torch.from_numpy(x)).numpy()
    got = mlmodel.predict({"input": x.astype(np.float16)})["output"].astype(np.float32)
    if got.shape != ref.shape:
        sys.exit("Core ML output shape {} != PyTorch {}".format(got.shape, ref.shape))
    mse = float(np.mean((got - ref) ** 2))
    psnr = 10 * np.log10(1 / max(mse, 1e-12))
    print("Core ML vs PyTorch: PSNR {:.1f} dB, max difference {:.4f}".format(psnr, float(np.abs(got - ref).max())))
    if psnr < 40:
        sys.exit("The converted model doesn't match PyTorch (PSNR {:.1f} dB < 40); not saving it.".format(psnr))

    os.makedirs(a.out_dir, exist_ok=True)
    out = os.path.join(a.out_dir, out_name)
    compiled = os.path.splitext(out)[0] + ".mlmodelc"
    if os.path.exists(compiled):  # Lumora compiles on first use; a stale compiled copy would shadow the new model
        import shutil
        shutil.rmtree(compiled)
    mlmodel.save(out)
    print("Saved", out)


if __name__ == "__main__":
    main()
