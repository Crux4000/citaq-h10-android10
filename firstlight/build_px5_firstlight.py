#!/usr/bin/env python3
"""Optional bring-up test: boot the PX5 4.19 kernel to a busybox shell (no Android).

usage: build_px5_firstlight.py <stock recovery.img> <px5_kernel> <citaq-px5.dtb> <busybox> <init.sh> <out.img>

  citaq-px5.dtb   dtb/make_citaq_dtb.sh px5.dtb citaq-px5.dtb (stage 1 only)
  busybox         a static busybox - the stock recovery's 32-bit one works (runs via CONFIG_COMPAT)
  init.sh         firstlight/initramfs-init.sh

Flash to the RECOVERY slot only (tools/flash_slot.py), watch the serial console (UART2,
TP17/TP18/TP19, 115200), `adb reboot recovery`. The init prints a hardware report, turns the
screen to static, and reboots back to stock Android after 5 minutes unless you press Enter.
Useful when adapting this port to a different RK3368 board.
"""
import gzip
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from rkbootimg import rsce_unpack, rsce_pack, read_stock, pack


def newc(entries):
    out = b''; ino = 300000
    for name, mode, data, rdev in entries + [('TRAILER!!!', 0, b'', (0, 0))]:
        nb = name.encode() + b'\0'
        f = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(nb), 0]
        h = b'070701' + b''.join(b'%08X' % x for x in f) + nb
        h += b'\0' * ((-len(h)) % 4)
        out += h + data + b'\0' * ((-len(data)) % 4)
        ino += 1
    return out


def initramfs(busybox, init):
    D = 0o040755; F = 0o100755; C = 0o020600
    ents = [('.', D, b'', (0, 0))]
    for d in ('bin', 'dev', 'proc', 'sys', 'tmp'):
        ents.append((d, D, b'', (0, 0)))
    ents.append(('dev/console', C, b'', (5, 1)))
    ents.append(('bin/busybox', F, open(busybox, 'rb').read(), (0, 0)))
    ents.append(('init', F, open(init, 'rb').read(), (0, 0)))
    return gzip.compress(newc(ents), 9, mtime=0)


def main(stock, image, dtb, busybox, init, out):
    header, ps, second = read_stock(stock)
    ents = [(n, open(dtb, 'rb').read() if n == 'rk-kernel.dtb' else b) for n, b in rsce_unpack(second)]
    kimg = open(image, 'rb').read()
    assert kimg[0x38:0x3c] == b'ARM\x64', 'not a raw arm64 Image'
    assert struct.unpack('<Q', kimg[8:16])[0] == 0x80000, 'TEXT_OFFSET must be 0x80000'
    # U-Boot copies the kernel to 0x280000 and the ramdisk to 0x05bf0000: the kernel (incl. BSS) must fit between.
    isz = struct.unpack('<Q', kimg[16:24])[0]
    assert 0x280000 + isz < 0x05bf0000, 'kernel image_size overlaps the ramdisk load address'
    img, (k, r, s) = pack(header, ps, kimg, initramfs(busybox, init), rsce_pack(ents))
    open(out, 'wb').write(img)
    print(f'kernel {k} (image_size {isz:#x})  ramdisk {r}  second {s}  image {len(img)} ({len(img) // 16384} x 16384)')


if __name__ == '__main__':
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    main(*sys.argv[1:7])
