#!/usr/bin/env python3
"""Copy the PX5 Android 10 super.img into the Citaq H10-3's eMMC "user" area, over adb.

Target: p16 ("user", 8.63 GiB) of the eMMC (/dev/block/mmcblk0p16 on stock), starting 1024 MiB in,
i.e. after the 1 GiB that stays as stock Android's internal storage. Region size 3112 MiB
(= the PX5 super partition, 0x614000 sectors).

Works on a sparse (3A FF 26 ED) or raw super.img. Unpacks on the PC and sends it in
128 MiB pieces (stock Android only has ~1.6 GB free in /data). All-zero pieces are written
on the terminal instead of being pushed. Every piece is MD5-checked on the terminal
before it is written, and the whole region is MD5-checked at the end.

  python super_to_citaq.py check  <super.img>
  python super_to_citaq.py write  <super.img> <adb> [--start N]
  python super_to_citaq.py nofbe  <super.img> [<adb>]   (find / patch out file encryption)
  python super_to_citaq.py zero   <adb>     (blank the start of metadata..cache and userdata)
  python super_to_citaq.py verify <super.img> <adb>

Run from STOCK Android 5.1 (adb root). "check" only reads the PC file. Everything that
writes runs a preflight first and refuses unless: p16 starts and ends exactly where the
16 GB Citaq H10-3 layout says, and the terminal's internal storage has already been
shrunk to <= 1 GiB (so stock Android can never write into the super region).
Needs the static arm64 `rkio` helper (src/rkio.c) next to this script.

Known-good super.img (CHS7_PX5_10.0_IMG(20200603)): unpacks to exactly 3112 MiB,
whole-region MD5 db834dc68c97662488718f9cd9ca0495.
"""
import sys, os, struct, hashlib, subprocess, shutil, functools

PART = '/dev/block/mmcblk0p16'     # set by locate(): the eMMC is not always mmcblk0
P16_START = 12443648             # 6076 MiB: Rockchip parameter offsets are relative to sector 0x2000 (+4 MiB)
P16_SECTORS = 18092032           # 8834 MiB, runs to the end of the eMMC (14910 MiB). A bigger p16 (some
                                 # eMMCs are a little larger) is fine: everything Android 10 uses ends at 14910 MiB
OFFSET_MIB = 1024                # super starts 1 GiB into p16
REGION_MIB = 3112                # 0x614000 sectors
PIECE_MIB = 128
MIB = 1 << 20
TMP = '/data/local/tmp/super.part'
RKIO = '/data/local/tmp/rkio'    # static arm64 helper: the stock busybox dd can't seek past 2 GiB

