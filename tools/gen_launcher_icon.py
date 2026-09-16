"""生成 NikonSync / 尼康速传 的启动图标（定稿：V5 同心圆 + 同步箭头 + 对焦点）。

设计说明（原创标记，不含任何相机厂商的商标图形）：
    外圈是一对**带箭头的同步弧**（无线传输），内圈是**镜头筒**，中心的实心点
    **对焦点**——三者分别对应 App 的三件事：无线传照片、相机、点画面指定对焦。
    形状本身在 48dp 下仍然清楚（见 docs/icon/preview.png）。

为什么要用几何绘制而不是 AI 生成：启动图标最怕小尺寸糊成一团，几何形状 + 4x 超采样
再 LANCZOS 缩小，边缘干净可控；AI 生成的位图在 48dp 上往往细节粘连。

产物：
    mipmap-*/ic_launcher.png              传统图标（圆角方块 + 深色渐变 + 标记）
    mipmap-*/ic_launcher_foreground.png   自适应图标前景（108dp 画布、透明底）
    mipmap-anydpi-v26/ic_launcher.xml     自适应图标声明
    drawable/ic_launcher_background.xml   自适应图标背景（竖向渐变）
"""
import math
import os

from PIL import Image, ImageDraw

ACCENT = (255, 225, 0)      # 与 App 里的 kAccent 一致
BG_TOP = (38, 42, 51)
BG_BOTTOM = (16, 18, 22)

CANVAS = 108.0              # 自适应图标画布（安全区约中心 66~72dp）
CENTER = 54.0
RING_R = 24.0               # 同步环半径
RING_W = 6.4
GAP = 26.0                  # 左右缺口角度
INNER_R = 10.4              # 镜头筒半径
INNER_W = 3.6
DOT_R = 3.5                 # 对焦点

SS = 4                      # 超采样


def _arrowhead(d, cx, cy, r, theta_deg, width, color):
    """在弧线端点画一个沿顺时针切向的箭头（PIL 角度系：0=3点，顺时针对应角度增大）。"""
    th = math.radians(theta_deg)
    px, py = cx + r * math.cos(th), cy + r * math.sin(th)
    tx, ty = -math.sin(th), math.cos(th)      # 前进方向
    nx, ny = math.cos(th), math.sin(th)       # 径向
    tip = (px + tx * width * 1.10, py + ty * width * 1.10)
    base = (px - tx * width * 0.28, py - ty * width * 0.28)
    hw = width * 0.92
    d.polygon([tip,
               (base[0] + nx * hw, base[1] + ny * hw),
               (base[0] - nx * hw, base[1] - ny * hw)], fill=color)


def render_mark(px, scale=SS):
    """渲染标记（透明底、超采样原图；调用方负责缩放）。px = 最终像素边长。"""
    s = px * scale
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = s / CANVAS
    cx = cy = CENTER * k

    # 外圈：两段同步弧（缺口落在左、右，顺时针）
    r = RING_R * k
    w = RING_W * k
    box = [cx - r, cy - r, cx + r, cy + r]
    top_a, top_b = 180.0 + GAP / 2 + 8.0, 360.0 - GAP / 2 - 8.0
    bot_a, bot_b = GAP / 2 + 8.0, 180.0 - GAP / 2 - 8.0
    d.arc(box, top_a, top_b, fill=ACCENT, width=int(round(w)))
    d.arc(box, bot_a, bot_b, fill=ACCENT, width=int(round(w)))
    _arrowhead(d, cx, cy, r, top_b, w, ACCENT)
    _arrowhead(d, cx, cy, r, bot_b, w, ACCENT)

    # 内圈：镜头筒
    ri = INNER_R * k
    wi = max(2, int(round(INNER_W * k)))
    d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], outline=ACCENT, width=wi)

    # 中心：对焦点
    rd = DOT_R * k
    d.ellipse([cx - rd, cy - rd, cx + rd, cy + rd], fill=ACCENT)
    return img


def legacy_icon(px):
    """传统图标：深色圆角方块（带竖向渐变）+ 标记。"""
    s = px * SS
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    grad = Image.new('RGB', (1, s))
    for y in range(s):
        t = y / max(1, s - 1)
        grad.putpixel((0, y), tuple(
            int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)))
    grad = grad.resize((s, s))
    mask = Image.new('L', (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, s - 1, s - 1], radius=int(s * 0.225), fill=255)
    img.paste(grad, (0, 0), mask)
    img.alpha_composite(render_mark(px, scale=SS))
    return img.resize((px, px), Image.LANCZOS)


ADAPTIVE_XML = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
'''

BG_XML = '''<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标背景：与 App 的深色主题一致（上浅下深） -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:angle="270"
        android:startColor="#262A33"
        android:endColor="#101216"
        android:type="linear" />
</shape>
'''


def main():
    root = os.path.join('android', 'app', 'src', 'main', 'res')
    legacy = {'mipmap-mdpi': 48, 'mipmap-hdpi': 72, 'mipmap-xhdpi': 96,
              'mipmap-xxhdpi': 144, 'mipmap-xxxhdpi': 192}
    fg = {'mipmap-mdpi': 108, 'mipmap-hdpi': 162, 'mipmap-xhdpi': 216,
          'mipmap-xxhdpi': 324, 'mipmap-xxxhdpi': 432}

    for d, px in legacy.items():
        out = os.path.join(root, d)
        os.makedirs(out, exist_ok=True)
        legacy_icon(px).save(os.path.join(out, 'ic_launcher.png'))
    for d, px in fg.items():
        out = os.path.join(root, d)
        os.makedirs(out, exist_ok=True)
        render_mark(px, scale=SS).resize((px, px), Image.LANCZOS).save(
            os.path.join(out, 'ic_launcher_foreground.png'))

    anydpi = os.path.join(root, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, 'ic_launcher.xml'), 'w', encoding='utf-8') as f:
        f.write(ADAPTIVE_XML)
    drawable = os.path.join(root, 'drawable')
    os.makedirs(drawable, exist_ok=True)
    with open(os.path.join(drawable, 'ic_launcher_background.xml'), 'w', encoding='utf-8') as f:
        f.write(BG_XML)

    # 给人看的预览：从 192 到 48，外加自适应前景在圆形/方形遮罩下的样子
    os.makedirs('docs/icon', exist_ok=True)
    sheet = Image.new('RGB', (1020, 460), (245, 246, 248))
    x = 40
    for px in (192, 144, 96, 72, 48):
        ic = legacy_icon(px)
        sheet.paste(ic, (x, 60), ic)
        x += px + 34
    # 自适应前景：套圆形与方形遮罩（模拟不同启动器）
    fgimg = render_mark(432, scale=SS).resize((432, 432), Image.LANCZOS)
    fgsheet = Image.new('RGB', (432, 432), (16, 18, 22))
    fgsheet.paste(fgimg, (0, 0), fgimg)
    circle = Image.new('L', (432, 432), 0)
    ImageDraw.Draw(circle).ellipse([0, 0, 431, 431], fill=255)
    roundmasked = Image.new('RGB', (432, 432), (245, 246, 248))
    roundmasked.paste(fgsheet, (0, 0), circle)
    sheet.paste(roundmasked.resize((180, 180), Image.LANCZOS), (40, 220))
    d = ImageDraw.Draw(sheet)
    d.text((40, 30), 'legacy ic_launcher (192/144/96/72/48)', fill=(20, 20, 20))
    d.text((250, 300), 'adaptive foreground + circle mask', fill=(20, 20, 20))
    sheet.save('docs/icon/preview.png')
    print('icons written; preview at docs/icon/preview.png')


if __name__ == '__main__':
    main()
