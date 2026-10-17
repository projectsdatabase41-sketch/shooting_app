"""Генератор фоновых картинок и иконки Nexus (минимализм, тёмная и светлая темы).

Запуск из корня репозитория:  python tools/gen_backgrounds.py
Нужен Pillow. Результат:
  assets/bg/web/*.webp      — 1080x1920 (веб)
  assets/bg/android/*.webp  — 1440x2560 (Android, «2K»)
  assets/icon/nexus_icon_*.png, assets/icon/nexus_icon_adaptive_fg.png
Стиль общий с видео-заставкой: тонкие концентрические кольца мишени и один
оранжевый акцент на очень спокойном фоне.
"""
import math
import os
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ORANGE = (255, 106, 19)

THEMES = {
    'dark': {
        'top': (7, 9, 13), 'bottom': (18, 30, 52),
        'ring': (159, 211, 255), 'glow': (58, 141, 255),
    },
    'light': {
        'top': (250, 251, 253), 'bottom': (214, 227, 244),
        'ring': (18, 54, 94), 'glow': (160, 200, 255),
    },
}

SS = 2  # суперсэмплинг для гладких линий


def vgrad(w, h, top, bottom):
    m = Image.linear_gradient('L').resize((w, h))
    return Image.composite(Image.new('RGB', (w, h), bottom), Image.new('RGB', (w, h), top), m)


def radial(img, cx, cy, radius, color, strength):
    """Мягкое свечение: центр (cx, cy) в пикселях, strength 0..1."""
    w, h = img.size
    m = Image.radial_gradient('L').resize((radius * 2, radius * 2))  # 0 в центре, 255 по краю
    m = m.point(lambda v: int(strength * max(0, 255 - min(255, v * 1.45)) ** 1.5 / 255 ** 0.5))
    full = Image.new('L', (w, h), 0)
    full.paste(m, (int(cx - radius), int(cy - radius)))
    img.paste(Image.new('RGB', (w, h), color), (0, 0), full)


def target(img, cx, cy, radii, color, a0, fade, width, dot=None):
    """Симметричные кольца; прозрачность плавно падает от центра наружу."""
    w, h = img.size
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i, r in enumerate(radii):
        a = max(0.0, a0 * (fade ** i))
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=color + (int(255 * a),), width=width)
    if dot:
        ang, ri, rr = dot
        x, y = cx + radii[ri] * math.cos(ang), cy + radii[ri] * math.sin(ang)
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=ORANGE + (255,))
    img.paste(Image.alpha_composite(img.convert('RGBA'), layer).convert('RGB'))