def raw_stream(path):
    """Yield the unpacked (raw) image as byte blocks; also returns total size via first yield."""
    f = open(path, 'rb')
    hdr = f.read(28)
    magic, maj, mnr, fhs, chs, bs, tblk, tchk, _ = struct.unpack('<IHHHHIIII', hdr)
    if magic != 0xED26FF3A:
        f.seek(0, 2); size = f.tell(); f.seek(0)
        yield ('raw', size)
        while True:
            b = f.read(8 * MIB)
            if not b: return
            yield b
    yield ('sparse', bs * tblk)
    f.seek(fhs)
    for _ in range(tchk):
        ch = f.read(chs)
        ctype, _, csz, tsz = struct.unpack('<HHII', ch[:12])
        n = csz * bs
        if ctype == 0xCAC1:                      # RAW
            left = n
            while left:
                b = f.read(min(left, 8 * MIB)); left -= len(b); yield b
        elif ctype == 0xCAC2:                    # FILL
            pat = f.read(4)
            blk = pat * (MIB // 4)
            left = n
            while left:
                k = min(left, MIB); left -= k; yield blk[:k]
        elif ctype == 0xCAC3:                    # DONT_CARE -> zeros
            z = bytes(MIB); left = n
            while left:
                k = min(left, MIB); left -= k; yield z[:k]
        elif ctype == 0xCAC4:                    # CRC32
            f.read(4)
        else:
            sys.exit(f'unknown sparse chunk type {ctype:#x}')

def pieces(path):
    """Yield (index, bytes) of PIECE_MIB pieces covering the whole region (zero-padded)."""
    g = raw_stream(path)
    kind, size = next(g)
    if size > REGION_MIB * MIB:
        sys.exit(f'image unpacks to {size} bytes, bigger than the {REGION_MIB} MiB region')
    print(f'{kind} image, unpacks to {size:,} bytes; region {REGION_MIB} MiB')
    buf = bytearray(); idx = 0; total = REGION_MIB * MIB; done = 0
    for b in g:
        buf += b
        while len(buf) >= PIECE_MIB * MIB:
            yield idx, bytes(buf[:PIECE_MIB * MIB]); del buf[:PIECE_MIB * MIB]
            idx += 1; done += PIECE_MIB * MIB
    # pad the rest of the region with zeros
    while done < total:
        want = min(PIECE_MIB * MIB, total - done)
        buf += bytes(want - len(buf))
        yield idx, bytes(buf[:want]); del buf[:want]
        idx += 1; done += want


@functools.lru_cache(maxsize=None)
def find_adb(name):
    """The adb argument as given, or found on PATH. Accepts the docs' ADB placeholder on Linux/macOS too."""
    if os.path.isfile(name):
        return name
    for n in (name, name.lower()):
        p = shutil.which(n)
        if p:
            return p
    sys.exit(f'adb not found: "{name}". Put adb on your PATH or give its full path '
             '(e.g. C:\\platform-tools\\adb.exe or ~/platform-tools/adb).')

def adb(adbexe, *args, check_out=None):
    r = subprocess.run([find_adb(adbexe), *args], capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if check_out and check_out not in out:
        sys.exit(f'adb {" ".join(args)} failed:\n{out}')
    return out

RESUME = None

def sh(adbexe, cmd, marker='__OK__'):
    out = adb(adbexe, 'shell', cmd + f' && echo {marker}')
    if marker not in out:
        hint = f'\nResume with: --start {RESUME}' if RESUME is not None else ''
        sys.exit(f'terminal command failed:\n  {cmd}\n{out}{hint}')
    return out.replace(marker, '').strip()

def region_md5_local(path):
    h = hashlib.md5()
    for _, p in pieces(path): h.update(p)
    return h.hexdigest()

FIND_EMMC = 'for b in /sys/block/mmcblk*; do n=${b##*/}; case $n in *boot*|*rpmb*) continue;; esac; [ "$(cat $b/device/type 2>/dev/null)" = MMC ] && echo $n; done'

def locate(adbexe):
    """Point PART at p16 of the terminal's eMMC, whatever mmcblk number it got."""
    global PART
    found = sh(adbexe, FIND_EMMC + '; true').split()
    if len(found) != 1:
        sys.exit(f'expected exactly one eMMC, found {found or "none"} - stopping')
    PART = f'/dev/block/{found[0]}p16'
    return PART

def preflight(adbexe):
    if 'device' not in adb(adbexe, 'get-state'):
        sys.exit('no adb device')
    adb(adbexe, 'root'); adb(adbexe, 'wait-for-device')
    locate(adbexe)
    sec = int(sh(adbexe, f'cat /sys/class/block/{os.path.basename(PART)}/size').split()[-1])
    if sec < P16_SECTORS:
        sys.exit(f'{PART} is {sec} sectors, smaller than the expected {P16_SECTORS} - stopping')
    if sec > P16_SECTORS:
        print(f'{PART} is {sec} sectors, {(sec - P16_SECTORS) * 512 // MIB} MiB bigger than the 16 GB '
              'reference unit - fine, the extra stays unused')
    st = sh(adbexe, f'cat /sys/class/block/{os.path.basename(PART)}/start')
    if int(st.split()[-1]) != P16_START:
        sys.exit(f'{PART} starts at sector {st}, expected {P16_START} - the Android 10 '
                 'partition map would be wrong - stopping')
    # busybox df needs /etc/mtab (missing on Android 5) and this busybox has no stat;
    # Android's own df prints e.g. "/mnt/internal_sd  1023.0M  24.0K  1023.0M  8192".
    line = [l for l in sh(adbexe, 'df /mnt/internal_sd').splitlines() if 'internal_sd' in l][-1]
    size = line.split()[1]
    kb = int(float(size[:-1]) * {'K': 1, 'M': 1024, 'G': 1024 * 1024}[size[-1].upper()])
    if kb < 100 * 1024:
        sys.exit(f'internal storage reads {kb} KB - is it mounted? stopping')
    if kb > 1024 * 1024:
        sys.exit(f'internal storage is still {kb} KB (> 1 GiB). Shrink it first - stopping')
    print(f'p16 OK ({PART}, start {P16_START}), internal storage {kb} KB - safe to write')
    push_rkio(adbexe)

def push_rkio(adbexe):
    local = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rkio')
    if not os.path.exists(local):
        sys.exit(f'rkio helper not found next to this script ({local}) - build src/rkio.c first')
    adb(adbexe, 'push', local, RKIO, check_out='pushed')
    sh(adbexe, f'chmod 755 {RKIO}')

def write(path, adbexe, start=0):
    preflight(adbexe)
    tmp = os.path.join(os.path.dirname(os.path.abspath(path)), 'super.part.tmp')
    n = REGION_MIB // PIECE_MIB + (1 if REGION_MIB % PIECE_MIB else 0)
    global RESUME
    for idx, p in pieces(path):
        if idx < start: continue
        RESUME = idx
        cnt = len(p) // MIB
        seek = OFFSET_MIB + idx * PIECE_MIB
        if p.count(0) == len(p):
            sh(adbexe, f'{RKIO} z {PART} {seek} {cnt}')
            print(f'piece {idx + 1}/{n}: zeros written on the terminal (seek {seek} MiB)')
            continue
        md5 = hashlib.md5(p).hexdigest()
        open(tmp, 'wb').write(p)
        adb(adbexe, 'push', tmp, TMP, check_out='pushed')
        got = sh(adbexe, f'busybox md5sum {TMP}').split()[0]
        if got != md5:
            sys.exit(f'piece {idx}: md5 mismatch after push ({got} != {md5}). Re-run with --start {idx}')
        print(f'piece {idx + 1}/{n}: pushed, writing...', end='\r')
        sh(adbexe, f'{RKIO} w {TMP} {PART} {seek}')
        sh(adbexe, f'rm {TMP}')
        print(f'piece {idx + 1}/{n}: {cnt} MiB written at {seek} MiB, md5 {md5}')
    os.remove(tmp) if os.path.exists(tmp) else None
    RESUME = None
    verify(path, adbexe)

def verify(path, adbexe):
    print('MD5 of the whole region on the PC...')
    local = region_md5_local(path)
    print('MD5 of the whole region on the terminal (about a minute)...')
    locate(adbexe)
    push_rkio(adbexe)
    remote = sh(adbexe, f'{RKIO} r {PART} {OFFSET_MIB} {REGION_MIB} 2>/dev/null | busybox md5sum').split()[0]
    print(f'PC       {local}\nterminal {remote}')
    print('MATCH - super is in place' if local == remote else 'MISMATCH - do not boot it, re-run write')

FBE_OLD = b'fileencryption=software'
FBE_NEW = b'check,check,check,check'      # same length; 'check' is already in those lines

def find_fbe(path):
    """Offsets (from the start of the super region) of fileencryption=software inside
    uncommented /data fstab lines."""
    hits = []; base = 0; tail = b''
    for _, p in pieces(path):
        buf = tail + p; start = base - len(tail)
        i = buf.find(FBE_OLD)
        while i >= 0:
            ls = buf.rfind(b'\n', 0, i) + 1
            le = buf.find(b'\n', i)
            line = buf[ls:le if le >= 0 else i + 200]
            if b'/data' in line and not line.lstrip().startswith(b'#'):
                off = start + i
                if off not in [h[0] for h in hits]:
                    hits.append((off, line.decode('latin-1')))
            i = buf.find(FBE_OLD, i + 1)
        tail = buf[-4096:]; base += len(p)
    return hits

def nofbe(path, adbexe):
    print('scanning the image for the /data encryption flag (about a minute)...')
    hits = find_fbe(path)
    for off, line in hits:
        print(f'  at {off:#x} (MiB {off >> 20}): {line}')
    if not hits:
        sys.exit('nothing found - is this the right super.img?')
    if not adbexe:
        return
    preflight(adbexe)
    mibs = sorted({off >> 20 for off, _ in hits} | {(off + len(FBE_OLD) - 1) >> 20 for off, _ in hits})
    want = set(mibs); blocks = {}
    for idx, p in pieces(path):
        for m in list(want):
            lo = m - idx * PIECE_MIB
            if 0 <= lo < PIECE_MIB:
                blocks[m] = bytearray(p[lo * MIB:(lo + 1) * MIB]); want.discard(m)
        if not want: break
    for off, _ in hits:
        for k in range(len(FBE_OLD)):
            a = off + k; blk = blocks[a >> 20]
            assert blk[a & (MIB - 1)] == FBE_OLD[k]
            blk[a & (MIB - 1)] = FBE_NEW[k]
    tmp = os.path.join(os.path.dirname(os.path.abspath(path)), 'fbe.part.tmp')
    for m, blk in blocks.items():
        old = sh(adbexe, f'{RKIO} r {PART} {OFFSET_MIB + m} 1 2>/dev/null | busybox md5sum').split()[0]
        orig = hashlib.md5(next(p for i, p in pieces_mib(path, m))).hexdigest()
        if old != orig:
            sys.exit(f'MiB {m} on the terminal does not match the image ({old} != {orig}) - stopping')
        open(tmp, 'wb').write(bytes(blk))
        adb(adbexe, 'push', tmp, TMP, check_out='pushed')
        sh(adbexe, f'{RKIO} w {TMP} {PART} {OFFSET_MIB + m}')
        new = sh(adbexe, f'{RKIO} r {PART} {OFFSET_MIB + m} 1 2>/dev/null | busybox md5sum').split()[0]
        ok = new == hashlib.md5(bytes(blk)).hexdigest()
        print(f'MiB {m}: patched, read back {"OK" if ok else "MISMATCH"}')
        if not ok: sys.exit('read-back mismatch - stopping')
    os.remove(tmp)
    print('DONE - file encryption flag removed from the /data line(s)')

def pieces_mib(path, m):
    for idx, p in pieces(path):
        lo = m - idx * PIECE_MIB
        if 0 <= lo < PIECE_MIB:
            yield m, p[lo * MIB:(lo + 1) * MIB]; return

if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] not in ('check', 'write', 'verify', 'zero', 'nofbe'):
        sys.exit(__doc__)
    if a[0] == 'check':
        g = raw_stream(a[1]); kind, size = next(g)
        print(f'{a[1]}: {kind}, unpacks to {size:,} bytes ({size / MIB:.1f} MiB); region {REGION_MIB} MiB')
        print('fits' if size <= REGION_MIB * MIB else 'DOES NOT FIT')
        print('whole-region MD5 (for later):', region_md5_local(a[1]))
    elif a[0] == 'write':
        start = int(a[a.index('--start') + 1]) if '--start' in a else 0
        write(a[1], a[2], start)
    elif a[0] == 'nofbe':
        nofbe(a[1], a[2] if len(a) > 2 else None)
    elif a[0] == 'zero':
        # p16-relative: metadata/misc/frp/security + first 16 MiB of cache = 4136..4180,
        # userdata first 16 MiB = 4548..4564. Super (1024..4136) is not touched.
        preflight(a[1])
        sh(a[1], f'{RKIO} z {PART} 4136 44 && {RKIO} z {PART} 4548 16')
        print('ZEROED metadata/misc/frp/security/cache start and userdata start')
    else:
        verify(a[1], a[2])
