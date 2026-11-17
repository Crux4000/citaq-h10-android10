#!/usr/bin/env python3
"""Pull the build inputs out of the PX5 Android 10 boot.img (Android boot header v2).

usage: extract_px5_boot.py <px5 boot.img> <outdir>

writes px5_kernel (raw arm64 Image), px5_ramdisk (gz cpio), px5_second (RSCE), px5.dtb (rk-kernel.dtb)
Known-good inputs (CHS7_PX5_10.0_IMG(20200603)): boot.img 27,635,712 bytes;
px5_kernel MD5 starts c17c05ad, px5_ramdisk f16dc2b1, px5.dtb 9766b2fe.
"""
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rkbootimg import rsce_unpack

if len(sys.argv) != 3:
    sys.exit(__doc__)
b = open(sys.argv[1], 'rb').read(); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
assert b[:8] == b'ANDROID!', 'not an Android boot image'
ks, ka, rs, ra, ss, sa, ta, ps = struct.unpack('<8I', b[8:40])
up = lambda n: (n + ps - 1) // ps * ps
o = ps; k = b[o:o + ks]; o += up(ks); r = b[o:o + rs]; o += up(rs); s = b[o:o + ss]
files = [('px5_kernel', k), ('px5_ramdisk', r), ('px5_second', s)]
files += [('px5.dtb', d) for n, d in rsce_unpack(s) if n == 'rk-kernel.dtb']
for n, d in files:
    open(os.path.join(out, n), 'wb').write(d)
    print(f'{n:12s} {len(d):>10,} bytes  md5 {hashlib.md5(d).hexdigest()}')
print('page size', ps)
