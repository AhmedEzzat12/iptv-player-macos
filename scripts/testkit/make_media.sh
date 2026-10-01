#!/usr/bin/env bash
# Generates the Tuner test-kit media into TestMedia/ (repo root): four "channel" clips (MPEG-TS) with
# big burned-in names + a running timecode, their HLS renditions, seven movies (MP4/MKV, one with two
# audio and two subtitle tracks), two series (2 seasons x 3 episodes) and posters/backdrops/logos.
#
# Usage: scripts/testkit/make_media.sh            (idempotent: existing files are skipped)
#        FFMPEG=/path/to/ffmpeg TESTKIT_MEDIA=/elsewhere scripts/testkit/make_media.sh
#
# This ffmpeg build may lack libfreetype (no drawtext), so all text is rendered to PNG by a tiny
# bitmap-font renderer below (Python stdlib only) and composited with ffmpeg's overlay filter.
# Titles come from the catalog in server.py, so what you see on screen matches the API/playlist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export TESTKIT_MEDIA="${TESTKIT_MEDIA:-$ROOT/TestMedia}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"

if [[ ! -x "$FFMPEG" ]]; then
  echo "error: ffmpeg not found at $FFMPEG (brew install ffmpeg, or set FFMPEG=...)" >&2
  exit 1
fi
if ! "$FFMPEG" -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  echo "error: $FFMPEG has no libx264 encoder" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 1; }

mkdir -p "$TESTKIT_MEDIA"
echo "Generating test media into $TESTKIT_MEDIA"

python3 - "$SCRIPT_DIR" "$FFMPEG" <<'PY'
import concurrent.futures as cf
import os
import shutil
import struct
import subprocess
import sys
import time
import unicodedata
import zlib
from pathlib import Path

SCRIPT_DIR, FFMPEG = sys.argv[1], sys.argv[2]
sys.path.insert(0, SCRIPT_DIR)
import server as kit  # noqa: E402  (catalog: FEEDS, MOVIES, SERIES, paths)

OUT = kit.MEDIA
WORK = OUT / "_work"
W, H, FPS = 1280, 720, 25
made, skipped = [], []

# ------------------------------------------------------------------------------------------------
# 5x7 bitmap font + RGBA canvas + PNG writer
# ------------------------------------------------------------------------------------------------
FONT = {
    "A": ".###. #...# #...# ##### #...# #...# #...#", "B": "####. #...# #...# ####. #...# #...# ####.",
    "C": ".###. #...# #.... #.... #.... #...# .###.", "D": "####. #...# #...# #...# #...# #...# ####.",
    "E": "##### #.... #.... ####. #.... #.... #####", "F": "##### #.... #.... ####. #.... #.... #....",
    "G": ".###. #...# #.... #.### #...# #...# .####", "H": "#...# #...# #...# ##### #...# #...# #...#",
    "I": ".###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.", "J": "..### ...#. ...#. ...#. ...#. #..#. .##..",
    "K": "#...# #..#. #.#.. ##... #.#.. #..#. #...#", "L": "#.... #.... #.... #.... #.... #.... #####",
    "M": "#...# ##.## #.#.# #.#.# #...# #...# #...#", "N": "#...# #...# ##..# #.#.# #..## #...# #...#",
    "O": ".###. #...# #...# #...# #...# #...# .###.", "P": "####. #...# #...# ####. #.... #.... #....",
    "Q": ".###. #...# #...# #...# #.#.# #..#. .##.#", "R": "####. #...# #...# ####. #.#.. #..#. #...#",
    "S": ".#### #.... #.... .###. ....# ....# ####.", "T": "##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..",
    "U": "#...# #...# #...# #...# #...# #...# .###.", "V": "#...# #...# #...# #...# #...# .#.#. ..#..",
    "W": "#...# #...# #...# #.#.# #.#.# #.#.# .#.#.", "X": "#...# #...# .#.#. ..#.. .#.#. #...# #...#",
    "Y": "#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..", "Z": "##### ....# ...#. ..#.. .#... #.... #####",
    "0": ".###. #...# #..## #.#.# ##..# #...# .###.", "1": "..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.",
    "2": ".###. #...# ....# ...#. ..#.. .#... #####", "3": "##### ...#. ..#.. ...#. ....# #...# .###.",
    "4": "...#. ..##. .#.#. #..#. ##### ...#. ...#.", "5": "##### #.... ####. ....# ....# #...# .###.",
    "6": "..##. .#... #.... ####. #...# #...# .###.", "7": "##### ....# ...#. ..#.. .#... .#... .#...",
    "8": ".###. #...# #...# .###. #...# #...# .###.", "9": ".###. #...# #...# .#### ....# ...#. .##..",
    " ": "..... ..... ..... ..... ..... ..... .....", ":": "..... ..#.. ..#.. ..... ..#.. ..#.. .....",
    ".": "..... ..... ..... ..... ..... .##.. .##..", ",": "..... ..... ..... ..... .##.. ..#.. .#...",
    "-": "..... ..... ..... ##### ..... ..... .....", "(": "...#. ..#.. .#... .#... .#... ..#.. ...#.",
    ")": ".#... ..#.. ...#. ...#. ...#. ..#.. .#...", "&": ".##.. #..#. #.#.. .#... #.#.# #..#. .##.#",
    "/": "..... ....# ...#. ..#.. .#... #.... .....", "'": "..#.. ..#.. .#... ..... ..... ..... .....",
    "!": "..#.. ..#.. ..#.. ..#.. ..#.. ..... ..#..", "?": ".###. #...# ....# ...#. ..#.. ..... ..#..",
    "#": ".#.#. .#.#. ##### .#.#. ##### .#.#. .#.#.", "+": "..... ..#.. ..#.. ##### ..#.. ..#.. .....",
    "=": "..... ..... ##### ..... ##### ..... .....", "%": "##... ##..# ...#. ..#.. .#... #..## ...##",
    '"': ".#.#. .#.#. .#.#. ..... ..... ..... .....", "_": "..... ..... ..... ..... ..... ..... #####",
    "<": "...#. ..#.. .#... #.... .#... ..#.. ...#.", ">": ".#... ..#.. ...#. ....# ...#. ..#.. .#...",
    "|": "..#.. ..#.. ..#.. ..#.. ..#.. ..#.. ..#..", "@": ".###. #...# #.### #.#.# #.##. #.... .####",
    "*": "..... #.#.# .###. ##### .###. #.#.# .....",
}
GLYPHS = {ch: spec.split() for ch, spec in FONT.items()}


