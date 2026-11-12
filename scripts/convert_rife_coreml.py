"""
Convert Practical-RIFE (MIT) to a Core ML .mlpackage that Lumora can use.

  pip install torch coremltools numpy
  git clone https://github.com/hzwer/Practical-RIFE && download the 4.x weights per its README
  python convert_rife_coreml.py --rife-dir Practical-RIFE --weights train_log --out RIFE4.mlpackage
  python convert_rife_coreml.py --rife-dir Practical-RIFE --weights train_log --flow-output --out RIFE4Flow.mlpackage   # HDR / 12-bit

Then copy the .mlpackage into ~/Library/Application Support/Lumora/Models/.

Inputs: img0, img1 (1x3xHxW, fp16, 0..1) and timestep (1x1xHxW). Output: output (1x3xHxW).
Lumora feeds the encoded log / PQ / HLG signal directly, so HDR survives untouched.

RIFE's forward() signature differs slightly between 4.x releases; adjust Wrapper.forward if the trace fails.
"""
import argparse, sys
import torch
# Load checkpoints as plain tensors only: a tampered .pkl/.pth can't run code during unpickling.
_torch_load = torch.load
def _weights_only_load(*args, **kwargs):
    kwargs["weights_only"] = True
    return _torch_load(*args, **kwargs)
torch.load = _weights_only_load
import coremltools as ct

# Practical-RIFE's model/loss.py imports torchvision for a training-only loss (VGG) that inference never builds.
# Stub it when it isn't installed, so conversion doesn't need torchvision.
try:
    import torchvision.models  # noqa: F401
except ImportError:
    import types
    _tv = types.ModuleType("torchvision")
    _tv.models = types.ModuleType("torchvision.models")
    sys.modules["torchvision"] = _tv
    sys.modules["torchvision.models"] = _tv.models

p = argparse.ArgumentParser()
p.add_argument("--rife-dir", required=True)
p.add_argument("--weights", required=True)
p.add_argument("--out", default="RIFE4.mlpackage")
p.add_argument("--variant", default="standard", help="(kept for compatibility; scales are detected automatically)")
p.add_argument("--max-size", type=int, default=4096)
p.add_argument("--flow-output", action="store_true",
               help="Export motion (flow) + blend mask instead of the finished frame. Lumora then warps the "
                    "original 10/12-bit HDR pixels itself in 32-bit float (recommended for HDR).")
p.add_argument("--mask-is-logit", action="store_true",
               help="(default; kept for compatibility) Apply a sigmoid to the mask output. Every RIFE 4.x IFNet "
                    "returns the last block's raw mask logits, so the sigmoid is always applied unless "
                    "--mask-is-probability is given.")
p.add_argument("--mask-is-probability", action="store_true",
               help="Don't apply the sigmoid (only for a modified IFNet that already returns a 0...1 mask).")
a = p.parse_args()

sys.path.insert(0, a.rife_dir)
from train_log.RIFE_HDv3 import Model  # noqa: E402  (path used by Practical-RIFE 4.x releases)

model = Model()
model.load_model(a.weights, -1)
model.eval()
flownet = model.flownet

# Practical-RIFE loads with strict=False, which silently leaves layers random if the checkpoint's keys don't
# match. Refuse to convert a network that didn't get all of its weights.
_ckpt = {k.replace("module.", ""): v for k, v in torch.load("{}/flownet.pkl".format(a.weights), map_location="cpu").items()}
_missing = [k for k in flownet.state_dict() if k not in _ckpt]
if _missing:
    sys.exit("flownet.pkl doesn't match this RIFE release's network ({} missing weights, e.g. {})".format(len(_missing), _missing[:3]))

def last(v):
    return v[-1] if isinstance(v, (list, tuple)) else v

