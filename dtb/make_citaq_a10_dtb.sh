#!/bin/sh
# Stage 2: Citaq H10-3 DTB for booting PX5 Android 10 (PX5 kernel + PX5 boot ramdisk).
# Usage: make_citaq_a10_dtb.sh px5.dtb out.dtb SERIAL
#   SERIAL   Android serial number for this terminal: 6-20 letters/digits. Google check-in rejects
#            the junk the PX5 firmware makes up, so pick your own - e.g. CITAQ + your Wi-Fi MAC
#            without colons. Becomes ro.boot.serialno (and adb's USB serial).
#   COUNTRY  (environment, optional) Wi-Fi regulatory country, default AU.
#   RAM_MB   (environment, optional) 2048 (default) or 1024 for a 1 GB terminal (untested).
#   ADC_KEYS (environment, optional) 1 = up to 6 extra buttons on the RECOVER line (untested; see
#            docs/HARDWARE.md "Extra buttons on the RECOVER line"). ADC_KEYCODES = their 6 Linux key codes.
#   PANEL    (environment, optional) h10 (default) or v8 for the Citaq V8's portrait 6-bit panel
#            (untested). v8 also names the board "Citaq V8" in the DTB, and the boot hook then
#            rotates Android 90 degrees by itself (/data/citaq/rotation overrides it).
# Needs fdtput + dtc (device-tree-compiler) and python3. Runs make_citaq_dtb.sh first.
set -e
D=$(dirname "$0")
[ $# -eq 3 ] || { sed -n '2,14p' "$0" >&2; exit 1; }
SERIAL=$3
COUNTRY=${COUNTRY:-AU}
echo "$SERIAL" | grep -Eq '^[A-Za-z0-9]{6,20}$' || { echo "SERIAL must be 6-20 letters/digits" >&2; exit 1; }
echo "$COUNTRY" | grep -Eq '^[A-Z]{2}$' || { echo "COUNTRY must be a 2-letter code like AU, US, GB" >&2; exit 1; }
ADC_KEYS=${ADC_KEYS:-0}
case $ADC_KEYS in 0|1) ;; *) echo "ADC_KEYS must be 0 or 1" >&2; exit 1;; esac
OUT=$2
# If any step fails, don't leave a half-built DTB behind that looks finished.
trap 'rm -f "$OUT" "$OUT.dts"; echo "FAILED - no $OUT written" >&2' EXIT
sh "$D/make_citaq_dtb.sh" "$1" "$2"
P() { fdtput "$OUT" "$@"; }
case ${PANEL:-h10} in
  v8) P -ts / model "Citaq V8 (PX5 Android 10)" ;;   # citaq-boot.sh looks for "V8" here
  *)  P -ts / model "Citaq H10-3 (PX5 Android 10)" ;;
esac

# Partition map for the 4.19 kernel (CONFIG_CMDLINE_PARTITION). All inside the stock "user"
# partition (mmcblk0p16 = 6076 MiB .. 14910 MiB on the 16 GB eMMC; Rockchip parameter offsets
# are +0x2000 sectors); its first 1 GiB stays as stock Android's internal_sd.
PARTS="3112M@7100M(super),16M@10212M(metadata),4M@10228M(misc),4M@10232M(frp),4M@10236M(security),384M@10240M(cache),4286M@10624M(userdata)"

# The Citaq U-Boot ignores the boot image's header cmdline but puts the DTB's /chosen/bootargs
# in FRONT of the parameter-partition cmdline, and ro.boot.* properties keep the first value,
# so everything here wins - no need to touch the parameter partition.
P -ts /chosen bootargs "swiotlb=1 console=ttyFIQ0 androidboot.baseband=N/A androidboot.hardware=rk30board androidboot.console=ttyFIQ0 androidboot.selinux=permissive androidboot.boot_devices=ff0f0000.dwmmc androidboot.wificountrycode=$COUNTRY androidboot.serialno=$SERIAL androidboot.verifiedbootstate=orange firmware_class.path=/vendor/firmware loop.max_part=7 usbcore.autosuspend=-1 printk.devkmsg=on kpti=0 blkdevparts=mmcblk0:$PARTS"
# (firmware_class.path: the GPU firmware rgx.fw.signed.5.9.1.46 lives in /vendor/firmware - without
#  this the PowerVR driver can't find it and surfaceflinger oopses in pvr_sync_open.
#  usbcore.autosuspend=-1: the rear-port USB hub wedges on autosuspend and ignores new devices.)

