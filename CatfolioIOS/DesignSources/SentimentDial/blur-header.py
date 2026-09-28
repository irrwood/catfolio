"""Bake the fixed progressive blur in premultiplied RGBA, at 3x resolution.
No frame-time shader or GPU readback is needed for this decorative backdrop.
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image, ImageFilter
source = Path(__file__).parent
sharp = Image.open(source / 'header-sharp.png').convert('RGBA')
rgba = np.asarray(sharp, dtype=np.float32)
rgba[:, :, :3] *= rgba[:, :, 3:4] / 255
premultiplied = Image.fromarray(np.uint8(rgba))
height = rgba.shape[0]
progress = np.clip((np.arange(height) / 3 - 299) / (420 - 299), 0, 1)
levels = 20
selection = progress * levels
result = np.zeros_like(rgba)
for level in range(levels + 1):
    # Existing shader's exp(-2*x*x/radius^2) corresponds to sigma=radius/2.
    pixels = np.asarray(premultiplied.filter(ImageFilter.GaussianBlur(75 * level / levels)), dtype=np.float32)
    weight = np.maximum(0, 1 - np.abs(selection - level))[:, None, None]
    result += pixels * weight
alpha = result[:, :, 3:4]
result[:, :, :3] = np.divide(result[:, :, :3] * 255, alpha, out=np.zeros_like(result[:, :, :3]), where=alpha > 0)
dest = source.parent.parent / 'CatfolioIOS/Assets.xcassets/SentimentDialHeaderFace.imageset'
dest.mkdir(exist_ok=True)
Image.fromarray(np.uint8(np.clip(result, 0, 255))).save(dest / 'art.png')
(dest / 'Contents.json').write_text(json.dumps({'images':[{'filename':'art.png','idiom':'universal','scale':'3x'}],'info':{'author':'xcode','version':1}}, indent=2) + '\n')
