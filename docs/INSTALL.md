# Install guide

This takes a stock Citaq H10-3 (Android 5.1, userdebug) to Android 10. Allow an afternoon. Steps 1–7
happen from **stock Android 5.1**. Nothing reaches the boot path until step 8, and even then it goes
into the **recovery slot**, so a plain power-on still boots stock until step 11.

Read [RECOVERY.md](RECOVERY.md) first, so you know how to get back before you start.

## What you need

**On the bench**
- the terminal, opened up, on its 24 V supply, with the backup LiPo connected (the board won't run without it)
- a micro-USB cable on **JP2**, the internal adb port on the compute board behind the screen
- recommended: a 3.3 V USB-serial adapter on the debug UART (**TP17** = board TX, **TP18** = board RX,
  **TP19** = GND, 115200 8N1). Don't connect the adapter's VCC. It shows you every boot.
- a USB mouse is handy for the first Android 10 boot (no touch until the boot hook is installed)

**On the PC**
- `adb` (Android platform-tools)
- Python 3.8+ (Windows, Linux or macOS) for everything in `tools/`
- **Linux or WSL** for the build steps:
  - `device-tree-compiler` (`dtc`, `fdtput`) for the DTB
  - `aarch64-linux-gnu-gcc` *or* `pip install ziglang` for `src/build.sh`
  - a JDK and Android build-tools `d8` for `src/thermalstub/build.sh`
- RKDevTool v2.9x (Windows) to unpack the PX5 firmware
- about 10 GB of free disk space

**Downloads**
- **PX5 Android 10 firmware:** `CHS7_PX5_10.0_IMG(20200603).zip` from the Hal9k firmware library
  (RockChip PX5 → Android 10 → CHS). Other PX5 Android 10 images will have different files: the
  patches in `patches/` check MD5s and will refuse them.
- **Google apps** (for step 13), from a trusted mirror such as APKMirror:
  - Google Play services `26.45.31` (arm64-v8a + armeabi-v7a, nodpi, min API 28) or newer
  - Google Play Store `54.1.11` (universal, min API 29) or newer
- **`bcmdhd-citaq.ko`** from this repo's release page (or build it: [WIFI.md](WIFI.md))

Throughout, `adb` means your adb and `ADB` in tool arguments is the path to it (e.g. `adb` or
`C:\platform-tools\adb.exe`).

---

## 1. Check the terminal

```sh
adb connect <terminal-ip>:5555        # stock has network adb on; or use JP2
adb root
adb shell getprop ro.build.type       # must be: userdebug
adb shell getprop ro.board.platform   # must be: rk3368
adb shell cat /sys/class/block/mmcblk0p16/size    # must be: 18092032
adb shell cat /sys/class/block/mmcblk0p16/start   # must be: 12443648
```
If any of these differ, stop: the partition offsets in this repo won't match your eMMC.

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
python tools/super_to_citaq.py write super.img ADB          # ~3 GB in 128 MiB pieces, each MD5-checked, then a full verify
python tools/super_to_citaq.py nofbe super.img ADB          # /data without file-based encryption (no OP-TEE on the Citaq)
python tools/super_files.py patch super.img ADB patches/services_patch.json
python tools/super_files.py patch super.img ADB patches/oat_rename.json
python tools/super_files.py patch super.img ADB patches/services_patch2.json
python tools/super_files.py patch super.img ADB patches/touch_service.json
python tools/super_to_citaq.py zero ADB                     # blank metadata/cache/userdata so Android 10 formats them
```
If `write` stops part-way, re-run it with `--start N` as it tells you. Run the patches **in this
order**, because each one checks the bytes it expects to find.

## 8. Put Android 10 in the recovery slot

```sh
python tools/flash_slot.py ADB recovery citaq-a10.img
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

Put these in one folder: `device/citaq-boot.sh`, `src/out/{ilits.bin,blshim,volshim,propset}`,
`src/thermalstub/thermalstub.jar` and `bcmdhd.ko` (from the release). Optionally add a 1024×768
`bootlogo.png`.

```sh
python tools/install_data.py ADB that-folder/
adb reboot recovery
```
On this boot, touch, Wi-Fi, sound, brightness, the printer/LEDs and network adb (port 5555) all come up.
`/data/citaq/*.log` shows what the hook did.

> The boot hook rotates the screen 180° (`user_rotation 2`) for the **assembled** case. On the bench
> the picture will be upside down. Edit the `user_rotation 2` line in `citaq-boot.sh` if you mount it
> the other way.

## 11. Make Android 10 the default boot

Once you're happy:
```sh
python tools/flash_slot.py ADB boot citaq-a10.img
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

Rebuild (step 5), then `flash_slot.py ADB boot new.img`. You can update the recovery slot as well,
or keep the old image there as a known-good spare.