def make(kind, theme, w, h):
    t = THEMES[theme]
    dark = theme == 'dark'
    W, H = w * SS, h * SS
    img = vgrad(W, H, t['top'], t['bottom'])
    ring = t['ring']
    lw = max(2, round(w * 0.0016)) * SS
    step = W * 0.14
    if kind == 'home':
        cx, cy = W / 2, H * 0.40
        radial(img, cx, cy, int(W * 0.9), t['glow'], 0.30 if dark else 0.40)
        target(img, cx, cy, [step * k for k in range(1, 9)], ring, 0.30 if dark else 0.26, 0.80, lw)
    elif kind == 'messenger':
        # в духе обоев Telegram: диагональный градиент + узор из простых значков
        v = Image.linear_gradient('L').resize((W, H))
        hz = Image.linear_gradient('L').rotate(90).resize((W, H))
        m = ImageChops.add(v, hz, scale=2)
        c1, c2 = ((12, 24, 48), (22, 70, 96)) if dark else ((205, 226, 248), (236, 244, 252))
        img = Image.composite(Image.new('RGB', (W, H), c2), Image.new('RGB', (W, H), c1), m)
        pat = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(pat)
        col = (255, 255, 255, 34) if dark else (18, 54, 94, 30)
        cell = W * 0.15
        u = cell * 0.17
        lw2 = max(2, lw)
        rnd = random.Random(3)
        for row in range(int(H / cell) + 2):
            for c in range(int(W / cell) + 2):
                x = c * cell + (cell / 2 if row % 2 else 0)
                y = row * cell
                k = (row * 3 + c * 5 + rnd.randint(0, 1)) % 6
                if k == 0:    # мишень
                    for r in (u, u * 0.55):
                        d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=lw2)
                elif k == 1:  # прицел
                    d.line([x - u, y, x + u, y], fill=col, width=lw2)
                    d.line([x, y - u, x, y + u], fill=col, width=lw2)
                elif k == 2:  # точка-пробоина
                    r = u * 0.45
                    d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=lw2)
                elif k == 3:  # кольцо
                    r = u * 0.8
                    d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=lw2)
                elif k == 4:  # ромб
                    r = u * 0.8
                    d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)], outline=col, width=lw2)
                else:         # плюс
                    d.line([x - u * 0.6, y, x + u * 0.6, y], fill=col, width=lw2)
                    d.line([x, y - u * 0.6, x, y + u * 0.6], fill=col, width=lw2)
        img = Image.alpha_composite(img.convert('RGBA'), pat).convert('RGB')
    elif kind == 'settings':
        cx, cy = W / 2, 0
        target(img, cx, cy, [step * k for k in range(2, 12)], ring, 0.12 if dark else 0.10, 0.88, lw)
    elif kind == 'ai':
        cx, cy = W / 2, H * 0.22
        radial(img, cx, cy, int(W * 0.85), t['glow'], 0.38 if dark else 0.50)
        target(img, cx, cy, [step * k for k in range(1, 7)], ring, 0.34 if dark else 0.28, 0.78, lw)
    elif kind == 'launch':
        base = Image.new('RGB', (W, H), (0, 0, 0) if dark else (244, 246, 248))
        cx, cy = W / 2, H / 2
        col = (159, 211, 255) if dark else (18, 54, 94)
        target(base, cx, cy, [W * (0.10 + 0.06 * i) for i in range(7)], col, 0.35, 1.0, lw * 2)
        img = base
    return img.resize((w, h), Image.LANCZOS)


def make_icon(theme, size=1024, foreground_only=False):
    S = size * SS
    if foreground_only:
        img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    else:
        bg = (11, 13, 16) if theme == 'dark' else (244, 246, 248)
        img = Image.new('RGBA', (S, S), bg + (255,))
    col = (159, 211, 255) if theme == 'dark' or foreground_only else (18, 54, 94)
    d = ImageDraw.Draw(img)
    cx = cy = S / 2
    # в безопасную зону адаптивной иконки (66%) вписываем самое большое кольцо
    maxr = S * (0.31 if foreground_only else 0.40)
    n = 5
    for i in range(n):
        r = maxr * (i + 1) / n
        a = 120 + int(120 * (i + 1) / n)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col + (a,), width=max(3, S // 170))
    return img.resize((size, size), Image.LANCZOS)


def save_webp(img, path, q=88):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, 'WEBP', quality=q, method=6)


def main():
    sizes = {'web': (1080, 1920), 'android': (1440, 2560)}
    for platform, (w, h) in sizes.items():
        for theme in THEMES:
            for kind in ('home', 'messenger', 'settings', 'ai'):
                save_webp(make(kind, theme, w, h), f'assets/bg/{platform}/{kind}_{theme}.webp')
    # заставка для веба — только 1080x1920
    for theme in THEMES:
        save_webp(make('launch', theme, 1080, 1920), f'assets/bg/web/launch_{theme}.webp', q=92)
    os.makedirs('assets/icon', exist_ok=True)
    make_icon('dark').save('assets/icon/nexus_icon_dark.png')
    make_icon('light').save('assets/icon/nexus_icon_light.png')
    make_icon('dark', foreground_only=True).save('assets/icon/nexus_icon_adaptive_fg.png')


if __name__ == '__main__':
    main()
