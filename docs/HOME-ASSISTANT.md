# Using it as a Home Assistant kiosk

The terminal makes a good wall panel: a 10" touch screen, a receipt printer, two status LEDs, three USB
ports (barcode scanner, SDR dongle, USB mic…) and a stand. On Android 10 it runs the **current** Home
Assistant Companion app and a current WebView, so modern dashboards and custom cards work.

## The app

- Install the Home Assistant app from Play.
- Log in as a local-only, non-admin HA user made for the kiosk.
- `citaq-boot.sh` opens the app on every boot, so the dashboard comes back after a power cut.
- Deep links work for jumping to a view:
  `am start -a android.intent.action.VIEW -d 'homeassistant://navigate/<dashboard>/<view>' io.homeassistant.companion.android`

## Control over adb

The boot hook sets `persist.adb.tcp.port 5555`, so HA's **Android Debug Bridge** integration can
connect to `<terminal-ip>:5555` and gives you a `media_player` entity. Use its
`androidtv.adb_command` action for anything:

| What | Command |
|---|---|
| screen off / on | `input keyevent 223` / `input keyevent 224` |
| brightness (0–255) | `settings put system screen_brightness 40` |
| media volume (0–15) | `media volume --stream 3 --set 8` |
| red LED on / off | `echo 1 > /sys/class/gpio/gpio124/value` / `echo 0 …` |
| blue LED | `/sys/class/gpio/gpio106/value` |
| relaunch the app | `am start -n io.homeassistant.companion.android/.launch.LaunchActivity` |
| reboot | `reboot` |

(`monkey` doesn't work on this build: it aborts with "SYS_KEYS has no physical keys".)

The terminal accepts **one adb connection at a time**. If you connect from a PC, HA's connection
drops until you disconnect.

## Receipt printer

`ha/kiosk.yaml` (a HA package) plus `ha/kiosk_print.py` print text, QR codes and dithered images:

1. Copy `kiosk_print.py` to `/config/kiosk/` and `kiosk.yaml` to `/config/packages/`. Packages need
   `homeassistant: packages: !include_dir_named packages` in `configuration.yaml`.
2. Rename `media_player.kiosk` in the YAML to your ADB entity.
3. For images, HA's Python needs Pillow (it's in the standard HA images). Put pictures in `/media/kiosk`.
4. Call it from anywhere:
   ```yaml
   action: script.kiosk_job
   data:
     mode: text        # text | image | qr
     data: "Washing machine finished"
     size: big
     align: centre
   ```

**Upside-down printing (on by default).** The paper comes out of the H10-3 towards you, top edge
first, so a normal print reads upside down from the front. `kiosk_print.py` therefore prints flipped
by default:
- text uses the printer's upside-down mode (`ESC { 1`) with the lines sent in reverse order
- images are rotated 180°
- QR codes scan at any angle, so they're left as they are

A receipt made of **several jobs** has to be sent **bottom part first**: QR, then body, then title,
with `cut: "on"` only on the last one. Pass `flip: "off"` to print the normal way.

How it works: HA builds the ESC/POS bytes, uploads them with `androidtv.upload`, then runs
`cat job.bin > /dev/ttyS1`. The boot hook sets the port to 115200 raw with CTS flow control and
makes it writable. Feed, cut and cash-drawer-kick scripts are included too.

## Barcode scanners

USB HID scanners type into whatever has focus. To catch scans in the background, read the scanner's
`/dev/input/eventN` directly from a small daemon and post each code to an HA webhook. That way the
screen doesn't need a text box in focus.
