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
        'top': (10, 12, 15), 'bottom': (17, 21, 27),
        'ring': (159, 211, 255), 'glow': (58, 141, 255),
    },
    'light': {
        'top': (246, 248, 250), 'bottom': (233, 238, 243),
        'ring': (18, 54, 94), 'glow': (160, 200, 255),
    },
}

SS = 2  # суперсэмплинг для гладких линий


def gradient(w, h, top, bottom):
    img = Image.new('RGB', (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img


def rings(base, cx, cy, radii, color, alpha, width, dot=None):
    """Кольца с центром (cx, cy) в долях размера (в пикселях базы)."""
    w, h = base.size
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for r in radii:
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=color + (int(255 * alpha),), width=width)
    if dot:
        x, y, rr, a = dot
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=ORANGE + (int(255 * a),))
    base.paste(Image.alpha_composite(base.convert('RGBA'), layer).convert('RGB'))


def glow(base, cx, cy, radius, color, alpha):
    w, h = base.size
    layer = Image.new('RGBA', (w, h), color + (0,))
    mask = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=int(255 * alpha))
    mask = mask.filter(ImageFilter.GaussianBlur(radius / 2.2))
    layer.putalpha(mask)
    base.paste(Image.alpha_composite(base.convert('RGBA'), layer).convert('RGB'))


def dither(img, amp=1.2, seed=7):
    """Лёгкий шум против полос на плавных градиентах."""
    rnd = random.Random(seed)
    w, h = img.size
    noise = Image.new('L', (w, h))
    noise.putdata([128 + int(rnd.gauss(0, amp * 3)) for _ in range(w * h)])
    n = Image.merge('RGB', (noise, noise, noise))
    # смешиваем шум как «мягкий свет» очень слабо
    return ImageChops.add(img, n, scale=1, offset=-128)


def finish(img, w, h):
    return dither(img.resize((w, h), Image.LANCZOS))


def make(kind, theme, w, h):
    t = THEMES[theme]
    W, H = w * SS, h * SS
    img = gradient(W, H, t['top'], t['bottom'])
    ring = t['ring']
    lw = max(2, round(w * 0.0018)) * SS
    if kind == 'home':
        # огромные кольца, выходящие из правого нижнего угла
        cx, cy = W * 0.86, H * 1.02
        rings(img, cx, cy, [W * k for k in (0.35, 0.62, 0.9, 1.2, 1.55)], ring, 0.075, lw)
        rings(img, W * 0.12, H * 0.07, [W * 0.10, W * 0.18], ring, 0.04, lw)
    elif kind == 'messenger':
        # редкий рисунок из маленьких мишеней, 4–5% контраста
        step = W * 0.26
        for row in range(-1, int(H / step) + 2):
            off = step / 2 if row % 2 else 0
            for col in range(-1, int(W / step) + 2):
                x, y = col * step + off, row * step * 0.95
                rr = W * 0.022
                rings(img, x, y, [rr, rr * 1.9, rr * 2.8], ring, 0.05, max(1, lw // 2))
    elif kind == 'settings':
        # почти ровный фон, едва заметные кольца, уходящие от верхней кромки
        rings(img, W * 0.5, -H * 0.04, [W * k for k in (0.42, 0.7, 0.98, 1.28)], ring, 0.05, lw)
    elif kind == 'ai':
        glow(img, W * 0.5, H * 0.1, W * 0.72, t['glow'], 0.14 if theme == 'dark' else 0.28)
        rings(img, W * 0.5, H * 0.1, [W * k for k in (0.22, 0.4, 0.6, 0.82)], ring, 0.09 if theme == 'dark' else 0.10, lw,
              dot=(W * 0.5 + W * 0.07, H * 0.1 - W * 0.12, W * 0.011, 0.9))
    elif kind == 'launch':
        # как кадр заставки: семь колец и оранжевая точка над центром
        base = Image.new('RGB', (W, H), (0, 0, 0) if theme == 'dark' else (244, 246, 248))
        cx, cy = W * 0.5, H * 0.5
        radii = [W * (0.11 + 0.065 * i) for i in range(7)]
        col = (159, 211, 255) if theme == 'dark' else (18, 54, 94)
        for i, r in enumerate(radii):
            a = 0.55 + 0.4 * (i / 6) if theme == 'dark' else 0.5 + 0.4 * (i / 6)
            rings(base, cx, cy, [r], col, min(a, 0.95), lw * 2)
        rings(base, cx, cy, [], col, 0, 1, dot=(cx, cy - W * 0.115, W * 0.022, 1.0))
        img = base
    return finish(img, w, h)


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
    rr = S * 0.036
    px, py = cx + maxr * 0.16, cy - maxr * 0.46
    d.ellipse([px - rr, py - rr, px + rr, py + rr], fill=ORANGE + (255,))
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
