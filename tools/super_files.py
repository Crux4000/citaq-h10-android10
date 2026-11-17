#!/usr/bin/env python3
"""Read and patch files inside the PX5 super.img - no Android tools needed.

  python super_files.py <super.img> <out.zip>
      zip the init .rc files, fstabs, build.props and directory listings from
      system / vendor / odm / product (for reading on the PC).
  python super_files.py find <super.img> <out.zip> <text> [<text> ...]
      search every .apk/.jar/.vdex/.odex in system/product/vendor/odm for the text
      (inside the dex code too) and zip the files that contain it, plus app listings.
  python super_files.py patch <super.img> <adb> <patch.json>
      apply a byte patch (patches/*.json) to one file inside super, on the terminal:
      checks the file in super.img is the expected one (MD5), finds its blocks, patches
      only those 1 MiB blocks of the super region via rkio, and reads each one back.
      Run from STOCK Android 5.1 (the preflight from super_to_citaq.py applies).

Reads the dynamic-partition (LP) metadata, then reads the ext4 filesystems straight from
the (sparse) image. ext4 without metadata_csum, so in-place data/dirent edits are safe.

patch.json format:
  {"files": [{"path": "<partition>/<path in fs>", "md5_old": "...",
              "diffs": [[file_offset, "old hex", "new hex"], ...]}],
   "renames": [{"dir": "<partition>/<dir>", "old": "name", "new": "same-length name"}],
   "after": ["earlier_patch.json", ...]}      # patches already applied to the same file(s)
"""
import sys, os, struct, zipfile, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from super_to_citaq import raw_stream

MIB = 1 << 20

