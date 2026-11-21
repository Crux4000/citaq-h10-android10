# Bluetooth

Citaq fits one of two Wi-Fi/Bluetooth modules: an **AP6256** (Bluetooth **BCM4345C5**, the reference
terminal) or an **AP6255** (Bluetooth **BCM4345C0**, a second terminal). Either way the Bluetooth half is on
**UART0** (`/dev/ttyS0`). The Android 10 port drives it with the PX5 ROM's own Bluetooth stack and Broadcom
`libbt-vendor.so`. Four things had to be fixed before it worked:

| # | Problem | Fix |
|---|---|---|
| 1 | No Bluetooth rfkill switch, so Android can't power the chip | `wireless-bluetooth` node in the DTB (`dtb/make_citaq_a10_dtb.sh`) |
| 2 | The ROM has no Bluetooth firmware where the Bluetooth library looks | `BCM4345C5.hcd` / `BCM4345C0.hcd` + `bt_vendor.conf` in `/data/citaq/bt`, bind-mounted over `/vendor/etc/bluetooth` |
| 3 | The PX5 GPS service holds `/dev/ttyS0` | point it at a dummy port instead (it must keep running) |
| 4 | The MTC Bluetooth app only *pretends* to switch on | `setprop hct.bt.org true` |

Fixes 2–4 are done by the boot hook (`device/citaq-boot.sh`, section `00b5`). Tested with a Sony
SRS-XB13 speaker: pairs, A2DP and HFP connect, music streams with no drops. The AP6255 terminal paired a
phone on 21 Nov 2026.

## Download the firmware

Both firmware files come from Armbian's firmware collection. Get both: you don't need to know which module
your terminal has, because the Bluetooth library asks the chip its name and loads the matching file.

```sh
curl -LO https://raw.githubusercontent.com/armbian/firmware/bf5f7a802b8e1998e6bf95daed5ea965441af83d/BCM4345C5.hcd
curl -LO https://raw.githubusercontent.com/armbian/firmware/db8cc456dad5ad511b04f8a5130acda392cad20b/BCM4345C0.hcd
```

| File | Module | MD5 | Size |
|---|---|---|---|
| `BCM4345C5.hcd` | AP6256 | `fc394331d03baa5847e2b5de94ffbc9b` | 45,667 bytes |
| `BCM4345C0.hcd` | AP6255 | `d6313cb3835f7645240e2ad63ff152ab` | 65,570 bytes |

Copy them **and** `device/bt/bt_vendor.conf` loose into the folder you give `tools/install_data.py` (the
same folder as `citaq-boot.sh` and the rest; [INSTALL.md step 10](INSTALL.md#10-install-the-boot-hook-and-helpers)
has the exact commands). It checks the MD5s and installs them. With no `.hcd` and no `bt_vendor.conf` it
prints `bluetooth skipped` and carries on; with only one of the two kinds it stops.

**Already installed without them?** Add the two files to that folder and run `install_data.py` again.
It's safe to re-run. Reboot afterwards so the boot hook picks them up.

## 1. Device tree

The pins are the stock Citaq 3.10 DT's `wireless-bluetooth` node:

| Signal | Pin | Linux GPIO |
|---|---|---|
| BT power | gpio3 A3 | 99 |
| BT_REG_ON (reset) | gpio3 A5 | 101 |
| BT_WAKE | gpio3 A2 | 98 |
| host wake | gpio3 A7 | 103 |
| UART0 RTS | gpio2 D3, active low | 91 |

Rockchip's `rfkill-bt` driver (`CONFIG_RFKILL_RK=y` in the PX5 kernel) powers the chip from these and
registers `rfkill0` as `bluetooth`. It parks RTS as a GPIO while it powers the chip, so the node has a
second pinctrl state (`rts_gpio`, a new `uart0-rts-gpio` group). UART0 also gets its CTS pin, so the
vendor library can run hardware flow control at 1.5 Mbaud.

Before the DTB was written, the chip was tested by hand: with power and REG_ON high and RTS low, it
answered `HCI_Reset` at 115200 and named itself `BCM4345C5` (`BCM4345C0` on an AP6255).

## 2. Firmware and config

`libbt-vendor.so` reads `/vendor/etc/bluetooth/bt_vendor.conf`, which the ROM doesn't have (the folder
only holds `rtkbt.conf`). The boot hook bind-mounts `/data/citaq/bt` over that folder, so it needs:

