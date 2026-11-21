# Device list

Every board and stock build reported so far. To add yours, open a
**[device report](https://github.com/Crux4000/citaq-h10-android10/issues/new?template=device-report.yml)**.
Failures and "only ran the checks" reports are just as welcome as successes.

✅ works · ⚠️ partly · ❌ didn't work · ❓ not tried yet

## Reported

| Device | Board marking | eMMC | Stock build (`ro.build.display.id`) | `ro.build.type` | Result | Report |
|---|---|---|---|---|---|---|
| Citaq H10-3 (ex-Menulog / Just Eat) | CTE-RK3368-V1.0 | 16 GB | 20220926.JE.H10.5.1.0005 | userdebug | ✅ full port, see [What works](../README.md#what-works) | @Crux4000 |
| Citaq H10-3, shipped with Android 6.0, flashed back to 5.1.1 with Citaq's `RK3368-8780-LVDS9-Citaq-20211101.1015` image (also has `RK3368_6.0_H10_20211130`); printer removed. `ro.product.device` = `Citaq_32` | CTE-RK3368-V1.0 20180801 | 16 GB (15,028 MiB; p16 18333696 sectors, 118 MiB bigger) | POS_32-userdebug-20211101.1015 | userdebug | ✅ clean install with the current scripts and no hand edits (20 Nov 2026), Android 10 as the default boot. **Sound codec is an ES8316, not the RT5651** (same stock DTB byte for byte), which needed ES8316 support (added 21 Nov 2026; sound confirmed working). Wi-Fi/BT module is an **AP6255** (Bluetooth BCM4345C0): Bluetooth works with `BCM4345C0.hcd` (phone paired 21 Nov 2026), now installed alongside the AP6256 file. The first attempt needed hand-fixes for the bigger p16 and a DTB-script bug with newer `dtc`; both are fixed. A second board of the same model failed the write step with unstable RAM/eMMC (a hardware fault, not the port) | [#4](https://github.com/Crux4000/citaq-h10-android10/issues/4) |

## Not tried yet

These use the same RK3368 chip, so the PX5 Android 10 build should be able to run on them **in
theory**. None of them has been tried. Each one would need its own device tree, and the
Citaq-only parts of this repo (touch driver, printer, LEDs, backlight and the boot hook) won't apply.
The tools check for the Citaq board and stop on anything else, so treat these as **porting projects,
not installs**. [`firstlight/`](../firstlight) (boot the PX5 kernel to a busybox shell from the recovery
slot) and [Tips for the next person](PORTING-NOTES.md#tips-for-the-next-person) are the place to start.

| Device | Why it's interesting | Status |
|---|---|---|
| **Citaq H10-3 with a different stock build** | The root method needs a `userdebug` build. Citaq's generic `POS_32-userdebug` build works too (see above); other builds are still unknown. | ⚠️ one more found |
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
