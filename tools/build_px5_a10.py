#!/usr/bin/env python3
"""Citaq H10-3 boot image that boots PX5 Android 10 on the stock Citaq U-Boot.

usage: build_px5_a10.py <stock recovery.img> <px5_kernel> <citaq-a10.dtb> <px5_ramdisk> <out.img>

  stock recovery.img   your own terminal's recovery partition (dump it, see docs/INSTALL.md).
                       Only its header and its RSCE logos are reused.
  px5_kernel, px5_ramdisk   from extract_px5_boot.py
  citaq-a10.dtb        from dtb/make_citaq_a10_dtb.sh

The same image works in the recovery slot (test) and in the boot slot (default boot).

Ramdisk = the PX5 boot.img first-stage ramdisk, unchanged except fstab.rk30board:
  - userdata: no file-based encryption / checkpoint (the Citaq has no OP-TEE for keymaster)
  - cache: formattable
"""
import gzip
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rkbootimg import rsce_unpack, rsce_pack, read_stock, pack


def cpio_read(b):
    out = []; o = 0
    while True:
        h = b[o:o + 110]; assert h[:6] == b'070701', 'not newc'
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        nsz, fsz = f[11], f[6]
        name = b[o + 110:o + 110 + nsz - 1].decode()
        o += 110 + nsz; o += (-o) % 4
        data = b[o:o + fsz]; o += fsz; o += (-o) % 4
        if name == 'TRAILER!!!': return out
        out.append([name, f, data])


def cpio_write(ents):
    out = b''
    for name, f, data in ents + [['TRAILER!!!', [0] * 4 + [1] + [0] * 8, b'']]:
        f = list(f); nb = name.encode() + b'\0'; f[6] = len(data); f[11] = len(nb)
        h = b'070701' + b''.join(b'%08X' % x for x in f) + nb
        h += b'\0' * ((-len(h)) % 4)
        out += h + data + b'\0' * ((-len(data)) % 4)
    return out


def patch_fstab(t):
    lines = []
    for l in t.split('\n'):
        s = l.split()
        if len(s) >= 5 and not l.startswith('#'):
            if s[1] == '/data':
                fl = [x for x in s[4].split(',') if not x.startswith(('fileencryption', 'checkpoint'))]
                s[4] = ','.join(fl); l = '  '.join(s)
            elif s[1] == '/cache' and 'formattable' not in s[4]:
                s[4] += ',formattable'; l = '  '.join(s)
        lines.append(l)
    return '\n'.join(lines)


def main(stock, image, dtb, ramdisk, out):
    ents = cpio_read(gzip.decompress(open(ramdisk, 'rb').read()))
    for e in ents:
        if e[0] == 'fstab.rk30board':
            new = patch_fstab(e[2].decode())
            print('--- fstab.rk30board (patched) ---\n' + new)
            e[2] = new.encode()
    rd = gzip.compress(cpio_write(ents), 9, mtime=0)
    header, ps, second = read_stock(stock)
    res = [(n, open(dtb, 'rb').read() if n == 'rk-kernel.dtb' else b) for n, b in rsce_unpack(second)]
    kimg = open(image, 'rb').read()
    assert kimg[0x38:0x3c] == b'ARM\x64', 'not a raw arm64 Image'
    # The Citaq U-Boot always copies the kernel to 0x280000, so it needs TEXT_OFFSET 0x80000.
    assert struct.unpack('<Q', kimg[8:16])[0] == 0x80000, 'TEXT_OFFSET must be 0x80000'
    img, (k, r, s) = pack(header, ps, kimg, rd, rsce_pack(res))
    open(out, 'wb').write(img)
    print(f'kernel {k}  ramdisk {r}  second {s}  image {len(img)} ({len(img) // 16384} x 16384)')
    print('md5', hashlib.md5(img).hexdigest())


if __name__ == '__main__':
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    main(*sys.argv[1:6])
