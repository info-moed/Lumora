"""
Convert Real-ESRGAN (BSD-3-Clause) weights to Core ML for Lumora's AI upscaler.

  pip install torch coremltools basicsr realesrgan
  # download weights from https://github.com/xinntao/Real-ESRGAN/releases
  python convert_realesrgan_coreml.py --model x4plus --weights RealESRGAN_x4plus.pth

Copy the resulting .mlpackage to ~/Library/Application Support/Lumora/Models/.
The tile size must match "tile" in Lumora/Resources/upscale_models.json (Lumora processes overlapping tiles).
"""
import argparse
import torch
# Load checkpoints as plain tensors only: a tampered .pkl/.pth can't run code during unpickling.
_torch_load = torch.load
def _weights_only_load(*args, **kwargs):
    kwargs["weights_only"] = True
    return _torch_load(*args, **kwargs)
torch.load = _weights_only_load
import coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan.archs.srvgg_arch import SRVGGNetCompact

MODELS = {
    "x4plus": (lambda: RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4),
               "RealESRGAN_x4plus.mlpackage", 256),
    "x2plus": (lambda: RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=2),
               "RealESRGAN_x2plus.mlpackage", 384),
    "animevideov3": (lambda: SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4, act_type="prelu"),
                     "RealESR_AnimeVideoV3.mlpackage", 384),
}

p = argparse.ArgumentParser()
p.add_argument("--model", required=True, choices=MODELS.keys())
p.add_argument("--weights", required=True)
a = p.parse_args()

make, out_name, tile = MODELS[a.model]
net = make()
sd = torch.load(a.weights, map_location="cpu")
sd = sd.get("params_ema", sd.get("params", sd))
net.load_state_dict(sd, strict=True)
net.eval()

class Clamp(torch.nn.Module):
    def __init__(self, n): super().__init__(); self.n = n
    def forward(self, x): return self.n(x).clamp(0, 1)

traced = torch.jit.trace(Clamp(net), torch.rand(1, 3, tile, tile))
fp16 = ct.converters.mil.mil.types.fp16
mlmodel = ct.convert(traced,
                     inputs=[ct.TensorType(name="input", shape=(1, 3, tile, tile), dtype=fp16)],
                     outputs=[ct.TensorType(name="output", dtype=fp16)],
                     compute_precision=ct.precision.FLOAT16,
                     minimum_deployment_target=ct.target.macOS15)
mlmodel.short_description = f"Real-ESRGAN {a.model} (BSD-3-Clause)"
mlmodel.save(out_name)
print("Saved", out_name)
