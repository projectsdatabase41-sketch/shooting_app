"""Собирает assets/video/splash_loop.mp4 — 1 с, N в круге с пульсацией и кольцами
(та же картинка, что рисует _NexusPulsePainter в lib/widgets/splash_gate.dart).
Нужно: pip install pillow imageio-ffmpeg. Запуск из корня: python tools/gen_splash_video.py"""
import math, subprocess
import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFont

W, H, FPS, SS = 720, 1280, 30, 2
BLUE = (159, 211, 255)


def frame(t):
    w, h = W * SS, H * SS
    img = Image.new('RGB', (w, h), (0, 0, 0))
    cx, cy, u = w / 2, h / 2, min(w, h)
    ph = t * 2 * math.pi
    lay = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for i in range(5):
        r = u * (0.30 + 0.07 * i) + u * 0.006 * math.sin(ph + i * 1.2)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=BLUE + (int(255 * (0.28 - 0.045 * i)),), width=max(2, int(u * 0.0022)))
    r0 = u * 0.17 * (1 + 0.06 * math.sin(ph))
    d.ellipse([cx - r0, cy - r0, cx + r0, cy + r0], outline=BLUE + (255,), width=max(3, int(u * 0.008)))
    f = ImageFont.truetype('C:/Windows/Fonts/seguisb.ttf', int(r0 * 1.15))
    bb = f.getbbox('N')  # центр по самому глифу, а не по строке
    d.text((cx - (bb[0] + bb[2]) / 2, cy - (bb[1] + bb[3]) / 2), 'N', font=f, fill=(255, 255, 255, 255))
    img = Image.alpha_composite(img.convert('RGBA'), lay).convert('RGB')
    return img.resize((W, H), Image.LANCZOS)


p = subprocess.Popen([imageio_ffmpeg.get_ffmpeg_exe(), '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-',
                      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '18', '-movflags', '+faststart', '-an', 'assets/video/splash_loop.mp4'],
                     stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
for i in range(FPS):
    p.stdin.write(frame(i / FPS).tobytes())
p.stdin.close(); p.wait()
