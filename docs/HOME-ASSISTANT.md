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
| screen (backlight) off / on | `script.kiosk_screen` with `on: false` / `on: true` (see [Screen off](#screen-off)). `input keyevent 223/224` don't work: the car firmware ignores sleep requests |
| brightness (10–255) | `settings put system screen_brightness 40` (Android won't go below 10; needs `blshim` running) |
| media volume (0–15) | `media volume --stream 3 --set 8` |
| red LED on / off | `echo 1 > /sys/class/gpio/gpio124/value` / `echo 0 …` (or `script.kiosk_led`, below) |
| blue LED | `/sys/class/gpio/gpio106/value` |
| extra outputs on the LED header (CN5 pins 5, 6, 8) | `/sys/class/gpio/gpio27/value`, `gpio26`, `gpio118`; off unless `/data/citaq/cn5-gpio` exists (see [HARDWARE.md](HARDWARE.md#led-header-cn5)) |
| relaunch the app | `am start -n io.homeassistant.companion.android/.launch.LaunchActivity` |
| reboot | `reboot` |
| CPU temperature (millidegrees, e.g. `55000` = 55 °C; needs the 21 Nov 2026 DTB to be accurate) | `cat /sys/class/thermal/thermal_zone0/temp` |

(`monkey` doesn't work on this build: it aborts with "SYS_KEYS has no physical keys". Don't use it
anyway: before aborting it resets the screen rotation to 0° and turns auto-rotate on, which turns an
assembled terminal's display upside down. Fix with
`adb shell "settings put system accelerometer_rotation 0; settings put system user_rotation 2"`.)

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

How it works: HA builds the ESC/POS bytes and uploads them with `androidtv.upload`. One adb command
then asks the printer for its status and, only if it's ready, sends the job and watches the UART's
byte counter until every byte has gone. The boot hook sets the port to 115200 raw with CTS flow
control and makes it writable. Feed, cut, cash-drawer-kick and printer-buzzer-off
(`kiosk_buzzer_off`) scripts are included too.

### When the printer has a problem

Every job asks the printer first (ESC/POS `DLE EOT`, about half a second). If the lid is open, the
paper is out, the cutter is jammed or the printer doesn't answer, **nothing is sent**, and:

- HA shows a notification and the **red LED blinks**
- `input_text.kiosk_printer_status` says what's wrong (`out of paper`, `lid open`, ...); it's `ok`
  after a good print
- if you put a Companion app notify action in `input_text.kiosk_notify_target` (for example
  `notify.mobile_app_kiosk`), the terminal itself shows a pop-up
- every 30 seconds HA looks again, so the LED, pop-up and notification clear by themselves once the
  paper is in and the lid is shut

If the printer stops taking data part-way through a job (paper runs out mid-receipt), HA gives up
waiting after 10 seconds and raises the same alert, instead of hanging. That matters because the ADB
integration has only one connection: a print that never finishes used to freeze every other kiosk
command too. The job stays queued on the terminal and finishes once the printer is fixed, or
`script.kiosk_printer_cancel` drops it.

`script.kiosk_printer_check` reads the status on demand and returns `ok`, `problem` and `warning`
(`paper running low`). The four reply bytes, for reference:

| State | Status | Offline cause | Error | Paper sensor |
|---|---|---|---|---|
| Ready | `16` | `12` | `12` | `12` |
| Lid open | `1e` | `36` | `12` | `72` |
| Out of paper, lid shut | `1e` | `32` | `12` | `72` |

**Multi-part receipts:** HA doesn't pass a failed `kiosk_job` back to the script that called it, so
check the status between parts, or the later parts will be tried anyway:

```yaml
- action: script.kiosk_job
  data: {mode: image, data: logo.png, cut: "off"}
- condition: state
  entity_id: input_text.kiosk_printer_status
  state: ["ok", "paper running low"]
- action: script.kiosk_job
  data: {mode: text, data: "Washing machine finished"}
```

### The beeper

The printer has its own alarm for no paper or lid open. `input_boolean.kiosk_printer_beeper` (off by
default) controls it: switching it sends the Citaq buzzer command, and it's sent again whenever the
terminal comes back online, because the printer powers up with the beeper on. Print jobs deliberately
don't reset the printer (`ESC @`) or touch the buzzer setting: doing that in every job made the printer
pause and beep between the parts of a receipt.

## Screen off

The car firmware's power manager ignores sleep requests, so `input keyevent 223` (sleep) and `224`
(wake) do nothing. `script.kiosk_screen` in `ha/kiosk.yaml` switches the **backlight** instead:
`on: false` sets it to 0 (fully dark), `on: true` puts Android's brightness back.

```yaml
action: script.kiosk_screen
data:
  "on": false
```

Android keeps running underneath, so the dashboard stays live and a touch on the dark screen still
taps whatever is under your finger. A motion sensor or a schedule is a better way to turn it back on.
Moving the brightness slider (or `settings put system screen_brightness …`) also turns it back on.

If neither this nor the brightness slider changes anything, check that `blshim` is running:
`adb root`, then `adb shell "ps -A | grep blshim; cat /data/citaq/blshim.log"`.

If brightness works **backwards** (255 = dark, the slider dims as you drag it up, screen off turns it fully
on), your terminal's backlight runs the other way round. Fix it with `adb root`, then
`adb shell touch /data/citaq/backlight-invert` and a reboot (needs the boot hook and `blshim` from
23 Nov 2026 or later). `blshim.log` then ends in `, inverted)`.

## LEDs

Two status LEDs, red and blue, on plain on/off pins: they're either on or off, there's no
brightness control. `script.kiosk_led` in `ha/kiosk.yaml` drives them (same setup as the printer
above). Flashing patterns run as a small loop **on the terminal**, so they stay smooth at any speed
and the automation that started them carries on straight away. Each call stops whatever pattern
was running before and sets both LEDs, so the newest alert always wins.

| Field | Values | Default |
|---|---|---|
| `pattern` | `off`, `solid`, `blink`, `alternate` (red ↔ blue) | `solid` |
| `colour` | `red`, `blue`, `both` (for `solid` and `blink`) | `red` |
| `speed` | ms each light stays on/off, 50 or more (`blink`, `alternate`) | `500` |
| `duration` | seconds before it switches itself off, `0` = until the next call | `0` |

```yaml
action: script.kiosk_led
data:
  pattern: blink
  colour: blue
  speed: 800
```

Turn them off with `pattern: "off"`. Flashing patterns need the Android 10 port; `off` and `solid`
also work on stock 5.1. Calls from before Nov 2026 (`state: "on"`/`"off"` with a `colour`) still work.

To try patterns without writing YAML, the package adds four helpers (**Kiosk LED pattern**, **colour**,
**speed** and **duration**) and `script.kiosk_led_from_dashboard`, which runs the LEDs with whatever
they're set to. Put them on a dashboard and press the script's Run button.

Example: washer finished. This needs a power-monitoring plug or sensor on the washer.

```yaml
triggers:
  - trigger: numeric_state
    entity_id: sensor.washing_machine_power
    below: 3
    for:
      minutes: 2
actions:
  - action: script.kiosk_led
    data:
      pattern: blink
      colour: blue
      speed: 800
  - action: notify.mobile_app_<your_terminal>
    data:
      message: TTS
      data:
        tts_text: "The washing machine has finished"
        media_stream: music_stream
```

The trigger only fires when the power drops from above 3 W to below it, so it doesn't repeat while
the washer sits idle. Stop the LED with `pattern: "off"` from a dashboard button, or from a second
automation (the washer door opening, say).

HA doesn't know whether an LED is on. If you want a dashboard to show it, add an `input_boolean` and
set it in the same automation.

## Text-to-speech

The ADB `media_player` sends commands; it can't play media. Two ways to make the terminal talk:

1. **The Companion app's TTS notification.** Nothing to install, and it works with the screen off.
   It uses Android's voice (Google Speech Services is in the image), not your HA voice:
   ```yaml
   action: notify.mobile_app_<your_terminal>
   data:
     message: TTS
     data:
       tts_text: "The washing machine has finished"
       media_stream: music_stream
   ```
   Find the name under Settings → Devices & services → Mobile App. On Android 10 the app registers
   as a new device whose model shows as **PX5**. If you used the app on stock 5.1, the old entry
   (Android version 22) is dead: HA says the message was sent but it never arrives. Delete it.
2. **Browser Mod (HACS)** registers the dashboard in the Companion app as a `media_player`, so
   `tts.speak` with your HA voice, chimes and media URLs work. It only plays while the app is open on
   screen, which on a kiosk is nearly always.

## Barcode scanners

USB HID scanners type into whatever has focus. To catch scans in the background, read the scanner's
`/dev/input/eventN` directly from a small daemon and post each code to an HA webhook. That way the
screen doesn't need a text box in focus.