# What the PX5 dtbo.img overlay did (our U-Boot doesn't apply dtbo): no DT fstab/vbmeta
# (so first-stage init uses the ramdisk fstab), boot device = eMMC only.
fdtput -r "$OUT" /firmware/android/fstab
fdtput -r "$OUT" /firmware/android/vbmeta
P -ts /firmware/android boot_devices "ff0f0000.dwmmc"

# JP2 micro-USB (dwc2 OTG @ff580000): device mode for adb instead of the PX5/MTC
# forced host mode. If it ever sticks in host mode again: cold power cycle (24 V + LiPo).
P -ts /usb@ff580000 status okay
P -ts /usb@ff580000 dr_mode peripheral
P -ts /usb@ff580000 force_mode device
P -ts /syscon@ff770000/usb2-phy@700/otg-port status okay


# Power button (Citaq stock DT: power-key = gpio0 pin 2, active low, KEY_POWER - same pin
# and code as the PX5 gpio-keys node). Also gives Android a /dev/input device: without
# any input device system_server aborts ("Could not register INotify for /dev/input").
P -ts /gpio-keys status okay
# --- CPU/GPU speed: real CPU voltage control. vdd_arm on the Citaq is a Silergy SYR827 @ i2c0 0x40
#     (stock 3.10 DT "syr827@40", vdd_arm 1.05-1.5 V) that powers only the CPU. Measured: VSEL0 0xa4 =
#     enabled 1162.5 mV (active/normal), VSEL1 0x0f = 900 mV disabled (sleep) -> fcs,suspend-voltage-selector = 1
#     (driver: normal = VSEL0, sleep = VSEL1). ID1 0x88 -> die id 8 = SYR82X (712.5 mV + 12.5 mV steps).
#     The fan53555 driver replaces the fixed vdd_cpu regulator under the same phandle (0x0f), so cpufreq and
#     the rk3368 tsadc both use it. Thermal trips 70/80 C passive, 125 C critical; cpu + gpu cooling maps.
#     PX5 OPP tables restored: cpu@0-3 -> opp_table0 (<= 1200 MHz), cpu@100-103 -> opp_table1 (<= 1512 MHz).
fdtput -r "$OUT" /citaq-fixed-vdd_cpu
R=/i2c@ff650000/syr827@40
fdtput -c "$OUT" $R
P -ts $R compatible silergy,syr827
P -tx $R reg 0x40
P -ts $R regulator-name vdd_cpu
P -tu $R regulator-min-microvolt 712500
P -tu $R regulator-max-microvolt 1400000
P -tu $R regulator-ramp-delay 1000
P -tu $R fcs,suspend-voltage-selector 1
P -ts $R regulator-always-on ""
P -ts $R regulator-boot-on ""
P -tx $R phandle 0x0f
P -ts /i2c@ff650000 status okay
# The legacy rk3368 tsadc driver "voltage-compensates" each reading as code * tsadc-supply volts, and with
# its clock running (xin32k, see make_citaq_dtb.sh) that is right: measured on the bench against a probe on
# the chip, the raw code scales as 1/vdd_cpu (code x V ~153 at every speed from 408 to 1200 MHz at ~50 C).
# So tsadc-supply must be the live vdd_cpu (phandle 0x0f, the SYR827 above). Earlier versions used a fixed
# 1.1625 V reference here because the readings looked wrong with vdd_cpu - they were really stale values
# from the dead clock.
P -tx /tsadc@ff280000 tsadc-supply 0x0f

