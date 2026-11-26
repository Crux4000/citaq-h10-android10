# 4G modem (Fibocom NL668-EAU)

> **Status: registers on LTE, sends SMS, mobile data works at the Linux level.** The modem powers up, its
> drivers load, it answers AT commands, has a good signal and sees all three Australian carriers. With an
> active SIM it **registers on LTE, sends SMS and gives Android mobile data** (opt-in, see
> [Android mobile data](#android-mobile-data-opt-in), 26 Nov 2026). Receiving SMS is unconfirmed (that SIM may
> be data-only). The Huawei ME909s fitted to some terminals has registered on LTE, **sent and received SMS**
> and **gives Android mobile data** with the same opt-in (see [Other modems](#other-modems)).
> **If you try it, please open an issue or comment on this repo and say what worked or what failed** (with your
> carrier and the output of `device/modem/at-probe.sh`). That's how this gets from "should work" to "works".

The H10-3 has a **Fibocom NL668-EAU** LTE module on the compute board, with its own SIM slot. It sits on the
internal USB hub at **1-1.1**. Some terminals have a **Huawei ME909s-120** in the same slot instead (see
[Other modems](#other-modems)). Everything below was tested on the NL668.

## What the port does

Nothing in the PX5 Android 10 build powers the modem, so it's off by default. The stock Citaq device tree drove
it through Rockchip's `rk_bp_auto` driver with three pins:

| Signal | Pin | Linux GPIO | Stock DT flag |
|---|---|---|---|
| power key | gpio0 D4 | 28 | active-low |
| reset | gpio3 B5 | 109 | active-low |
| W_DISABLE (radio off) | gpio3 B1 | 105 | active-low |

At boot all three are inputs. Driving **all three high** (key released, out of reset, radio enabled) brings the
modem up about 14 s later. No power-key pulse is needed. The boot hook (`device/citaq-boot.sh`, section `3b`)
does this on every boot. To keep the modem off, create the file `/data/citaq/no-modem`.

The PX5 kernel already has both drivers:

- `option` → **`/dev/ttyUSB0`–`3`**. **`ttyUSB2`** is the AT command port (1 and 3 answer too; 0 doesn't).
- `qmi_wwan` → **`wwan0`** plus the QMI control device `cdc-wdm0` (see the note under "Testing with an active SIM"): the data
  path, for mobile data without Android's phone stack.

USB ID `1508:1001` ("Fibocom Wireless Inc. / Fibocom Modem"). `AT+GTUSBMODE?` reports `17`.

Checked after a reboot with the boot hook: the four `ttyUSB` ports appear (owner `radio`, mode 666), `wwan0`
exists (down, as expected without a SIM), and **nothing else holds the ports**. The ROM's `rild` does run, but
it doesn't recognise the NL668 (see [Mobile data](#mobile-data)), so it never opens the ports and doesn't fight
scripts over the AT port. Bluetooth (which shares nothing with the modem) is unaffected.

One gotcha: these serial ports come up with `iuclc` set, so replies arrive in lowercase (`ok`) and scripts
looking for `OK` miss them. The boot hook sets the ports raw without case mapping, and world-writable like the
printer port so Home Assistant can use them over adb.

## Testing it

`device/modem/at-probe.sh` finds the AT port and runs the basic checks, then a network scan (up to 3 minutes):

```sh
adb push device/modem/at-probe.sh /data/local/tmp/
adb shell "su 0 sh /data/local/tmp/at-probe.sh; cat /data/local/tmp/at-probe.log"
```

What it showed on the test terminal, **without a SIM**:

| Command | Result |
|---|---|
| `ATI` | Fibocom Wireless Inc., NL668-EAU, revision `19005.1000.00.02.73.12`, IMEI |
| `AT+CFUN?` | `1,0` (radio fully on) |
| `AT+CPIN?` | `ERROR` (no SIM) |
| `AT+CSQ` | `21,99` (about −71 dBm: antenna connected and good) |
| `AT+CREG?` / `AT+CEREG?` | `0,0` (not registered, as expected without a SIM) |
| `AT+COPS=?` | Optus AU 50502, Telstra Mobile 50501, vodafone AU 50503, all LTE |

**With a SIM** (23 Nov 2026, an old SIM that came in the terminal, probably no longer active): the board's
SIM slot works on Android 10. `AT+CPIN?` gave `READY`, and the network scan marked Optus as available and
Telstra and Vodafone as forbidden, so the modem read the SIM's home network. It stayed at `+CEREG: 0,2`
(searching) and never registered, as expected for a cancelled SIM.

**With an active SIM** (26 Nov 2026, in a 3D-printed micro-to-standard adaptor): registered on LTE on its home
network (`+CEREG: 0,1`, `+COPS: 0,0,"iiNet",7`) with a strong signal (`+CSQ: 25`, about −63 dBm), and
`sms-test.sh` sent a text that arrived (`+CMGS: 5`). Texts sent *to* the terminal didn't arrive, while the same
phone could text others. The modem was set up to accept them (`+CSMS: 0,1,1,1`, storage free), so it's likely the
SIM's plan (possibly data-only); not settled yet. The NL668's default `+CNMI: 0,0,0,0,0` means no new-message
notices: `AT+CNMI=2,1,0,0,0` (resets on reboot) makes it announce each stored text with `+CMTI: "ME",<index>`.

## Testing with an active SIM

The steps below. Please report back either way.

1. **Registration:** `AT+CPIN?` should say `READY`, `AT+CEREG?` should end in `,1` (home) or `,5` (roaming),
   and `AT+COPS?` should name the carrier.
2. **SMS** (text mode). `device/modem/sms-test.sh` sends one message (works on both the NL668 and the Huawei ME909s); send it
   to your own phone:
   ```sh
   adb push device/modem/sms-test.sh /data/local/tmp/
   adb shell "su 0 sh /data/local/tmp/sms-test.sh +61400000000 'Test from the Citaq'"
   ```
   It ends with `RESULT: sent` when the modem answers `+CMGS`. By hand it's `AT+CMGF=1`, then
   `AT+CMGS="+61400000000"`, then the text at the `>` prompt, ended with Ctrl-Z (byte 0x1A).
   Useful as a backup alert path for Home Assistant when Wi-Fi or the internet is down.
3. **Data:** untested, see [Mobile data](#mobile-data) below. On the NL668 that means QMI on `wwan0`, for
   example with `qmicli`/`uqmi`-style tools (not on the device yet) or the modem's own dial-up commands. Note that the kernel registers `cdc-wdm0`, but Android's ueventd
   doesn't create `/dev/cdc-wdm0`, so QMI tools would first need the node made by hand (`mknod`, major/minor
   from `/sys/class/usbmisc/cdc-wdm0/dev`).

**Android's mobile data needs a RIL** (radio interface layer) that knows the modem; without one, Settings →
Mobile network is greyed out even when the modem has registered. Stock Citaq's `ril-nl668.so` is for
Android 5 and 32-bit. The PX5 ROM has `RIL_RK_DATA_V10.0`, Rockchip's generic data-only RIL for USB 3G/4G
dongles, which only drives modems in its built-in list. Neither the NL668 nor the ME909s is in that list as
shipped; the boot hook can patch them in (see [Android mobile data](#android-mobile-data-opt-in)). SMS is
not handled by that RIL at all, so SMS stays on AT commands.

## Mobile data

Two layers are needed, and both now work on the NL668:

1. **A data link in Linux.** Possible routes:
   - **PPP dial-up** on one of the modem's `ttyUSB` ports (`ATD*99***1#` uses context 1 and its APN). The
     kernel has PPP built in and the image has `pppd` and `chat`. **Works on the NL668** (26 Nov 2026, see
     [PPP test](#ppp-test) below). Simple and works with almost any modem, but PPP over a USB serial port
     tops out at roughly 10-20 Mbit/s.
   - **The modem's fast data interface** (full LTE speed): QMI on `wwan0` for the NL668 (`qmi_wwan` already
     binds), or the ME909s's own network interface: in its current USB layout it already shows up as a CDC
     Ethernet `wwan0` (`cdc_ether`), started with Huawei's `AT^NDISDUP` plus DHCP. Neither is wired into
     Android yet.
2. **Android using it.** Android 10 sends each app's traffic over networks its connectivity service knows
   about, so a link brought up by hand mostly isn't used by apps (root shell tools do use it). That needs a
   RIL: see [Android mobile data](#android-mobile-data-opt-in).

### Android mobile data (opt-in)

The ROM's Rockchip RIL dials PPP and hands the link to Android as mobile data, but only for modems in its
built-in table. The boot hook (section 3b2) can patch our two modems into that table at boot:

```sh
adb shell "su 0 touch /data/citaq/mobile-data"
adb reboot
```

At boot the hook checks the stock library's MD5, copies it to `/data/citaq/ril/`, rewrites two entries for
modems no H10 ships with (Fibocom NL668 `1508:1001`: AT on `ttyUSB2`, PPP on `ttyUSB3`; Huawei ME909s
`12d1:15c1`: AT on `ttyUSB2`, PPP on `ttyUSB0`), fixes how it hangs up (it called a `busybox` this ROM doesn't
have, so `pppd` kept running when mobile data was switched off and the next connect failed with "port busy"),
checks the result's MD5, bind-mounts it over the original and restarts `rild`. Nothing on `/vendor` is
changed; `/data/citaq/ril/ril.log` says what it did.

After a reboot Settings → Network → Mobile network is no longer greyed out, the status bar shows LTE, and
Android uses mobile data **only when Wi-Fi/Ethernet are down** (Wi-Fi stays the default). The APN comes from
the modem's stored context 1 (`AT+CGDCONT?`) or Android's APN settings.

| Modem | Result |
|---|---|
| Fibocom NL668-EAU | ✅ works (26 Nov 2026, Vodafone AU): `MOBILE[LTE] CONNECTED`, pings and DNS fine, switching mobile data off and on works |
| Huawei ME909s-120 | ✅ works (26 Nov 2026, Telstra, unit 2): `MOBILE[LTE] CONNECTED`, validated, browsing over LTE with Wi-Fi off |

Things to know:

- **SMS scripts and the RIL both want the AT port.** `rild` holds `ttyUSB2` open the whole time, so
  `at-probe.sh`, `sms-test.sh` and an SMS bridge on that port will clash with it. That's why it's opt-in. In
  practice (ME909s, 26 Nov 2026) `sms-test.sh` on `ttyUSB2` still sends the text, but the RIL reads the same
  port and can take the modem's `+CMGS` answer, so the script times out and can't say whether it was sent; the
  script now warns about this. On the NL668 the QMI option below frees `ttyUSB3` for them. A second AT port on
  the ME909s would do the same; not found yet. Otherwise leave mobile data off, or stop the RIL first
  (`adb shell "su 0 setprop ctl.stop vendor.ril-daemon"`, `ctl.start` to bring it back); stopping it while
  connected can leave the modem's data call open until the next reboot.
- **Speed:** PPP over a serial port. Fine as a backup link for Home Assistant.
- **To undo:** `adb shell "su 0 rm /data/citaq/mobile-data"` and reboot. The stock library is back.
- If `ril.log` says the MD5 differs, your ROM's library isn't the one this was made for; please open an issue.

#### Faster: QMI instead of PPP (Fibocom NL668, opt-in)

The NL668 also has a QMI data interface (`wwan0`, `qmi_wwan` driver, `/dev/cdc-wdm0` control channel). Section
3b3 of the boot hook can use it for the data link while the RIL still does everything else: the RIL's "dial
PPP" step (`/etc/ppp/call-pppd`) is swapped for `qmidial` (`src/qmidial.c`, a small static QMI client built by
`src/build.sh`). It starts the call over QMI in raw-IP mode, renames `wwan0` to `ppp0` and sets the same
properties `pppd` would, so the RIL and Android see a normal mobile link. It runs as `pppd` so the RIL's hang-up
stops it too. A small root watcher keeps `/dev/cdc-wdm0` and the kernel's raw-IP switch right, including after
the modem resets.

```sh
src/build.sh                                                   # builds out/qmidial (or install_data.py picks it up)
adb push src/out/qmidial /data/local/tmp/
adb shell "su 0 sh -c 'cp /data/local/tmp/qmidial /data/citaq/qmidial; chmod 755 /data/citaq/qmidial; touch /data/citaq/mobile-data /data/citaq/mobile-data-qmi'"
adb reboot
```

Check with `adb shell "su 0 cat /data/citaq/ril/ril.log /data/citaq/qmi/qmi.log"` (the first ends in `data
link: QMI`). Why bother:

- **No serial-port limit:** the link runs at whatever the network gives (PPP over the USB serial port is the
  bottleneck at LTE speeds). On the reference terminal, the kiosk itself (`nc` downloads at 1 GHz) topped out
  before the link did, so there's no clean number yet.
- **`ttyUSB3` stays free:** SMS and AT scripts can use it while mobile data is on:
  `adb shell "su 0 sh -c 'PORT=/dev/ttyUSB3 sh /data/local/tmp/sms-test.sh <number>'"`.

Seen on the reference terminal (26 Nov 2026), with PPP and with QMI alike: the NL668 sometimes drops off USB
and comes back ~15 s later (a modem reset), often around a data connect. The RIL reconnects by itself and the
hook's watcher re-arms QMI, so data comes back within a minute, but the cause isn't known yet (power, SIM
contact and the RIL's `AT+CGACT=0,1` before each connect are suspects). `dmesg | grep "usb 1-1.1: new"` counts
them; please report if you see it too.

NL668 only; the ME909s has no QMI (its fast interface is a CDC Ethernet one, not wired up yet). Undo with
`rm /data/citaq/mobile-data-qmi` and a reboot, which goes back to PPP.

### PPP test

`device/modem/ppp-test.sh` dials PPP on `ttyUSB3`, pings out through that link only, then hangs up. Wi-Fi,
Ethernet and Android's routing are left alone: it adds no default route, sends only traffic bound to `ppp0`
out of it through a temporary rule, and removes the rule afterwards. Needs a registered SIM with an active data
context (`AT+CGACT?` shows `1,1`). It's for terminals **without** the mobile-data option: with
`/data/citaq/mobile-data` on, the RIL already uses the PPP port, so this fails with "Connect script failed".
On the ME909s the PPP port is `ttyUSB0` (`PORT=/dev/ttyUSB0`).

If an `adb shell "..."` line with nested quotes gives syntax errors on your PC (fish, the default shell on
CachyOS, quotes differently from bash), type `adb shell`, then `su`, and run the part inside the quotes
directly on the terminal.

```sh
adb push device/modem/ppp-test.sh /data/local/tmp/
adb shell "su 0 sh /data/local/tmp/ppp-test.sh; cat /data/local/tmp/ppp-test.log"
```

On the NL668 (26 Nov 2026, LTE, `+CSQ` 21-25): `CONNECT` straight away, `ppp0` up with an address and DNS
servers in 2 s, 1.1.1.1 and 8.8.8.8 answered every ping (0 % loss, 18-170 ms, typically 30 ms), and it hung
up cleanly. The network accepted the APN stored in the modem (`AT+CGCONTRDP` shows the APN and addresses it
handed out). pppd has to run in its own session (`setsid`): started straight from an adb shell, it gets SIGHUP
when that shell closes and hangs up a second after connecting.

**What the ROM already has** (checked on the reference terminal, 26 Nov 2026):

- `rild` runs at boot (`vendor.ril-daemon`) with Rockchip's dongle RIL, `/vendor/lib64/libril-rk29-dataonly.so`
  (data only, no calls or SMS). Every 3 seconds it reads the modem's USB ID and looks it up in a built-in list
  of supported modems. If it finds a match it takes an AT port and dials **PPP** with `/etc/ppp/call-pppd`
  (`pppd`, `chat` and the `ip-up`/`ip-down` scripts are all in the image), and Android treats that as mobile
  data.
- **Fibocom NL668 (`1508:1001`): not in the list.** The radio log repeats `tty Device id is: 1508/1001`,
  `match model count=0`, `Not support modem!!!!`, so Settings → Mobile network stays greyed out.
- **Huawei ME909s (`12d1:15c1`): not in the list either.** The name `ME909S` appears in the library's
  strings, but under a different USB ID; a tester's log showed the same `Not support modem!!!!` for
  `12D1/15C1`.
- Both are fixed by the opt-in patch above.
- Also in the image: `libril-ec20.so` (Quectel's QMI RIL for the EC20, which uses the same Qualcomm platform as
  the NL668) and AOSP's `libreference-ril.so`.

**To help, run `device/modem/modem-data-probe.sh`** and post the log in an issue. It's read-only (it only
reads system files and sends AT queries; no dialling or mode changes) and works with or without a SIM. It
lists the modem's USB interfaces and their drivers, the dial-up and RIL pieces present in the image, the RIL
properties, init entries and recent RIL log (whether it recognised the modem), and the modem's data-related
AT settings:

```sh
adb push device/modem/modem-data-probe.sh /data/local/tmp/
adb shell "su 0 sh /data/local/tmp/modem-data-probe.sh; cat /data/local/tmp/modem-data-probe.log"
```

Long numbers show as `[hidden]` and IP addresses in the data-context lines as `[ip]`; check the log before
posting anyway, and paste it inside a code block.

## Other modems

Citaq fits different modules to the same board. So far:

| Module | Seen on | Status on Android 10 |
|---|---|---|
| Fibocom NL668-EAU | unit 1 in [DEVICES.md](DEVICES.md) | ⚠️ registers on LTE, **sends SMS**, **Android mobile data** (opt-in, PPP or QMI); receiving SMS unconfirmed |
| Huawei ME909s-120 | units 2 and 3 | ⚠️ powers up and answers AT commands (units 2 and 3), reads the SIM, **registers on LTE**, **sends and receives SMS**, **Android mobile data** (opt-in, PPP; unit 2) |

The ME909s sits in the same mini PCIe slot, and the boot hook powers it the same way. On unit 2 (23 Nov 2026,
[#4](https://github.com/Crux4000/citaq-h10-android10/issues/4)) it came up under the `option` driver and
answered AT on **`ttyUSB2`**, same as the Fibocom:

| Command | Result (no SIM) |
|---|---|
| `ATI` | Huawei Technologies Co., Ltd., ME909s-120 V2, revision `11.617.24.00.00` |
| `AT+CFUN?` | `1` (radio fully on) |
| `AT+CPIN?`, `AT+CSQ`, `AT+CREG?`, `AT+COPS?` | `+CME ERROR: 10` (SIM not inserted) |
| `AT+CEREG?` | `0,2` (not registered, searching) |
| `AT+COPS=?` | `+CME ERROR: 10`: unlike the Fibocom, the ME909s won't scan for networks without a SIM |
| unprompted (`^HCSQ`, `^RSSI`) | `^HCSQ: "LTE",42,30,86,16` and `^RSSI: 17`: it hears LTE at about −79 dBm (RSRP about −111 dBm), even though this unit's antennas have been removed. `at-probe.sh` now also asks for this with `AT^HCSQ?`, plus the SIM state with `AT^SYSINFOEX` |

With a SIM in (23 Nov 2026), after a full power-off and reseating the SIM in its adaptor: `AT+CPIN?` gave
`READY`, so the ME909s reads SIMs through the board's slot. The scan found Optus (available) and Vodafone
(forbidden), but with no antennas fitted the signal came and went (`+CSQ: 16`, then `^RSSI: 99`) and it didn't
register (`+CEREG: 0,2`, `^SRVST: 0`); that SIM turned out to be inactive.

Unit 3 (23 Nov 2026, no SIM) gave the same results on `ttyUSB2` with an older firmware revision,
`11.617.15.00.00`.

With an **active SIM** (Kogan Mobile, still no antennas): it **registered on LTE**. `+CREG: 0,1`, `+CEREG: 0,1`
(home network), `+COPS: 0,0,"KOGAN",7`, `+CSQ: 12` (about −89 dBm). The scan showed Kogan (50503) as the
current network, Optus as available and Telstra as forbidden. This is the first modem to register on a network
on the Android 10 port.

**SMS works** (23 Nov 2026, same SIM): `sms-test.sh` got `+CMGS: 162` back (`RESULT: sent`) and the text
arrived on the phone. Since then the reporter has run it on Wi-Fi antennas salvaged from other hardware, which
work well enough for an SMS bridge to Home Assistant.

**Receiving works too** (26 Nov 2026): texts sent to the terminal are stored on the modem and listed in text
mode, so Home Assistant can poll for them over adb:

```
AT+CMGF=1
OK
AT+CMGL="ALL"
+CMGL: 1,"REC READ","+614xxxxxxxx",,"26/11/26,17:01:04+44"
Test
+CMGL: 2,"REC UNREAD","+614xxxxxxxx",,"26/11/26,17:11:04+44"
Test
```

`AT+CMGL="REC UNREAD"` lists only new ones (and marks them read), and `AT+CMGD=<index>` deletes one so the
SIM's storage doesn't fill up.

**Android mobile data works** (26 Nov 2026, Telstra SIM, unit 2). The stock RIL doesn't recognise the ME909s
(`12d1:15c1`) as shipped; the opt-in patch in [Android mobile data](#android-mobile-data-opt-in) adds it (AT on
`ttyUSB2`, PPP on `ttyUSB0`). With Wi-Fi off, `dumpsys connectivity` showed `MOBILE[LTE] CONNECTED` on `ppp0`,
validated, and a what's-my-IP site showed a Telstra address. The APN came from Android's APN list (Telstra
Internet). `ppp-test.sh` fails with "Connect script failed" while this is on, as expected (the RIL holds
`ttyUSB0`). In its current USB layout the ME909s also shows a CDC Ethernet `wwan0` (`cdc_ether` binds it), so a
faster non-PPP route exists too, not wired up yet. If you have one, please run `at-probe.sh` and
`modem-data-probe.sh` and open an issue with the logs. The script shows the IMEI and other long numbers as
`[hidden]`, but check the log before posting anyway, and paste it inside a ```` ``` ```` code block so GitHub
keeps the layout.

After boot, `/data/citaq/modem.log` shows which modem came up (its USB ID) and which `ttyUSB` ports it
made: `1508:1001` is the Fibocom, `12d1:xxxx` a Huawei. If a modem causes any trouble (for example an
extra network interface Android tries to use), `adb shell "touch /data/citaq/no-modem"` and a reboot
leave it switched off.
