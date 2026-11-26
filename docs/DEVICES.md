# Device list

Every board and stock build reported so far. To add yours, open a
**[device report](https://github.com/Crux4000/citaq-h10-android10/issues/new?template=device-report.yml)**.
Failures and "only ran the checks" reports are just as welcome as successes.

✅ works · ⚠️ partly · ❌ didn't work · ❓ not tried yet

## Reported

| # | Device | Stock build | Sound | Wi-Fi / BT | Result | Report |
|---|---|---|---|---|---|---|
| 1 | Citaq H10-3 (ex-Menulog / Just Eat) | `20220926.JE.H10.5.1.0005` | RT5651 | AP6256 | ✅ Everything in [What works](../README.md#what-works) | @Crux4000 |
| 2 | Citaq H10-3 (shipped with Android 6.0) | `POS_32-userdebug-20211101.1015` | ES8316 | AP6255 | ✅ Works | [#4](https://github.com/Crux4000/citaq-h10-android10/issues/4) |
| 3 | Citaq H10-3 (ex-Menulog, green pre-rebrand) | `20200303.JE.H10.5.1.0004` | RT5651 | AP6255 | ❓ Checks only, not installed yet | [netguycode/citaq#32](https://github.com/netguycode/citaq/issues/32) |
| 4 | Citaq H10-3 (ex-Just Eat, on Android 6.0?) | `POS-userdebug-20211130.1225` | RT5651 | ❓ | ❓ Checks only. Different partition layout, needs 5.1.1 first | [#6](https://github.com/Crux4000/citaq-h10-android10/issues/6) |

All four boards are marked **CTE-RK3368-V1.0**, have a 16 GB eMMC and a `userdebug` stock build, and
units 1 and 2 carry byte-for-byte the same stock device tree. Citaq fits different sound, Wi-Fi/Bluetooth,
eMMC and 4G modem chips to boards that look identical, and mixes them independently: unit 3 has unit 1's
sound chip and unit 2's Wi-Fi module and 4G modem. The port detects or supports both sound chips and both
Wi-Fi modules, and both modems power up and answer AT commands.

### 1: Citaq H10-3, ex-Menulog / Just Eat

- **Board:** CTE-RK3368-V1.0, eMMC 16 GB.
- **Stock build:** `20220926.JE.H10.5.1.0005`, `userdebug`.
- **Result:** the reference terminal the port was developed on. Everything in
  [What works](../README.md#what-works).
- **Sound:** RT5651. The boot hook's codec detection picks it and sound plays (22 Nov 2026).

### 2: Citaq H10-3, shipped with Android 6.0

- **Board:** CTE-RK3368-V1.0 20180801, eMMC 16 GB (15,028 MiB; p16 is 18,333,696 sectors, 118 MiB bigger
  than unit 1).
- **Stock build:** flashed back from Android 6.0 to 5.1.1 with Citaq's
  `RK3368-8780-LVDS9-Citaq-20211101.1015` image (Citaq's `RK3368_6.0_H10_20211130` image was also
  available). `POS_32-userdebug-20211101.1015`, `ro.product.device` = `Citaq_32`. Printer removed.
- **Install:** clean install with the current scripts and no hand edits (20 Nov 2026). Android 10 is
  the default boot. The first attempt needed hand fixes for the bigger p16 and for a DTB-script bug with
  newer `dtc`. Both are now fixed in the scripts.
- **Sound:** ES8316, not the RT5651. ES8316 support was added on 21 Nov 2026, and sound is confirmed
  working.
- **Bluetooth:** AP6255 module (BCM4345C0). Works with `BCM4345C0.hcd`, which is now installed alongside
  the AP6256 file (phone paired 21 Nov 2026).
- **Wi-Fi:** the AP6255's default firmware crashed about every 13 minutes. Cypress's firmware for the same
  chip ran overnight without a crash, and the boot hook now uses it (22 Nov 2026).
  After a soft reboot Wi-Fi used to stay off until a full power-off. **Fixed** (23 Nov 2026): the boot hook
  now takes `wlan0` down before every reboot (step 1c), and Wi-Fi came back on every reboot in testing
  ([#4](https://github.com/Crux4000/citaq-h10-android10/issues/4), [#5](https://github.com/Crux4000/citaq-h10-android10/pull/5)).
- **4G modem:** **Huawei ME909s-120** (revision `11.617.24.00.00`), like unit 3. On Android 10 it powers
  up, answers AT commands on `ttyUSB2`, reads the SIM and registers on LTE with an active SIM, even with
  its antennas removed (23 Nov 2026). SMS and data untested. See [MODEM.md](MODEM.md#other-modems).
- **Also:** a second board of the same model failed the write step with unstable RAM/eMMC. That's a
  hardware fault, not the port.

### 3: Citaq H10-3, ex-Menulog (green, before the orange rebrand)

- **Board:** CTE-RK3368-V1.0 20180801. eMMC 16 GB, Toshiba (`016G70`, maker ID `0x11`), with the same
  partition layout as unit 2 (p16 is 18,333,696 sectors).
- **Stock build:** `20200303.JE.H10.5.1.0004` (an older Just Eat build than unit 1's), `userdebug`.
- **Checks on stock 5.1** (23 Nov 2026): `ili2105_ts/2-0041` (Ilitek touch), `rt5651/1-001a`, `rk818/0-001c`,
  `syr82x/0-0040`. This is the first stock 5.1 output from a second terminal, and it confirms the touch
  controller shows up as `2-0041`.
- **Sound:** RT5651, like unit 1. **Wi-Fi/BT:** AP6255 module, like unit 2 (from a photo).
- **4G modem:** **Huawei ME909s-120**, like unit 2 (not the Fibocom NL668 on unit 1). See
  [MODEM.md](MODEM.md#other-modems).
- **Result:** not installed yet. The owner reports Wi-Fi crashes on stock 5.1.

### 4: Citaq H10-3, ex-Just Eat, probably on Android 6.0

- **Board:** CTE-RK3368-V1.0. eMMC 16 GB, Toshiba (`016GB0`, maker ID `0x11`). 2 GB RAM (MemTotal
  2,047,980 kB). A 32 GB SD card shows up as `mmcblk1`, which doesn't matter.
- **Stock build:** `POS-userdebug-20211130.1225`, `userdebug`, model `CITAQ V8`, device `rk3368`. The date
  matches Citaq's `RK3368_6.0_H10_20211130` Android 6.0 image (Android version not confirmed yet).
- **Partition layout:** not the 5.1 one. System is 2 GiB and p16 is 12,574,720 KB, which puts p16's start
  at about sector 5,619,712 instead of 12,443,648, so the install tools stop at their first check. The way
  through is what terminal 2 did: flash Citaq's 5.1.1 image first (see
  [INSTALL.md step 1](INSTALL.md#1-check-the-terminal)).
- **Checks on stock** (23 Nov 2026): `ili2105_ts/2-0041` (Ilitek touch), `rt5651/1-001a`, `rk818/0-001c`,
  `syr82x/0-0040`. Same parts as terminal 3, all supported by the port.
- **Wi-Fi/BT and 4G modem:** not known yet.
- **Result:** not installed yet.

## Not tried yet

These use the same RK3368 chip, so the PX5 Android 10 build should be able to run on them **in
theory**. None of them has been tried. Each one would need its own device tree, and the
Citaq-only parts of this repo (touch driver, printer, LEDs, backlight and the boot hook) won't apply.
The tools check for the Citaq board and stop on anything else, so treat these as **porting projects,
not installs**. [`firstlight/`](../firstlight) (boot the PX5 kernel to a busybox shell from the recovery
slot) and [Tips for the next person](PORTING-NOTES.md#tips-for-the-next-person) are the place to start.

| Device | Why it's interesting | Status |
|---|---|---|
| **Citaq H10-3 with a different stock build** | The root method needs a `userdebug` build. Citaq's generic `POS_32-userdebug` build and the older Just Eat `…0004` build are `userdebug` too (see above), and so is Citaq's Android 6.0 `POS-userdebug` build, though it uses a different partition layout. Other builds are still unknown. | ⚠️ three more found |
| Other Citaq models | Worth checking `ro.board.platform`. If it says `rk3368`, the port is a DTB away. | ❓ |
| Beelink i68 / Tronsmart Orion R68 | RK3368 TV boxes from 2015. Rockchip shipped DTBs for the Orion R68 and similar boards | ❓ |
| GeekBox | RK3368 box with a public Android 5.1 SDK and kernel source | ❓ |
| Zidoo X6 Pro, Ugoos UT4, Kingnovel R8, Rikomagic MK68 | RK3368 TV boxes | ❓ |
| RK3368 / RK3368H tablets | Generic 2016–17 tablets. A tablet with a battery makes a good wall panel | ❓ |
| Other RK3368 POS, kiosk and signage terminals | Same idea as the H10-3 | ❓ |

TV boxes are probably the easiest of these. They have no LCD panel or touch controller, just HDMI,
Ethernet and USB.

### Not covered by this repo

- **Other Rockchip chips.** PX6 (RK3399) and PX30 (RK3326) head units have their own Android 10
  builds, so the same approach could work for RK3399 and RK3326 devices. It would need a different
  donor firmware and different patches.
- **Crestron TSW-xx60 panels.** These use an Amlogic S812, not Rockchip.

## What to check before you start

Run these over adb on the **stock** firmware and include the output in your report:

```
adb shell getprop ro.board.platform
adb shell getprop ro.product.model
adb shell getprop ro.product.device
adb shell getprop ro.build.type
adb shell getprop ro.build.display.id
adb shell cat /proc/partitions
adb shell "ls -d /sys/bus/i2c/drivers/*/*-00*"
adb shell "cat /sys/block/mmcblk*/device/name /sys/block/mmcblk*/device/manfid"
adb shell grep MemTotal /proc/meminfo
```

- `ro.board.platform` must be `rk3368`.
- The `i2c` line lists the chips that answered at boot. On stock firmware an H10-3 shows its touch
  controller and sound chip there: `2-0041` is the Ilitek touch controller, `1-001a` an RT5651 and
  `1-0010` an ES8316. Anything else on bus 2, please mention it in your report. (On Android 10 the
  touch controller won't be listed, because its driver runs in user space.)
- The `mmcblk` line gives the eMMC chip's name and maker ID.
- `ro.build.type` must be `userdebug` for the `adb root` method in [INSTALL.md](INSTALL.md). On a
  `user` build you'll need another way in (maskrom dump, UART, an exploit), and that's worth a
  report on its own.
- In `/proc/partitions`, the `mmcblk0` line (in KB) gives the eMMC size.
- `MemTotal` should be about 1,900,000 kB (2 GB). If yours has 1 GB, see
  [INSTALL.md step 5](INSTALL.md#5-build-the-dtb-and-boot-image-linuxwsl).

**Also very useful: your stock device tree.** It shows how your board is wired (sound codec,
Wi-Fi/Bluetooth power and clock pins, panel, touch), which is the first thing to compare when
something works on one terminal and not another. This copies it off read-only, on stock 5.1 or
after installing Android 10 (the install never touches it):

```
python tools/dump_stock_dtb.py adb
```

It writes `stock-dtb/rk-kernel.dtb` (and `rk-kernel.dts` if `dtc` is installed). Attach either to
your report. A device tree contains no serial numbers or MAC addresses.

Please **don't** post serial numbers, IMEIs, MAC addresses or IP addresses. `getprop ro.serialno` and
`/proc/cmdline` both contain the serial, so leave them out.
