#!/usr/bin/env python3
"""Look inside a Rockchip firmware image (update.img), read-only. No terminal needed.

usage: rkimg_peek.py <firmware.zip | update.img>

Works on Windows, macOS and Linux with plain Python 3. Takes a firmware .zip as downloaded
(reads the update.img inside it) or a bare update.img. It only READS that file.

Prints: the image header, the partition list inside it, the parameter (partition table +
kernel command line), and for each device tree in the resource image the screen settings.
Also saves parameter.txt, resource.img, the .dtb file(s), uboot.img, trust.img and the loader
into a new folder next to the input, named <input>-peek, and prints their md5s, the U-Boot
version and any SD-card related strings in the bootloader parts.
"""
import hashlib
import os
import re
import struct
import sys
import zipfile


def open_image(path):
    """Return a forward-readable file object for the update.img (inside a zip or bare)."""
    if zipfile.is_zipfile(path):
        z = zipfile.ZipFile(path)
        imgs = [i for i in z.infolist() if i.filename.lower().endswith('.img')]
        if not imgs:
            sys.exit('no .img file inside the zip')
        info = max(imgs, key=lambda i: i.file_size)
        print(f'zip member: {info.filename} ({info.file_size:,} bytes)')
        return z.open(info)
    return open(path, 'rb')


class Reader:
    """Forward-only reader (a zip member can only be read forwards cheaply)."""
    def __init__(self, f):
        self.f, self.pos = f, 0

    def read_at(self, off, n):
        if off < self.pos:
            raise RuntimeError(f'need to go back to {off:#x} (at {self.pos:#x})')
        skip = off - self.pos
        while skip:
            chunk = self.f.read(min(skip, 1 << 20))
            if not chunk:
                raise RuntimeError('file ended early')
            skip -= len(chunk)
        data = self.f.read(n)
        self.pos = off + len(data)
        if len(data) != n:
            raise RuntimeError('file ended early')
        return data


def cstr(b):
    return b.split(b'\0')[0].decode('latin-1')


# ---------- minimal flattened device tree reader ----------
def fdt_nodes(dtb):
    """Yield (path, {prop: bytes}) for every node."""
    magic, total, off_struct, off_strings = struct.unpack('>IIII', dtb[:16])
    if magic != 0xd00dfeed:
        raise ValueError('not a device tree')
    strings = dtb[off_strings:]
    p, stack, props = off_struct, [], []
    while True:
        tok = struct.unpack('>I', dtb[p:p + 4])[0]; p += 4
        if tok == 1:                                   # begin node
            end = dtb.index(b'\0', p); name = dtb[p:end].decode('latin-1')
            p = (end + 4) & ~3
            stack.append(name); props.append({})
        elif tok == 2:                                 # end node
            yield '/' + '/'.join(s for s in stack if s), props.pop(); stack.pop()
        elif tok == 3:                                 # property
            ln, noff = struct.unpack('>II', dtb[p:p + 8]); p += 8
            pname = cstr(strings[noff:noff + 64]); props[-1][pname] = dtb[p:p + ln]
            p = (p + ln + 3) & ~3
        elif tok == 4:
            continue
        elif tok == 9:
            return
        else:
            raise ValueError(f'bad token {tok}')


def u32(v):
    return struct.unpack('>I', v[:4])[0] if v is not None and len(v) >= 4 else None


