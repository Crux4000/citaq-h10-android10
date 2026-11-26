# Install guide

This takes a stock Citaq H10-3 (Android 5.1, userdebug) to Android 10. Allow an afternoon. Steps 1–7
happen from **stock Android 5.1**. Nothing reaches the boot path until step 8, and even then it goes
into the **recovery slot**, so a plain power-on still boots stock until step 11.

Read [RECOVERY.md](RECOVERY.md) first, so you know how to get back before you start.

## What you need

**An up-to-date copy of this repo.** Fixes land often, so pull before you start, and again if a
step fails in a way the docs don't describe:
```sh
git pull
git log -1 --oneline        # compare with the latest commit shown on GitHub
```
If `git pull` refuses because you've edited files (for example a hand-fix from an earlier attempt),
run `git stash` first. That puts your edits aside safely, and the fix you needed is usually already
upstream.

**On the bench**
- the terminal, opened up (photos of where everything is: [HARDWARE.md → Getting inside](HARDWARE.md#getting-inside)), on its 24 V supply, with the backup LiPo connected (the board won't run without it)
- a micro-USB cable on **JP2**, the internal adb port on the compute board behind the screen
- recommended: a 3.3 V USB-serial adapter on the debug UART (**TP17** = board TX, **TP18** = board RX,
  **TP19** = GND, 115200 8N1). Don't connect the adapter's VCC. It shows you every boot.
- a USB mouse is handy for the first Android 10 boot (no touch until the boot hook is installed)

**On the PC**
- `adb`: [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools)
- [Python 3.8+](https://www.python.org/downloads/) (Windows, Linux or macOS) for everything in `tools/`
- **Linux or [WSL](https://learn.microsoft.com/en-us/windows/wsl/install)** for the build steps
  (on Debian/Ubuntu: `sudo apt install device-tree-compiler gcc-aarch64-linux-gnu`):
  - `device-tree-compiler` (`dtc`, `fdtput`) for the DTB
  - `aarch64-linux-gnu-gcc` *or* `pip install` [`ziglang`](https://pypi.org/project/ziglang/) for `src/build.sh`
  - a JDK (e.g. [Eclipse Temurin](https://adoptium.net/)) and Android build-tools `d8` for
    `src/thermalstub/build.sh`. `d8` comes with the build-tools package, installed with `sdkmanager` from the
    [Android command-line tools](https://developer.android.com/tools/releases/cmdline-tools).
- Windows only, to unpack the PX5 firmware: **RKDevTool v2.96** (`RKDevTool_Release_v2.96_zh.zip`) and the
  Rockchip USB driver **DriverAssitant v5.14** (`DriverAssitant_v5.14.zip`). Both are on
  [Radxa's RKDevTool page](https://docs.radxa.com/en/rock5/rock5a/low-level-dev/maskrom/windows), under
  "Install RKDevTool". Other 2.9x versions should work too.
- about 10 GB of free disk space

**Downloads**

Links go to each file's home page rather than to a copy. If a link dies, search for the exact filename and
check it against the version or MD5 given here.

| What | Version / file | Where |
|---|---|---|
| PX5 Android 10 firmware | `CHS7_PX5_10.0_IMG(20200603).zip`, 1,137,878,295 bytes<br>MD5 `3b67bce7a84430912c3779b649f8cdf2`<br>SHA-256 `3a0dbe4690051c07a02eb3f9c7225abd6ce782b3dc78b8c798c7d5ceb9a97ab5` | [Hal9k Firmware Library](https://hal9k.ru/?page_id=7): [RockChip PX5 Android 10 → CHS](https://hal9k.ru/?page_id=7&dir=library%2FRockChip%20PX5%20Android%2010%2FCHS) (the `IMG` one, 1.06 GB, not the `ota` files) |
| Google Play services (step 13) | `26.45.31` or newer: arm64-v8a + armeabi-v7a, nodpi, min API 28 | [APKMirror](https://www.apkmirror.com/apk/google-inc/google-play-services/) |
| Google Play Store (step 13) | `54.1.11` or newer: universal, min API 29 | [APKMirror](https://www.apkmirror.com/apk/google-inc/google-play-store/) |
| Wi-Fi driver | `bcmdhd-citaq.ko` (or build it: [WIFI.md](WIFI.md)) | [this repo's releases](https://github.com/Crux4000/citaq-h10-android10/releases) |
| Bluetooth firmware (optional) | `BCM4345C5.hcd` (AP6256) and `BCM4345C0.hcd` (AP6255); get both | Armbian firmware, links and MD5s in [BLUETOOTH.md](BLUETOOTH.md) |

Check the zip before unpacking it: `certutil -hashfile <zip> MD5` on Windows, `md5sum <zip>` on Linux.
Only that exact PX5 image works. Other PX5 Android 10 images have different files, and the patches in
`patches/` check MD5s and will refuse them. Step 3 confirms you have the right one:
`super_to_citaq.py check` must report whole-region MD5 `db834dc68c97662488718f9cd9ca0495`.

Throughout, `adb` means your adb. The tools take it as their first argument: plain `adb` works if it's
on your PATH, otherwise give the full path (e.g. `C:\platform-tools\adb.exe` or `~/platform-tools/adb`).
The commands work the same on Windows and Linux.

---

## 1. Check the terminal

```sh
adb connect <terminal-ip>:5555        # stock has network adb on; or use JP2
adb root
adb shell getprop ro.build.type       # must be: userdebug
adb shell getprop ro.board.platform   # must be: rk3368
adb shell cat /sys/class/block/mmcblk0p16/size    # must be: 18092032 or a bit more
adb shell cat /sys/class/block/mmcblk0p16/start   # must be: 12443648
```
If any of these differ, stop: the partition offsets in this repo won't match your eMMC. The one
exception is the size: some eMMCs are slightly bigger (18333696 has been reported), which is fine,
because everything Android 10 uses ends where the 16 GB reference unit's eMMC ends. The tools accept
a bigger size and tell you how much stays unused.

**On Android 6.0?** (`adb shell getprop ro.build.version.release` says `6.0`, the build ID looks like
`POS-userdebug-20211130…`, and p16 starts much earlier: `5627904` on the one measured.) Citaq's 6.0
image uses a different partition layout, so the tools will refuse it. Terminal 2 in
[DEVICES.md](DEVICES.md) got past this by flashing Citaq's Android 5.1.1 image
(`RK3368-8780-LVDS9-Citaq-20211101.1015`) first, then starting again from step 1. Citaq support
provided it; download links are in [#6](https://github.com/Crux4000/citaq-h10-android10/issues/6), and
`python tools/rkimg_peek.py <zip>` shows what's inside a firmware zip before you use it. That flash replaces
everything on the eMMC, including the bootloader, so back up first. On the 6.0 layout everything before
p16 is bigger than 2 GB: back up p16's start ÷ 2048 MiB (**2748 MiB** for a start of `5627904`) instead of
the 1912 MiB in step 2, and on Windows pull it in three pieces.

**`ro.product.model` says `CITAQ V8`?** That's a different model with a portrait screen, built on the
same board. The same route works: the 5.1.1 image above is the H10's, so stock 5.1.1 will look wrong on
the V8 (colours, sideways), but it only has to boot far enough for adb, and step 5 has a V8 screen option
(untested; see unit 4 in [DEVICES.md](DEVICES.md)). The V8's model and screen rotation live only in its
stock `/system/build.prop`, which the reflash replaces, so `adb pull /system/build.prop` first and keep it.

## 2. Back up the whole eMMC

The first ~2 GB holds every partition except your user data, and it's what you'd need to put the
terminal back exactly as it was. `adb root` first.

```sh
adb exec-out "dd if=/dev/block/mmcblk0 bs=1048576 count=1912 2>/dev/null" > firmware.img   # Linux/WSL; 2,004,877,312 bytes
```
On Windows, PowerShell corrupts binary output, so dump on the device and pull it in pieces
(the stock busybox can't handle files over 2 GiB):
```powershell
adb shell "busybox dd if=/dev/block/mmcblk0 of=/sdcard/fw_a.img bs=1048576 count=1000"
adb pull /sdcard/fw_a.img
adb shell "busybox dd if=/dev/block/mmcblk0 of=/sdcard/fw_b.img bs=1048576 skip=1000 count=912"
adb pull /sdcard/fw_b.img
adb shell "rm /sdcard/fw_a.img /sdcard/fw_b.img"
```
Check each piece with `busybox md5sum` on the device against `certutil -hashfile <f> MD5` on the PC.
Keep two copies, one of them off the PC.

Also keep a copy of your **recovery partition**, because step 6 needs it:
```sh
adb shell "dd if=/dev/block/platform/ff0f0000.rksdmmc/by-name/recovery of=/sdcard/recovery.img"
adb pull /sdcard/recovery.img
```

## 3. Unpack the PX5 firmware

In RKDevTool: **Advanced Function → Unpack** the PX5 `.img` from the zip. The Upgrade Firmware tab has
no unpack option. You get `Output\Android\Image\` with `boot.img` (27,635,712 bytes) and `super.img`.

```sh
python tools/super_to_citaq.py check super.img
#  -> sparse, unpacks to 3,263,168,512 bytes (3112.0 MiB); fits
#  -> whole-region MD5 db834dc68c97662488718f9cd9ca0495
python tools/extract_px5_boot.py boot.img px5/
#  -> px5_kernel (md5 c17c05ad...), px5_ramdisk (f16dc2b1...), px5.dtb (9766b2fe...)
```

## 4. Build the helpers (Linux/WSL)

```sh
sh src/build.sh                    # -> src/out/rkio ilits.bin blshim volshim propset
sh src/thermalstub/build.sh        # -> src/thermalstub/thermalstub.jar
cp src/out/rkio tools/             # super_to_citaq.py / super_files.py push it from here
```

## 5. Build the DTB and boot image (Linux/WSL)

Pick a serial number for your terminal: 6–20 letters and digits. `CITAQ` plus the Wi-Fi MAC without
colons works well (MAC from `adb shell cat /sys/class/net/wlan0/address` on stock). Google's check-in
needs a sane one.

```sh
COUNTRY=AU sh dtb/make_citaq_a10_dtb.sh px5/px5.dtb citaq-a10.dtb CITAQ0123456789AB
python3 tools/build_px5_a10.py recovery.img px5/px5_kernel citaq-a10.dtb px5/px5_ramdisk citaq-a10.img
```
`COUNTRY` is your Wi-Fi regulatory country (default `AU`).

**Citaq V8?** (`ro.product.model` said `CITAQ V8` on stock 6.0; its screen is 8" and portrait.) Add
`PANEL=v8` in front of the `make_citaq_a10_dtb.sh` command. That uses the V8 panel's settings (71 MHz,
6-bit) and names the board "Citaq V8", so the boot hook (step 10) rotates Android 90° to portrait by
itself. This is **untested**: please report how it goes in
[#6](https://github.com/Crux4000/citaq-h10-android10/issues/6). If the picture is fine but the colours
look wrong (banding, false colours), rebuild with `PANEL=v8 LVDS_BUS_FORMAT=0x1011` and flash again.
Until step 10 the screen will be sideways; that's expected.

Every terminal so far has **2 GB of RAM**, and the DTB assumes that. Check yours on stock:
`adb shell grep MemTotal /proc/meminfo` should say about 1,900,000 kB. If it says about 950,000 kB (1 GB),
add `RAM_MB=1024` in front of the `make_citaq_a10_dtb.sh` command. That's untested, so please open an
issue too. `flash_slot.py` (step 8) refuses to write an image built for more RAM than the terminal has.

## 6. Make room: shrink internal storage to 1 GiB

The Android 10 `super`, `metadata`, `cache` and `userdata` go into the stock **user** partition
(`mmcblk0p16`, 8.6 GiB). Its first 1 GiB stays as stock Android's internal storage.
**This wipes stock's internal storage (`/mnt/internal_sd`).** Copy off anything you want first.

```sh
adb root
adb shell vdc volume unmount /mnt/internal_sd
adb shell newfs_msdos -F 32 -O android -c 16 -s 2097152 /dev/block/mmcblk0p16
adb shell vdc volume mount /mnt/internal_sd
adb shell df /mnt/internal_sd       # ~1023M
```
(If `vdc` complains on your build, unmount internal storage from Settings → Storage instead, run the
`newfs_msdos` line, and mount it again there. `super_to_citaq.py` re-checks the result before it writes.)

## 7. Write and patch `super` (from stock 5.1)

Each command runs a preflight first. It checks p16's exact start and size, and that internal storage
is ≤ 1 GiB, before anything is written.

```sh
python tools/super_to_citaq.py write super.img adb &&
python tools/super_to_citaq.py nofbe super.img adb &&
python tools/super_files.py patch super.img adb patches/services_patch.json &&
python tools/super_files.py patch super.img adb patches/oat_rename.json &&
python tools/super_files.py patch super.img adb patches/services_patch2.json &&
python tools/super_files.py patch super.img adb patches/touch_service.json &&
python tools/super_to_citaq.py zero adb && echo "STEP 7 DONE"
```
In a Linux/WSL/macOS shell the `&&` makes the first failure stop everything after it, so it's safe to
paste the whole block. On Windows, run the commands one at a time and don't go on if one stops. If you
don't see `STEP 7 DONE` at the end, fix what stopped and carry on from that command (for `write`, with
the `--start N` it gives you). What each one does:
- `write`: about 3 GB in 128 MiB pieces, each MD5-checked and read back, then a full verify
- `nofbe`: /data without file-based encryption (there's no OP-TEE on the Citaq)
- the four `patch` commands: services, odex renames and the touch service
- `zero`: blanks metadata/cache/userdata so Android 10 formats them on first boot

Keep the **24 V supply connected** for this step. Running the board from the micro-USB cable alone
isn't enough for long eMMC writes.

If `write` stops part-way, re-run it with `--start N` as it tells you. When it stops, it says why:
- **md5 mismatch after push, the same wrong value twice**: the copy didn't arrive intact. It retries
  by itself; if it keeps failing, try another USB cable or port (no hubs).
- **a different value on a second read**, or a piece that **doesn't read back** after writing, or
  `rkio: write: Input/output error`: the terminal's own storage or RAM is misbehaving. It prints the
  kernel's eMMC messages to help tell which. On a board that does this every time, suspect the
  hardware, not the files.

Run the patches **in this order**, because each one checks the bytes it expects to find.

## 8. Put Android 10 in the recovery slot

```sh
python tools/flash_slot.py adb recovery citaq-a10.img
```
It checks the slot position, saves `recovery-backup-<time>.img` (keep it!), pushes the image,
checks the MD5, asks you to confirm, writes, and reads it back.

## 9. First boot

```sh
adb reboot recovery
```
On serial you'll see the 4.19 kernel come up. The **first** boot takes about 2½ minutes, because
`services.jar` runs without its precompiled code. The PX5 car launcher appears, with no touch yet.
Plug the PC into **JP2**:
```sh
adb devices          # the terminal, now on Android 10
adb root
adb shell getprop sys.boot_completed     # 1
```
To go back to stock at any point, `adb reboot` (normal boot = stock 5.1 until step 11) or power-cycle.

## 10. Install the boot hook and helpers

`install_data.py` takes **one folder with every file loose in it** (no subfolders). Build it like this:

```sh
mkdir install
cp device/citaq-boot.sh src/out/ilits.bin src/out/blshim src/out/volshim src/out/propset install/
cp src/thermalstub/thermalstub.jar install/
cp ~/Downloads/bcmdhd.ko install/                 # from this repo's releases page
# optional: Bluetooth (the config + both firmware files; the right one is picked at runtime)
cp device/bt/bt_vendor.conf install/
curl -L -o install/BCM4345C5.hcd https://raw.githubusercontent.com/armbian/firmware/bf5f7a802b8e1998e6bf95daed5ea965441af83d/BCM4345C5.hcd
curl -L -o install/BCM4345C0.hcd https://raw.githubusercontent.com/armbian/firmware/db8cc456dad5ad511b04f8a5130acda392cad20b/BCM4345C0.hcd
# optional: a 1024x768 boot logo
# cp my-logo.png install/bootlogo.png

python tools/install_data.py adb install/
adb reboot recovery
```
Check its output: with the Bluetooth files you should see `BCM4345C5.hcd -> /data/citaq/bt/...  ok` (and
the same for `BCM4345C0.hcd`). If it says `bluetooth skipped`, the files weren't in the folder.
On this boot, touch, Wi-Fi, sound, brightness, the printer/LEDs and network adb (port 5555) all come up.
Bluetooth is ready too; switch it on from quick settings (if the tile does nothing, run
`adb shell svc bluetooth enable` once). [BLUETOOTH.md](BLUETOOTH.md) has the checks.
`/data/citaq/*.log` shows what the hook did.

> **Screen dark, or the brightness slider works backwards?** Some terminals' backlight runs the other
> way round (0 = full brightness). adb still works, so run
> `adb shell "touch /data/citaq/backlight-invert"` and `adb reboot recovery`. After that,
> `adb shell cat /data/citaq/blshim.log` should end in `, inverted)`. See
> [#4](https://github.com/Crux4000/citaq-h10-android10/issues/4).

> The boot hook rotates the screen 180° (`user_rotation 2`) for the **assembled** H10 case, and 90°
> (`user_rotation 1`) on a V8 (DTB built with `PANEL=v8`). On the bench an H10's picture will be upside
> down. To choose a different rotation, put one digit in `/data/citaq/rotation` (0 = the panel's native
> way up, 1 = 90°, 2 = 180°, 3 = 270°), for example `adb shell "echo 3 > /data/citaq/rotation"`, then
> reboot. Touch follows the rotation.

## 11. Make Android 10 the default boot

Once you're happy:
```sh
python tools/flash_slot.py adb boot citaq-a10.img
```
This saves the stock **boot** slot as `boot-backup-<time>.img`. Keep that file: it's how you get stock
5.1 back. The stock kernel lives in a separate partition that's never touched. From now on every
power-on boots Android 10, and the recovery slot holds a spare copy.

## 12. Speed it up (optional)

```sh
adb shell cmd package compile -m speed -a           # 15-20 min, one-off
adb shell settings put global window_animation_scale 0.5
adb shell settings put global transition_animation_scale 0.5
adb shell settings put global animator_duration_scale 0.5
adb push device/debloat.sh /data/local/tmp/ && adb shell sh /data/local/tmp/debloat.sh   # removes 51 car/bloat apps (undo: restore.sh)
```

## 13. Google Play

The PX5 build ships 2019 Google apps, which fail check-in. Then:
1. `adb install -r` the Play services and Play Store APKs listed above.
2. The boot hook already runs the `thermalservice` stub and fixes `ro.serialno`. Check with
   `adb shell getprop ro.serialno`, which should show your serial and not `id.so`.
3. Sign in. If Play says the device isn't certified, register its GSF ID at
   google.com/android/uncertified, then wait. It can take a while.
4. Update Android System WebView and Chrome from Play.

## 14. Home Assistant (optional)

See [HOME-ASSISTANT.md](HOME-ASSISTANT.md).

---

## After a factory reset / userdata wipe

`/data/citaq` is gone, so redo **step 10**. Everything in `super` and the boot slots is untouched.

## Updating the boot image later

Rebuild (step 5), then `flash_slot.py adb boot new.img`. You can update the recovery slot as well,
or keep the old image there as a known-good spare.
