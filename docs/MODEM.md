# 4G modem (Fibocom NL668-EAU)

> **Status: hardware works, not tested with an active SIM.** The modem powers up, its drivers load, it answers
> AT commands, has a good signal and can see all three Australian carriers. Registering on a network, SMS and
> mobile data have **not** been tried yet on the NL668, because the test terminal has no active SIM. The
> Huawei ME909s fitted to some terminals has registered on LTE and **sent and received SMS** (see
> [Other modems](#other-modems)).
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
- `qmi_wwan` → **`wwan0`** plus the QMI control device `cdc-wdm0` (see the note under "Not tested yet"): the data
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
(searching) and never registered, as expected for a cancelled SIM. Registration, SMS and data still need an
active SIM.

## Not tested yet (needs an active SIM)

With a SIM in, these are the things to try. Please report back either way.

1. **Registration:** `AT+CPIN?` should say `READY`, `AT+CEREG?` should end in `,1` (home) or `,5` (roaming),
   and `AT+COPS?` should name the carrier.
2. **SMS** (text mode). `device/modem/sms-test.sh` sends one message (works on a Huawei ME909s, not yet tried on the NL668); send it
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

**Android's own mobile data and SMS apps don't use the modem (yet),** which is why Settings → Mobile network
is greyed out even when the modem has registered. That needs a RIL (radio interface layer) that knows the
modem. Stock Citaq's `ril-nl668.so` is for Android 5 and 32-bit. The PX5 ROM reports
`gsm.version.ril-impl = RIL_RK_DATA_V10.0`, Rockchip's generic RIL for USB 3G/4G dongles. It runs, but it
only drives modems in its built-in list, and the NL668 isn't one of them (the Huawei ME909s is; see
[Mobile data](#mobile-data)). Talking to the modem directly over AT/QMI is the practical route for now.

## Mobile data

Not working yet on either modem; this is the plan and what's still unknown. Two layers are needed:

1. **A data link in Linux.** Possible routes, easiest first:
   - **PPP dial-up** on one of the modem's `ttyUSB` ports (`ATD*99#` plus your carrier's APN). The kernel has
     PPP built in; it needs a `pppd` binary on the system. Slowest, but no new driver.
   - **The modem's fast data interface:** QMI on `wwan0` for the NL668 (driver already binds), or Huawei NCM
     (`AT^NDISDUP`) for the ME909s, which needs `huawei_cdc_ncm` (not in this kernel; it would be built as a
     module like `bcmdhd.ko`) unless the modem can be switched to a mode the kernel already has (MBIM, ECM)
     with `AT^SETPORT`. Check Huawei's AT manual before changing ports: a wrong setting can hide the AT port.
2. **Android using it.** Android 10 sends each app's traffic over networks its connectivity service knows
   about, so a link brought up by hand mostly isn't used by apps (root shell tools do use it). The proper
   fix is a RIL that drives the modem. See below: one is already running.

**What the ROM already has** (checked on the reference terminal, 26 Nov 2026):

- `rild` runs at boot (`vendor.ril-daemon`) with Rockchip's dongle RIL, `/vendor/lib64/libril-rk29-dataonly.so`
  (data only, no calls or SMS). Every 3 seconds it reads the modem's USB ID and looks it up in a built-in list
  of supported modems. If it finds a match it takes an AT port and dials **PPP** with `/etc/ppp/call-pppd`
  (`pppd`, `chat` and the `ip-up`/`ip-down` scripts are all in the image), and Android treats that as mobile
  data.
- **Fibocom NL668 (`1508:1001`): not in the list.** The radio log repeats `tty Device id is: 1508/1001`,
  `match model count=0`, `Not support modem!!!!`, so Settings → Mobile network stays greyed out.
- **Huawei ME909s: in the list** (`HUAWEI lte ME909S`, also the `MU709` found in Citaq V8 terminals). So
  terminals with an ME909s may get Android mobile data from the stock RIL as it is, maybe needing only an APN
  in Settings. Not tried yet: this is the thing to test next with an active SIM.
- Also in the image: `libril-ec20.so` (Quectel's QMI RIL for the EC20, which uses the same Qualcomm platform as
  the NL668) and AOSP's `libreference-ril.so`. Possible routes for the NL668 later: add it to the RK RIL's list
  (a byte patch to the library), or adapt the Quectel RIL.

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
| Fibocom NL668-EAU | unit 1 in [DEVICES.md](DEVICES.md) | as above |
| Huawei ME909s-120 | units 2 and 3 | ⚠️ powers up and answers AT commands (units 2 and 3), reads the SIM, **registers on LTE**, **sends and receives SMS** (unit 2); mobile data untested |

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
SIM's storage doesn't fill up. Mobile data is still untested.

For data the kernel has `cdc_ether`, `cdc_ncm` and `cdc_mbim`, but not Huawei's own `huawei_cdc_ncm`, so
mobile data on the ME909s may need a different route (see [Mobile data](#mobile-data)). If you have one,
please run `at-probe.sh` and `modem-data-probe.sh` and open an issue with the logs. The script shows the IMEI and other long numbers as
`[hidden]`, but check the log before posting anyway, and paste it inside a ```` ``` ```` code block so GitHub
keeps the layout.

After boot, `/data/citaq/modem.log` shows which modem came up (its USB ID) and which `ttyUSB` ports it
made: `1508:1001` is the Fibocom, `12d1:xxxx` a Huawei. If a modem causes any trouble (for example an
extra network interface Android tries to use), `adb shell "touch /data/citaq/no-modem"` and a reboot
leave it switched off.
