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
  qmidial            optional, src/build.sh: QMI data for the Fibocom NL668 (docs/MODEM.md, mobile-data-qmi)
  BCM4345C5.hcd      optional, Bluetooth firmware for the AP6256 (docs/BLUETOOTH.md) -> /data/citaq/bt/
  BCM4345C0.hcd      optional, Bluetooth firmware for the AP6255                    -> /data/citaq/bt/
  bt_vendor.conf     optional, device/bt/bt_vendor.conf                             -> /data/citaq/bt/
                     (Bluetooth is installed when bt_vendor.conf and at least one .hcd are there -
                     put both .hcd files in and the Bluetooth library picks the one matching the
                     chip it finds; the ROM's own rtkbt.conf
                     is copied in next to them, because the boot hook bind-mounts the folder
                     over /vendor/etc/bluetooth)

Run it on the Android 10 port (not stock 5.1): /data is the port's own userdata, and it is
wiped clean the first time Android 10 boots - so this step comes after that first boot,
and again after any factory reset. Missing optional files are skipped; missing required ones stop it.
"""
import hashlib
import os
import functools
import shutil
import subprocess
import sys

REQUIRED = ['citaq-boot.sh', 'ilits.bin', 'bcmdhd.ko', 'blshim', 'volshim', 'propset', 'thermalstub.jar']
OPTIONAL = ['bootlogo.png', 'qmidial']
BT_CONF = 'bt_vendor.conf'
BT_HCD_MD5 = {                                       # Citaq fits either Wi-Fi/BT module
    'BCM4345C5.hcd': 'fc394331d03baa5847e2b5de94ffbc9b',   # AP6256; armbian/firmware bf5f7a8, 45,667 bytes
    'BCM4345C0.hcd': 'd6313cb3835f7645240e2ad63ff152ab',   # AP6255; armbian/firmware db8cc45, 65,570 bytes
}
BT_DIR = '/data/citaq/bt'
TARGET = {'citaq-boot.sh': 'ilits'}          # init's akmd service runs /data/citaq/ilits
EXEC = {'citaq-boot.sh', 'ilits.bin', 'blshim', 'volshim', 'propset', 'qmidial'}



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


def md5(path):
    return hashlib.md5(open(path, 'rb').read()).hexdigest()


def push(adbexe, local, dst, mode):
    want = md5(local)
    run(adbexe, 'push', local, dst)
    got = sh(adbexe, f'md5sum {dst}').split()[0]
    if got != want:
        sys.exit(f'{os.path.basename(local)}: md5 mismatch after push ({got} != {want})')
    sh(adbexe, f'chmod {mode} {dst}')
    print(f'{os.path.basename(local):16s} -> {dst}  ok')


def check_bt(src):
    """The Bluetooth files to install ([] if none); stops on a half set or a wrong .hcd."""
    hcds = [f for f in BT_HCD_MD5 if os.path.exists(os.path.join(src, f))]
    conf = os.path.exists(os.path.join(src, BT_CONF))
    if not hcds and not conf:
        return []
    if not conf or not hcds:
        sys.exit(f'bluetooth needs {BT_CONF} and at least one of {" / ".join(BT_HCD_MD5)} in {src}')
    for f in hcds:
        if md5(os.path.join(src, f)) != BT_HCD_MD5[f]:
            sys.exit(f'{f} is not the expected file (md5 should be {BT_HCD_MD5[f]})')
    return hcds + [BT_CONF]


def install_bt(adbexe, src, files):
    sh(adbexe, f'mkdir -p {BT_DIR}')
    for f in files:
        push(adbexe, os.path.join(src, f), f'{BT_DIR}/{f}', '644')
    # The bind mount hides the ROM's /vendor/etc/bluetooth, so keep its rtkbt.conf. On a re-run the
    # mount is already active and the file is already in BT_DIR.
    sh(adbexe, f'[ -f {BT_DIR}/rtkbt.conf ] || cp /vendor/etc/bluetooth/rtkbt.conf {BT_DIR}/')
    sh(adbexe, f'chmod 755 {BT_DIR}; chmod 644 {BT_DIR}/*; chcon -R u:object_r:vendor_configs_file:s0 {BT_DIR}')
    print(f'rtkbt.conf       -> {BT_DIR}/rtkbt.conf  ok')


def main():
    a = sys.argv[1:]
    if len(a) != 2:
        sys.exit(__doc__)
    adbexe, src = a
    missing = [f for f in REQUIRED if not os.path.exists(os.path.join(src, f))]
    if missing:
        sys.exit(f'missing in {src}: {", ".join(missing)}')
    bt = check_bt(src)
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
        push(adbexe, os.path.join(src, f), '/data/citaq/' + TARGET.get(f, f), '755' if f in EXEC else '644')
    if bt:
        install_bt(adbexe, src, bt)
    else:
        print('bluetooth        skipped (no .hcd / bt_vendor.conf)')
    print('done. Reboot into Android 10 to start the boot hook:\n'
          '  adb reboot recovery   (while Android 10 is only in the recovery slot)\n'
          '  adb reboot            (once it is the default boot)')


if __name__ == '__main__':
    main()
