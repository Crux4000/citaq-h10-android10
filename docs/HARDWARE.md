# Citaq H10-3 hardware map

Everything below was read from a live terminal (stock 5.1 and the Android 10 port), the stock 3.10
device tree, or the stock POSFactory test app. Board: **CTE-RK3368-V1.0**. On the H10-3 the compute
board sits **behind the screen**, not in the base.

## Getting inside

The compute board sits behind the screen. Everything you need for the port is in its bottom-right corner.

![Citaq H10-3 compute board with the debug UART, RECOVER button, JP2 adb port and backup LiPo marked](img/board-overview.jpg)

**Debug UART close-up.** TX and RX are labelled from the *board's* side, so wire adapter **RX → TP17**,
adapter **TX → TP18** and **GND → TP19**. Thin wires soldered to the pads are much easier than holding
probes during a boot. If nothing shows up in your terminal, swap the TP17/TP18 wires; doing that is
harmless. CN3/CN7 are empty footprints and aren't needed.

![TP17 = TX, TP18 = RX, TP19 = GND next to the RECOVER and RESET buttons](img/board-uart.jpg)

## Overview

| Part | Detail |
|---|---|
| SoC | Rockchip RK3368, 4× + 4× Cortex-A53, PowerVR **G6110** (BVNC 5.9.1.46) |
| RAM | 2 GB DDR3 (2× Samsung K4B4G16) |
| eMMC | Samsung 16 GB (14,910 MiB), HS200 under 4.19 (stock ran 50 MHz) |
| Display | 10" 1024×768 4:3, **LVDS single-channel 8-bit, JEIDA**, 65 MHz |
| Touch | Ilitek **ILI2105**, I2C2 (`i2c@ff140000`) addr **0x41**, IRQ gpio0 B4 (gpio12, low = data), reset gpio0 B3 (gpio11) |
| PMIC | Rockchip **RK818** on I2C0 @ 0x1c, plus **Silergy SYR827** (vdd_cpu) @ 0x40 |
| Wi-Fi/BT | **AP6256** (BCM4345 rev 9, 2.4 + 5 GHz) on SDIO0. The stock DT says AP6212, which is wrong. Bluetooth core **BCM4345C5** on **UART0 → /dev/ttyS0** |
| Audio | **Realtek RT5651** on I2C1 @ 0x1a, i2s-8ch, MCLK = SCLK_I2S_8CH_OUT; speaker amp gpio0 C3 (gpio19), **active high**. The headphone jack and the speaker amp share the headphone output, so the boot hook mutes the amp while the jack is in. The stock DT also lists an ES8316 that isn't fitted |
| Printer | 80 mm thermal, ESC/POS, **UART1 → /dev/ttyS1, 115200, CTS flow control**, 552 dots wide |
| LEDs | red **gpio124**, blue **gpio106** (1 = on) |
| USB | internal GL850G hub (1-1) → Fibocom NL668-EAU 4G modem (1-1.1, see [MODEM.md](MODEM.md)); rear hub GL850G (1-1.3) → 3 ports + RTL8152 Ethernet (1-1.3.4) |
| JP2 | internal micro-USB = dwc2 OTG (`usb@ff580000`) = adb port |
| Debug UART | UART2: **TP17** board TX, **TP18** board RX, **TP19** GND, 3.3 V, 115200 |
| Buttons | power key gpio0 A2 (active low); RECOVER / RESET on the compute board |
| Battery | 1S 3.7 V 1600 mAh LiPo (backup). The board won't run without it |
| Power | 24 V 2.5 A barrel; the back switch cuts DC input (and the printer) |
| Other | DS2411 1-wire silicon serial on gpio3 B4 (unused so far); no camera |

GPIO numbers are Linux numbers: `bank × 32 + letter × 8 + pin` (A=0, B=1, C=2, D=3).

## Other GPIOs

