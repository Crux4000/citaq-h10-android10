#!/usr/bin/env python3
"""Shared helpers for Rockchip (legacy U-Boot 2017.02-RK3368) boot images.

The Citaq H10-3's stock U-Boot checks boot/recovery images with Rockchip's own SHA-1
recipe, which is NOT the standard mkbootimg one:

    SHA-1( kernel, le32(kernel_size), ramdisk, le32(ramdisk_size),
           second, le32(second_size), header bytes 0x20..0x240 )   -> header id[0:20] at 0x240

The hash runs on the RK3368 crypto engine fed in 4-byte words, so every hashed chunk
must be a multiple of 4 bytes - we zero-pad each chunk to 16. A mismatch shows on the
serial console as "boot or recovery image sha mismatch!".

"second" is a Rockchip RSCE resource package (rk-kernel.dtb + logos); U-Boot loads the
kernel's FDT from it, so a test DTB never touches the resource partition.
"""
import hashlib
import struct


def pad16(b):
    return b + b'\0' * ((-len(b)) % 16)


def rsce_unpack(r):
    assert r[:4] == b'RSCE', 'not an RSCE resource package'
    n = struct.unpack('<I', r[12:16])[0]
    out = []
    for i in range(n):
        e = r[512 * (1 + i):512 * (2 + i)]
        assert e[:4] == b'ENTR'
        name = e[4:260].split(b'\0')[0].decode()
        off, size = struct.unpack('<II', e[260:268])
        out.append((name, r[off * 512:off * 512 + size]))
    return out


def rsce_pack(entries):
    n = len(entries)
    hdr = bytearray(512)
    hdr[0:4] = b'RSCE'
    hdr[8:12] = bytes([1, 1, 1, 0])          # header blks, tbl offset blks, entry blks
    struct.pack_into('<I', hdr, 12, n)
    table = b''
    data = b''
    blk = 1 + n
    for name, body in entries:
        e = bytearray(512)
        e[0:4] = b'ENTR'
        nb = name.encode(); e[4:4 + len(nb)] = nb
        struct.pack_into('<II', e, 260, blk, len(body))
        table += bytes(e)
        chunk = body + b'\0' * ((-len(body)) % 512)
        data += chunk
        blk += len(chunk) // 512
    return bytes(hdr) + table + data


def read_stock(path):
    """Return (header_page_bytes, page_size, second) from a stock Citaq boot/recovery image."""
    r = open(path, 'rb').read()
    assert r[:8] == b'ANDROID!', f'{path}: not an Android boot image'
    ks, ka, rs, ra, ss, sa, ta, ps = struct.unpack('<8I', r[8:40])
    pg = lambda n: (n + ps - 1) // ps * ps
    second = r[ps + pg(ks) + pg(rs):ps + pg(ks) + pg(rs) + ss]
    return r[:ps], ps, second


def pack(header_page, ps, kernel, ramdisk, second, max_size=32 * 1024 * 1024):
    """Pack kernel/ramdisk/second behind a copy of the stock header with the Rockchip id hash.
    Output is padded to a whole number of 16 KiB blocks (the dd block size used everywhere)."""
    K, R, S = pad16(kernel), pad16(ramdisk), pad16(second)
    pg = lambda n: (n + ps - 1) // ps * ps
    hd = bytearray(header_page)
    for off, b in ((8, K), (16, R), (24, S)):
        struct.pack_into('<I', hd, off, len(b))
    h = hashlib.sha1()
    for b in (K, R, S):
        h.update(b); h.update(struct.pack('<I', len(b)))
    h.update(bytes(hd[0x20:0x240]))
    hd[576:608] = h.digest() + b'\0' * 12
    img = bytes(hd)
    for b in (K, R, S):
        img += b + b'\0' * (pg(len(b)) - len(b))
    assert len(img) <= max_size, f'image is {len(img)} bytes, too big for a {max_size >> 20} MiB slot'
    img += b'\0' * ((-len(img)) % 16384)
    return img, (len(K), len(R), len(S))
