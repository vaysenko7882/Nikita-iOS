#!/usr/bin/env python3
"""Build CodeGram assets from the owner's original logo (no redrawing)."""
from pathlib import Path
import base64
import io
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
original = Image.open(ROOT / 'tools/nikita/assets/CodeGramLogo.png').convert('RGB')
icon = original.resize((1024, 1024), Image.Resampling.LANCZOS)
target = ROOT / 'Telegram/Telegram-iOS/Telegram.icon'
icon.save(target / 'Assets/CodeGram.png', optimize=True)
for path in (ROOT / 'Telegram/Telegram-iOS/DefaultAppIcon.xcassets').rglob('*.png'):
    with Image.open(path) as original:
        size = original.size
    icon.resize(size, Image.Resampling.LANCZOS).save(path, optimize=True)
menu = ROOT / 'submodules/TelegramUI/Images.xcassets/Item List/Icons/Madgram.imageset'
for path in menu.glob('*.png'):
    with Image.open(path) as original:
        size = original.size
    icon.resize(size, Image.Resampling.LANCZOS).save(path, optimize=True)
for name in ('MadGram.png', 'Nikita.png'):
    (target / 'Assets' / name).unlink(missing_ok=True)
metadata = target / 'icon.json'
metadata.write_text(metadata.read_text().replace('MadGram', 'CodeGram').replace('Nikita', 'CodeGram'))
# The old badge was a pre-rendered raster logo; replace that asset as well.
gray = original.convert('L')
box = gray.point(lambda x: 255 if x > 80 else 0).getbbox()
mark = original.crop(box).convert('RGBA')
mark.putalpha(gray.crop(box))
mark.thumbnail((144, 144), Image.Resampling.LANCZOS)
out = io.BytesIO()
mark.save(out, format='PNG', optimize=True)
encoded = base64.b64encode(out.getvalue()).decode('ascii')
source = '''// Generated from the original tools/nikita/assets/CodeGramLogo.png.
import UIKit
private let codegramMarkImage = Data(base64Encoded: "%s").flatMap { UIImage(data: $0) }
public func codegramBrandMark() -> UIImage? { return codegramMarkImage }
''' % encoded
(ROOT / 'submodules/Display/Source/CodeGramBrandData.swift').write_text(source)
badge = Image.new('RGBA', (384, 78))
ImageDraw.Draw(badge).rounded_rectangle((1, 1, 383, 77), radius=38, fill=(18, 18, 18, 250), outline=(80, 80, 80, 255))
small = mark.copy()
small.thumbnail((52, 52), Image.Resampling.LANCZOS)
badge.alpha_composite(small, (166, 13))
badge.save(ROOT / 'submodules/TelegramUI/Images.xcassets/Components/AppBadge.imageset/AppBadge@3x.png', optimize=True)
print('CodeGram icons generated from the supplied original.')