class Img:
    """Random access to the unpacked super image (sparse aware), with a chunk map."""
    def __init__(self, path):
        f = open(path, 'rb'); self.f = f
        magic, maj, mnr, fhs, chs, bs, tblk, tchk, _ = struct.unpack('<IHHHHIIII', f.read(28))
        self.map = []                 # (raw_start, raw_len, kind, file_off_or_fill)
        if magic != 0xED26FF3A:
            f.seek(0, 2); self.map.append((0, f.tell(), 'raw', 0)); return
        f.seek(fhs); pos = 0
        for _ in range(tchk):
            ctype, _, csz, tsz = struct.unpack('<HHII', f.read(12)); n = csz * bs
            if ctype == 0xCAC1: self.map.append((pos, n, 'raw', f.tell())); f.seek(n, 1)
            elif ctype == 0xCAC2: self.map.append((pos, n, 'fill', f.read(4)))
            elif ctype == 0xCAC3: self.map.append((pos, n, 'fill', b'\0\0\0\0'))
            elif ctype == 0xCAC4: f.read(4); n = 0
            pos += n
    def read(self, off, n):
        out = bytearray()
        for s, l, k, v in self.map:
            if off + n <= s or off >= s + l: continue
            a = max(off, s); b = min(off + n, s + l)
            if k == 'raw': self.f.seek(v + a - s); out += self.f.read(b - a)
            else: out += (v * ((b - a) // 4 + 2))[(a - s) % 4:(a - s) % 4 + b - a]
        assert len(out) == n, (off, n, len(out))
        return bytes(out)

def lp_partitions(img):
    g = img.read(4096, 4096)
    assert struct.unpack('<I', g[:4])[0] == 0x616c4467, 'no LP geometry'
    mmax, slots, lbs = struct.unpack('<III', g[40:52])
    h = img.read(4096 + 8192, 4096)
    assert struct.unpack('<I', h[:4])[0] == 0x414C5030, 'no LP header'
    hsz = struct.unpack('<I', h[8:12])[0]
    tsz = struct.unpack('<I', h[44:48])[0]
    d = struct.unpack('<12I', h[80:128])
    t = img.read(4096 + 8192 + hsz, tsz)
    def table(i): o, n, e = d[3 * i:3 * i + 3]; return [t[o + k * e:o + (k + 1) * e] for k in range(n)]
    parts, exts = table(0), table(1)
    out = {}
    for p in parts:
        name = p[:36].split(b'\0')[0].decode()
        attr, fi, ne, gi = struct.unpack('<IIII', p[36:52])
        el = []
        for e in exts[fi:fi + ne]:
            nsec, ttype, tdata = struct.unpack('<QIQ', e[:20])
            el.append((nsec * 512, ttype, tdata * 512))
        out[name] = el
    return out

class Part:
    def __init__(self, img, extents): self.img = img; self.ext = extents
    def read(self, off, n):
        out = b''; base = 0
        for size, ttype, phys in self.ext:
            if off < base + size and off + n > base:
                a = max(off, base); b = min(off + n, base + size)
                out += self.img.read(phys + a - base, b - a) if ttype == 0 else bytes(b - a)
            base += size
        return out

class Ext4:
    def __init__(self, dev):
        self.d = dev; sb = dev.read(1024, 1024)
        assert struct.unpack('<H', sb[56:58])[0] == 0xEF53, 'not ext4'
        self.bs = 1024 << struct.unpack('<I', sb[24:28])[0]
        self.ipg = struct.unpack('<I', sb[40:44])[0]
        self.isz = struct.unpack('<H', sb[88:90])[0]
        incompat = struct.unpack('<I', sb[96:100])[0]
        self.desc = struct.unpack('<H', sb[254:256])[0] if incompat & 0x80 else 32
        self.desc = self.desc or 32
        self.gdt = (1 if self.bs > 1024 else 2) * self.bs
        self.feat = struct.unpack('<III', sb[92:104])   # compat, incompat, ro_compat
    def inode(self, n):
        g, i = divmod(n - 1, self.ipg)
        gd = self.d.read(self.gdt + g * self.desc, self.desc)
        it = struct.unpack('<I', gd[8:12])[0]
        if self.desc >= 64: it |= struct.unpack('<I', gd[40:44])[0] << 32
        return self.d.read(it * self.bs + i * self.isz, self.isz)
    def data(self, ino):
        mode = struct.unpack('<H', ino[0:2])[0]
        size = struct.unpack('<I', ino[4:8])[0] | (struct.unpack('<I', ino[108:112])[0] << 32)
        flags = struct.unpack('<I', ino[32:36])[0]
        blk = ino[40:100]
        if (mode & 0xF000) == 0xA000 and size < 60: return blk[:size]          # fast symlink
        if flags & 0x10000000: return blk[:size]                                # inline data
        out = bytearray()
        def walk(node):
            magic, ent, mx, depth = struct.unpack('<HHHH', node[:8])
            assert magic == 0xF30A
            for k in range(ent):
                e = node[12 + 12 * k:24 + 12 * k]
                if depth == 0:
                    lblk, ln, hi, lo = struct.unpack('<IHHI', e)
                    unin = ln > 32768; ln = ln - 32768 if unin else ln
                    p = (hi << 32) | lo
                    need = lblk * self.bs + ln * self.bs
                    if len(out) < need: out.extend(bytes(need - len(out)))
                    if not unin: out[lblk * self.bs:need] = self.d.read(p * self.bs, ln * self.bs)
                else:
                    lblk, lo, hi, _ = struct.unpack('<IIHH', e)
                    walk(self.d.read(((hi << 32) | lo) * self.bs, self.bs))
        if flags & 0x80000: walk(blk)
        else:
            for k in range(12):
                b = struct.unpack('<I', blk[4 * k:4 * k + 4])[0]
                if b: out += self.d.read(b * self.bs, self.bs)
        return bytes(out[:size])
    def listdir(self, ino_no):
        d = self.data(self.inode(ino_no)); o = 0; out = {}
        while o + 8 <= len(d):
            ino, rl, nl, ft = struct.unpack('<IHBB', d[o:o + 8])
            if rl < 8: break
            if ino: out[d[o + 8:o + 8 + nl].decode('latin-1')] = (ino, ft)
            o += rl
        return out
    def lookup(self, path):
        ino = 2
        for p in [x for x in path.split('/') if x]:
            ents = self.listdir(ino)
            if p not in ents: return None
            ino = ents[p][0]
        return ino
    def fmap(self, ino):
        """[(file_off, part_off, length)] for an extent-mapped file."""
        out = []
        def walk(node):
            magic, ent, mx, depth = struct.unpack('<HHHH', node[:8])
            for k in range(ent):
                e = node[12 + 12 * k:24 + 12 * k]
                if depth == 0:
                    lblk, ln, hi, lo = struct.unpack('<IHHI', e)
                    if ln > 32768: ln -= 32768
                    out.append((lblk * self.bs, ((hi << 32) | lo) * self.bs, ln * self.bs))
                else:
                    lblk, lo, hi, _ = struct.unpack('<IIHH', e)
                    walk(self.d.read(((hi << 32) | lo) * self.bs, self.bs))
        walk(ino[40:100])
        return out
    def isdir(self, n): return (struct.unpack('<H', self.inode(n)[0:2])[0] & 0xF000) == 0x4000

def main(path, outzip):
    img = Img(path)
    parts = lp_partitions(img)
    print('partitions:', {k: sum(e[0] for e in v) // MIB for k, v in parts.items()}, 'MiB')
    z = zipfile.ZipFile(outzip, 'w', zipfile.ZIP_DEFLATED)
    want = {
        'vendor': ['etc/init', 'etc/init/hw', 'etc/fstab.rk30board', 'build.prop', 'ueventd.rc',
                   'etc/selinux/vendor_property_contexts', 'bin', 'bin/hw', 'firmware', 'lib64/egl',
                   'lib/egl', 'lib64/hw', 'etc/permissions', 'lib/modules', 'etc/init.insmod.cfg'],
        'system': ['system/etc/init', 'system/etc/init/hw', 'system/build.prop', 'system/bin'],
        'odm': ['etc/init', 'build.prop', 'etc/selinux'],
        'product': ['build.prop', 'etc/init'],
    }
    for pname, paths in want.items():
        if pname not in parts: continue
        fs = Ext4(Part(img, parts[pname]))
        listing = []
        for p in paths:
            n = fs.lookup(p)
            if n is None: listing.append(f'{p}: (missing)'); continue
            if fs.isdir(n):
                dl = fs.listdir(n)
                ents = sorted(e for e in dl if e not in ('.', '..'))
                listing.append(f'{p}/: ' + ' '.join(ents))
                for e in ents:
                    m = dl[e][0]
                    if not fs.isdir(m) and (e.endswith(('.rc', '.prop', '.cfg', '.sh', '.xml', 'contexts')) or 'fstab' in e):
                        z.writestr(f'{pname}/{p}/{e}', fs.data(fs.inode(m)))
            else:
                z.writestr(f'{pname}/{p}', fs.data(fs.inode(n)))
        z.writestr(f'{pname}/_listing.txt', '\n\n'.join(listing))
        print(f'{pname}: done')
    z.close()
    print('wrote', outzip, os.path.getsize(outzip), 'bytes')

def part_to_super(extents, off):
    base = 0
    for size, ttype, phys in extents:
        if base <= off < base + size:
            assert ttype == 0
            return phys + off - base
        base += size
    raise ValueError(off)

def patch(path, adbexe, pjson):
    import json, hashlib
    import super_to_citaq as T
    P = json.load(open(pjson))
    img = Img(path); parts = lp_partitions(img)
    edits = {}                                     # super offset -> (old, new)
    prior = {}                                     # earlier patches already on the terminal
    def file_edits(pname, fs, ino, diffs, into=None):
        into = edits if into is None else into
        fm = fs.fmap(ino)
        def f2s(fo):
            for lo, po, ln in fm:
                if lo <= fo < lo + ln:
                    return part_to_super(parts[pname], po + fo - lo)
            raise ValueError(fo)
        for fo, old, new in diffs:
            old = bytes.fromhex(old); new = bytes.fromhex(new)
            for k in range(len(old)):
                into[f2s(fo + k)] = (old[k], new[k])
    def rename_edits(R, into):
        pname, dpath = R['dir'].split('/', 1)
        fs = Ext4(Part(img, parts[pname]))
        dn = fs.lookup(dpath); assert dn, dpath
        dino = fs.inode(dn); d = fs.data(dino)
        old, new = R['old'].encode(), R['new'].encode(); assert len(old) == len(new)
        o = 0; hit = None
        while o + 8 <= len(d):
            ino_, rl, nl, ft = struct.unpack('<IHBB', d[o:o + 8])
            if rl < 8: break
            if ino_ and d[o + 8:o + 8 + nl] == old: hit = o + 8
            o += rl
        if hit is None:
            return False
        file_edits(pname, fs, dino, [(hit, old.hex(), new.hex())], into)
        return True
    for pj in P.get('after', []):                  # replay earlier patch files into 'prior'
        Q = json.load(open(os.path.join(os.path.dirname(os.path.abspath(pjson)), pj)))
        for F in Q.get('files', [Q] if 'diffs' in Q else []):
            pn, fp = F['path'].split('/', 1)
            fs = Ext4(Part(img, parts[pn])); n = fs.lookup(fp)
            file_edits(pn, fs, fs.inode(n), F['diffs'], prior)
        for R in Q.get('renames', []):
            rename_edits(R, prior)
        print(f'(accounting for earlier patch {pj})')
    for F in P.get('files', [P] if 'diffs' in P else []):
        pname, fpath = F['path'].split('/', 1)
        fs = Ext4(Part(img, parts[pname]))
        n = fs.lookup(fpath); assert n, fpath
        ino = fs.inode(n)
        if hashlib.md5(fs.data(ino)).hexdigest() != F['md5_old']:
            sys.exit(f'{F["path"]} in super.img is not the expected file - stopping')
        file_edits(pname, fs, ino, F['diffs'])
        print(f'{F["path"]}: byte patch')
    for R in P.get('renames', []):                 # same-length rename of a directory entry
        if rename_edits(R, edits):
            print(f'{R["dir"]}/{R["old"]} -> {R["new"]}')
        else:
            print(f'{R["dir"]}/{R["old"]}: not found, skipping')
    mibs = sorted({o >> 20 for o in edits})
    print(f'{len(edits)} bytes to change in {len(mibs)} MiB block(s): {mibs}')
    T.preflight(adbexe)
    tmp = os.path.join(os.path.dirname(os.path.abspath(path)), 'patch.part.tmp')
    for m in mibs:
        ref = bytearray(img.read(m * MIB, MIB))           # original block from super.img
        for o, (ob, nb) in prior.items():
            if o >> 20 == m:
                ref[o & (MIB - 1)] = nb
        # Pull the block as it is on the terminal and patch THAT (other bytes in the same
        # 1 MiB may legitimately differ, e.g. filesystem bookkeeping written by Android).
        T.sh(adbexe, f'{T.RKIO} r {T.PART} {T.OFFSET_MIB + m} 1 > {T.TMP} 2>/dev/null')
        T.adb(adbexe, 'pull', T.TMP, tmp)
        blk = bytearray(open(tmp, 'rb').read())
        if len(blk) != MIB:
            sys.exit(f'MiB {m}: could not read the block from the terminal - stopping')
        ndiff = sum(1 for a, b in zip(blk, ref) if a != b)
        bad = [o for o, (ob, nb) in edits.items() if o >> 20 == m and blk[o & (MIB - 1)] not in (ob, nb)]
        if bad:
            sys.exit(f'MiB {m}: {len(bad)} target bytes are not the expected original values '
                     f'(first at {hex(bad[0])}) - stopping, nothing written')
        if ndiff:
            pages = sorted({(i >> 12) for i, (a, b) in enumerate(zip(blk, ref)) if a != b})
            print(f'MiB {m}: note - {ndiff} bytes differ from super.img in 4K page(s) {pages[:8]}'
                  f'{"..." if len(pages) > 8 else ""} (left as they are on the terminal)')
        for o, (ob, nb) in edits.items():
            if o >> 20 == m:
                blk[o & (MIB - 1)] = nb
        open(tmp, 'wb').write(bytes(blk))
        T.adb(adbexe, 'push', tmp, T.TMP, check_out='pushed')
        T.sh(adbexe, f'{T.RKIO} w {T.TMP} {T.PART} {T.OFFSET_MIB + m}')
        back = T.sh(adbexe, f'{T.RKIO} r {T.PART} {T.OFFSET_MIB + m} 1 2>/dev/null | busybox md5sum').split()[0]
        ok = back == hashlib.md5(bytes(blk)).hexdigest()
        print(f'MiB {m}: patched, read back {"OK" if ok else "MISMATCH"}')
        if not ok: sys.exit('read-back mismatch - stopping')
    os.remove(tmp)
    print('DONE - patch applied')

def walk(fs, ino, path, depth):
    for name, (n, ft) in fs.listdir(ino).items():
        if name in ('.', '..'): continue
        p = f'{path}/{name}'
        if ft == 2:
            if depth > 0: yield from walk(fs, n, p, depth - 1)
        elif ft == 1:
            yield p, n

def find(path, outzip, texts):
    img = Img(path); parts = lp_partitions(img)
    z = zipfile.ZipFile(outzip, 'w', zipfile.ZIP_STORED)
    roots = {'system': ['system/app', 'system/priv-app', 'system/framework'],
             'product': ['app', 'priv-app', 'framework'],
             'vendor': ['app', 'priv-app', 'framework'], 'odm': ['app', 'priv-app']}
    report = []
    for pname, dirs in roots.items():
        if pname not in parts: continue
        fs = Ext4(Part(img, parts[pname]))
        c, i, r = fs.feat
        report.append(f'## {pname}: ext4 compat={c:#x} incompat={i:#x} ro_compat={r:#x} '
                      f'metadata_csum={bool(r & 0x400)} shared_blocks={bool(r & 0x4000)}')
        for d in dirs:
            n = fs.lookup(d)
            if n is None: continue
            for fp, fino in walk(fs, n, d, 3):
                if not fp.endswith(('.apk', '.jar', '.vdex', '.odex', '.dex')): continue
                ino = fs.inode(fino)
                size = struct.unpack('<I', ino[4:8])[0]
                report.append(f'{pname}/{fp}  {size}')
                data = fs.data(ino)
                blobs = [data]
                if fp.endswith(('.apk', '.jar')):
                    try:
                        zz = zipfile.ZipFile(io.BytesIO(data))
                        blobs += [zz.read(m) for m in zz.namelist() if m.endswith('.dex')]
                    except Exception as e:
                        report.append(f'   (zip error {e})')
                hits = [t for t in texts if any(t.encode() in b for b in blobs)]
                if hits:
                    msg = f'MATCH {pname}/{fp} ({size} bytes): {hits}'
                    print(msg); report.append(msg)
                    if size < 150 * MIB:
                        z.writestr(f'{pname}/{fp}', data)
                    else:
                        report.append('   (too big, not saved)')
        print(f'{pname}: searched')
    z.writestr('_report.txt', '\n'.join(report))
    z.close()
    print('wrote', outzip, os.path.getsize(outzip), 'bytes')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if sys.argv[1] == 'patch':
        patch(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == 'find':
        find(sys.argv[2], sys.argv[3], sys.argv[4:])
    else:
        main(sys.argv[1], sys.argv[2])
