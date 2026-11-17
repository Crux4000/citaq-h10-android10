#!/usr/bin/env python3
"""Install the boot hook and helpers into /data/citaq on the Android 10 port, over adb.

usage: install_data.py <adb> <dir>

<dir> must hold (build them first, see docs/INSTALL.md):
  citaq-boot.sh      device/citaq-boot.sh             -> /data/citaq/ilits (the boot hook)
  ilits.bin          src/build.sh                     -> touch daemon
  bcmdhd.ko          docs/WIFI.md (release download)   -> Wi-Fi driver
  blshim volshim propset                               -> brightness / volume / serial helpers
  thermalstub.jar    src/thermalstub/build.sh          -> stand-in thermalservice for Google Play
  bootlogo.png       optional, 1024x768 boot logo

Run it on the Android 10 port (not stock 5.1): /data is the port's own userdata, and it is
wiped clean the first time Android 10 boots - so this step comes after that first boot,
and again after any factory reset. Missing optional files are skipped; missing required ones stop it.
"""
import hashlib
import os
import subprocess
import sys

REQUIRED = ['citaq-boot.sh', 'ilits.bin', 'bcmdhd.ko', 'blshim', 'volshim', 'propset', 'thermalstub.jar']
OPTIONAL = ['bootlogo.png']
TARGET = {'citaq-boot.sh': 'ilits'}          # init's akmd service runs /data/citaq/ilits
EXEC = {'citaq-boot.sh', 'ilits.bin', 'blshim', 'volshim', 'propset'}


def run(adbexe, *args):
    r = subprocess.run([adbexe, *args], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def sh(adbexe, cmd):
    out = run(adbexe, 'shell', cmd + ' && echo __OK__')
    if '__OK__' not in out:
        sys.exit(f'terminal command failed:\n  {cmd}\n{out}')
    return out.replace('__OK__', '').strip()


def main():
    a = sys.argv[1:]
    if len(a) != 2:
        sys.exit(__doc__)
    adbexe, src = a
    missing = [f for f in REQUIRED if not os.path.exists(os.path.join(src, f))]
    if missing:
        sys.exit(f'missing in {src}: {", ".join(missing)}')
    if 'device' not in run(adbexe, 'get-state'):
        sys.exit('no adb device')
    run(adbexe, 'root'); run(adbexe, 'wait-for-device')
    if 'uid=0(' not in sh(adbexe, 'id'):
        sys.exit('adb is not root (adb root failed)')
    rel = sh(adbexe, 'getprop ro.build.version.release')
    if not rel.startswith('10'):
        sys.exit(f'terminal is running Android {rel} - boot the Android 10 port first')
    sh(adbexe, 'mkdir -p /data/citaq')
    for f in REQUIRED + [o for o in OPTIONAL if os.path.exists(os.path.join(src, o))]:
        local = os.path.join(src, f)
        dst = '/data/citaq/' + TARGET.get(f, f)
        want = hashlib.md5(open(local, 'rb').read()).hexdigest()
        run(adbexe, 'push', local, dst)
        got = sh(adbexe, f'md5sum {dst}').split()[0]
        if got != want:
            sys.exit(f'{f}: md5 mismatch after push ({got} != {want})')
        sh(adbexe, f'chmod {"755" if f in EXEC else "644"} {dst}')
        print(f'{f:16s} -> {dst}  ok')
    print('done. Reboot into Android 10 to start the boot hook:\n'
          '  adb reboot recovery   (while Android 10 is only in the recovery slot)\n'
          '  adb reboot            (once it is the default boot)')


if __name__ == '__main__':
    main()
