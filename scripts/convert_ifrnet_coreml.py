"""
Convert IFRNet (MIT, https://github.com/ltkong218/IFRNet) to a Core ML .mlpackage that Lumora can use.

  pip install torch coremltools numpy                     (Model Lab's venv already has them)
  download the official checkpoints (the Dropbox link in IFRNet's README) and unzip them
  python convert_ifrnet_coreml.py --weights checkpoints/IFRNet_large/IFRNet_L_Vimeo90K.pth --out IFRNet-L.mlpackage
  python convert_ifrnet_coreml.py --weights checkpoints/IFRNet_large/IFRNet_L_Vimeo90K.pth --flow-output \
      --out IFRNet-L-Flow.mlpackage                      # motion + blend mask only (flow mode, second opinion)

Then copy the .mlpackage into ~/Library/Application Support/Lumora/Models/ and add an entry to models.json there
(docs/features.md, "Interpolation models", has the exact entries).

The network is defined in this file with the same layers and weight names as IFRNet's models/IFRNet*.py, so
conversion needs only the checkpoint (loaded as plain tensors) and runs no downloaded code. The variant (IFRNet,
IFRNet_L, IFRNet_S) is read from the checkpoint's layer widths, and every weight must load (strict), or conversion
stops.

Inputs: img0, img1 (1x3xHxW, fp16, 0..1) and timestep (1x1xHxW, every value t). H and W must be multiples of 16
(Lumora pads to the spec's padMultiple). Output: output (1x3xHxW), or with --flow-output flow (1x4xHxW: t->0 dx,dy
then t->1 dx,dy, in input pixels) and mask (1x1xHxW, weight of img0). The flow export leaves out IFRNet's learned
residual (the correction it adds after warping), so flow mode is a little softer than image mode.
"""
import argparse, sys
import torch
import torch.nn.functional as _F
import coremltools as ct

p = argparse.ArgumentParser()
p.add_argument("--weights", required=True, help="an official IFRNet*.pth checkpoint")
p.add_argument("--out", default="IFRNet.mlpackage")
p.add_argument("--max-size", type=int, default=4096)
p.add_argument("--flow-output", action="store_true",
               help="Export motion (flow) + blend mask instead of the finished frame. Lumora then warps the "
                    "original 10/12-bit HDR pixels itself in 32-bit float.")
a = p.parse_args()

# Checkpoints are loaded as plain tensors only: a tampered .pth can't run code during unpickling.
state = torch.load(a.weights, map_location="cpu", weights_only=True)
if isinstance(state, dict) and isinstance(state.get("state_dict"), dict):
    state = state["state_dict"]
state = {k.replace("module.", ""): v for k, v in state.items()}

VARIANTS = {   # first encoder width -> (name, encoder widths, ResBlock side channels, first kernel)
    32: ("IFRNet", (32, 48, 72, 96), 32, 3),
    64: ("IFRNet_L", (64, 96, 144, 192), 64, 7),
    24: ("IFRNet_S", (24, 36, 54, 72), 24, 3),
}
first = state.get("encoder.pyramid1.0.0.weight")
if first is None:
    sys.exit("{} isn't an IFRNet checkpoint (no encoder.pyramid1.0.0.weight)".format(a.weights))
if int(first.shape[0]) not in VARIANTS:
    sys.exit("unknown IFRNet width {} in {}".format(int(first.shape[0]), a.weights))
variant, C, SIDE, K1 = VARIANTS[int(first.shape[0])]
nn = torch.nn


def convrelu(i, o, k=3, s=1, pad=1):
    return nn.Sequential(nn.Conv2d(i, o, k, s, pad, bias=True), nn.PReLU(o))


class ResBlock(nn.Module):
    # IFRNet updates the last `side` channels in place (out[:, -s:] = conv(out[:, -s:])); this is the same
    # computation written with cat, which converts reliably.
    def __init__(self, c, side):
        super().__init__()
        self.side = side
        self.conv1 = convrelu(c, c)
        self.conv2 = convrelu(side, side)
        self.conv3 = convrelu(c, c)
        self.conv4 = convrelu(side, side)
        self.conv5 = nn.Conv2d(c, c, 3, 1, 1, bias=True)
        self.prelu = nn.PReLU(c)

    def forward(self, x):
        s = self.side
        out = self.conv1(x)
        out = torch.cat([out[:, :-s], self.conv2(out[:, -s:])], 1)
        out = self.conv3(out)
        out = torch.cat([out[:, :-s], self.conv4(out[:, -s:])], 1)
        return self.prelu(x + self.conv5(out))


class Encoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.pyramid1 = nn.Sequential(convrelu(3, C[0], K1, 2, K1 // 2), convrelu(C[0], C[0]))
        self.pyramid2 = nn.Sequential(convrelu(C[0], C[1], 3, 2, 1), convrelu(C[1], C[1]))
        self.pyramid3 = nn.Sequential(convrelu(C[1], C[2], 3, 2, 1), convrelu(C[2], C[2]))
        self.pyramid4 = nn.Sequential(convrelu(C[2], C[3], 3, 2, 1), convrelu(C[3], C[3]))

    def forward(self, img):
        f1 = self.pyramid1(img)
        f2 = self.pyramid2(f1)
        f3 = self.pyramid3(f2)
        return f1, f2, f3, self.pyramid4(f3)


class Decoder(nn.Module):
    def __init__(self, cin, cmid, cout):
        super().__init__()
        self.convblock = nn.Sequential(convrelu(cin, cmid), ResBlock(cmid, SIDE),
                                       nn.ConvTranspose2d(cmid, cout, 4, 2, 1, bias=True))


class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.encoder = Encoder()
        self.decoder4 = Decoder(2 * C[3] + 1, 2 * C[3], 4 + C[2])
        self.decoder3 = Decoder(3 * C[2] + 4, 3 * C[2], 4 + C[1])
        self.decoder2 = Decoder(3 * C[1] + 4, 3 * C[1], 4 + C[0])
        self.decoder1 = Decoder(3 * C[0] + 4, 3 * C[0], 8)


model = Net()
missing, unexpected = model.load_state_dict(state, strict=False)
if missing or unexpected:
    sys.exit("{} doesn't match {} ({} missing, {} unexpected weights, e.g. {})".format(
        a.weights, variant, len(missing), len(unexpected), (list(missing) + list(unexpected))[:3]))
model.eval()
print("variant {} ({} weights)".format(variant, len(state)))


def warp(img, flow):
    """IFRNet's warp() (utils.py) with the sampling grid built by arange: Core ML Tools can't convert torch.linspace
    for a flexible size."""
    h, w = flow.shape[2], flow.shape[3]
    xs = torch.arange(w, dtype=flow.dtype) * (2.0 / (w - 1.0)) - 1.0
    ys = torch.arange(h, dtype=flow.dtype) * (2.0 / (h - 1.0)) - 1.0
    gx = flow[:, 0:1, :, :] / ((w - 1.0) / 2.0) + xs.view(1, 1, 1, -1)
    gy = flow[:, 1:2, :, :] / ((h - 1.0) / 2.0) + ys.view(1, 1, -1, 1)
    g = torch.cat([gx, gy], 1).permute(0, 2, 3, 1)
    return _F.grid_sample(input=img, grid=g, mode="bilinear", padding_mode="border", align_corners=True)


def resize2(x):
    return _F.interpolate(x, scale_factor=2.0, mode="bilinear", align_corners=False)


class Wrapper(nn.Module):
    """IFRNet's Model.inference(img0, img1, embt) at scale_factor 1 (its resizes are then identities), returning
    either the finished frame or the full-resolution flows and the blend mask it warps with."""
    def __init__(self, m):
        super().__init__()
        self.m = m

    @staticmethod
    def dec(d, ft, f0, f1, fl0, fl1):
        return d.convblock(torch.cat([ft, warp(f0, fl0), warp(f1, fl1), fl0, fl1], 1))

    def forward(self, img0, img1, timestep):
        m = self.m
        # Decoder4 wants the time as a 1/16-resolution map. Slicing one value and repeating it (IFRNet's own
        # embt.repeat) traced fine but lost the input in conversion: every t came out as the traced 0.5. Pooling the
        # (constant) timestep map down 16x gives the same map and stays tied to the input.
        embt16 = _F.avg_pool2d(timestep, kernel_size=16, stride=16)
        mean_ = torch.cat([img0, img1], 2).mean(1, keepdim=True).mean(2, keepdim=True).mean(3, keepdim=True)
        i0, i1 = img0 - mean_, img1 - mean_
        f0_1, f0_2, f0_3, f0_4 = m.encoder(i0)
        f1_1, f1_2, f1_3, f1_4 = m.encoder(i1)
        out4 = m.decoder4.convblock(torch.cat([f0_4, f1_4, embt16], 1))
        fl0, fl1, ft = out4[:, 0:2], out4[:, 2:4], out4[:, 4:]
        out3 = self.dec(m.decoder3, ft, f0_3, f1_3, fl0, fl1)
        fl0, fl1, ft = out3[:, 0:2] + 2.0 * resize2(fl0), out3[:, 2:4] + 2.0 * resize2(fl1), out3[:, 4:]
        out2 = self.dec(m.decoder2, ft, f0_2, f1_2, fl0, fl1)
        fl0, fl1, ft = out2[:, 0:2] + 2.0 * resize2(fl0), out2[:, 2:4] + 2.0 * resize2(fl1), out2[:, 4:]
        out1 = self.dec(m.decoder1, ft, f0_1, f1_1, fl0, fl1)
        fl0 = out1[:, 0:2] + 2.0 * resize2(fl0)
        fl1 = out1[:, 2:4] + 2.0 * resize2(fl1)
        mask = torch.sigmoid(out1[:, 4:5])
        if a.flow_output:
            return torch.cat([fl0, fl1], 1), mask
        merged = mask * warp(i0, fl0) + (1 - mask) * warp(i1, fl1) + mean_
        return (merged + out1[:, 5:]).clamp(0, 1)


w = Wrapper(model).eval()
h, wd = 512, 896
ex = (torch.rand(1, 3, h, wd), torch.rand(1, 3, h, wd), torch.full((1, 1, h, wd), 0.5))
traced = torch.jit.trace(w, ex)

H = ct.RangeDim(lower_bound=64, upper_bound=a.max_size, default=h)
W = ct.RangeDim(lower_bound=64, upper_bound=a.max_size, default=wd)
fp16 = ct.converters.mil.mil.types.fp16
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="img0", shape=(1, 3, H, W), dtype=fp16),
            ct.TensorType(name="img1", shape=(1, 3, H, W), dtype=fp16),
            ct.TensorType(name="timestep", shape=(1, 1, H, W), dtype=fp16)],
    outputs=([ct.TensorType(name="flow", dtype=fp16), ct.TensorType(name="mask", dtype=fp16)] if a.flow_output
             else [ct.TensorType(name="output", dtype=fp16)]),
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
mlmodel.short_description = "{} frame interpolation (MIT, ltkong218/IFRNet)".format(variant)


