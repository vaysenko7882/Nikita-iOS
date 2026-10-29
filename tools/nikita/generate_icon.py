#!/usr/bin/env python3
"""Render the code-native Nikita monogram into the app's existing asset slots."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SIZE = 1024
icon = Image.new('RGB', (SIZE, SIZE))
pixels = icon.load()
for y in range(SIZE):
    for x in range(SIZE):
        glow = max(0, 1 - ((x - 760) ** 2 + (y - 740) ** 2) / 850 ** 2)
        pixels[x, y] = (int(9 + glow * 8), int(17 + glow * 36), int(28 + glow * 37))
mask = Image.new('L', (SIZE * 3, SIZE * 3))
draw = ImageDraw.Draw(mask)
def polygon(points):
    draw.polygon([(x * 3, y * 3) for x, y in points], fill=255)
polygon([(266, 254), (364, 254), (364, 770), (266, 770)])
polygon([(660, 254), (758, 254), (758, 770), (660, 770)])
polygon([(364, 254), (449, 254), (660, 612), (660, 770), (575, 770), (364, 412)])
mask = mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
color = Image.new('RGB', (SIZE, SIZE))
cd = ImageDraw.Draw(color)
for y in range(SIZE):
    t = y / SIZE
    cd.line((0, y, SIZE, y), fill=(int(138 - 70 * t), int(239 - 18 * t), int(242 - 69 * t)))
icon.paste(color, mask=mask)
target = ROOT / 'Telegram/Telegram-iOS/Telegram.icon'
icon.save(target / 'Assets/MadGram.png', optimize=True)
for path in (ROOT / 'Telegram/Telegram-iOS/DefaultAppIcon.xcassets').rglob('*.png'):
    with Image.open(path) as original:
        size = original.size
    icon.resize(size, Image.Resampling.LANCZOS).save(path, optimize=True)
menu = ROOT / 'submodules/TelegramUI/Images.xcassets/Item List/Icons/Madgram.imageset'
for path in menu.glob('*.png'):
    with Image.open(path) as original:
        size = original.size
    icon.resize(size, Image.Resampling.LANCZOS).save(path, optimize=True)
print('Updated default Nikita app icon and settings icon assets.')
