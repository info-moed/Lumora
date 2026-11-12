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
               help="Apply a sigmoid to the mask output (needed if your RIFE version returns raw mask logits).")
a = p.parse_args()

sys.path.insert(0, a.rife_dir)
from train_log.RIFE_HDv3 import Model  # noqa: E402  (path used by Practical-RIFE 4.x releases)

model = Model()
model.load_model(a.weights, -1)
model.eval()
flownet = model.flownet

def last(v):
    return v[-1] if isinstance(v, (list, tuple)) else v

class Wrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        # Number of coarse-to-fine flow blocks differs between releases (4.25+ added one); derive the scale list.
        blocks = [m for m in net.modules() if type(m).__name__.startswith("IFBlock")]
        n = max(4, len(blocks))
        self.scales = [2 ** (n - 1 - i) for i in range(n)]
    def forward(self, img0, img1, timestep):
        x = torch.cat((img0, img1), 1)                     # IFNet splits x into the two frames
        flow, mask, merged = self.net(x, timestep, self.scales)
        if a.flow_output:
            m = last(mask)
            if a.mask_is_logit:
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
mlmodel.save(a.out)
print("Saved", a.out)