def norm(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c)).replace("—", "-").replace("–", "-")
    return "".join(c if c in GLYPHS else (c.upper() if c.upper() in GLYPHS else "?") for c in text)


def text_w(text: str, scale: int) -> int:
    return max(0, len(norm(text)) * 6 * scale - scale)


def wrap(text: str, max_chars: int) -> list[str]:
    lines, cur = [], ""
    for word in text.split():
        if cur and len(cur) + 1 + len(word) > max_chars:
            lines.append(cur)
            cur = word
        else:
            cur = f"{cur} {word}".strip()
    return lines + ([cur] if cur else [])


def fit(text: str, max_w: int, hi: int, lo: int = 1) -> int:
    for s in range(hi, lo - 1, -1):
        if text_w(text, s) <= max_w:
            return s
    return lo


class Canvas:
    def __init__(self, w, h, rgba=(0, 0, 0, 0)):
        self.w, self.h = w, h
        self.buf = bytearray(bytes(rgba) * (w * h))

    def rect(self, x, y, w, h, rgba):
        x0, y0 = max(0, int(x)), max(0, int(y))
        x1, y1 = min(self.w, int(x + w)), min(self.h, int(y + h))
        if x1 <= x0 or y1 <= y0:
            return
        row = bytes(rgba) * (x1 - x0)
        for yy in range(y0, y1):
            o = (yy * self.w + x0) * 4
            self.buf[o:o + len(row)] = row

    def vgradient(self, top, bottom, x=0, y=0, w=None, h=None):
        w, h = w or self.w, h or self.h
        for i in range(h):
            t = i / max(1, h - 1)
            self.rect(x, y + i, w, 1, tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))

    def circle(self, cx, cy, r, rgba):
        for yy in range(int(cy - r), int(cy + r) + 1):
            dy = yy + 0.5 - cy
            if abs(dy) <= r:
                half = (r * r - dy * dy) ** 0.5
                self.rect(cx - half, yy, 2 * half, 1, rgba)

    def text(self, x, y, text, scale, rgba, shadow=None):
        if shadow:
            off = max(1, scale // 2)
            self.text(x + off, y + off, text, scale, shadow)
        cx = x
        for ch in norm(text):
            for r, row in enumerate(GLYPHS[ch]):
                c = 0
                while c < 5:
                    if row[c] == "#":
                        c0 = c
                        while c < 5 and row[c] == "#":
                            c += 1
                        self.rect(cx + c0 * scale, y + r * scale, (c - c0) * scale, scale, rgba)
                    else:
                        c += 1
            cx += 6 * scale

    def ctext(self, y, text, scale, rgba, shadow=None, x0=0, w=None):
        w = self.w if w is None else w
        self.text(x0 + (w - text_w(text, scale)) // 2, y, text, scale, rgba, shadow)

    def save(self, path: Path):
        stride = self.w * 4
        raw = bytearray()
        for y in range(self.h):
            raw.append(0)
            raw += self.buf[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_bytes(png)
        os.replace(tmp, path)


def rgba(c, a=255):
    return (c[0], c[1], c[2], a)


def shade(c, f):
    return tuple(max(0, min(255, int(v * f))) for v in c)


def mix(c, d, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c, d))


WHITE, BLACK = (255, 255, 255, 255), (0, 0, 0, 255)
YELLOW = (255, 214, 64, 255)


def make_image(path: Path, draw):
    if path.exists() and path.stat().st_size > 0:
        skipped.append(path)
        return
    draw().save(path)
    made.append(path)


# ------------------------------------------------------------------------------------------------
# Artwork: logos, posters, backdrops, episode stills
# ------------------------------------------------------------------------------------------------

def poster(title, year, genre, color, kind):
    def draw():
        c = Canvas(400, 600, BLACK)
        c.vgradient(rgba(shade(color, 1.15)), rgba(shade(color, 0.18)))
        for i in range(4):
            c.rect(0, 64 + i * 30, 400, 10, rgba(mix(shade(color, 1.3), (255, 255, 255), 0.15)))
        c.rect(0, 0, 400, 40, (0, 0, 0, 255))
        c.ctext(13, f"TUNER TEST KIT  {kind}", 2, (200, 200, 200, 255))
        lines = wrap(title, 11)
        scale = min(fit(l, 360, 7) for l in lines)
        y = 330 - (len(lines) * 9 * scale) // 2
        for line in lines:
            c.ctext(y, line, scale, WHITE, shadow=BLACK)
            y += 9 * scale
        c.ctext(500, str(year), 5, YELLOW, shadow=BLACK)
        c.ctext(552, genre, fit(genre, 370, 3), (230, 230, 230, 255))
        return c
    return draw


def backdrop(title, subtitle, color):
    def draw():
        c = Canvas(W, H, BLACK)
        c.vgradient(rgba(shade(color, 0.9)), rgba(shade(color, 0.12)))
        for i, r in enumerate((320, 230, 150)):
            c.circle(980, 260, r, rgba(mix(shade(color, 0.9), (255, 255, 255), 0.12 + i * 0.1)))
        c.text(70, 470, title, fit(title, 1140, 10), WHITE, shadow=BLACK)
        c.text(74, 580, subtitle, 4, (235, 235, 235, 255), shadow=BLACK)
        return c
    return draw


def logo(feed):
    slug, color = feed["slug"], feed["color"]
    solid = feed["slug"] in ("news", "movies")   # two solid, two with transparency

    def draw():
        c = Canvas(400, 400, rgba(color) if solid else (0, 0, 0, 0))
        if not solid:
            c.circle(200, 200, 196, rgba(color))
            c.circle(200, 200, 176, rgba(shade(color, 0.75)))
        word = slug.upper()
        s = fit(word, 300 if not solid else 360, 14)
        c.ctext(200 - (7 * s) // 2 + 20, word, s, WHITE, shadow=(0, 0, 0, 255))
        c.ctext(200 - (7 * s) // 2 - 40, "TUNER", 6, (255, 255, 255, 230))
        return c
    return draw


def episode_still(series, ep):
    def draw():
        c = Canvas(640, 360, BLACK)
        c.vgradient(rgba(shade(series["color"], 1.1)), rgba(shade(series["color"], 0.2)))
        c.ctext(24, series["title"], fit(series["title"], 600, 4), (240, 240, 240, 255), shadow=BLACK)
        code = f"S{ep['season']:02d}E{ep['episode']:02d}"
        c.ctext(120, code, 12, WHITE, shadow=BLACK)
        c.ctext(250, ep["title"], fit(ep["title"], 600, 5), YELLOW, shadow=BLACK)
        return c
    return draw


# ------------------------------------------------------------------------------------------------
# Video overlays (transparent 1280x720) + timecode digits
# ------------------------------------------------------------------------------------------------
TC_SCALE, TC_PAD = 7, 16
TC_H = 7 * TC_SCALE + 2 * TC_PAD
TC_SEC_W = TC_PAD + text_w("00:00:00", TC_SCALE)
TC_FF_W = TC_SCALE + text_w(":00", TC_SCALE) + TC_PAD
TC_X = (W - TC_SEC_W - TC_FF_W) // 2
TC_Y = H - 48 - TC_H
TC_SECONDS = 120


def timecode_images():
    def sec(n):
        def draw():
            c = Canvas(TC_SEC_W, TC_H, (0, 0, 0, 200))
            c.text(TC_PAD, TC_PAD, f"00:{n // 60:02d}:{n % 60:02d}", TC_SCALE, WHITE)
            return c
        return draw

    def ff(n):
        def draw():
            c = Canvas(TC_FF_W, TC_H, (0, 0, 0, 200))
            c.text(TC_SCALE, TC_PAD, f":{n:02d}", TC_SCALE, YELLOW)
            return c
        return draw

    for n in range(TC_SECONDS):
        make_image(WORK / "tc" / f"sec_{n:04d}.png", sec(n))
    for n in range(FPS):
        make_image(WORK / "tc" / f"ff_{n:02d}.png", ff(n))


def band(c, color, y=36, h=200):
    c.rect(0, y, W, h, (0, 0, 0, 165))
    c.rect(0, y, 22, h, rgba(color))
    c.rect(W - 22, y, 22, h, rgba(color))


def feed_overlay(n, feed):
    def draw():
        c = Canvas(W, H)
        band(c, feed["color"])
        name = feed["name"].upper()
        c.ctext(58, name, fit(name, 1160, 14), WHITE, shadow=rgba(shade(feed["color"], 0.6)))
        sub = f"FEED {n} - {feed['tagline']} - {feed['tone']} HZ BEEP"
        c.ctext(58 + 7 * 14 + 30, sub, fit(sub, 1160, 5), YELLOW)
        label = f"CLIP TIME (LOOPS EVERY {kit.FEED_SECONDS} S)"
        c.rect((W - text_w(label, 3)) // 2 - 10, TC_Y - 42, text_w(label, 3) + 20, 37, (0, 0, 0, 200))
        c.ctext(TC_Y - 34, label, 3, (230, 230, 230, 255))
        return c
    return draw


def movie_overlay(m):
    def draw():
        c = Canvas(W, H)
        band(c, m["color"], h=210)
        lines = wrap(m["title"].upper(), 18)
        scale = min(fit(l, 1160, 11 if len(lines) == 1 else 8) for l in lines)
        y = 52 if len(lines) > 1 else 64
        for line in lines:
            c.ctext(y, line, scale, WHITE, shadow=BLACK)
            y += 9 * scale
        meta = f"MOVIE {m['id']} - {m['year']} - .{m['ext'].upper()}"
        c.ctext(36 + 210 - 46, meta, 5, YELLOW)
        if len(m["audio"]) > 1 or m["subtitles"]:
            info = [f"AUDIO {i + 1}: {lang.upper()} - {'HIGH DOUBLE' if beeps == 2 else 'LOW SINGLE'} BEEP ({hz} HZ)"
                    for i, (lang, _title, hz, beeps) in enumerate(m["audio"])]
            if m["subtitles"]:
                info.append("SUBTITLES: " + " + ".join(lang.upper() for lang, *_ in m["audio"]))
            y0 = 300
            c.rect(140, y0 - 16, W - 280, len(info) * 44 + 24, (0, 0, 0, 165))
            for i, line in enumerate(info):
                c.ctext(y0 + i * 44, line, 4, WHITE)
        return c
    return draw


def episode_overlay(s, ep):
    def draw():
        c = Canvas(W, H)
        band(c, s["color"], h=230)
        c.ctext(52, s["title"].upper(), fit(s["title"].upper(), 1160, 6), (235, 235, 235, 255), shadow=BLACK)
        c.ctext(52 + 7 * 6 + 22, f"S{ep['season']:02d} E{ep['episode']:02d}", 13, WHITE, shadow=BLACK)
        t = ep["title"].upper()
        c.ctext(52 + 7 * 6 + 22 + 7 * 13 + 22, t, fit(t, 1160, 5), YELLOW, shadow=BLACK)
        return c
    return draw


# ------------------------------------------------------------------------------------------------
# ffmpeg
# ------------------------------------------------------------------------------------------------

def hexc(c):
    return "0x%02x%02x%02x" % tuple(c)


def beep(hz, beeps=1, level=0.25, loop_seconds=None):
    gate = r"lt(mod(t\,1)\,0.15)" if beeps == 1 else r"(lt(mod(t\,1)\,0.1)+between(mod(t\,1)\,0.2\,0.3))"
    spec = f"aevalsrc=exprs={level}*sin(2*PI*{hz}*t)*{gate}:s=48000:c=stereo:n=1024"
    if loop_seconds:
        # Looping clips: the AAC encoder prepends one 1024-sample priming frame, so generate exactly one
        # frame less than the clip length; priming + audio then spans exactly loop_seconds and the
        # server can splice loops back-to-back without overlapping audio timestamps.
        frames = loop_seconds * 48000 // 1024 - 1
        spec += f":d={(frames * 1024 - 0.5) / 48000:.8f}"
    return spec


FEED_BG = {
    "news": "gradients=s=1280x720:r=25:c0=0x081a4a:c1=0x2060dc:c2=0x0f3b91:n=3:speed=0.02:type=1:seed=7",
    "sports": "testsrc2=s=1280x720:r=25",
    "movies": "smptehdbars=s=1280x720:r=25",
    "kids": "cellauto=s=320x180:r=25:rule=110:seed=3,scale=1280:720:flags=neighbor,format=rgb24,"
            "lutrgb=r=60+val*0.75:g=25+val*0.45:b=10",
}
MOVIE_BG = {
    1001: "testsrc=s=1280x720:r=25",
    1002: "colorspectrum=s=1280x720:r=25:type=all",
    1003: "mandelbrot=s=640x360:r=25,scale=1280:720",
    1004: "life=s=320x180:r=25:mold=10:ratio=0.5:seed=4,scale=1280:720:flags=neighbor,format=rgb24",
    1005: "gradients=s=1280x720:r=25:c0=0x5a1408:c1=0xd2783c:n=2:speed=0.03:seed=5",
    1006: "testsrc2=s=1280x720:r=25,hue=s=0.3",
    1007: "mandelbrot=s=640x360:r=25:start_scale=1.5,scale=1280:720",
}
X264 = ["-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level:v", "4.0", "-pix_fmt", "yuv420p",
        "-r", str(FPS), "-g", str(2 * FPS), "-keyint_min", str(2 * FPS), "-sc_threshold", "0"]


def compose(bg, seconds, overlay_png, bar_color, audio_specs, extra_inputs=()):
    """Inputs + filtergraph: background, motion bar, static overlay, HH:MM:SS + :FF timecode."""
    args = ["-f", "lavfi", "-t", str(seconds), "-i", bg]
    for spec in audio_specs:
        args += ["-f", "lavfi", "-t", str(seconds), "-i", spec]
    k = 1 + len(audio_specs)
    args += ["-loop", "1", "-framerate", str(FPS), "-t", str(seconds), "-i", str(overlay_png),
             "-framerate", "1", "-start_number", "0", "-i", str(WORK / "tc" / "sec_%04d.png"),
             "-framerate", str(FPS), "-start_number", "0", "-i", str(WORK / "tc" / "ff_%02d.png"),
             "-f", "lavfi", "-t", str(seconds), "-i", f"color=c={hexc(bar_color)}:s=180x14:r={FPS}"]
    for extra in extra_inputs:
        args += ["-i", str(extra)]
    ov, sec, ff, bar = k, k + 1, k + 2, k + 3
    graph = (f"[0:v]scale={W}:{H},setsar=1,format=yuv420p[bg];"
             f"[bg][{bar}:v]overlay=x='(W-w)*(0.5+0.5*sin(2*PI*t/4))':y={TC_Y - 70}[m];"
             f"[m][{ov}:v]overlay=0:0[a];"
             f"[a][{sec}:v]overlay={TC_X}:{TC_Y}:eof_action=repeat[b];"
             f"[{ff}:v]loop=loop=-1:size={FPS}:start=0,setpts=N/{FPS}/TB[ff];"
             f"[b][ff]overlay={TC_X + TC_SEC_W}:{TC_Y}:shortest=1,format=yuv420p[v]")
    return args, graph, k + 4


def run_ffmpeg(args, out: Path):
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.stem + ".tmp" + out.suffix)
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *args, str(tmp)]
    t0 = time.time()
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg failed for {out.name}:\n{res.stderr}\ncmd: {' '.join(cmd)}")
    os.replace(tmp, out)
    made.append(out)
    print(f"  made {out.relative_to(OUT)}  ({out.stat().st_size / 1_048_576:.1f} MB, {time.time() - t0:.0f}s)", flush=True)


def need(out: Path) -> bool:
    if out.exists() and out.stat().st_size > 0:
        skipped.append(out)
        return False
    return True


def make_feed(n, feed):
    out = kit.feed_ts_path(n)
    if not need(out):
        return
    secs = kit.FEED_SECONDS
    args, graph, _ = compose(FEED_BG[feed["slug"]], secs, WORK / f"feed{n}.png", feed["color"],
                             [beep(feed["tone"], loop_seconds=secs)])
    args += ["-filter_complex", graph, "-map", "[v]", "-map", "1:a", "-t", str(secs), *X264,
             "-crf", "23", "-maxrate", "1500k", "-bufsize", "3000k",
             "-c:a", "aac", "-b:a", "96k", "-ar", "48000", "-ac", "2",
             "-metadata", f"service_name={feed['name']}", "-metadata", "service_provider=Tuner Test Kit",
             "-f", "mpegts"]
    run_ffmpeg(args, out)


def make_hls(n):
    folder = kit.feed_hls_dir(n)
    if (folder / "index.m3u8").exists():
        skipped.append(folder / "index.m3u8")
        return
    tmp = folder.with_name(folder.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", str(kit.feed_ts_path(n)),
           "-c", "copy", "-f", "hls", "-hls_time", "2", "-hls_list_size", "0", "-hls_playlist_type", "vod",
           "-hls_flags", "independent_segments", "-hls_segment_filename", str(tmp / "seg_%03d.ts"),
           str(tmp / "index.m3u8")]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        shutil.rmtree(tmp, ignore_errors=True)
        raise RuntimeError(f"HLS segmenting failed for feed {n}:\n{res.stderr}")
    shutil.rmtree(folder, ignore_errors=True)
    os.replace(tmp, folder)
    made.append(folder / "index.m3u8")
    print(f"  made {folder.relative_to(OUT)}/ ({len(list(folder.glob('*.ts')))} segments)", flush=True)


SUB_WORDS = {"eng": "Subtitle", "spa": "Subtítulo", "fre": "Sous-titre"}


def write_srt(path: Path, lang: str, seconds: int):
    def ts(s):
        return f"00:{s // 60:02d}:{s % 60:02d},000"
    cues = []
    for i, start in enumerate(range(1, seconds - 1, 4), start=1):
        cues.append(f"{i}\n{ts(start)} --> {ts(start + 3)}\n[{lang.upper()}] {SUB_WORDS.get(lang, 'Subtitle')} {i}"
                    f" @ {start // 60:02d}:{start % 60:02d}\n")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(cues), encoding="utf-8")


def make_movie(m):
    out = OUT / m["file"]
    if not need(out):
        return
    secs = m["seconds"]
    subs = []
    if m["subtitles"]:
        for lang, *_ in m["audio"]:
            p = WORK / "subs" / f"{m['id']}-{lang}.srt"
            write_srt(p, lang, secs)
            subs.append(p)
    audio = [beep(hz, beeps) for _lang, _t, hz, beeps in m["audio"]]
    args, graph, first_extra = compose(MOVIE_BG[m["id"]], secs, WORK / f"movie{m['id']}.png", m["color"], audio, subs)
    args += ["-filter_complex", graph, "-map", "[v]"]
    for i in range(len(audio)):
        args += ["-map", f"{1 + i}:a"]
    for i in range(len(subs)):
        args += ["-map", f"{first_extra + i}:s"]
    args += ["-t", str(secs), *X264, "-crf", "24", "-maxrate", "1200k", "-bufsize", "2400k",
             "-c:a", "aac", "-b:a", "96k", "-ar", "48000", "-ac", "2",
             "-metadata", f"title={m['title']}", "-metadata", f"date={m['year']}"]
    for i, (lang, title, _hz, _b) in enumerate(m["audio"]):
        args += [f"-metadata:s:a:{i}", f"language={lang}", f"-metadata:s:a:{i}", f"title={title}",
                 f"-disposition:a:{i}", "default" if i == 0 else "0"]
    if subs:
        args += ["-c:s", "mov_text" if m["ext"] == "mp4" else "srt"]
        for i, (lang, *_r) in enumerate(m["audio"]):
            args += [f"-metadata:s:s:{i}", f"language={lang}", f"-metadata:s:s:{i}", f"title={lang.upper()} subtitles",
                     f"-disposition:s:{i}", "0"]
    args += ["-movflags", "+faststart", "-f", "mp4"] if m["ext"] == "mp4" else ["-f", "matroska"]
    run_ffmpeg(args, out)


def make_episode(s, ep):
    out = OUT / ep["file"]
    if not need(out):
        return
    secs = kit.EPISODE_SECONDS
    c0, c1 = shade(s["color"], 0.35), shade(s["color"], 1.1)
    bg = (f"gradients=s=1280x720:r=25:c0={hexc(c0)}:c1={hexc(c1)}:c2={hexc(shade(s['color'], 0.7))}:n=3"
          f":speed=0.03:type={ep['episode'] % 4}:seed={ep['id']}")
    args, graph, _ = compose(bg, secs, WORK / f"ep{ep['id']}.png", shade(s["color"], 1.3),
                             [beep(300 + 60 * ep["episode"] + 200 * (ep["season"] - 1))])
    args += ["-filter_complex", graph, "-map", "[v]", "-map", "1:a", "-t", str(secs), *X264,
             "-crf", "25", "-maxrate", "900k", "-bufsize", "1800k",
             "-c:a", "aac", "-b:a", "96k", "-ar", "48000", "-ac", "2",
             "-metadata", f"title={s['title']} S{ep['season']:02d}E{ep['episode']:02d} {ep['title']}",
             "-movflags", "+faststart", "-f", "mp4"]
    run_ffmpeg(args, out)


# ------------------------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------------------------
t_start = time.time()
print("Rendering artwork and overlays...", flush=True)
IMG = OUT / "img"
timecode_images()
for n, feed in kit.FEEDS.items():
    make_image(IMG / kit.IMG["logo"](feed["slug"]), logo(feed))
    make_image(IMG / kit.IMG["feed_backdrop"](feed["slug"]),
               backdrop(feed["name"], f"FEED {n} - {feed['tagline']}", feed["color"]))
    make_image(WORK / f"feed{n}.png", feed_overlay(n, feed))
for m in kit.MOVIES:
    make_image(IMG / kit.IMG["movie_poster"](m["id"]), poster(m["title"], m["year"], m["genre"], m["color"], "MOVIE"))
    make_image(IMG / kit.IMG["movie_backdrop"](m["id"]), backdrop(m["title"], f"{m['year']} - {m['genre']}", m["color"]))
    make_image(WORK / f"movie{m['id']}.png", movie_overlay(m))
for s in kit.SERIES:
    make_image(IMG / kit.IMG["series_poster"](s["id"]), poster(s["title"], s["year"], s["genre"], s["color"], "SERIES"))
    make_image(IMG / kit.IMG["series_backdrop"](s["id"]), backdrop(s["title"], f"{s['year']} - {s['genre']}", s["color"]))
    for ep in kit.episodes(s):
        make_image(IMG / ep["image"], episode_still(s, ep))
        make_image(WORK / f"ep{ep['id']}.png", episode_overlay(s, ep))

print("Encoding video (skips files that already exist)...", flush=True)
jobs = [(make_feed, (n, f)) for n, f in kit.FEEDS.items()]
jobs += [(make_movie, (m,)) for m in kit.MOVIES]
jobs += [(make_episode, (s, ep)) for s in kit.SERIES for ep in kit.episodes(s)]
with cf.ThreadPoolExecutor(max_workers=3) as pool:
    for fut in [pool.submit(fn, *a) for fn, a in jobs]:
        fut.result()
for n in kit.FEEDS:
    make_hls(n)

media_files = [p for p in OUT.rglob("*") if p.is_file() and "_work" not in p.parts]
total = sum(p.stat().st_size for p in media_files)
print(f"\nDone in {time.time() - t_start:.0f}s: {len(made)} generated, {len(skipped)} already present.")
print(f"TestMedia size: {total / 1_048_576:.1f} MB ({len(media_files)} files, excluding _work/)")
PY

echo
echo "Next: python3 scripts/testkit/server.py   (then see docs/testing.md)"
