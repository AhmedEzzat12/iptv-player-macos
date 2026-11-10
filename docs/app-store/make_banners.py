#!/usr/bin/env python3
"""Draws the App Store header (3840x1646) and search results (3840x2560) images from the test-kit screenshots in
docs/app-store/screenshots. Run from the repo root: python3 docs/app-store/make_banners.py"""
from PIL import Image, ImageCms, ImageDraw, ImageFilter, ImageFont

SHOTS = "docs/app-store/screenshots"
ICON = "iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
FONT = "/System/Library/Fonts/SFNS.ttf"
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()  # App Store wants opaque sRGB
CYAN, PURPLE = (64, 200, 255), (150, 95, 255)


def font(size, weight="Bold"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def background(w, h):
    """Near-black with a cyan glow top-left and a purple glow bottom-right."""
    img = Image.new("RGB", (w, h), (10, 11, 18))
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(glow)
    d.ellipse((-w * 0.25, -h * 0.6, w * 0.55, h * 0.9), fill=(18, 70, 105))
    d.ellipse((w * 0.45, h * 0.15, w * 1.3, h * 1.6), fill=(60, 30, 110))
    glow = glow.filter(ImageFilter.GaussianBlur(w // 9))
    return Image.blend(img, glow, 0.85)


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def paste_with_shadow(canvas, img, xy, radius, blur=60, offset=30, opacity=170):
    img = rounded(img, radius)
    shadow = Image.new("RGBA", (img.width + blur * 4, img.height + blur * 4), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (blur * 2, blur * 2, blur * 2 + img.width, blur * 2 + img.height), radius, fill=(0, 0, 0, opacity))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow, (xy[0] - blur * 2, xy[1] - blur * 2 + offset))
    canvas.alpha_composite(img, xy)


def phone(path, height):
    """An iPhone screenshot in a simple dark bezel."""
    shot = Image.open(path).convert("RGB")
    w = int(shot.width * height / shot.height)
    shot = shot.resize((w, height), Image.LANCZOS)
    pad = max(10, height // 60)
    frame = Image.new("RGB", (w + pad * 2, height + pad * 2), (28, 28, 32))
    frame.paste(rounded(shot, int(w * 0.13)), (pad, pad), rounded(shot, int(w * 0.13)))
    return frame, int((w + pad * 2) * 0.15)


def title_block(canvas, x, y, scale):
    d = ImageDraw.Draw(canvas)
    icon = Image.open(ICON).convert("RGBA").resize((int(300 * scale),) * 2, Image.LANCZOS)
    paste_with_shadow(canvas, icon.convert("RGB"), (x, y), int(66 * scale), blur=30, offset=14, opacity=140)
    tx = x + icon.width + int(70 * scale)
    d.text((tx, y + int(10 * scale)), "Antenna", font=font(int(210 * scale)), fill=(255, 255, 255))
    d.text((tx + int(6 * scale), y + int(235 * scale)), "IPTV PLAYER", font=font(int(62 * scale), "Semibold"),
           fill=CYAN)
    return icon.height


def header():
    W, H = 3840, 1646
    c = background(W, H).convert("RGBA")
    x0, y0 = 260, 330
    title_block(c, x0, y0, 1.0)
    d = ImageDraw.Draw(c)
    d.text((x0, y0 + 430), "Your IPTV, beautifully organised.", font=font(96, "Semibold"), fill=(235, 235, 245))
    d.text((x0, y0 + 570), "Live TV  ·  Guide  ·  Movies  ·  Shows  ·  Downloads", font=font(62, "Regular"),
           fill=(170, 175, 195))
    d.text((x0, y0 + 700), "iPhone  ·  iPad  ·  Mac", font=font(62, "Medium"), fill=PURPLE)
    mac = Image.open(f"{SHOTS}/mac-1-home.png").convert("RGB").resize((1920, 1200), Image.LANCZOS)
    paste_with_shadow(c, mac, (1700, 230), 36)
    ph, r = phone(f"{SHOTS}/iphone-3-livetv.png", 1240)
    paste_with_shadow(c, ph, (3200, 330), r)
    c.convert("RGB").save(f"{SHOTS}/header-3840x1646.png", dpi=(72, 72), icc_profile=SRGB)


def search_results():
    W, H = 3840, 2560
    c = background(W, H).convert("RGBA")
    d = ImageDraw.Draw(c)
    title_block(c, 300, 220, 1.0)
    d.text((300, 640), "Your IPTV, beautifully organised.", font=font(120, "Semibold"), fill=(235, 235, 245))
    mac = Image.open(f"{SHOTS}/mac-2-show.png").convert("RGB").resize((2560, 1600), Image.LANCZOS)
    paste_with_shadow(c, mac, (300, 900), 44)
    ph, r = phone(f"{SHOTS}/iphone-1-home.png", 1900)
    paste_with_shadow(c, ph, (2950, 560), r)
    c.convert("RGB").save(f"{SHOTS}/search-results-3840x2560.png", dpi=(72, 72), icc_profile=SRGB)


if __name__ == "__main__":
    header()
    search_results()
    print("ok")
