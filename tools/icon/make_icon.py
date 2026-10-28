# Z Computer app icon: dark blue gradient, a virtual-machine window frame, a bold Z, a cyan terminal cursor.
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096           # supersampled master
OUT = sys.argv[1]  # repo root

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient_bg():
    top, bottom = (10, 15, 44), (24, 48, 140)
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        c = lerp(top, bottom, y / (S - 1))
        for x in range(S): px[x, y] = c
    # soft radial glow, top-left
    glow = Image.new("L", (S, S), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-S*0.25, -S*0.35, S*0.85, S*0.65), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(S*0.16))
    blue = Image.new("RGB", (S, S), (59, 130, 246))
    img = Image.composite(blue, img, glow.point(lambda v: int(v * 0.42)))
    # faint grid (circuit / computer feel)
    g = ImageDraw.Draw(img, "RGBA")
    step = S // 16
    for i in range(1, 16):
        g.line((i*step, 0, i*step, S), fill=(255, 255, 255, 10), width=4)
        g.line((0, i*step, S, i*step), fill=(255, 255, 255, 10), width=4)
    return img

def draw_art(img):
    d = ImageDraw.Draw(img, "RGBA")
    # VM window frame
    m = S * 0.17
    r = S * 0.07
    d.rounded_rectangle((m, m, S - m, S - m), radius=r, outline=(255, 255, 255, 70), width=int(S*0.012))
    # title bar line + three dots
    ty = m + S * 0.085
    d.line((m, ty, S - m, ty), fill=(255, 255, 255, 55), width=int(S*0.008))
    for i, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = m + S * 0.055 + i * S * 0.05
        rr = S * 0.015
        d.ellipse((cx - rr, ty - S*0.0425 - rr, cx + rr, ty - S*0.0425 + rr), fill=col + (235,))
    # The Z (three strokes), white
    L, R = S * 0.30, S * 0.70
    T, B = S * 0.355, S * 0.775
    w = S * 0.075   # bar thickness
    dw = S * 0.112  # diagonal width (horizontal span)
    z = Image.new("L", (S, S), 0)
    zd = ImageDraw.Draw(z)
    zd.rectangle((L, T, R, T + w), fill=255)
    zd.rectangle((L, B - w, R - S*0.07, B), fill=255)  # bottom bar stops short for the cursor
    zd.polygon([(R - dw, T + w), (R, T + w), (L + dw, B - w), (L, B - w)], fill=255)
    zs = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    zs.paste((245, 248, 255, 255), mask=z)
    # drop shadow under the Z
    sh = z.filter(ImageFilter.GaussianBlur(S * 0.012))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0)); shadow.paste((5, 10, 40, 150), mask=sh)
    img.alpha_composite(shadow.transform(shadow.size, Image.AFFINE, (1, 0, -S*0.008, 0, 1, -S*0.012)))
    img.alpha_composite(zs)
    # cyan cursor block after the bottom bar, with glow
    cx0, cy0 = R - S*0.05, B - w
    cur = Image.new("RGBA", (S, S), (0, 0, 0, 0)); cd = ImageDraw.Draw(cur)
    cd.rounded_rectangle((cx0, cy0, cx0 + w*0.78, B), radius=S*0.008, fill=(34, 211, 238, 255))
    glow = cur.filter(ImageFilter.GaussianBlur(S*0.02))
    img.alpha_composite(glow); img.alpha_composite(glow); img.alpha_composite(cur)
    return img

def squircle_mask(size, radius_frac=0.2237):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * radius_frac), fill=255)
    return m

master = draw_art(gradient_bg().convert("RGBA"))

# iOS: full-bleed square (iOS applies its own mask)
ios = master.resize((1024, 1024), Image.LANCZOS).convert("RGB")
ios.save(os.path.join(OUT, "ZComputeriOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"), optimize=True)

# macOS: Apple's icon grid = rounded rect ~824 px on a 1024 canvas, with a soft shadow
def mac_icon(px):
    canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    inner = int(round(px * 824 / 1024))
    art = master.resize((inner, inner), Image.LANCZOS)
    mask = squircle_mask(inner)
    shaped = Image.new("RGBA", (inner, inner), (0, 0, 0, 0)); shaped.paste(art, mask=mask)
    off = (px - inner) // 2
    if px >= 64:
        sh = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        sm = Image.new("L", (px, px), 0); sm.paste(mask, (off, off + int(px*0.012)))
        sm = sm.filter(ImageFilter.GaussianBlur(px * 0.012))
        sh.paste((0, 0, 0, 110), mask=sm)
        canvas.alpha_composite(sh)
    canvas.alpha_composite(shaped, (off, off))
    return canvas

macdir = os.path.join(OUT, "ZComputer/Resources/Assets.xcassets/AppIcon.appiconset")
for name, px in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                 ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                 ("icon_512x512", 512), ("icon_512x512@2x", 1024)]:
    mac_icon(px).save(os.path.join(macdir, name + ".png"), optimize=True)

# previews
master.resize((512, 512), Image.LANCZOS).convert("RGB").save(os.path.join(os.path.dirname(sys.argv[0]), "preview-ios.png"))
mac_icon(512).save(os.path.join(os.path.dirname(sys.argv[0]), "preview-mac.png"))
print("done")