# The converted model must match PyTorch at a size other than the traced one (no baked-in shapes), on a smooth
# picture moving by a few pixels (random noise has no well-defined motion, so fp16 vs fp32 diverge on it).
def _pattern(hh, ww, dx, dy):
    yy, xx = torch.meshgrid(torch.arange(hh, dtype=torch.float32) - dy, torch.arange(ww, dtype=torch.float32) - dx, indexing="ij")
    r = 0.5 + 0.25 * torch.sin(xx / 7.0) * torch.cos(yy / 11.0) + 0.2 * torch.sin((xx + yy) / 23.0)
    g = 0.5 + 0.3 * torch.cos(xx / 13.0 + yy / 5.0)
    b = 0.5 + 0.3 * torch.sin(yy / 9.0)
    return torch.stack([r, g, b])[None].clamp(0, 1)


try:
    import numpy as np
    th, tw = 192, 320
    _a, _b = _pattern(th, tw, 0, 0), _pattern(th, tw, 6, 3)
    # The Vimeo90K checkpoints were trained on triplets only (t = 0.5 always) and ignore the time input; the GoPro
    # checkpoints were trained for 8x and follow it. Say which one this is.
    with torch.no_grad():
        _q = [w(_a, _pattern(th, tw, 12, 0), torch.full((1, 1, th, tw), tv)) for tv in (0.25, 0.75)]
    _q = [x[0] if isinstance(x, (list, tuple)) else x for x in _q]
    _sens = float((_q[0] - _q[1]).abs().mean())
    if _sens < 0.1 * float((_a - _pattern(th, tw, 12, 0)).abs().mean()):
        print("WARNING: this checkpoint ignores the time input (output at t=0.25 and t=0.75 differ by {:.4f}): it makes "
              "only midpoints. Use it for 2x only, or convert a "
              "GoPro checkpoint for other times.".format(_sens))
    else:
        print("time input: follows t (output at t=0.25 vs t=0.75 differs by {:.4f})".format(_sens))
    # Times other than the traced 0.5: a time that is lost in conversion (baked in as a constant) shows up here.
    for _tv in (0.25, 0.75):
        _t = torch.full((1, 1, th, tw), _tv)
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
            print("check {} at {}x{}, t={}: mean abs difference vs PyTorch {:.5f}".format(_name, tw, th, _tv, _err))
            if not np.isfinite(_err) or _err > _lim:
                sys.exit("converted model differs from PyTorch on {} at t={} (mean abs {:.4f})".format(_name, _tv, _err))
except SystemExit:
    raise
except Exception as e:      # prediction isn't available everywhere (e.g. non-macOS); conversion itself succeeded
    print("note: couldn't run the post-conversion check:", e)

mlmodel.save(a.out)
print("Saved", a.out)