# (1) The legacy rk3368 tsadc driver asks the MCU over SCPI for the reading whenever the PM QoS
# cpu_dma_latency request exceeds latency-bound (default 50000 us) - i.e. always, unless something holds a
# low-latency request - and the Citaq MCU firmware answers a constant 122 (= "25 C"). Make the bound huge so
# it always reads the ADC itself. (2) The big cluster (cpu4-7) keeps the PX5's 1296/1416/1512 MHz OPPs
# (1.225/1.30/1.35 V). The boot hook caps the speed (/data/citaq/cpu-max-mhz, default 1008 MHz); 1512 is an
# opt-in for terminals with better cooling. (Earlier DTBs dropped these OPPs after 1512 MHz hung the board
# under sustained load on 17 Nov 2026 - with the tsadc clock dead, so throttling never worked. With the fixed
# sensor, a bench test throttled back to <= 1200 MHz within 1-2 s under sustained load and never hung.)
P -tx /tsadc@ff280000 latency-bound 0x7fffffff
for c in cpu@0 cpu@1 cpu@2 cpu@3; do P -tx /cpus/$c operating-points-v2 0x0c; done
for c in cpu@100 cpu@101 cpu@102 cpu@103; do P -tx /cpus/$c operating-points-v2 0x11; done
# GPU 400 MHz (its OPP is 1.10 V; vdd_logic measured 1.1375 V). 576 MHz needs 1.2 V - stays out.
fdtput -c "$OUT" /gpu_opp_table/opp-400000000
P -tx /gpu_opp_table/opp-400000000 opp-hz 0 0x17d78400
P -tu /gpu_opp_table/opp-400000000 opp-microvolt 1100000
# (vdd_log stays DECLARED as 1.10 V: the GPU OPPs are single-value 1.10 V, and the OPP core disables any OPP
#  whose exact voltage the fixed regulator doesn't report. Real rail is 1.1375 V - above what 400 MHz needs.)

# --- Wi-Fi on SDIO0 (dwmmc@ff0d0000), written the way Rockchip's own 4.19 AP6xxx boards do it.
#     The stock Citaq DT says AP6212, but the module answers as SDIO 02D0:A9BF = BCM4345 rev 9 = AP6256
#     (2.4 + 5 GHz); the bcmdhd driver detects the chip itself, wifi_chip_type is only used for power.
#     Chip power-enable = GPIO3_A4 (driven by an mmc-pwrseq so the core powers the chip and enumerates
#     it at boot), host-wake = GPIO3_A6. act_ldo3 (3.3 V, always-on in the stock DT) is left as is.
PH=0x1f0   # free phandle for the new pwrseq node
fdtput -c "$OUT" /sdio-pwrseq
P -ts /sdio-pwrseq compatible mmc-pwrseq-simple
P -tx /sdio-pwrseq reset-gpios 0x71 4 1          # gpio3 A4, active low (high = chip on)
P -tu /sdio-pwrseq post-power-on-delay-ms 100
P -tx /sdio-pwrseq phandle $PH
S=/dwmmc@ff0d0000
fdtput -d "$OUT" $S supports-sd
fdtput -d "$OUT" $S card-detect-delay
P -ts $S supports-sdio ""
P -ts $S cap-sdio-irq ""
P -ts $S non-removable ""
P -ts $S keep-power-in-suspend ""
P -tu $S bus-width 4
P -tu $S max-frequency 50000000
P -tu $S clock-frequency 50000000
P -tu $S clock-freq-min-max 200000 50000000
P -tx $S pinctrl-0 0x1b 0x1c 0x1e               # sdio0 clk, cmd, bus4 (no card-detect pin)
P -tx $S mmc-pwrseq $PH
P -ts $S status okay
W=/wireless-wlan
fdtput -d "$OUT" $W WIFI,vbat_gpio
P -ts $W wifi_chip_type ap6212
P -tu $W sdio_vref 1800
P -tx $W WIFI,host_wake_irq 0x71 6 0
P -ts $W status okay
# SDIO pads at 1.8 V like stock (wifi-supply = vcc_18). Only the wifi domain is listed, so the
# io-domain driver leaves every other domain exactly as U-Boot set it.
I=/syscon@ff770000/io-domains
for s in dvp-supply audio-supply gpio30-supply gpio1830-supply sdcard-supply; do fdtput -d "$OUT" $I $s; done
P -tx $I wifi-supply 0x57
P -ts $I status okay
# --- Sound: Citaq fits one of two codecs on I2C1 (ff660000), both on i2s-8ch@ff898000 with
#     MCLK = SCLK_I2S_8CH_OUT (cru 113) on GPIO2_C4 and the same speaker amp. The stock DT lists both
#     and its kernel used whichever answered:
#       Realtek RT5651 @0x1a  - the reference terminal (stock last_kmsg: es8316 probe fails, "#0: RK_RT5651")
#       Everest ES8316 @0x10  - a second terminal with the identical stock firmware (issue #1, Nov 2026)
#     RT5651 first: its node and card below are the reference setup.
P -ts /i2c@ff660000 status okay
C=/i2c@ff660000/rt5651@1a
fdtput -c "$OUT" $C
P -ts $C compatible realtek,rt5651
P -tx $C reg 0x1a
P -tx $C "#sound-dai-cells" 0
P -tx $C clocks 0x0a 0x71                      # 113 = SCLK_I2S_8CH_OUT (-tx is hex!)
P -ts $C clock-names mclk
P -tx $C spk-con-gpios 0x2f 0x13 0             # speaker amp enable gpio0 C3 = ACTIVE HIGH (tested: high = sound,
                                               # low = silent; the stock DT's ACTIVE_LOW flag is wrong/unused).
                                               # The rt5651 driver switches it on at unmute, off at mute.
