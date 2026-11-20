# Android 10 on the Citaq H10-3 POS terminal (RK3368), with GPU acceleration

The Citaq H10-3 is a 10" Android point-of-sale terminal with a built-in 80 mm receipt printer.
Ex-Menulog / Just Eat units are turning up free or cheap, and they make a great wall kiosk, but they
ship with **Android 5.1 from 2016**. Modern browsers and the Home Assistant app no longer run on it.

This repo takes one of those terminals to **Android 10 with working PowerVR GPU acceleration**. The
receipt printer, LEDs, touch, Wi-Fi, Bluetooth, sound and Google Play all work. It does this **without replacing
the bootloader and without repartitioning**, and the stock Android 5.1 stays on the eMMC as a
fallback.

> **Tried it? Please report back, good or bad.** So far this has been done on exactly one terminal.
> Whether it worked, half-worked or ended in maskrom, a quick
> **[device report](https://github.com/Crux4000/citaq-h10-android10/issues/new?template=device-report.yml)**
> adds your unit to the **[device list](docs/DEVICES.md)** and helps the next person. Reports from other
> H10-3 stock builds and from other RK3368 hardware are the most useful. Just running the `getprop`
> checks and reporting what you have counts too.

![The Citaq H10-3 running Android 10 as a Home Assistant kiosk, printing its own receipt](docs/img/kiosk.jpg)

| | |
|:---:|:---:|
| <img src="docs/img/about-android10.jpg" width="340" alt="Settings, About: Android 10"> | <img src="docs/img/receipt.jpg" width="260" alt="Receipt printed by the terminal"> |
| Settings → About tablet | printed from Home Assistant |

| | |
|---|---|
| Hardware | Citaq H10-3, Rockchip RK3368 (8× Cortex-A53), PowerVR G6110, 2 GB RAM, 16 GB eMMC, 1024×768 LVDS |
| Before | Android 5.1.1, kernel 3.10, security patch 2016-04-01, WebView 95 |
| After | Android 10 (Rockchip PX5 build), kernel 4.19.111, **OpenGL ES 3.1 on the G6110**, WebView 157, current Play Store and HA app |
| Boot | ~22 s to `boot_completed` (stock U-Boot, eMMC at HS200) |

## How it works, in one paragraph

The RK3368 is the same chip as the **PX5**, which sits inside thousands of Android car head units. Those
got an Android 10 build from Rockchip, and that build carries the **newest G6110 GPU driver there is**.
The open-source Mesa/PowerVR driver lists this GPU as unsupported, so mainline Linux would mean
software rendering. This port takes the PX5 Android 10 kernel and system and boots them on the
Citaq's own 2019 U-Boot. To make that work it:

- writes a new device tree for the Citaq hardware
- puts the dynamic `super` partition inside the old internal-storage area
- byte-patches the car firmware so it stops waiting for a car that isn't there
- fills the gaps with small userspace drivers for touch, backlight and volume

The full story, including every boot loop and its fix, is in **[docs/PORTING-NOTES.md](docs/PORTING-NOTES.md)**.

## What works

| Feature | Status | Notes |
|---|---|---|
| GPU (PowerVR Rogue G6110) | ✅ | GLES 3.1, 200/288/400 MHz DVFS |
| Display 1024×768 LVDS | ✅ | JEIDA 24-bit; rotated 180° for the assembled case |
| Touch (Ilitek ILI2105) | ✅ | userspace driver `ilits` (I2C → uinput), 2 fingers |
| Wi-Fi (AP6256, 2.4 + 5 GHz) | ✅ | rebuilt `bcmdhd.ko` (see [docs/WIFI.md](docs/WIFI.md)) |
| Bluetooth (AP6256 / BCM4345C5) | ✅ | speakers, headsets; see [docs/BLUETOOTH.md](docs/BLUETOOTH.md) |
| Ethernet (RTL8152) | ✅ | |
| 4G modem (Fibocom NL668) | ⚠️ | powers up, AT commands, sees all carriers; **untested with a SIM**, see [docs/MODEM.md](docs/MODEM.md) |
| Sound (RT5651 + speaker amp) | ✅ | Android volume works through `volshim` |
| Headphone jack | ✅ | built-in speakers mute while something is plugged in |
| Brightness slider | ✅ | through `blshim` |
| Receipt printer (`/dev/ttyS1`) | ✅ | ESC/POS, same paths as stock, so existing scripts keep working |
| Red / blue LEDs | ✅ | gpio124 / gpio106 |
| 3 USB host ports | ✅ | barcode scanners, mice, flash drives, SDR dongles |
| adb over USB (JP2) and network | ✅ | userdebug build, `adb root` works |
| Google Play / sign-in | ✅ | with a `thermalservice` stub and a serial-number fix |
| CPU DVFS + thermal | ✅ | 408 MHz–1 GHz by default, 1.2 GHz opt-in; runs warm with no heatsink, see [Known issues](#known-issues) |
| Back power switch | ✅ | clean shutdown and real power-off |
| Survives a battery pull | ✅ | the boot hook re-programs the PMIC |
| Battery % / charge status | ❌ | no RK818 driver; charging itself works |
| Android's own "Power off" | ⚠️ | halts but stays powered; use the back switch |
| Hardware volume keys / MTC volume slider | ⚠️ | go to the (absent) car MCU; use any app that uses Android's media volume |

## Do I have the right terminal?

You need **all** of these. The scripts check most of them and stop if something doesn't match.

- **Citaq H10-3** with the `CTE-RK3368-V1.0` board and a 16 GB eMMC (`ro.board.platform=rk3368`)
- the stock **userdebug** build, so `adb root` works. Ex-Menulog units with build
  `20220926.JE.H10.5.1.0005` (`ro.product.device=justeat_32`) are. Check with
  `adb shell getprop ro.build.type`. A `user` build can't be rooted this way.
  [docs/DEVICES.md](docs/DEVICES.md) lists every build and board reported so far.
- **the case open** on the bench, because you need the internal **JP2 micro-USB** for adb on Android
  10's first boot. A 3.3 V USB-serial adapter on the debug UART is strongly recommended.

<a href="docs/HARDWARE.md#getting-inside"><img src="docs/img/board-overview.jpg" width="600" alt="Inside the H10-3: debug UART, RECOVER button, JP2 adb port and backup LiPo marked"></a>

*Inside the H10-3: everything you need is in the bottom-right corner of the board. Details in [HARDWARE.md](docs/HARDWARE.md#getting-inside).*

## Getting started

1. Read **[docs/INSTALL.md](docs/INSTALL.md)** end to end before starting.
2. Back up your whole eMMC. The guide shows how.
3. Build the image, test it from the **recovery slot** (stock still boots normally), then make it the
   default.

Rolling back is one command (`tools/flash_slot.py … boot <your backup>`), and the stock 5.1 system is
never touched. See [docs/RECOVERY.md](docs/RECOVERY.md).

## Repo layout

```
tools/        PC side (Python 3, no Android SDK needed)
  extract_px5_boot.py    pull kernel / ramdisk / DTB out of the PX5 boot.img
  build_px5_a10.py       build the Citaq boot image (Rockchip SHA-1 header hash)
  super_to_citaq.py      write super.img into the user area over adb, with MD5 checks
  super_files.py         read/patch files inside super.img (applies patches/*.json on the device)
  flash_slot.py          write an image to the boot or recovery slot - checks, backup, verify
  install_data.py        push the boot hook + helpers to /data/citaq
  rkbootimg.py           shared Rockchip boot-image helpers
dtb/          device-tree scripts (PX5 EVB DTB -> Citaq H10-3), need dtc/fdtput
patches/      byte patches for super: CarService null fix, odex hide, touch service
device/       on-terminal scripts: citaq-boot.sh (the boot hook), debloat/restore, bt/bt_vendor.conf, modem/at-probe.sh
src/          static arm64 helpers (C) + thermalstub (Java); build.sh builds them
firstlight/   optional kernel bring-up test (busybox initramfs) for adapting to other boards
ha/           Home Assistant package: printer, LEDs, app relaunch over adb
docs/         install, recovery, hardware map, porting notes, Wi-Fi driver, Bluetooth, 4G modem, Home Assistant
```

## What is *not* in this repo

- **The PX5 firmware** (Rockchip/HCT `CHS7_PX5_10.0_IMG(20200603)`). You download it yourself from
  the [Hal9k Firmware Library](https://hal9k.ru/?page_id=7), and the tools extract and patch it on your PC.
- **Google apps** (Play services, Play Store). Sideload them from a trusted mirror.
- **`bcmdhd.ko`**. It's GPL and built from Rockchip's public kernel tree, and it's attached to the
  GitHub release along with the exact source commit and config. See [docs/WIFI.md](docs/WIFI.md).
- **`BCM4345C5.hcd`** (Bluetooth firmware). Download it from Armbian's firmware repo; the link and
  MD5 are in [docs/BLUETOOTH.md](docs/BLUETOOTH.md).

## Known issues

- **It runs hot, and one freeze is under investigation.** These terminals have no heatsink on the
  SoC, and there are only a couple of millimetres between the chip and the case.
  - **Don't trust the built-in temperature reading yet.** The port's sensor driver corrects the
    reading against a fixed CPU voltage, but the voltage actually scales between 1.0 and 1.225 V. So
    the reading jumps around (42 °C and 69 °C a few minutes apart has been seen) and probably reads low
    at full speed. A fix is being worked on and will be checked against a real probe first.
  - **Real measurement:** a probe inside the closed case, next to the SoC but not touching it, was
    about 20 °C above room temperature after half an hour at 1.2 GHz and still rising. The chip itself
    is hotter than the air around it. A second terminal reported the SoC hot enough to burn a finger.
  - **Freeze:** on 19 Nov 2026 one terminal froze after about 3 hours at 1.2 GHz: screen off, touch
    and adb dead, nothing in the logs, back after a power-cycle. The cause isn't confirmed yet. Heat
    at 1.2 GHz is the main suspect.

  **Since 20 Nov 2026 the CPU defaults to 1008 MHz** instead of 1.2 GHz. A second user reports that a
  lower limit helped, with no noticeable difference in the Home Assistant app. 1.2 GHz is still there
  as an opt-in ([docs/HARDWARE.md](docs/HARDWARE.md#cpu-speed-limit)) and will become the default
  again once the temperature reading is fixed. **Installed before 20 Nov?** Your boot hook still
  defaults to 1.2 GHz. Either re-run `install_data.py`, or just set the limit:
  `adb shell "echo 1008 > /data/citaq/cpu-max-mhz"`. If you still get freezes at 1008 MHz, please open
  an issue.

## Warning

This writes to the eMMC of a device that has no official recovery path apart from Rockchip's
maskrom tools. Everything here was done on one terminal and works there. The scripts check partition
positions and MD5s before writing, and they back up what they replace. Even so, **you do this at your
own risk**, and you should keep the full eMMC backup somewhere safe.

## Credits

- The PX5 head-unit community and the **Hal9k** firmware library, for keeping these images available
- Rockchip's open `develop-4.19` kernel tree (Wi-Fi driver rebuild) and their vendor device trees
- The mainline `ili210x` driver (touch protocol) and the mainline `rk808` / Pinephone Pro RK818 work (32 kHz clock fix)

## Licence

Copyright (C) 2026 Crux4000

The code and docs in this repo are licensed under the **GNU General Public License v3.0 or later**
(see [LICENSE](LICENSE)). You're free to use, modify and share them, including commercially, but if you
distribute this work or anything built from it (for example, terminals sold with it installed), you
must make the complete source available under the same licence.

Copies obtained before 18 November 2026 were released under the MIT licence.

The PX5 firmware, Google apps and the Linux kernel / `bcmdhd` remain under their own licences.