# IFBlock shrinks its input with F.interpolate(scale_factor=1/scale) (1/16 ... 1/2). Core ML Tools can't convert a
# fractional bilinear scale on a flexible-size input, so during conversion that exact operation is expressed as
# the equivalent 2x2 average + strided pick (PyTorch's bilinear downscale by an even integer factor s samples
# halfway between pixels s*i + s/2 - 1 and s*i + s/2). Everything else goes to the real F.interpolate.
import types
import torch.nn.functional as _F
def _interpolate(x, size=None, scale_factor=None, mode="nearest", align_corners=None, **kwargs):
    if size is None and isinstance(scale_factor, (int, float)) and 0 < scale_factor < 1 and mode == "bilinear" \
            and not align_corners and not kwargs.get("antialias", False):
        s = round(1 / scale_factor)
        if s >= 2 and s % 2 == 0 and abs(1 / scale_factor - s) < 1e-6:
            o = s // 2 - 1
            return _F.avg_pool2d(x, kernel_size=2, stride=1)[:, :, o::s, o::s]
    return _F.interpolate(x, size=size, scale_factor=scale_factor, mode=mode, align_corners=align_corners, **kwargs)
_ifnet = sys.modules.get("train_log.IFNet_HDv3")
if _ifnet is not None and getattr(_ifnet, "F", None) is _F:
    with torch.no_grad():
        _x = torch.rand(1, 6, 128, 192)
        for _sc in (16, 8, 4, 2):
            _ref = _F.interpolate(_x, scale_factor=1. / _sc, mode="bilinear", align_corners=False)
            _alt = _interpolate(_x, scale_factor=1. / _sc, mode="bilinear", align_corners=False)
            if _ref.shape != _alt.shape or (_ref - _alt).abs().max() > 1e-5:
                sys.exit("internal check failed: convertible downscale differs from F.interpolate at 1/{}".format(_sc))
    _patched = types.ModuleType("convertible_functional")
    _patched.__dict__.update(_F.__dict__)
    _patched.interpolate = _interpolate
    _ifnet.F = _patched

# Practical-RIFE's warp() builds its sampling grid with torch.linspace(steps=width), which Core ML Tools can't
# convert for a flexible size, and caches it. The same grid, built with arange (no cache), converts.
def _warp(tenInput, tenFlow):
    h, w = tenFlow.shape[2], tenFlow.shape[3]
    xs = torch.arange(w, dtype=tenFlow.dtype) * (2.0 / (w - 1.0)) - 1.0
    ys = torch.arange(h, dtype=tenFlow.dtype) * (2.0 / (h - 1.0)) - 1.0
    gx = tenFlow[:, 0:1, :, :] / ((tenInput.shape[3] - 1.0) / 2.0) + xs.view(1, 1, 1, -1)
    gy = tenFlow[:, 1:2, :, :] / ((tenInput.shape[2] - 1.0) / 2.0) + ys.view(1, 1, -1, 1)
    g = torch.cat([gx, gy], 1).permute(0, 2, 3, 1)
    return _F.grid_sample(input=tenInput, grid=g, mode="bilinear", padding_mode="border", align_corners=True)
if _ifnet is not None and hasattr(_ifnet, "warp"):
    with torch.no_grad():
        _img, _fl = torch.rand(1, 3, 96, 160), torch.randn(1, 2, 96, 160) * 4
        if (_ifnet.warp(_img, _fl) - _warp(_img, _fl)).abs().max() > 1e-4:
            sys.exit("internal check failed: convertible warp differs from Practical-RIFE's warp")
    _ifnet.warp = _warp

class Wrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        # Number of coarse-to-fine flow blocks differs between releases (4.25+ added one); derive the scale list.
        blocks = [m for m in net.modules() if type(m).__name__.startswith("IFBlock")]
        n = max(4, len(blocks))
        self.scales = [2 ** (n - 1 - i) for i in range(n)]
    def forward(self, img0, img1, timestep):
        # warp() caches its sampling grid per size in a module-level dict. Left in place, the second tracing pass
        # (and the converted model) would get the first pass's grid as a fixed constant instead of building it
        # from the input size, so start every pass with an empty cache.
        _wl = sys.modules.get("model.warplayer")
        if _wl is not None and isinstance(getattr(_wl, "backwarp_tenGrid", None), dict):
            _wl.backwarp_tenGrid.clear()
        x = torch.cat((img0, img1), 1)                     # IFNet splits x into the two frames
        # IFNet expands a tensor timestep itself (timestep.repeat(1, 1, H, W)), so it must get one value per
        # batch item, not the full [1,1,H,W] map (that would become [1,1,H*H,W*W]).
        flow, mask, merged = self.net(x, timestep[:, :, :1, :1], self.scales)
        if a.flow_output:
            m = last(mask)
            if not a.mask_is_probability:
                m = torch.sigmoid(m)
            # flow[:, 0:2] warps img0 to time t, flow[:, 2:4] warps img1; units are input pixels.
            return last(flow), m
        return last(merged).clamp(0, 1)

