#!/usr/bin/env python3
"""Write a boot image to the Citaq H10-3's boot or recovery slot over adb - with checks.

usage: flash_slot.py <adb> <boot|recovery> <image.img> [--yes]

  recovery   test slot: `adb reboot recovery` boots it, a plain power-on still boots stock.
  boot       default slot: every normal power-on / reboot boots it.

What it does, in order (stops at the first problem, before anything is written):
  1. adb root, works out whether the terminal is on stock Android 5.1 or the Android 10 port
  2. checks the slot is where it should be:
       stock 5.1  - /dev/block/platform/ff0f0000.rksdmmc/by-name/<slot> must start at the expected sector
       Android 10 - the slot must currently hold a boot image (ANDROID! or Rockchip KRNL header)
  3. backs the slot up to the PC (<slot>-backup-<time>.img) - keep these!
  4. pushes the image, MD5-checks it on the terminal, asks you to confirm
  5. dd to the eMMC, reads it back and compares MD5s

Slot positions on the 16 GB Citaq H10-3 (16 KiB blocks of /dev/block/mmcblk0):
  boot     block 3328, 32 MiB      recovery  block 5376, 32 MiB
(Rockchip parameter offsets + the 0x2000-sector base; both checked live on hardware.)
"""
import datetime
import hashlib
import os
import functools
import shutil
import subprocess
import sys

BLK = 16384
SLOTS = {'boot': 3328, 'recovery': 5376}
SLOT_BLOCKS = 2048                 # 32 MiB each
DEV = '/dev/block/mmcblk0'
BYNAME = '/dev/block/platform/ff0f0000.rksdmmc/by-name'
TMP = '/data/local/tmp/flash_slot.img'



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

def run(adbexe, *args):
    r = subprocess.run([find_adb(adbexe), *args], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def sh(adbexe, cmd):
    out = run(adbexe, 'shell', cmd + ' && echo __OK__')
    if '__OK__' not in out:
        sys.exit(f'terminal command failed:\n  {cmd}\n{out}')
    return out.replace('__OK__', '').strip()


def main():
    a = [x for x in sys.argv[1:] if x != '--yes']
    yes = '--yes' in sys.argv
    if len(a) != 3 or a[1] not in SLOTS:
        sys.exit(__doc__)
    adbexe, slot, image = a
    blk = SLOTS[slot]
    img = open(image, 'rb').read()
    if img[:8] != b'ANDROID!' and img[:4] != b'KRNL':
        sys.exit(f'{image} is not a boot image (no ANDROID! or Rockchip KRNL header)')
    if len(img) % BLK or len(img) // BLK > SLOT_BLOCKS:
        sys.exit(f'{image}: {len(img)} bytes - must be whole 16 KiB blocks and at most 32 MiB')
    nblk = len(img) // BLK
    want = hashlib.md5(img).hexdigest()

    if 'device' not in run(adbexe, 'get-state'):
        sys.exit('no adb device')
    run(adbexe, 'root'); run(adbexe, 'wait-for-device')
    if 'uid=0(' not in sh(adbexe, 'id'):
        sys.exit('adb is not root (adb root failed)')
    rel = sh(adbexe, 'getprop ro.build.version.release')
    bb = 'busybox ' if sh(adbexe, 'command -v busybox >/dev/null && echo yes || echo none') == 'yes' else ''
    print(f'terminal: Android {rel}; slot {slot} = {DEV} block {blk} (x16 KiB)')

    # 2. is the slot where we think it is?
    link = f'{BYNAME}/{slot}'
    if sh(adbexe, f'[ -L {link} ] && echo yes || echo no') == 'yes':
        part = os.path.basename(sh(adbexe, f'{bb}readlink {link}'))
        start = int(sh(adbexe, f'cat /sys/class/block/{part}/start'))
        if start * 512 != blk * BLK:
            sys.exit(f'{link} = {part} starts at sector {start}, expected {blk * BLK // 512} - stopping')
        print(f'  {link} -> {part}, start sector {start}: matches')
    else:
        head = sh(adbexe, f'{bb}dd if={DEV} bs={BLK} skip={blk} count=1 2>/dev/null | head -c 8')
        if head != 'ANDROID!' and not head.startswith('KRNL'):
            sys.exit(f'no boot image found at block {blk} (header {head!r}) - stopping')
        print(f'  block {blk} holds a boot image ({head[:8]!r}): OK')

    # 3. backup
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    bak = f'{slot}-backup-{stamp}.img'
    n = 1
    while os.path.exists(bak):                     # never overwrite an earlier backup
        bak = f'{slot}-backup-{stamp}-{n}.img'; n += 1
    sh(adbexe, f'{bb}dd if={DEV} of={TMP} bs={BLK} skip={blk} count={SLOT_BLOCKS} 2>/dev/null')
    run(adbexe, 'pull', TMP, bak)
    if not os.path.exists(bak) or os.path.getsize(bak) != SLOT_BLOCKS * BLK:
        sys.exit('backup pull failed - stopping, nothing written')
    print(f'  backed up the current {slot} slot to {bak} (md5 {hashlib.md5(open(bak, "rb").read()).hexdigest()})')

    # 4. push + check
    out = run(adbexe, 'push', image, TMP)
    if 'pushed' not in out and 'file pushed' not in out and '1 file' not in out:
        sys.exit(f'push failed:\n{out}')
    got = sh(adbexe, f'{bb}md5sum {TMP}').split()[0]
    if got != want:
        sys.exit(f'pushed image md5 {got} != {want} - stopping, nothing written')
    print(f'  image pushed, md5 {want} ({nblk} blocks)')
    if not yes:
        r = input(f'Write {os.path.basename(image)} to the {slot} slot now? type yes: ')
        if r.strip().lower() != 'yes':
            sys.exit('not written')

    # 5. write + verify
    sh(adbexe, f'{bb}dd if={TMP} of={DEV} bs={BLK} seek={blk} conv=notrunc 2>/dev/null && sync')
    back = sh(adbexe, f'{bb}dd if={DEV} bs={BLK} skip={blk} count={nblk} 2>/dev/null | {bb}md5sum').split()[0]
    sh(adbexe, f'rm {TMP}')
    if back != want:
        sys.exit(f'READ-BACK MISMATCH ({back} != {want}). Do not reboot - write the backup {bak} back '
                 f'with this script and check the docs.')
    print(f'DONE - {slot} slot written and verified. Roll back with: flash_slot.py {adbexe} {slot} {bak}')


if __name__ == '__main__':
    main()