| GPIO | Pin | Use |
|---|---|---|
| 29 | gpio0 D5 | LCD reset (release high) |
| 30 | gpio0 D6 | LCD chip select / power (high) |
| 31 | gpio0 D7 | stock init-gpio (high) |
| 81 | gpio2 C1 | stock init-gpio (high) - possibly printer power |
| 114 | gpio3 C2 | LCD enable (high) |
| 100 / 102 | gpio3 A4 / A6 | Wi-Fi WL_REG_ON (via mmc-pwrseq) / host wake |
| 99 / 101 | gpio3 A3 / A5 | Bluetooth power / BT_REG_ON (via rfkill-bt) |
| 98 / 103 | gpio3 A2 / A7 | Bluetooth BT_WAKE / host wake |
| 91 | gpio2 D3 | UART0 RTS (Bluetooth), active low |
| 28 | gpio0 D4 | 4G modem power key (high = released) |
| 109 / 105 | gpio3 B5 / B1 | 4G modem reset / W_DISABLE (high = running, radio on) |
| 15 | gpio0 B7 | headphone-jack detect, active low (0 = plugged in); needs its pull-up on (the DTB does it) |

## Backlight

PWM0 (`pwm@ff680000`, pin GPIO3_B0), period 25 µs, **normal polarity**, duty 0 = off. In the port,
the MTC `pwm-backlight` driver is pointed at the unused PWM3 and `blshim` drives PWM0 through sysfs.

## RK818 PMIC

I2C0 address 0x1c (`i2cget -f -y 0 0x1c <reg>`). With no driver, these are the registers that matter.
Stock values are restored by `citaq-boot.sh`. OTP values are what you get after a battery pull.

| Reg | Name | Stock | OTP / notes |
|---|---|---|---|
| 0x20 | CLK32OUT | bit0 = 1, bit1 = 0 (32 kHz out) | 0x02: pin not a clock → Wi-Fi "HT Avail timeout" |
| 0x23 | DCDC_EN | 0x7f | ok |
| 0x24 | LDO_EN | **0xff** | 0x54 (only LDO3/5/7) → blank LCD, dead touch |
| 0x2f | BUCK1 (vdd_logic, GPU) | 0x22 = 1.1375 V | 0x1f = 1.1 V |
| 0x33 | BUCK2 | 0x1f = 1.1 V | — |
| 0x3b | LDO1 | 0x0f = 3.3 V | 0x00 |
| 0x3d | LDO2 (vcc_tp, touch) | 0x0f = 3.3 V | 0x00 |
| 0x45 | LDO6 | 0x02 = 1.0 V | 0x00 = 0.8 V |
| 0x4b | DEVCTRL | write 0x01 = DEV_OFF (power off) | |
| 0xa0 | SUP_STS | bit1 = DC input present (0xbf on DC, 0x8c on battery) | |
| 0xa1 | USB_CTRL | low nibble 0xb = 3 A input limit | 0 = 450 mA |
| 0xa3 | CHRG_CTRL1 | 0x80 = 4.05 V / 1.0 A | 0xb5 = 4.2 V / 2.0 A |

The charger runs on its own once programmed, so charging works without a driver. Only the battery %
reading is missing.

## SYR827 (vdd_cpu)

I2C0 @ 0x40, ID 0x88. VSEL0 = 0xa4 (enabled, 1162.5 mV) at boot, VSEL1 = sleep. Driven in the port by
the `fan53555` driver (`fcs,suspend-voltage-selector = 1`). CPU OPPs are capped at 1.2 GHz: 1512 MHz at
1.35 V hung the board after 30–70 s of full load without a heatsink.

## CPU speed limit

Both clusters top out at 1.2 GHz: the DTB drops the big cluster's 1296/1416/1512 MHz OPPs, because
1512 MHz at 1.35 V hung the board after 30–70 s of full load. Both clusters share the SYR827 rail, so
it runs at whatever the busier cluster needs, and the little cluster needs the most:

| Limit | Little cluster (cpu0–3) | Big cluster (cpu4–7) | Notes |
|---|---|---|---|
| 1200 MHz (default) | 1.225 V | 1.15 V | fastest; about 40% more CPU heat than 1008 |
| 1008 MHz | 1.125 V | 1.05 V | try this first if the terminal freezes |
| 816 MHz | 1.025 V | 1.00 V | coolest; fine for a dashboard |