def describe_dtb(name, dtb):
    print(f'\n  {name}: {len(dtb):,} bytes, md5 {hashlib.md5(dtb).hexdigest()}')
    face_names = {0x0: 'P888 (8-bit)', 0x1: 'P666 (6-bit)', 0x2: 'P565', 0x21: 'D888_P666 (6-bit, dithered)',
                  0x22: 'D888_P565'}
    found = False
    for path, props in fdt_nodes(dtb):
        if path.endswith('/display-timings') or '/display-timings/' in path:
            if not path.split('/')[-1].startswith('timing'):
                continue
            found = True
            v = {k: u32(props.get(k)) for k in ('clock-frequency', 'hactive', 'vactive', 'out-face',
                                                 'lvds-format', 'screen-type', 'hback-porch',
                                                 'hfront-porch', 'hsync-len', 'vback-porch',
                                                 'vfront-porch', 'vsync-len')}
            clk = v['clock-frequency']
            face = v['out-face']
            print(f'    screen {path}: {v["hactive"]}x{v["vactive"]}, '
                  f'{clk / 1e6 if clk else "?"} MHz, out-face {face:#x} '
                  f'= {face_names.get(face, "?")}, lvds-format {v["lvds-format"]}, '
                  f'screen-type {v["screen-type"]}')
            print(f'      porches h {v["hback-porch"]}/{v["hfront-porch"]}/{v["hsync-len"]}  '
                  f'v {v["vback-porch"]}/{v["vfront-porch"]}/{v["vsync-len"]}')
        if path.startswith('/i2c@ff140000/') and 'reg' in props:   # touch bus
            comp = cstr(props.get('compatible', b''))
            print(f'    touch node {path.split("/")[-1]}: {comp}')
        if path == '/chosen' and 'bootargs' in props:
            print(f'    chosen bootargs: {cstr(props["bootargs"])}')
        if path.startswith('/lcdc@') and 'rockchip,mirror' in props:
            print(f'    lcdc mirror: {u32(props["rockchip,mirror"])}')
    if not found:
        print('    (no display-timings found)')


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    outdir = os.path.splitext(src)[0] + '-peek'
    r = Reader(open_image(src))

    fw = r.read_at(0, 0x66)
    if fw[:4] == b'RKFW':
        year, month, day, hour, minute = struct.unpack('<HBBBB', fw[14:20])
        chip = struct.unpack('<I', fw[21:25])[0]
        ld_off, ld_len, im_off, im_len = struct.unpack('<IIII', fw[25:41])
        ver = struct.unpack('<I', fw[6:10])[0]
        print(f'RKFW header: version {ver >> 24}.{(ver >> 16) & 0xff}.{ver & 0xffff}, '
              f'built {year}-{month:02}-{day:02} {hour:02}:{minute:02}, chip {chip:#x}')
        print(f'  loader at {ld_off:#x} ({ld_len:,} B), firmware at {im_off:#x} ({im_len:,} B)')
        base = im_off
    elif fw[:4] == b'RKAF':
        base = 0
    else:
        sys.exit(f'not a Rockchip update.img (starts with {fw[:4]!r})')

    if base == 0:
        af = fw + r.read_at(0x66, 140 + 16 * 112 - 0x66)
    else:
        af = r.read_at(base, 140 + 16 * 112)
    if af[:4] != b'RKAF':
        sys.exit('RKAF header not found where expected')
    model, ident, maker = cstr(af[8:42]), cstr(af[42:72]), cstr(af[72:128])
    num = struct.unpack('<I', af[136:140])[0]
    print(f'RKAF: model "{model}", id "{ident}", manufacturer "{maker}", {num} parts')
    parts = []
    for i in range(min(num, 16)):
        e = af[140 + i * 112:140 + (i + 1) * 112]
        name, fname = cstr(e[0:32]), cstr(e[32:92])
        nand_size, pos, nand_addr, padded, size = struct.unpack('<IIIII', e[92:112])
        parts.append((pos, name, fname, nand_addr, size))
        print(f'  {name:<14} {fname:<28} {size:>13,} B   flash addr {nand_addr:#x}')

    os.makedirs(outdir, exist_ok=True)
    for pos, name, fname, nand_addr, size in sorted(parts):
        if name not in ('parameter', 'resource', 'uboot', 'trust', 'bootloader') or size == 0:
            continue
        data = r.read_at(base + pos, size)
        if name in ('uboot', 'trust', 'bootloader'):
            out = os.path.basename(fname) or name + '.img'
            with open(os.path.join(outdir, out), 'wb') as f:
                f.write(data)
            print(f'\n--- {name}: {out}, {len(data):,} B, md5 {hashlib.md5(data).hexdigest()} ---')
            for m in sorted(set(re.findall(rb'U-Boot 20\d\d\.\d\d[ -~]{0,60}', data)))[:3]:
                print(f'  version: {m.decode()}')
            hits = sorted(set(s.decode() for s in re.findall(rb'[ -~]{6,}', data)
                              if re.search(rb'(?i)sd ?card|sd ?boot|sdfw|sd_?update|external_sd|mmc ?1', s)))
            for s in hits[:25]:
                print(f'  sd: {s[:100]}')
            if len(hits) > 25:
                print(f'  sd: ... {len(hits) - 25} more')
            continue
        if name == 'parameter':
            if data[:4] == b'PARM':
                ln = struct.unpack('<I', data[4:8])[0]
                data = data[8:8 + ln]
            with open(os.path.join(outdir, 'parameter.txt'), 'wb') as f:
                f.write(data)
            print('\n--- parameter ---')
            print(data.decode('latin-1').strip())
        else:
            with open(os.path.join(outdir, 'resource.img'), 'wb') as f:
                f.write(data)
            if data[:4] != b'RSCE':
                print(f'\nresource is not an RSCE package (starts {data[:4]!r})')
                continue
            n = struct.unpack('<I', data[12:16])[0]
            print(f'\n--- resource: {n} entries ---')
            for i in range(n):
                e = data[512 * (1 + i):512 * (2 + i)]
                ename = cstr(e[4:260])
                off, sz = struct.unpack('<II', e[260:268])
                body = data[off * 512:off * 512 + sz]
                print(f'  {ename} ({sz:,} B)')
                if ename.endswith('.dtb'):
                    with open(os.path.join(outdir, os.path.basename(ename)), 'wb') as f:
                        f.write(body)
                    describe_dtb(ename, body)
    print(f'\nSaved to {outdir}')


if __name__ == '__main__':
    main()
