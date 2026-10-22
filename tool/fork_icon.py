"""Draws this fork's icon, Baogong's (包工头): the original's pixel bun in a
builder's hard hat, safety orange on the original's dark tile. One grid for
every size: the app icons, assets/branding/logo.svg, and the menu bar's
cells (macos/Runner/Attention.swift's logoCells, printed). Run from the
repository after changing MARK (needs Pillow, and ImageMagick for the
Windows .ico):

    python3 tool/fork_icon.py
"""
import os
import subprocess
from PIL import Image, ImageDraw, ImageFilter

# 10 wide: a hard hat (ridge, dome, a brim out past the head) on the bun.
MARK = [
    "....##....",
    "..######..",
    ".########.",
    "##########",
    ".#......#.",
    ".#.#..#.#.",
    ".#......#.",
    "..######..",
]

GLOW = (255, 214, 150)  # the middle's light
ORANGE = (255, 148, 52)  # the edges'
BRIM = (226, 112, 30)  # the brim, a shade under the rest

# The logo's units per cell, as the original's 56 × 42 (8 × 6 cells of 7).
UNIT = 7


def icon(size=1024):
    """The app icon at 1024, on Apple's grid: an 824 tile from 100 in."""
    s = size / 1024
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    box = tuple(int(v * s) for v in (100, 100, 924, 924))
    radius = int(185 * s)
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        tuple(int(v * s) for v in (100, 112, 924, 936)), radius, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * s)))
    tile = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle(box, radius, fill=(14, 14, 14, 255))
    img.alpha_composite(tile)
    ImageDraw.Draw(img).rounded_rectangle(
        box, radius, outline=(255, 255, 255, 30), width=max(1, int(5 * s)))

    rows, cols = len(MARK), len(MARK[0])
    cell = 66 * s
    w, h = cols * cell, rows * cell
    ox, oy = (size - w) / 2, (size - h) / 2
    cx, cy = size / 2, size / 2 + 20 * s
    fig = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(fig)
    for y, row in enumerate(MARK):
        brim = set(row) == {'#'}
        for x, ch in enumerate(row):
            if ch != '#':
                continue
            x0, y0 = ox + x * cell, oy + y * cell
            # Lighter towards the middle, as the original's gold is.
            dist = min(1, ((x0 + cell / 2 - cx) ** 2 + (y0 + cell / 2 - cy) ** 2) ** 0.5 / (w * 0.62))
            base = BRIM if brim else ORANGE
            t = (1 - dist) ** 1.6 * (0.55 if brim else 1)
            color = tuple(int(b + (g - b) * t) for b, g in zip(base, GLOW))
            d.rectangle((round(x0), round(y0), round(x0 + cell) - 1, round(y0 + cell) - 1),
                        fill=color + (255,))
    glow = fig.filter(ImageFilter.GaussianBlur(28 * s))
    img.alpha_composite(Image.blend(Image.new('RGBA', (size, size), (0, 0, 0, 0)), glow, 0.45))
    img.alpha_composite(fig)
    return img


def runs():
    """Each row's runs of cells, as (x, y, width) in cells."""
    for y, row in enumerate(MARK):
        x = 0
        while x < len(row):
            if row[x] != '#':
                x += 1
                continue
            end = x
            while end < len(row) and row[end] == '#':
                end += 1
            yield x, y, end - x
            x = end


def svg():
    w, h = len(MARK[0]) * UNIT, len(MARK) * UNIT
    path = ''.join(f'M{x * UNIT} {y * UNIT}H{(x + n) * UNIT}V{(y + 1) * UNIT}H{x * UNIT}Z'
                   for x, y, n in runs())
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" fill="none" '
            f'xmlns="http://www.w3.org/2000/svg">\n<path d="{path}" fill="black"/>\n</svg>\n')


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    master = icon()
    icons = os.path.join(root, 'macos/Runner/Assets.xcassets/AppIcon.appiconset')
    for n in (16, 32, 64, 128, 256, 512, 1024):
        master.resize((n, n), Image.LANCZOS).save(os.path.join(icons, f'app_icon_{n}.png'))
    master.resize((128, 128), Image.LANCZOS).save(os.path.join(root, 'assets/branding/app_icon.png'))
    with open(os.path.join(root, 'assets/branding/logo.svg'), 'w') as f:
        f.write(svg())
    sizes = []
    for n in (16, 24, 32, 48, 64, 256):
        path = f'/tmp/fork_icon_{n}.png'
        master.resize((n, n), Image.LANCZOS).save(path)
        sizes.append(path)
    subprocess.run(['magick', *sizes, os.path.join(root, 'windows/runner/resources/app_icon.ico')],
                   check=True)
    print('Attention.swift logoCells, in units of', UNIT, 'cells:')
    for x, y, n in runs():
        print(f'    CGRect(x: {x * UNIT}, y: {y * UNIT}, width: {n * UNIT}, height: {UNIT}),')


if __name__ == '__main__':
    main()