There is no heatsink, so the chip runs hot at 1.2 GHz, and the built-in temperature reading isn't
reliable yet (see [Known issues](../README.md#known-issues)). The boot hook reads the limit from
`/data/citaq/cpu-max-mhz` (`816`, `1008` or `1200`; anything else means 1200) and logs what it set to
`/data/citaq/cpu.log`.

Set it for every boot:

```sh
adb root
adb shell "echo 1008 > /data/citaq/cpu-max-mhz"
```

Apply it now as well, without rebooting:

```sh
adb shell 'for p in /sys/devices/system/cpu/cpufreq/policy*; do echo 1008000 > $p/scaling_max_freq; done'
```

Delete the file to go back to 1200 MHz. Check with
`adb shell cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq`.

## Thermal

`tsadc@ff280000`, legacy rk3368 driver. Two quirks:
1. It asks the MCU over SCPI for the reading unless a low-latency PM QoS request is active. On this
   firmware the MCU always answers "25 °C". The port sets `latency-bound = 0x7fffffff` so it always reads
   the ADC directly.
2. It multiplies by `tsadc-supply`, which gives nonsense when that supply is the scaling vdd_cpu. The
   port gives it a fixed 1.1625 V reference instead.

Calibration point: 42 °C reported at 37 °C on the package top. That is the only point checked, so
readings up near the 70 °C trip may be several degrees out either way. The raw ADC code moves about
3 °C per step (122 = 25 °C, 128 = 42 °C, 139 = 75 °C raw) and the driver smooths it, so the reported
temperature moves in flat steps rather than smoothly.

## eMMC layout

Rockchip legacy `parameter` layout: offsets in the parameter file are relative to sector **0x2000** (4 MiB).

| What | Where (`/dev/block/mmcblk0`) | Notes |
|---|---|---|
| boot slot | 16 KiB block **3328**, 32 MiB | stock: Rockchip `KRNL`-wrapped ramdisk; port: Android boot image |
| kernel | separate partition | stock kernel, never touched |
| recovery slot | 16 KiB block **5376**, 32 MiB | |
| system | 1.5 GiB | stock 5.1 |
| user (`mmcblk0p16`) | sector 12,443,648 (6076 MiB) to the end, 18,092,032 sectors | |

Android 10 inside p16 (passed to the kernel as `blkdevparts=` from the DTB):

| Partition | Offset (MiB of mmcblk0) | Size |
|---|---|---|
| (stock internal storage, FAT32) | 6076 | 1024 MiB |
| super | 7100 | 3112 MiB |
| metadata | 10212 | 16 MiB |
| misc | 10228 | 4 MiB |
| frp | 10232 | 4 MiB |
| security | 10236 | 4 MiB |
| cache | 10240 | 384 MiB |
| userdata | 10624 | 4286 MiB |

## Bootloader facts

- `U-Boot 2017.02-RK3368-06 (Feb 21 2019)`, `bootcmd=bootrk`, `bootdelay=0`; secure boot off.
- Images are checked with Rockchip's SHA-1 recipe: kernel, size, ramdisk, size, second, size, then
  header bytes 0x20–0x240, stored at 0x240. Each chunk must be a multiple of 4 bytes (the crypto
  engine is fed in words), so pad to 16. See `tools/rkbootimg.py`.
- The kernel is always copied to **0x280000**, so it needs TEXT_OFFSET 0x80000 (kernels ≤ 5.7 as-is).
- The ramdisk goes to 0x05bf0000, and the FDT comes from `rk-kernel.dtb` inside the image's RSCE "second".
- The boot image header cmdline is **ignored**. The DTB's `/chosen/bootargs` is put **in front of** the
  parameter-partition cmdline, so the DTB controls the kernel command line. The cmdline buffer looks
  like 1 KiB.
- Fallback chain: boot/recovery → backup partition → rockusb.
- `adb reboot recovery` sets a one-shot flag in `misc`.
