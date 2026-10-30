#!/usr/bin/env python3
"""Render the code-native Nikita monogram into the app's existing asset slots."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SIZE = 1024
icon = Image.new('RGB', (SIZE, SIZE))
draw_background = ImageDraw.Draw(icon)
for y in range(SIZE):
    t = y / (SIZE - 1)
    draw_background.line((0, y, SIZE, y), fill=(int(48 - 27 * t), int(174 - 43 * t), int(245 - 23 * t)))
mask = Image.new('L', (SIZE * 3, SIZE * 3))
draw = ImageDraw.Draw(mask)
def polygon(points):
    draw.polygon([(x * 3, y * 3) for x, y in points], fill=255)
polygon([(266, 254), (364, 254), (364, 770), (266, 770)])
polygon([(660, 254), (758, 254), (758, 770), (660, 770)])
polygon([(364, 254), (449, 254), (660, 612), (660, 770), (575, 770), (364, 412)])
mask = mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
icon.paste((255, 255, 255), mask=mask)
target = ROOT / 'Telegram/Telegram-iOS/Telegram.icon'
icon.save(target / 'Assets/Nikita.png', optimize=True)
for path in (ROOT / 'Telegram/Telegram-iOS/DefaultAppIcon.xcassets').rglob('*.png'):
    with Image.open(path) as original:
        size = original.size
    icon.resize(size, Image.Resampling.LANCZOS).save(path, optimize=True)
menu = ROOT / 'submodules/TelegramUI/Images.xcassets/Item List/Icons/Madgram.imageset'
for path in menu.glob('*.png'):
    with Image.open(path) as original:
        size = original.size
    icon.resize(size, Image.Resampling.LANCZOS).save(path, optimize=True)
legacy = target / 'Assets/MadGram.png'
if legacy.exists():
    legacy.unlink()
metadata = target / 'icon.json'
metadata.write_text(metadata.read_text().replace('MadGram', 'Nikita'))
# The old badge was a pre-rendered raster logo; replace that asset as well.
from PIL import ImageFont
badge = Image.new('RGBA', (279, 66))
bd = ImageDraw.Draw(badge)
bd.rounded_rectangle((1, 1, 278, 65), radius=32, fill=(26, 26, 26, 245), outline=(72, 72, 72, 255), width=1)
small = icon.resize((42, 42), Image.Resampling.LANCZOS).convert('RGBA')
rounded = Image.new('L', (42, 42))
ImageDraw.Draw(rounded).rounded_rectangle((0, 0, 41, 41), radius=12, fill=255)
badge.paste(small, (30, 12), rounded)
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 28)
bd.text((86, 16), 'НИКИТА', fill='white', font=font)
badge.save(ROOT / 'submodules/TelegramUI/Images.xcassets/Components/AppBadge.imageset/AppBadge@3x.png', optimize=True)
print('Updated blue/white Nikita icons and status badge.')
