#!/bin/busybox sh
# Citaq H10-3: PX5 Android 10 kernel (Rockchip 4.19) first light.
# 32-bit ARM busybox from the stock recovery, run through CONFIG_COMPAT.
# This busybox's ash has no [ / echo / test builtins: link applets first.
for a in $(/bin/busybox --list); do /bin/busybox ln -sf /bin/busybox /bin/$a; done
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /tmp
mount -t tmpfs tmp /tmp

# Console = the FIQ debugger tty on UART2 (115200). Wait up to 10 s for it.
n=0
while [ ! -c /dev/ttyFIQ0 ] && [ $n -lt 10 ]; do sleep 1; n=$((n+1)); done
if [ -c /dev/ttyFIQ0 ]; then exec </dev/ttyFIQ0 >/dev/ttyFIQ0 2>&1; fi

# Blue LED (GPIO3_B2 = gpio106) on = our init is running.
echo 106 > /sys/class/gpio/export 2>/dev/null
echo out > /sys/class/gpio/gpio106/direction 2>/dev/null
echo 1 > /sys/class/gpio/gpio106/value 2>/dev/null

line() { echo "------------------------------------------------------------"; }
sec() { echo; line; echo " $*"; line; }

echo
echo "============================================================"
echo " Citaq H10-3: PX5 Android 10 kernel (4.19) first light"
echo "============================================================"
uname -a
echo "uptime: $(cat /proc/uptime)   cpus: $(grep -c ^processor /proc/cpuinfo)"
grep -E 'MemTotal|MemFree' /proc/meminfo
echo "model: $(cat /proc/device-tree/model 2>/dev/null)"
echo "cmdline: $(cat /proc/cmdline)"

sec "GPU (PowerVR Rogue G6110)"
dmesg | grep -iE 'pvr|rogue|gpu' | tail -n 30
ls -l /dev/pvr* /dev/dri 2>&1

sec "Display (VOP / LVDS / panel / backlight)"
dmesg | grep -iE 'drm|vop|lvds|panel|backlight|pwm' | tail -n 40
ls -l /dev/fb* 2>&1
for c in /sys/class/drm/card*-*; do
  [ -d "$c" ] || continue
  echo "$c: status=$(cat $c/status 2>/dev/null) enabled=$(cat $c/enabled 2>/dev/null) modes=$(cat $c/modes 2>/dev/null | tr '\n' ' ')"
done
cat /sys/class/backlight/*/brightness 2>/dev/null | sed 's/^/backlight brightness: /'

sec "Storage / USB / network / i2c / input"
cat /proc/partitions
dmesg | grep -iE 'mmc[0-9]|dwmmc' | tail -n 10
ls /sys/class/net
dmesg | grep -iE 'usb [0-9]|r8152|rtl8152|ehci|ohci|dwc2' | tail -n 15
ls /dev/i2c-* 2>&1
ls /dev/input 2>&1

sec "Problems (fail / error / timeout / deferred)"
dmesg | grep -iE 'fail|error|unable|timeout|defer|not found|invalid' | grep -v 'Error Reporting' | tail -n 50

sec "Regulators"
grep -H . /sys/class/regulator/*/name 2>/dev/null | head -n 20

# Display test: fill the framebuffer with noise. If the screen turns to static,
# the LVDS path works.
if [ -c /dev/fb0 ]; then
  sec "Display test: writing noise to /dev/fb0 (screen should turn to static)"
  fbset 2>&1
  cat /dev/urandom > /dev/fb0 2>/dev/null
  echo "done"
fi

echo
line
echo " Full kernel log: type  dmesg"
echo " Back to Android: type  reboot -f"
echo
echo " Press Enter within 5 minutes to keep this shell."
echo " (No key = this test reboots back to Android by itself.)"
line
if read -t 300 k; then
  echo "OK, staying. Shell on ttyFIQ0:"
  exec setsid cttyhack sh
fi
echo "no key in 5 min, rebooting to Android"
echo 0 > /sys/class/gpio/gpio106/value 2>/dev/null
sync
reboot -f
