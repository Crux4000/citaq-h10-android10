#!/bin/sh
# Stage 1: convert the PX5 EVB V11 Android 10 DTB (Rockchip 4.19) into a Citaq H10-3
# (CTE-RK3368-V1.0) DTB. Used on its own for the "first light" kernel test, and as the base
# for make_citaq_a10_dtb.sh. Usage: make_citaq_dtb.sh px5.dtb citaq-px5.dtb
# Needs fdtput (device-tree-compiler package).
# Principle: change as little hardware state as possible. The vendor U-Boot has already
# powered and configured everything; the kernel must not reprogram any voltage.
set -e
IN=$1; OUT=$2
[ -n "$IN" ] && [ -n "$OUT" ] || { echo "usage: $0 px5.dtb out.dtb" >&2; exit 1; }
cp "$IN" "$OUT"
P() { fdtput "$OUT" "$@"; }
off() { fdtput -ts "$OUT" "$1" status disabled; }

P -ts / model "Citaq H10-3 (PX5 4.19 first light)"

# --- 1. Power: no PMIC driver. The PX5 board has an RK808; the Citaq has an RK818 plus
#        a SYR827 buck. Replace every PMIC regulator with an always-on fixed regulator that
#        keeps the same phandle, so consumers resolve but nothing is ever programmed.
fdtput -r "$OUT" /i2c@ff650000/pmic@1b
fixed() { # name phandle microvolts
  n=/citaq-fixed-$1
  fdtput -c "$OUT" $n
  P -ts $n compatible regulator-fixed
  P -ts $n regulator-name "$1"
  P -tu $n regulator-min-microvolt $3
  P -tu $n regulator-max-microvolt $3
  P -ts $n regulator-always-on ""
  P -ts $n regulator-boot-on ""
  P -tx $n phandle $2
}
fixed vdd_cpu     0x0f 1100000
fixed vdd_log     0x62 1100000
fixed vcc_ddr     0xb6 1200000
fixed vcc_io      0x32 3300000
fixed vcc18_flash 0xb7 1800000
fixed vcca_33     0x56 3300000
fixed vdd_10      0xb8 1000000
fixed avdd_33     0xb9 3300000
fixed vccio_sd    0x58 3300000
fixed vdd10_lcd   0xba 1000000
fixed vcc_18      0x57 1800000
fixed vcc18_lcd   0xbb 1800000
fixed vcc_sd      0xbc 3300000
fixed vcc33_lcd   0x80 3300000

# --- 2. No DVFS: CPU stays at the U-Boot clock (no cpufreq), DDR devfreq off,
#        GPU limited to its 1.10 V operating points (<= 400 MHz).
#        (make_citaq_a10_dtb.sh adds real CPU voltage control + OPPs back.)
for c in cpu@0 cpu@1 cpu@2 cpu@3 cpu@100 cpu@101 cpu@102 cpu@103; do
  fdtput -d "$OUT" /cpus/$c operating-points-v2
done
off /dmc
off /rockchip-system-monitor
fdtput -r "$OUT" /gpu_opp_table/opp-576000000
fdtput -r "$OUT" /gpu_opp_table/opp-400000000   # first light: 200/288 MHz only
# IO-voltage domains: leave the GRF exactly as U-Boot set it.
off /syscon@ff738000/io-domains
off /syscon@ff770000/io-domains

# --- 3. Console: Citaq debug UART is UART2 (TP17/18/19, 115200). PX5 put its FIQ console
#        on UART1 (0xff190000), which is the Citaq's receipt printer.
#        The PX5 kernel has no 8250 console (CONFIG_SERIAL_8250_CONSOLE off) - its only
#        console is the Rockchip FIQ debugger (ttyFIQ0). Move it to UART2 at 115200 and
#        run it in plain IRQ mode (uses UART2's own interrupt from serial@ff690000) so it
#        doesn't depend on trust-zone SIP calls the Citaq's older ATF may not have. The 8250
#        driver stays OFF on UART2 (it would fight the debugger for the port).
#        No VT in this kernel, so ttyFIQ0 is the first console registered and gets enabled
#        even though the parameter cmdline says console=ttyS2; /dev/console -> ttyFIQ0.
P -tu /fiq-debugger rockchip,serial-id 2
P -tu /fiq-debugger rockchip,baudrate 115200
P -tu /fiq-debugger rockchip,irq-mode-enable 1
P -tx /fiq-debugger pinctrl-0 0x47
P -ts /serial@ff690000 status disabled