w = Wrapper(flownet).eval()
h, wd = 512, 896
ex = (torch.rand(1, 3, h, wd), torch.rand(1, 3, h, wd), torch.full((1, 1, h, wd), 0.5))
traced = torch.jit.trace(w, ex)

H = ct.RangeDim(lower_bound=64, upper_bound=a.max_size, default=h)
W = ct.RangeDim(lower_bound=64, upper_bound=a.max_size, default=wd)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="img0", shape=(1, 3, H, W), dtype=ct.converters.mil.mil.types.fp16),
            ct.TensorType(name="img1", shape=(1, 3, H, W), dtype=ct.converters.mil.mil.types.fp16),
            ct.TensorType(name="timestep", shape=(1, 1, H, W), dtype=ct.converters.mil.mil.types.fp16)],
    outputs=([ct.TensorType(name="flow", dtype=ct.converters.mil.mil.types.fp16),
              ct.TensorType(name="mask", dtype=ct.converters.mil.mil.types.fp16)] if a.flow_output
             else [ct.TensorType(name="output", dtype=ct.converters.mil.mil.types.fp16)]),
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
mlmodel.short_description = "Practical-RIFE frame interpolation (MIT)"

# The converted model must match PyTorch at a size other than the one it was traced at (no baked-in shapes), on a
# smooth picture moving by a few pixels (random noise has no well-defined motion, so fp16 vs fp32 diverge on it).
def _pattern(h, w_, dx, dy):
    yy, xx = torch.meshgrid(torch.arange(h, dtype=torch.float32) - dy, torch.arange(w_, dtype=torch.float32) - dx, indexing="ij")
    r = 0.5 + 0.25 * torch.sin(xx / 7.0) * torch.cos(yy / 11.0) + 0.2 * torch.sin((xx + yy) / 23.0)
    g = 0.5 + 0.3 * torch.cos(xx / 13.0 + yy / 5.0)
    b = 0.5 + 0.3 * torch.sin(yy / 9.0)
    return torch.stack([r, g, b])[None].clamp(0, 1)
try:
    import numpy as np
    th, tw = 192, 320
    _a, _b = _pattern(th, tw, 0, 0), _pattern(th, tw, 6, 3)
    _t = torch.full((1, 1, th, tw), 0.5)
    with torch.no_grad():
        _ref = w(_a, _b, _t)
    _ref = _ref if isinstance(_ref, (list, tuple)) else (_ref,)
    _out = mlmodel.predict({"img0": _a.numpy().astype(np.float16), "img1": _b.numpy().astype(np.float16),
                            "timestep": _t.numpy().astype(np.float16)})
    for _name, _r in zip(["flow", "mask"] if a.flow_output else ["output"], _ref):
        _got = np.asarray(_out[_name], dtype=np.float32)
        if _got.shape != tuple(_r.shape):
            sys.exit("converted model returns {} {} at {}x{}, PyTorch {}".format(_name, _got.shape, tw, th, tuple(_r.shape)))
        _err = float(np.abs(_got - _r.numpy()).mean())
        _lim = {"flow": 0.25, "mask": 0.05}.get(_name, 0.01)      # pixels of motion; 0...1 for mask and picture
        print("check {} at {}x{}: mean abs difference vs PyTorch {:.5f}".format(_name, tw, th, _err))
        if not np.isfinite(_err) or _err > _lim:
            sys.exit("converted model differs from PyTorch on {} (mean abs {:.4f})".format(_name, _err))
except SystemExit:
    raise
except Exception as e:      # prediction isn't available everywhere (e.g. non-macOS); conversion itself succeeded
    print("note: couldn't run the post-conversion check:", e)

mlmodel.save(a.out)
print("Saved", a.out)
