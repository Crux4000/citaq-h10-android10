#!/bin/sh
# Build the static arm64 helpers for the Citaq H10-3 (run on Linux / WSL / macOS).
# Uses aarch64-linux-gnu-gcc if present, otherwise zig (pip install ziglang) - both give
# fully static binaries that run on stock Android 5.1 and on the Android 10 port.
#   rkio      64-bit dd/zero/read for the stock 5.1 side (super_to_citaq.py, super_files.py)
#   ilits.bin touch daemon (Ilitek ILI2105 over I2C -> uinput)
#   blshim    Android brightness -> real backlight PWM
#   volshim   Android media volume -> codec volume (RT5651 or ES8316)
#   propset   rewrite an ro.* property in place (ro.serialno fix)
#   qmidial   QMI data call for the Fibocom NL668 under the ROM's RIL (optional, docs/MODEM.md)
set -e
cd "$(dirname "$0")"
OUT=${OUT:-out}; mkdir -p "$OUT"
if command -v aarch64-linux-gnu-gcc >/dev/null; then CC="aarch64-linux-gnu-gcc -static"
elif python3 -c 'import ziglang' 2>/dev/null; then CC="python3 -m ziglang cc -target aarch64-linux-musl -static"
else echo "need aarch64-linux-gnu-gcc or zig (pip install ziglang)" >&2; exit 1; fi
for p in rkio:rkio ilits:ilits.bin blshim:blshim volshim:volshim propset:propset qmidial:qmidial; do
  src=${p%%:*}; bin=${p##*:}
  $CC -O2 -Wall -o "$OUT/$bin" "$src.c"
  echo "built $OUT/$bin"
done