P -tx $C phandle 0x1f1
P -ts /i2s-8ch@ff898000 status okay
P -tx /i2s-8ch@ff898000 pinctrl-0 0x65 0x94        # i2s-8ch bus + mclk pin
S=/wm8978-sound                                     # reuse the PX5 simple-audio-card node
P -ts $S simple-audio-card,name realtek,rt5651-codec   # card id "realtekrt5651co" = the name the Rockchip audio HAL looks for (uses its rt5651 route table)
P -tu $S simple-audio-card,mclk-fs 256
P -ts $S simple-audio-card,widgets Speaker Speaker Headphone Headphones
P -ts $S simple-audio-card,routing Speaker LOUTL Speaker LOUTR Headphones HPOL Headphones HPOR
P -tx $S/simple-audio-card,codec sound-dai 0x1f1
# The codec driver in this kernel never enabled MCLK (clk_summary: i2s_8ch_clkout enable_cnt 0 while
# playing -> silence). A "clocks" property on the card's codec subnode makes simple-card itself
# clk_prepare_enable() it at stream startup and clk_set_rate(mclk-fs * fs) in hw_params.
P -tx $S/simple-audio-card,codec clocks 0x0a 0x71   # SCLK_I2S_8CH_OUT
P -ts $S status okay
# ES8316 alternative. Two things stop us simply listing both codecs and both cards:
#  - this kernel's es8316 driver registers its codec without checking the chip is there (an ES8316 card
#    came up on the RT5651 terminal in an early test, every control read failing), while the rt5651 driver
#    checks its ID register and fails cleanly;
#  - both cards need i2s-8ch, and whichever binds first keeps it - the other fails for good.
# So the ES8316 card gets a compatible that no driver matches: it never binds on its own, and the RT5651
# card is exactly as before. The boot hook (citaq-boot.sh, 00b3) checks which chip answers and, only when
# the RT5651 card didn't come up and something answers at 0x10, binds this card by hand (driver_override =
# asoc-simple-card). Name "rockchip,es8316-codec" -> card id "rockchipes8316c", which the Rockchip audio
# HAL has a route table for. No spk-con-gpios: the boot hook drives the speaker amp (see Headphone jack).
E=/i2c@ff660000/es8316@10
fdtput -c "$OUT" $E
P -ts $E compatible everest,es8316
P -tx $E reg 0x10
P -tx $E "#sound-dai-cells" 0
P -tx $E clocks 0x0a 0x71                      # SCLK_I2S_8CH_OUT
P -ts $E clock-names mclk
P -tx $E phandle 0x1f2
S=/es8316-sound
fdtput -c "$OUT" $S
P -ts $S compatible citaq,es8316-sound            # matches no driver on purpose (bound by the boot hook)
P -ts $S simple-audio-card,format i2s
P -ts $S simple-audio-card,name rockchip,es8316-codec
P -tu $S simple-audio-card,mclk-fs 256
P -ts $S simple-audio-card,widgets Speaker Speaker Headphone Headphones
P -ts $S simple-audio-card,routing Speaker HPOL Speaker HPOR Headphones HPOL Headphones HPOR
fdtput -c "$OUT" $S/simple-audio-card,cpu
P -tx $S/simple-audio-card,cpu sound-dai 0xaa      # i2s-8ch@ff898000
fdtput -c "$OUT" $S/simple-audio-card,codec
P -tx $S/simple-audio-card,codec sound-dai 0x1f2
P -tx $S/simple-audio-card,codec clocks 0x0a 0x71   # simple-card enables MCLK itself, as for the RT5651
P -ts $S status okay

