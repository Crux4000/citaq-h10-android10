#!/usr/bin/env python3
"""Build ESC/POS print jobs for the Citaq H10-3 kiosk printer.

Runs inside the Home Assistant container (called by shell_command).
Writes the raw printer bytes to /config/kiosk/job.bin; HA then uploads that
file to the terminal over ADB and cats it into /dev/ttyS1.

Usage:
  kiosk_print.py text  <base64 text>  [--size normal|tall|wide|big] [--align left|centre|right] [--bold on|off] [--cut on|off]
  kiosk_print.py image <base64 source> [--align ...] [--cut on|off]
        source = http(s) URL, absolute path, or a file name in /media/kiosk
  kiosk_print.py qr    <base64 text>  [--qrsize 1-16] [--align ...] [--cut on|off]
  kiosk_print.py list                  (prints JSON list of images in /media/kiosk)

--beeper off (the default) keeps the printer's alarm buzzer (no paper / lid open) silent.

--flip on (the default) prints upside down, so the receipt reads the right way up from the
front of the Citaq H10-3 (paper comes out towards you, top edge first). Text uses the printer's
upside-down mode (ESC { 1) with the lines sent in reverse order; images are rotated 180 degrees;
QR codes scan at any angle, so they are left alone. For a receipt built from several jobs, send
the jobs bottom part first (e.g. QR, then body, then title) - see docs/HOME-ASSISTANT.md.
Use --flip off for printers that face the other way.
"""
import argparse
import base64
import io
import json
import os
import sys
import textwrap
import urllib.request

OUT = "/config/kiosk/job.bin"
IMAGE_DIR = "/media/kiosk"
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp")
MAX_WIDTH = 552          # printable dots on this 80 mm head (from the stock POSFactory test app)
MAX_HEIGHT = 2400        # safety cap (~30 cm of paper)
BAND = 128               # image rows per GS v 0 block (keeps printer buffer happy)

ESC, GS = b"\x1b", b"\x1d"
INIT = ESC + b"@"
ALIGN = {"left": 0, "centre": 1, "center": 1, "right": 2}
SIZE = {"normal": 0x00, "tall": 0x01, "wide": 0x10, "big": 0x11}
FEED_AND_CUT = ESC + b"d\x04" + GS + b"VB\x00"
# Citaq printer command: alarm buzzer off. Every job starts with INIT (ESC @), and that reset turns
# the buzzer back on, so with --beeper off it is re-sent right after INIT in every job.
BUZZER_OFF = b"\x1f\x1b\x1f\x50\x42"


def b64(s):
    return base64.b64decode(s.encode()).decode("utf-8", "replace")


def align_cmd(a):
    return ESC + b"a" + bytes([ALIGN.get(a, 0)])


def build_text(text, size, align, bold, flip=False):
    out = INIT + align_cmd(align)
    out += ESC + b"E" + (b"\x01" if bold == "on" else b"\x00")
    out += GS + b"!" + bytes([SIZE.get(size, 0)])
    # dashboard text boxes are single-line, so allow a typed "\n" for new lines
    text = text.replace("\r\n", "\n").replace("\\n", "\n")
    # word-wrap so the printer doesn't split words (48 cols normal, 24 when double-wide)
    width = 24 if size in ("wide", "big") else 48
    lines = []
    for line in text.split("\n"):
        lines.extend(textwrap.wrap(line, width) or [""])
    if flip:
        lines.reverse()                  # last line first: it ends up at the bottom when read
        out += ESC + b"{\x01"           # upside-down mode: each line rotated 180 degrees
    body = "\n".join(lines).encode("cp437", "replace")
    out += body + b"\n"
    out += GS + b"!\x00" + ESC + b"E\x00" + ESC + b"{\x00" + align_cmd("left")
    return out