# --- 3b. Memory: the PX5 DTB has no /memory node (its newer U-Boot adds one). The Citaq
#        U-Boot 2017.02 fails that fixup ("could not set reg FDT_ERR_BADOFFSET"), so give the
#        kernel the real map: RAM minus the first 2 MB (ATF). Every terminal so far has 2 GB.
#        RAM_MB=1024 (environment) builds for a 1 GB terminal - untested. A DTB that claims more
#        RAM than the board has crashes the kernel early; tools/flash_slot.py checks this.
RAM_MB=${RAM_MB:-2048}
case $RAM_MB in 1024|2048) ;; *) echo "RAM_MB must be 1024 or 2048" >&2; exit 1;; esac
fdtput -c "$OUT" /memory
P -ts /memory device_type memory
P -tx /memory reg 0 0x200000 0 $(printf 0x%x $((RAM_MB * 1024 * 1024 - 0x200000)))

# --- 4. ramoops sits at 0x110000 on the PX5 - below the Citaq's RAM start (0x200000,
#        ARM Trusted Firmware lives there). Remove it.
fdtput -r "$OUT" /reserved-memory/ramoops@110000

# --- 5. PX5 / car-only hardware off.
off /i2c@ff140000/gt9xx@14          # Goodix touch (Citaq has Ilitek @0x41)
off /i2c@ff170000/wm8978@1a         # car audio codec
for n in /mtc-pre /mtc-init /mtc-car /mtc-vs /mtc-dvd /vehicle /cif_sensor \
         /cif@ff950000 /isp@ff910000 /wireless-wlan /rockchip-key /gpio-keys \
         /wm8978-sound /dwmmc@ff0d0000 /dwmmc@ff0c0000 \
         /serial@ff1b0000 /serial@ff1c0000 /pwm@ff680010 /i2s-8ch@ff898000 \
         /usb@ff580000 /syscon@ff770000/usb2-phy@700/otg-port; do   # JP2 adb port: hands off
  off $n
done
# 32 kHz clock: on the PX5 /xin32k is made by a PWM; on the Citaq the RK818's CLK32KOUT1 feeds the SoC's
# CLK32K ball directly, so declare it as a plain fixed clock (as mainline RK3368 boards do). Don't disable
# it: sclk_tsadc hangs off xin32k, and without it the temperature sensor runs at 0 Hz - conversions never
# finish and the driver keeps returning a stale or garbage reading (stuck values, false 119-125 C spikes,
# throttling that never engages).
P -ts /xin32k compatible fixed-clock
P -ts /xin32k status okay
fdtput -d "$OUT" /xin32k pwms
# GPIO-switched fixed regulators: drop the GPIOs (they are PX5 board pins).
fdtput -d "$OUT" /vcc-host gpio
fdtput -d "$OUT" /vcc-host enable-active-low
fdtput -d "$OUT" /vcc-host pinctrl-0
fdtput -d "$OUT" /vcc-host pinctrl-names
fdtput -d "$OUT" /vcc18-lcd-n gpio
fdtput -d "$OUT" /vcc18-lcd-n enable-active-high
fdtput -d "$OUT" /vcc18-lcd-n startup-delay-us

# --- 6. Display: Citaq LVDS panel 1024x768, 65 MHz, single channel 8-bit.
#        Porches from the vendor 3.10 DT. Backlight = pwm0, same as PX5.
T=/lvds-panel/display-timings/timing0
P -tu $T clock-frequency 65000000
P -tu $T hactive 1024
P -tu $T vactive 768
P -tu $T hback-porch 250
P -tu $T hfront-porch 10
P -tu $T hsync-len 100
P -tu $T vback-porch 18
P -tu $T vfront-porch 10
P -tu $T vsync-len 10
P -ts /lvds-panel rockchip,data-mapping vesa   # NOTE: this 4.19 kernel ignores rockchip,data-mapping
# The 4.19 Rockchip panel/LVDS code takes the format from the panel's "bus-format"
# (MEDIA_BUS_FMT_*). With none it runs 18-bit -> banding/false colours on this 8-bit panel.
# 0x1011 (RGB888_1X7X4_SPWG / VESA-24) = the driver default, colours still wrong.
# 0x1012 = RGB888_1X7X4_JEIDA: correct colours on the Citaq panel (confirmed on hardware).
P -tx /lvds-panel bus-format 0x1012
P -ts /lvds-panel compatible simple-panel
echo "built $OUT"
