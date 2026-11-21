# Recovery and rollback

Read this before you start. Nearly everything here can be undone from software, as long as you kept
the backups that `flash_slot.py` and step 2 of the install make.

## The safety net, in layers

| Layer | What's there | How you get to it |
|---|---|---|
| Stock kernel partition | untouched, always | — |
| Stock system (`/system`, 5.1) | untouched, always | boot the stock boot slot |
| Recovery slot | Android 10 test image (or stock recovery) | `adb reboot recovery`, or the RECOVER button on the compute board |
| Boot slot | Android 10 after install step 11, stock before | normal power-on / `adb reboot` |
| Full eMMC backup | your `firmware.img` from install step 2 | RKDevTool (loader mode) |

## Go back to stock Android 5.1

**Android 10 only in the recovery slot (before step 11):** just reboot normally, or power-cycle.

**Android 10 is the default boot:** put the stock boot slot back from the backup that
`flash_slot.py ... boot` saved. Run this from Android 10 (or from the recovery slot):
```sh
python tools/flash_slot.py adb boot boot-backup-YYYYMMDD-HHMMSS.img
adb reboot
```
Stock's own `/data` was never touched. Its internal storage was reformatted to 1 GiB in install
step 6, so it starts out empty. Android 10's partitions stay in the user area, and stock can't see
them.

**Put the stock recovery back** (optional):
`flash_slot.py adb recovery recovery-backup-....img` (or the `recovery.img` from install step 2).

## Boot loops and hangs

- **Stuck or looping in Android 10:** power-cycle with **both** the 24 V supply **and** the backup
  LiPo disconnected. The LiPo keeps the SoC alive through a 24 V power-off, so you have to pull both.
  If Android 10 is only in the recovery slot, the board then boots stock.
- **Android 10 is the default and it won't boot:** press **RECOVER** on the compute board (behind the
  screen, next to the debug pads) while powering on. That boots the recovery slot, which holds a
  spare copy of a known-good image. From there, rewrite the boot slot with `flash_slot.py`.
- **Kernel panic:** it reboots by itself after 5 s.
- **Stuck on the boot logo after changing the boot hook:** adbd is already running under the boot
  animation, so plug into JP2 and fix it from there, for example by restoring your previous
  `/data/citaq/ilits`. Power-cycling won't help, because the hook runs again on every boot. One known
  way to cause this is stopping the PX5 GPS service (see [BLUETOOTH.md](BLUETOOTH.md#3-the-gps-service-holds-the-port)):
  `adb shell getprop init.svc.vendor.gnss_service` should say `running`.
- **Frozen with the screen off, touch and adb dead, and it comes back after a power-cycle:** that's
  what the broken temperature sensor did before 21 Nov 2026: a garbage reading hit the 125 °C critical
  trip, which halts the board but leaves it powered (see [Known issues](../README.md#known-issues)).
  Check the sensor's clock runs: `adb root`, then
  `adb shell "grep -e xin32k -e tsadc /sys/kernel/debug/clk/clk_summary"` should show 32768 for both.
  If not, rebuild and flash the boot image. If it does and it still freezes, check the CPU limit
  (`adb shell cat /data/citaq/cpu.log`), drop it to 1008 or 816 MHz
  ([HARDWARE.md](HARDWARE.md#cpu-speed-limit)), and please open an issue.
- **Frozen but adb still answers** (for example a wedged USB hub on stock 5.1):
  `adb shell "echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger"` forces a clean reset
  without opening anything.

## JP2 stopped showing up on the PC

The PX5 kernel *wants* the OTG port in host mode, and that setting survives a warm reset. Our DTB puts
it in device mode, but if you ever boot a DTB without that (e.g. the first-light test), JP2 can
stay in host mode afterwards. Fix: cold power cycle (24 V **and** LiPo out).

## After a battery pull or a back-switch power-off: blank screen, no touch, no Wi-Fi, no sound

There's no PMIC driver in the PX5 kernel, so the RK818 keeps whatever state it was last programmed
to. A battery pull resets it to factory defaults: the LCD logic and touch supplies switch off, the
Wi-Fi 32 kHz clock stops, and the charger limits change. Turning the terminal off with the back
switch is a full PMIC power-off too, so the same thing happens on every cold boot. The Wi-Fi chip
and the RT5651 audio codec then get probed with no power and fail.

`citaq-boot.sh` detects this, puts the stock values back, and re-probes Wi-Fi and the audio codec on
every boot, so it fixes itself. If it doesn't, check `/data/citaq/rk818.log` (it should end with
`rt5651 codec bound (sound card: ok)` after a cold boot), `/data/citaq/sound.log` (which codec was found and
whether the sound card came up) and that `/data/citaq/ilits` exists. See
[HARDWARE.md](HARDWARE.md#rk818-pmic) for the registers.

## Worst case: nothing boots at all

The RK3368 boot ROM always falls back to **rockusb / maskrom** over JP2 when it finds nothing
bootable. Windows shows a "Rockusb Device". With the Rockchip driver and RKDevTool you can then write
your `firmware.img` back. In RKDevTool, **Reset Device** and **Read Flash Info** are harmless. Don't
press Run on the Download Image tab unless you've loaded the right files for *this* board, and never
use Erase.

Nothing in this guide writes the bootloader, trust, parameter or misc partitions, so the loader chain
itself is never at risk.