def load_image(src):
    from PIL import Image
    if src.startswith(("http://", "https://")):
        req = urllib.request.Request(src, headers={"User-Agent": "kiosk-print"})
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
        img = Image.open(io.BytesIO(data))
    else:
        path = src if os.path.isabs(src) else os.path.join(IMAGE_DIR, src)
        img = Image.open(path)
    return img


def build_image(src, align, flip=False):
    from PIL import Image, ImageOps
    img = load_image(src)
    img = ImageOps.exif_transpose(img)
    if flip:
        img = img.rotate(180, expand=True)
    # flatten transparency onto white
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
        bg.alpha_composite(img)
        img = bg
    img = img.convert("L")
    if img.width > MAX_WIDTH:
        h = round(img.height * MAX_WIDTH / img.width)
        img = img.resize((MAX_WIDTH, h), Image.LANCZOS)
    if img.height > MAX_HEIGHT:
        w = round(img.width * MAX_HEIGHT / img.height)
        img = img.resize((w, MAX_HEIGHT), Image.LANCZOS)
    img = ImageOps.autocontrast(img)
    mono = img.convert("1")              # Floyd-Steinberg dither
    width_bytes = (mono.width + 7) // 8
    # pad to whole bytes with white
    if mono.width % 8:
        padded = Image.new("1", (width_bytes * 8, mono.height), 1)
        padded.paste(mono, (0, 0))
        mono = padded
    raw = bytes(b ^ 0xFF for b in mono.tobytes())   # PIL: 1=white, printer: 1=black
    out = INIT + align_cmd(align)
    for y in range(0, mono.height, BAND):
        rows = min(BAND, mono.height - y)
        chunk = raw[y * width_bytes:(y + rows) * width_bytes]
        out += GS + b"v0\x00" + bytes([width_bytes & 0xFF, width_bytes >> 8,
                                         rows & 0xFF, rows >> 8]) + chunk
    out += align_cmd("left")
    return out


def build_qr(text, qrsize, align):
    data = text.encode("utf-8")
    n = len(data) + 3
    out = INIT + align_cmd(align)
    out += GS + b"(k\x04\x00\x31\x41\x32\x00"                 # model 2
    out += GS + b"(k\x03\x00\x31\x43" + bytes([max(1, min(16, qrsize))])  # module size
    out += GS + b"(k\x03\x00\x31\x45\x31"                     # error correction M
    out += GS + b"(k" + bytes([n & 0xFF, n >> 8]) + b"\x31\x50\x30" + data  # store
    out += GS + b"(k\x03\x00\x31\x51\x30"                     # print
    out += b"\n" + align_cmd("left")
    return out


def list_images():
    os.makedirs(IMAGE_DIR, exist_ok=True)
    try:
        files = sorted(f for f in os.listdir(IMAGE_DIR) if f.lower().endswith(IMAGE_EXT))
    except FileNotFoundError:
        files = []
    print(json.dumps(files or ["(no images in /media/kiosk)"]))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["text", "image", "qr", "list"])
    p.add_argument("data", nargs="?", default="")
    p.add_argument("--size", default="normal")
    p.add_argument("--align", default="left")
    p.add_argument("--bold", default="off")
    p.add_argument("--cut", default="on")
    p.add_argument("--qrsize", type=int, default=8)
    p.add_argument("--flip", default="on")
    p.add_argument("--beeper", default="off")
    a = p.parse_args()

    if a.mode == "list":
        list_images()
        return

    payload = b64(a.data) if a.data else ""
    if a.mode == "text":
        job = build_text(payload, a.size, a.align, a.bold, a.flip == "on")
    elif a.mode == "image":
        job = build_image(payload.strip(), a.align, a.flip == "on")
    else:
        job = build_qr(payload, a.qrsize, a.align)
    if a.beeper == "off" and job.startswith(INIT):
        job = INIT + BUZZER_OFF + job[len(INIT):]
    if a.cut == "on":
        job += FEED_AND_CUT
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(job)
    print(f"ok {len(job)} bytes")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # surface a readable error to HA
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
