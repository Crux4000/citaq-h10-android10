# 4G modem (Fibocom NL668-EAU)

> **Status: hardware works, not tested with a SIM.** The modem powers up, its drivers load, it answers AT
> commands, has a good signal and can see all three Australian carriers. Registering on a network, SMS and
> mobile data have **not** been tried yet, because the test terminal has no SIM.
> **If you try it, please open an issue or comment on this repo and say what worked or what failed** (with your
> carrier and the output of `device/modem/at-probe.sh`). That's how this gets from "should work" to "works".

The H10-3 has a **Fibocom NL668-EAU** LTE module on the compute board, with its own SIM slot. It sits on the
internal USB hub at **1-1.1**.

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
- `qmi_wwan` → **`wwan0`** plus **`/dev/cdc-wdm0`**: the QMI data path, for mobile data without Android's
  phone stack.

USB ID `1508:1001` ("Fibocom Wireless Inc. / Fibocom Modem"). `AT+GTUSBMODE?` reports `17`.

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

## Not tested yet (needs a SIM)

With a SIM in, these are the things to try. Please report back either way.

1. **Registration:** `AT+CPIN?` should say `READY`, `AT+CEREG?` should end in `,1` (home) or `,5` (roaming),
   and `AT+COPS?` should name the carrier.
2. **SMS** (text mode):
   ```
   AT+CMGF=1
   AT+CMGS="+61400000000"
   > test message      (end with Ctrl-Z, byte 0x1A)
   ```
   Useful as a backup alert path for Home Assistant when Wi-Fi or the internet is down.
3. **Data** over QMI on `wwan0`, for example with `qmicli`/`uqmi`-style tools (not on the device yet) or the
   modem's own dial-up commands. Untested.

**Android's own mobile data and SMS apps won't use the modem.** That needs a RIL (radio interface layer) for the
NL668 on Android 10. Stock Citaq's `ril-nl668.so` is for Android 5 and 32-bit, and the PX5 ROM's RIL is for a
different modem. Talking to the modem directly over AT/QMI is the practical route.