# --- Receipt printer: UART1 = serial@ff190000 -> /dev/ttyS1 (alias serial1), as stock: pins
#     uart1-xfer (GPIO0_C4/C5) + uart1-cts (GPIO0_C6), no RTS pin muxed. The PX5 had its FIQ console here.
P -ts /serial@ff190000 status okay
P -ts /serial@ff190000 pinctrl-names default
P -tx /serial@ff190000 pinctrl-0 0x91 0x10e

# --- Backlight. The MTC-patched pwm-backlight driver ignores 'brightness' and pins its PWM at 100 %.
#     Give that driver an unused PWM instead - pwm3 @ff680030 (its pin GPIO3_D6 is unused on the Citaq;
#     the stock DT only defines the pwm3 pin group) - so Android's lights HAL still has
#     /sys/class/backlight/backlight/brightness, and leave the real backlight PWM (pwm0 @ff680000,
#     GPIO3_B0) free for /data/citaq/blshim, which mirrors brightness (0-255) onto it via PWM sysfs.
P -ts /pwm@ff680030 status okay
P -tx /backlight pwms 0xd3 0 0x61a8 0

# --- Bluetooth: the AP6256's BT core (BCM4345C5) is on UART0 (serial@ff180000 -> /dev/ttyS0). Pins from the
#     stock Citaq 3.10 DT (wireless-bluetooth): BT power gpio3 A3, BT_REG_ON/reset gpio3 A5, BT_WAKE gpio3 A2,
#     host-wake gpio3 A7, UART0 RTS = gpio2 D3 (active low). The Rockchip rfkill-bt driver (CONFIG_RFKILL_RK)
#     gives Android its bluetooth rfkill switch; it parks RTS as a GPIO while powering the chip (pinctrl
#     "rts_gpio") and hands it back to the UART ("default"). UART0 also gets its CTS pin, so libbt-vendor can
#     run hardware flow control at 1.5 Mbaud. The rest (firmware, GPS HAL, the MTC app) is in docs/BLUETOOTH.md.
fdtput -c "$OUT" /pinctrl/uart0/uart0-rts-gpio
P -tx /pinctrl/uart0/uart0-rts-gpio rockchip,pins 0x02 0x1b 0x00 0x8b   # gpio2 D3 as GPIO, no pull
P -tx /pinctrl/uart0/uart0-rts-gpio phandle 0x1f3
P -tx /serial@ff180000 pinctrl-0 0x37 0x10c                              # uart0-xfer + uart0-cts
B=/wireless-bluetooth
fdtput -c "$OUT" $B
P -ts $B compatible bluetooth-platdata
P -tx $B uart_rts_gpios 0x93 0x1b 1                 # gpio2 D3, active low
P -ts $B pinctrl-names default rts_gpio
P -tx $B pinctrl-0 0x10d                            # uart0-rts (UART function)
P -tx $B pinctrl-1 0x1f3                            # uart0-rts as GPIO
P -tx $B BT,power_gpio 0x71 3 0                     # gpio3 A3, active high
P -tx $B BT,reset_gpio 0x71 5 0                     # gpio3 A5 = BT_REG_ON, active high
P -tx $B BT,wake_gpio 0x71 2 0                      # gpio3 A2, active high
P -tx $B BT,wake_host_irq 0x71 7 0                  # gpio3 A7
P -ts $B status okay

# --- Headphone jack: on the Citaq the jack and the built-in speaker amp share the codec's headphone output, so
#     the only way to mute the speakers with headphones in is the amp's enable pin (gpio0 C3 = gpio19). Stock
#     Android 5 had a headset driver doing that from the jack-detect pin (gpio0 B7 = gpio15, active low, with the
#     pull-up on). The PX5 build has neither. So: take the amp pin away from the codec driver (it treats
#     spk-con-gpios as optional: "cannot get spk-con-gpio" and carries on) and let the boot hook drive it, and turn
#     on gpio15's pull-up with a pin-controller hog (without it the pin reads 0 whether or not a plug is in).
fdtput -d "$OUT" /i2c@ff660000/rt5651@1a spk-con-gpios
fdtput -c "$OUT" /pinctrl/citaq-hog
fdtput -c "$OUT" /pinctrl/citaq-hog/jack-det
P -tx /pinctrl/citaq-hog/jack-det rockchip,pins 0x00 0x0f 0x00 0x8c   # gpio0 B7 as GPIO, pull-up
P -tx /pinctrl/citaq-hog/jack-det phandle 0x1f4
P -ts /pinctrl pinctrl-names default
P -tx /pinctrl pinctrl-0 0x1f4

