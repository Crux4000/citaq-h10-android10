#!/usr/bin/env python3
"""Copy the stock Citaq device tree (DTB) off a terminal, read-only.

usage: dump_stock_dtb.py <adb> [out_dir]

The stock Android 5.1 kernel reads its DTB from the `resource` partition (a Rockchip RSCE
package holding rk-kernel.dtb and the boot logos). Installing the Android 10 port never writes
to that partition, so the stock DTB is still there afterwards. Comparing it with another
terminal's shows whether two boards are wired the same (sound codec, Wi-Fi/Bluetooth power
and clock pins, panel, touch), which is the first thing to check when something works on one
terminal and not on another.

  stock 5.1  - reads /dev/block/platform/ff0f0000.rksdmmc/by-name/resource
  Android 10 - reads the same place by position: 20 MiB into the eMMC, 16 MiB long
               (the stock layout; the boot slot at 52 MiB and recovery at 84 MiB follow it)

Nothing is written to the terminal except a temporary copy in /data/local/tmp, which is removed.
Writes <out_dir>/resource.img and <out_dir>/rk-kernel.dtb, plus rk-kernel.dts if `dtc` is installed.
"""
import functools
import hashlib
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rkbootimg import rsce_unpack

MIB = 1 << 20
RESOURCE_MIB, RESOURCE_SIZE_MIB = 20, 16
BYNAME = '/dev/block/platform/ff0f0000.rksdmmc/by-name/resource'
TMP = '/data/local/tmp/resource.img'


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
    r = subprocess.run([find_adb(adbexe), *args], capture_output=True, encoding='utf-8', errors='replace')
    return (r.stdout + r.stderr).strip()


def sh(adbexe, cmd):
    out = run(adbexe, 'shell', cmd + ' && echo __OK__')
    if '__OK__' not in out:
        sys.exit(f'terminal command failed:\n  {cmd}\n{out}')
    return out.replace('__OK__', '').strip()


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    adbexe = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) == 3 else 'stock-dtb'
    os.makedirs(out_dir, exist_ok=True)

    if 'device' not in run(adbexe, 'get-state'):
        sys.exit('no adb device')
    run(adbexe, 'root'); run(adbexe, 'wait-for-device')
    if 'uid=0(' not in sh(adbexe, 'id'):
        sys.exit('adb is not root (adb root failed)')
    rel = sh(adbexe, 'getprop ro.build.version.release')
    bb = 'busybox ' if sh(adbexe, 'command -v busybox >/dev/null && echo yes || echo none') == 'yes' else ''

    if sh(adbexe, f'[ -e {BYNAME} ] && echo yes || echo no') == 'yes':
        src, how = BYNAME, f'{bb}dd if={BYNAME} of={TMP} bs=1048576 2>/dev/null'
    else:
        emmc = sh(adbexe, 'for b in /sys/block/mmcblk*; do n=${b##*/}; case $n in *boot*|*rpmb*) continue;; '
                          'esac; [ "$(cat $b/device/type 2>/dev/null)" = MMC ] && echo $n; done; true').split()
        if len(emmc) != 1:
            sys.exit(f'expected exactly one eMMC, found {emmc or "none"} - stopping')
        src = f'/dev/block/{emmc[0]} at {RESOURCE_MIB} MiB'
        how = (f'{bb}dd if=/dev/block/{emmc[0]} of={TMP} bs=1048576 skip={RESOURCE_MIB} '
               f'count={RESOURCE_SIZE_MIB} 2>/dev/null')
    print(f'terminal: Android {rel}; reading the stock resource partition from {src}')

    sh(adbexe, how)
    local = os.path.join(out_dir, 'resource.img')
    run(adbexe, 'pull', TMP, local)
    sh(adbexe, f'rm -f {TMP}')
    if not os.path.exists(local):
        sys.exit('pull failed')
    data = open(local, 'rb').read()
    if data[:4] != b'RSCE':
        sys.exit(f'no Rockchip resource package there (starts {data[:8].hex(" ")}). This terminal\'s '
                 'partition layout differs from the reference unit - please report it with /proc/partitions.')

    entries = rsce_unpack(data)
    print('resource entries: ' + ', '.join(f'{n} ({len(b):,} B)' for n, b in entries))
    dtbs = [(n, b) for n, b in entries if n.endswith('.dtb')]
    if not dtbs:
        sys.exit('no .dtb in the resource package')
    for name, body in dtbs:
        path = os.path.join(out_dir, name)
        open(path, 'wb').write(body)
        print(f'  {path}: {len(body):,} bytes, md5 {hashlib.md5(body).hexdigest()}')
        if shutil.which('dtc'):
            dts = path[:-4] + '.dts'
            r = subprocess.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', '-o', dts, path],
                               capture_output=True, text=True)
            print(f'  {dts}: written' if r.returncode == 0 else f'  dtc failed: {r.stderr.strip()}')
    print('Done. Attach the .dtb (or .dts) to your issue so it can be compared with the reference unit\'s.')


if __name__ == '__main__':
    main()
