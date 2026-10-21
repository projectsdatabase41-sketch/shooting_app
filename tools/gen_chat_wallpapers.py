"""Обои переписки: цветные градиенты с узором из простых значков (в духе Telegram).
Запуск из корня репозитория: python tools/gen_chat_wallpapers.py
Результат: assets/bg/chat/<id>.webp (1440x2560). Список id/названий — в ChatPreferences.imageWallpapers.
"""
import math
import os
import random

from PIL import Image, ImageChops, ImageDraw

W, H, SS = 1440, 2560, 2

# id: (верх-лево, низ-право, тёмный фон?, узор)
SETS = {
    'black': ((4, 4, 6), (16, 16, 20), True, 'mix'),
    'night': ((12, 24, 48), (22, 70, 96), True, 'mix'),
    'teal': ((8, 46, 52), (20, 110, 112), True, 'rings'),
    'forest': ((14, 38, 26), (46, 92, 58), True, 'dots'),
    'violet': ((30, 18, 58), (88, 52, 130), True, 'mix'),
    'wine': ((52, 14, 32), (126, 44, 72), True, 'rings'),
    'dusk': ((52, 28, 14), (150, 82, 36), True, 'dots'),
    'graphite': ((24, 26, 30), (58, 62, 70), True, 'mix'),
    'sand': ((240, 228, 205), (226, 201, 166), False, 'rings'),
    'mint': ((222, 244, 236), (186, 226, 212), False, 'dots'),
    'sky': ((205, 226, 248), (236, 244, 252), False, 'mix'),
    'lavender': ((232, 226, 250), (210, 200, 240), False, 'rings'),
    'peach': ((252, 232, 222), (246, 204, 184), False, 'dots'),
}


def make(name, c1, c2, dark, pattern):
    w, h = W * SS, H * SS
    v = Image.linear_gradient('L').resize((w, h))
    hz = Image.linear_gradient('L').rotate(90).resize((w, h))
    m = ImageChops.add(v, hz, scale=2)
    img = Image.composite(Image.new('RGB', (w, h), c2), Image.new('RGB', (w, h), c1), m)
    pat = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(pat)
    col = (255, 255, 255, 38) if dark else (20, 50, 90, 34)
    cell = w * 0.15
    u = cell * 0.17
    lw = max(2, int(w * 0.0016))
    rnd = random.Random(abs(hash(name)) % 1000)
    for row in range(int(h / cell) + 2):
        for c in range(int(w / cell) + 2):
            x = c * cell + (cell / 2 if row % 2 else 0)
            y = row * cell
            if pattern == 'dots':
                r = u * 0.22
                d.ellipse([x - r, y - r, x + r, y + r], fill=col)
                continue
            k = (row * 3 + c * 5 + rnd.randint(0, 1)) % 6 if pattern == 'mix' else 0
            if pattern == 'rings' or k == 0:  # мишень
                for r in (u, u * 0.55):
                    d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=lw)
            elif k == 1:  # прицел
                d.line([x - u, y, x + u, y], fill=col, width=lw)
                d.line([x, y - u, x, y + u], fill=col, width=lw)
            elif k == 2:
                r = u * 0.45
                d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=lw)
            elif k == 3:
                r = u * 0.8
                d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=lw)
            elif k == 4:  # ромб
                r = u * 0.8
                d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)], outline=col, width=lw)
            else:  # плюс
                d.line([x - u * 0.6, y, x + u * 0.6, y], fill=col, width=lw)
                d.line([x, y - u * 0.6, x, y + u * 0.6], fill=col, width=lw)
    img = Image.alpha_composite(img.convert('RGBA'), pat).convert('RGB')
    return img.resize((W, H), Image.LANCZOS)


def main():
    os.makedirs('assets/bg/chat', exist_ok=True)
    for name, (c1, c2, dark, pattern) in SETS.items():
        make(name, c1, c2, dark, pattern).save(f'assets/bg/chat/{name}.webp', 'WEBP', quality=82, method=6)


if __name__ == '__main__':
    main()