# --- Optional (ADC_KEYS=1, untested): extra buttons on the RECOVER line. RECOVER (K3) shorts SARADC channel 1,
#     which has a 10 k pull-up to 1.8 V, so more buttons can share that line, each pulling it down through its own
#     resistor to ground (the stock 3.10 DT reads it as a 6-key ladder: 0 / 2k / 5.1k / 8.2k / 12k / 27k). The PX5's
#     own rockchip-key node stays off (make_citaq_dtb.sh); this adds a mainline adc-keys node instead
#     (CONFIG_KEYBOARD_ADC=y), matching each reading to the nearest ladder voltage below. The ADC needs a
#     reference regulator to report volts, so it gets vcc_18 (fixed 1.8 V, phandle 0x57).
#     Default key codes: VOLUMEUP VOLUMEDOWN MENU CAMERA BACK HOMEPAGE (115 114 139 212 158 172), which Android's
#     Generic.kl maps to volume up/down, menu, camera, back and home. Override with ADC_KEYCODES="c1 ... c6".
if [ "$ADC_KEYS" = 1 ]; then
  set -- ${ADC_KEYCODES:-115 114 139 212 158 172}
  [ $# -eq 6 ] || { echo "ADC_KEYCODES needs exactly 6 key codes" >&2; exit 1; }
  P -tx /saradc@ff100000 vref-supply 0x57
  K=/adc-keys
  fdtput -c "$OUT" $K
  P -ts $K compatible adc-keys
  P -tx $K io-channels 0x97 1                       # saradc (PX5 phandle 0x97), channel 1 = RECOVER line
  P -ts $K io-channel-names buttons
  P -tu $K keyup-threshold-microvolt 1800000
  P -tu $K poll-interval 50
  n=0
  for uv in 0 300000 608000 811000 982000 1313000; do # 1.8 V x R / (R + 10k)
    n=$((n + 1))
    fdtput -c "$OUT" $K/button$n
    P -ts $K/button$n label "button$n"
    P -tu $K/button$n press-threshold-microvolt $uv
    P -tu $K/button$n linux,code $1
    shift
  done
  echo "ADC_KEYS: RECOVER-line buttons on, key codes ${ADC_KEYCODES:-115 114 139 212 158 172}"
fi

# The 4.19 MMC core numbers hosts in probe order (no DT aliases), and probe order = DT node
# order. With SDIO0 enabled before the eMMC node, the Wi-Fi host became mmc0 and the eMMC mmcblk1,
# so blkdevparts=mmcblk0:... matched nothing and init rebooted to the bootloader. Move the pwrseq
# and SDIO nodes to the end of the tree so the eMMC is probed first and stays mmc0/mmcblk0.
dtc -q -I dtb -O dts "$OUT" -o "$OUT.dts"
python3 - "$OUT.dts" <<'PY'
import sys,re
p=sys.argv[1]; t=open(p).read()
# Newer dtc (1.7.1+) restores labels from __symbols__ when decompiling, e.g. "sdio0: dwmmc@ff0d0000 {",
# so allow any "label:" prefixes in front of the node name.
def node(t,name):
    return re.search(r'\n\t(?:[A-Za-z_][\w]*: )*'+re.escape(name)+r' \{\n',t)
def cut(t,name):
    m=node(t,name)
    if not m: sys.exit(f'node {name} not found in the decompiled DTB - stopping')
    e=t.index('\n\t};\n',m.end()-1)+5   # whole lines incl. trailing newline; -1 so an empty node works
    return t[:m.start()+1]+t[e:], t[m.start()+1:e]
t,pw=cut(t,'sdio-pwrseq'); t,sd=cut(t,'dwmmc@ff0d0000')
end=t.rindex('\n};')            # close of the root node
t=t[:end+1]+pw+sd+t[end+1:]
emmc,sdio=node(t,'dwmmc@ff0f0000'),node(t,'dwmmc@ff0d0000')
if not (emmc and sdio and emmc.start()<sdio.start()):
    sys.exit('eMMC node is not ahead of the SDIO node - it would not be mmcblk0. stopping')
open(p,'w').write(t)
PY
dtc -q -I dts -O dtb "$OUT.dts" -o "$OUT"
rm -f "$OUT.dts"
trap - EXIT
echo "android dtb: $OUT  (serial $SERIAL, Wi-Fi country $COUNTRY)"