- `bt_vendor.conf`: `UartPort = /dev/ttyS0` and the firmware folder. It deliberately names no firmware
  file: the library then asks the chip its name and loads `<name>.hcd` ("AMPAK FW Auto detection ...
  Found patchfile" in logcat), which is how one install covers both modules.
- `BCM4345C5.hcd` and/or `BCM4345C0.hcd`
- a copy of the ROM's `rtkbt.conf` (the mount hides the original; `install_data.py` copies it)

The files are labelled `vendor_configs_file`. Delete `/data/citaq/bt` to undo it.

## 3. The GPS service holds the port

The PX5 head unit had a GPS on UART0. Its GNSS HAL (`vendor.gnss_service`) opens the port named in
**`vendor.gps.channel`** (`/dev/ttyS0`) at about 4 s into boot, and keeps it.

- **Don't stop it.** `system_server`'s location service waits for the GNSS HAL forever. With the HAL
  stopped, `system_server` restarts in a loop and the boot hangs on the logo. (adb still works under
  the boot animation, so this is fixable over JP2. See [RECOVERY.md](RECOVERY.md).)
- A port that doesn't exist (`/dev/ttyS4`) makes the HAL crash and restart in a loop.
- **What works:** `vendor.gps.channel=/dev/ptmx`, then restart the HAL. `/dev/ptmx` hands out a fresh
  pseudo-terminal that nothing ever writes to, so the HAL opens it happily and waits. ttyS0 is free.
- With the dummy port, every GPS request blocks Android's foreground system thread for 5 s waiting
  for an answer. The Citaq has no GPS anyway, so the hook switches the GPS location provider off
  (`settings put secure location_providers_allowed -gps`). Network location is unaffected.

The hook re-checks the property for the first 2 minutes in case a vendor `.rc` file sets it again.

## 4. The MTC Bluetooth app fakes it

The ROM's Bluetooth app (`/system/app/ExtAospBluetooth10`, `com.android.bluetooth`) is modified by
the head-unit maker (HCT). On the car, Bluetooth was a separate module run by the MCU, so the app was
hollowed out. Its `AdapterState`/`AdapterService` read the property **`hct.bt.org`** ("original"):

- not `"true"` (the default): the off state reports itself as **ON**, the BLE power-up is skipped, and
  `isEnabled`, `getState` and discovery short-circuit. Settings shows Bluetooth on, but the HAL is
  never called: the address stays `null`, the log says `Controller not ready`, and nothing opens ttyS0.
- `"true"`: the stock Android 10 code paths, so the HAL starts, opens the UART and loads the firmware.

So the fix is one `setprop`, set before `com.android.bluetooth` starts. No APK patch is needed, which
matters because the app is signed with the vendor's platform key.

## What a good start looks like

```
bt_vendor: init
bt_userial_vendor: userial vendor open: opening /dev/ttyS0
bt_hwcfg: Chipset BCM4345C5
bt_hwcfg: Target name = [BCM4345C5]
bt_hwcfg: Found patchfile: /vendor/etc/bluetooth//BCM4345C5.hcd
bt_hwcfg: bt vendor lib: set UART baud 1500000
bt_hwcfg: vendor lib fwcfg completed
AdapterState: BLE_ON : entered
AdapterState: TURNING_ON : entered
AdapterState: ON : entered
```

`bt_upio: open(/proc/bluetooth/sleep/...) failed: Permission denied` is harmless: there's no
low-power-mode interface, so the chip just stays awake.

## Checking it

```sh
adb shell grep -H . /sys/class/rfkill/*/type          # one of them: bluetooth
adb shell getprop hct.bt.org                         # true
adb shell getprop vendor.gps.channel                 # /dev/ptmx
adb shell "dumpsys bluetooth_manager | grep -i -E 'enabled:|state:|address:'"
```

To switch Bluetooth on from adb: `adb shell svc bluetooth enable` (Android 10 has no
`cmd bluetooth_manager`). Android remembers it, so it comes back on after a reboot. On the AP6255
terminal the quick-settings tile did nothing and Settings showed no on/off switch until Bluetooth had
been switched on this way once.

## Notes

- The adapter is named `rk3368`; rename it in Settings → Bluetooth.
- The address is a random `22:22:xx:xx:xx:xx`, generated by the stack on first start and kept after
  that.
- Pairing with a **phone** works but it drops straight away (reason `0x16`, local host terminated).
  Both ends are phone-type devices with no profile in common, so that's expected. Speakers, headsets,
  keyboards and scanners are what the kiosk can drive. A paired phone could also route its calls to
  the kiosk, so you may not want one paired anyway.
