#!/system/bin/sh
# Citaq boot hook. Started at boot as root by the repurposed akmd init service
# (/vendor/etc/init/init.rockchip.akmd.rc runs "/data/citaq/ilits run").
# 0) Android music volume: the MTC AudioService takes MAX_STREAM_VOLUME[MUSIC] from the car MCU
#    ("cfg_maxvolume=", answered "0" by our CarService patch) unless ro.config.media_vol_steps is set.
#    Must happen before system_server's AudioService starts (this service starts earlier, class main),
#    so it's the very first thing: anything slow before it (the codec detection below can wait a few
#    seconds on an ES8316 terminal) leaves Android with a 0-step volume range - the slider stuck at 0.
setprop ro.config.media_vol_steps 15
setprop ro.config.media_vol_default 10
# 000) Boot logo: the MTC bootanimation shows /system/media/defaultlogo_h.png on a 1024-wide panel (the car-stereo
#      "Insane Audio" logo; the logo choice normally comes from the car MCU). Bind our own 1024x768 PNG over it -
#      first thing, so it is in place before bootanim (~3 s) opens it. Delete /data/citaq/bootlogo.png to undo.
[ -f /data/citaq/bootlogo.png ] && mount -o bind /data/citaq/bootlogo.png /system/media/defaultlogo_h.png
# 00) RK818 PMIC rails. There is no RK818 driver in this kernel, so the rails keep whatever the PMIC last had;
#     a battery pull resets it to OTP defaults (LDO1/2/4/6/8 off, LDO6 0.8 V, vdd_logic 1.1 V), which kills
#     the LCD logic supply and the touch panel (vcc_tp). Restore the stock Citaq values (citaq310.dts):
#     LDO1 3.3 V, LDO2 vcc_tp 3.3 V, LDO6 1.0 V, BUCK1 vdd_logic 1.1375 V (what it ran on), LDO1-8 enabled.
if [ "$(i2cget -f -y 0 0x1c 0x24)" != 0xff ]; then
  i2cset -f -y 0 0x1c 0x2f 0x22 b
  i2cset -f -y 0 0x1c 0x3b 0x0f b
  i2cset -f -y 0 0x1c 0x3d 0x0f b
  i2cset -f -y 0 0x1c 0x45 0x02 b
  i2cset -f -y 0 0x1c 0x24 0xff b
  echo "$(date) rk818 rails restored" >> /data/citaq/rk818.log
  pmic_reset=1
fi
# 00b) RK818 CLK32KOUT2 = the 32.768 kHz sleep clock (LPO) for the AP6256 Wi-Fi/BT module. Reg 0x20:
#      bit0 = CLK32KOUT2_EN, bit1 = pin function (must be 0 = 32k clock out; cf. mainline rk818_pre_init_reg
#      CLK32KOUT2_FUNC, added for the same dead-Wi-Fi symptom on the Pinephone Pro). OTP default 0x02 = pin not a
#      clock -> after a battery pull the Wi-Fi firmware loads but fails "HT Avail timeout".
c=$(i2cget -f -y 0 0x1c 0x20)
[ $((c & 3)) = 1 ] || { i2cset -f -y 0 0x1c 0x20 $(printf 0x%02x $(((c & ~3) | 1))) b; pmic_reset=1; }
# 00b2) After a battery pull the kernel probed the SDIO host (~0.5 s) while the module had no supply/sleep clock,
#      so the Wi-Fi chip is missing or wedged. Now that rails + clock are back, unbind/bind the SDIO host: that
#      re-runs the mmc-pwrseq (WL_REG_ON power cycle) and re-enumerates the card before the Wi-Fi HAL loads bcmdhd.
if [ "$pmic_reset" = 1 ]; then
  d=/sys/bus/platform/drivers/dwmmc_rockchip
  sleep 0.2
  echo ff0d0000.dwmmc > $d/unbind; sleep 0.5; echo ff0d0000.dwmmc > $d/bind
  # if bcmdhd already tried (and failed) without a card it stays loaded but dead - drop it so the Wi-Fi HAL reloads it
  rmmod bcmdhd 2>/dev/null
  echo "$(date) sdio host rebound after PMIC reset" >> /data/citaq/rk818.log
fi
# 00b3) Same story for the RT5651 audio codec (I2C1 @0x1a): after a PMIC reset it was probed unpowered, the probe
#      failed, and the sound card stays deferred waiting for it -> no sound card at all. Bind it now that the rails
#      are back; the card registers straight after. (A power-off from the back switch also resets the PMIC.)
#      On a terminal with the ES8316 instead this bind just fails (nothing at 0x1a) - see 00b3b.
if [ ! -e /sys/bus/i2c/devices/1-001a/driver ]; then
  echo 1-001a > /sys/bus/i2c/drivers/rt5651/bind 2>/dev/null     # (binding is synchronous)
  [ -e /sys/bus/i2c/devices/1-001a/driver ] && rt_late=1
fi
# 00b3b) Which codec is fitted. Citaq builds this board with either a Realtek RT5651 (I2C1 @0x1a, the reference
#      terminal) or an Everest ES8316 (@0x10); the stock firmware is identical and lists both. The RT5651 driver
#      checks its chip ID, so if it is bound the RT5651 card comes up by itself. Otherwise, if something answers at
#      0x10, bind the DTB's ES8316 card (/es8316-sound), which is kept from binding on its own because the es8316
#      driver doesn't check for its chip and the two cards can't share the I2S port. Needs the Nov 2026 DTB with
#      the es8316-sound node; with an older DTB an ES8316 terminal just has no sound card, as before.
#      The result is in /data/citaq/codec (rt5651, es8316 or none) and /data/citaq/sound.log.
if [ -e /sys/bus/i2c/devices/1-001a/driver ]; then
  codec=rt5651
elif i2cget -f -y 1 0x10 0x00 > /dev/null 2>&1; then
  codec=es8316
  d=/sys/bus/platform/devices/es8316-sound
  if [ -e $d ] && [ ! -e $d/driver ]; then
    echo asoc-simple-card > $d/driver_override
    echo es8316-sound > /sys/bus/platform/drivers/asoc-simple-card/bind 2>/dev/null
  fi
else
  codec=none
fi
for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/snd/controlC0 ] && break; sleep 0.3; done
card=$(cat /proc/asound/card0/id 2>/dev/null)
echo $codec > /data/citaq/codec
echo "$(date) codec $codec, sound card ${card:-MISSING}$([ $codec = none ] && echo ' (nothing answered at I2C1 0x1a or 0x10)')" > /data/citaq/sound.log
[ "$rt_late" = 1 ] && echo "$(date) rt5651 codec bound (sound card: ${card:+ok}${card:-MISSING})" >> /data/citaq/rk818.log
# 00b4) tee-supplicant talks to an OP-TEE the Citaq's trust firmware doesn't have: it exits, init restarts it every
#      5 s forever, and each attempt logs an error - flooding the kernel log. Nothing on this build needs it.
stop tee-supplicant
# 00b5) Bluetooth (needs the DTB's wireless-bluetooth node). The AP6256's BT core (BCM4345C5) is on UART0 =
#      /dev/ttyS0. Three things in the PX5 ROM get in the way:
#      a) The GPS HAL (vendor.gnss_service) opens the port named by vendor.gps.channel (= /dev/ttyS0). The Citaq has
#         no GPS, but the HAL must keep RUNNING: system_server waits for it forever at boot (stopping it hangs the
#         boot on the logo). Point it at /dev/ptmx (a pty nobody writes to) and restart it, so ttyS0 is free.
#         A watcher re-asserts this for the first 2 minutes in case a vendor .rc sets the property later.
#      b) The MTC Bluetooth app (ExtAospBluetooth10) fakes "ON" without ever starting the controller unless
#         hct.bt.org=true (HCT's "original Android" switch, read when com.android.bluetooth starts).
#      c) No BCM4345C5 firmware in the ROM: /data/citaq/bt (BCM4345C5.hcd + bt_vendor.conf + the ROM's rtkbt.conf)
#         is bind-mounted over /vendor/etc/bluetooth, where libbt-vendor loads its config. Delete /data/citaq/bt to undo.
setprop hct.bt.org true
gps_off() { setprop vendor.gps.channel /dev/ptmx; stop vendor.gnss_service; start vendor.gnss_service; }
gps_off
( for i in $(seq 1 24); do
    sleep 5
    [ "$(getprop vendor.gps.channel)" = /dev/ptmx ] || gps_off
    [ "$(getprop hct.bt.org)" = true ] || setprop hct.bt.org true
  done ) &
[ -f /data/citaq/bt/bt_vendor.conf ] && mount -o bind /data/citaq/bt /vendor/etc/bluetooth
# 00c) RK818 charger back to the stock Citaq limits (citaq310.dts battery node): 4.05 V / 1.0 A charge
#      (CHRG_CTRL_REG1 0xa3 = EN|4050|1000 = 0x80; OTP default 0xb5 = 4.2 V / 2.0 A, too hard for a 1600 mAh pack),
#      input current limit 3000 mA (USB_CTRL 0xa1 low nibble 0xb; OTP default 0 = 450 mA).
[ "$(i2cget -f -y 0 0x1c 0xa3)" = 0x80 ] || i2cset -f -y 0 0x1c 0xa3 0x80 b
u=$(i2cget -f -y 0 0x1c 0xa1)
[ $((u & 15)) = 11 ] || i2cset -f -y 0 0x1c 0xa1 $(printf 0x%02x $(((u & 0xf0) | 11))) b
# 01) LCD power pins. Nothing in the PX5 DT drives them, so (like the PMIC) they only worked while they kept the
#     state stock Citaq firmware left in them; a battery pull leaves them as inputs/low = blank panel (backlight on).
#     Stock power_ctr sequence (citaq310.dts): lcd_en gpio3 C2 (114) high, lcd_cs gpio0 D6 (30) high,
#     stock init-gpios gpio0 D7 (31) high, then lcd_rst gpio0 D5 (29) released high.
( cd /sys/class/gpio
  for g in 29 30 31 114; do [ -d gpio$g ] || echo $g > export; done
  echo high > gpio114/direction; sleep 0.1
  echo high > gpio30/direction; sleep 0.1
  echo high > gpio31/direction
  [ "$(cat gpio29/direction)" = out ] && [ "$(cat gpio29/value)" = 1 ] || {
    echo low > gpio29/direction; sleep 0.1; echo 1 > gpio29/value; }
)
# 0b) "thermalservice": the MTC SystemServer never starts ThermalManagerService, so current Google Play services
#     crash (NPE in PowerManager.addThermalStatusListener). Register a do-nothing stand-in (thermalstub/).
if [ -f /data/citaq/thermalstub.jar ]; then
  CLASSPATH=/data/citaq/thermalstub.jar app_process /system/bin com.citaq.ThermalStub > /data/citaq/thermalstub.log 2>&1 &
fi
# 0c) Serial number: Rockchip drmservice sets ro.serialno to junk ("id.so") from the PX5 vendor storage, which
#     Google check-in rejects. Once it has been set, overwrite it in place with the kernel-cmdline serial
#     (androidboot.serialno=..., v18 DTB) using propset (edits the read-only property directly).
( S=$(getprop ro.boot.serialno)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -n "$(getprop ro.serialno)" ] && break; sleep 1
  done
  [ -n "$S" ] && [ "$(getprop ro.serialno)" != "$S" ] && /data/citaq/propset ro.serialno "$S"
) > /data/citaq/propset.log 2>&1 &
# 0d) Thermal: use the power_allocator governor the DT is tuned for (sustainable-power) instead of the kernel's
#     default step_wise, which never releases a throttle while the temperature is steady.
for z in /sys/class/thermal/thermal_zone*; do
  [ "$(cat $z/type)" = soc-thermal ] && echo power_allocator > $z/policy
done
# 0e) TSADC: the legacy rk3368 driver reads the sensor via SCPI (MCU) whenever the PM QoS cpu_dma_latency request
#     is above its latency-bound (50000 us); with no request (default 2 s) it always asks the MCU, which on this
#     firmware returns a constant 122 (= "25 C"). Hold a 50000 us request (hex c350) for good: the driver then reads
#     the ADC directly and the temperature is real. 50 ms allows every cpuidle state, so it costs no power.
( exec 3> /dev/cpu_dma_latency; echo c350 >&3; while :; do sleep 86400; done ) &
# 0f) CPU speed limit. /data/citaq/cpu-max-mhz holds 816, 1008, 1200 or 1512; no file (or anything else) = 1008.
#     816/1008/1200 cap both clusters. 1512 = cpu4-7 up to 1512 MHz @ 1.35 V, cpu0-3 at their 1200 MHz max.
#     Both clusters share one rail (1.125 V at 1008, 1.225 V at 1200, 1.35 V at 1512). The terminal has no
#     heatsink, so 1008 is the default; 1200 and 1512 are opt-in. They rely on the 70/80 C throttle, which only
#     works with a DTB from 21 Nov 2026 or later (fixed temperature sensor). On stock cooling 1512 only helps
#     short bursts (~20% faster); under sustained load it throttles back to <= 1200 MHz within 1-2 s. It's meant
#     for terminals with a heatsink or fan. On an older DTB without the 1512 OPP the kernel clamps it to 1200.
cpumax=$(cat /data/citaq/cpu-max-mhz 2>/dev/null | tr -dc 0-9)
case "$cpumax" in
  816|1008|1200) lit=$cpumax; big=$cpumax ;;
  1512) lit=1200; big=1512 ;;
  *) cpumax=1008; lit=1008; big=1008 ;;
esac
echo ${lit}000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
echo ${big}000 > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
# Log the limit we set, not scaling_max_freq read back: by now the boot-time throttle may already have pulled
# that down (it logged 816 on a 1512 terminal). cpuinfo_max_freq is the highest OPP the DTB offers, so an older
# DTB without 1512 still shows up here.
top=$(($(cat /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq) / 1000))
[ "$big" -gt "$top" ] && big="$top (DTB tops out at $top)"
echo "$(date) cpu max $cpumax MHz (cpu0-3 $lit, cpu4-7 $big)" > /data/citaq/cpu.log
# 1) Wi-Fi: use our rebuilt bcmdhd.ko instead of the vendor one (built for 4.19.101).
mount -o bind /data/citaq/bcmdhd.ko /vendor/lib/modules/bcmdhd.ko
# 1b) AP6255 terminals: the PX5 image's Broadcom firmware for the BCM43455 (fw_bcm43455c0_ag.bin) traps about every
#     13 min ("FIRMWARE HALTED", same pc each time) and Wi-Fi stays down. Cypress's build for the same chip, also in
#     the image (fw_cyw43455.bin, 7.45.203 CY), ran overnight without a trap (issue #4, 22 Nov 2026). The driver
#     only reads the 43455c0 file on an AP6255; AP6256 terminals load fw_bcm43456c5_ag.bin, so this needs no
#     detection and changes nothing on them.
F=/vendor/etc/firmware
[ -f $F/fw_cyw43455.bin ] && [ -f $F/fw_bcm43455c0_ag.bin ] && mount -o bind $F/fw_cyw43455.bin $F/fw_bcm43455c0_ag.bin
# 2) Sound: open the codec's playback path. RT5651: DAC -> line out + headphone out. ES8316: DAC -> headphone
#    mixer -> headphone out (it has no line out). On both the speaker amp hangs off the headphone output and the
#    amp pin is driven by 3c below.
case $codec in
  rt5651)
    for c in 'DAC MIXL INF1 Switch' 'DAC MIXR INF1 Switch' \
             'Stereo DAC MIXL DAC L1 Switch' 'Stereo DAC MIXR DAC R1 Switch' \
             'HPO MIX DAC1 Switch' 'HPO L Playback Switch' 'HPO R Playback Switch' \
             'LOUT MIX DAC L1 Switch' 'LOUT MIX DAC R1 Switch' \
             'LOUT L Playback Switch' 'LOUT R Playback Switch'; do
      tinymix "$c" 1 >/dev/null 2>&1
    done ;;
  es8316)
    for c in 'Left Headphone Mixer Left DAC Switch' 'Right Headphone Mixer Right DAC Switch'; do
      tinymix "$c" 1 >/dev/null 2>&1
    done ;;
esac
# 2b) Backlight: blshim mirrors Android's brightness (MTC pwm-backlight on dummy pwm3, v19 DTB) onto the
#     real backlight PWM (pwm0). Without the v19 DTB pwm0 is still held by pwm-backlight and blshim just exits.
[ -x /data/citaq/blshim ] && /data/citaq/blshim 3 > /data/citaq/blshim.log 2>&1 &
# 2c) Volume: volshim maps Android's media volume (Settings volume_music_speaker, 0-15) onto the codec's
#     hardware DAC volume (RT5651 or ES8316, it checks which) - this build applies no software volume
#     (the car MCU normally did).
[ -x /data/citaq/volshim ] && /data/citaq/volshim volume_music_speaker 15 > /data/citaq/volshim.log 2>&1 &
# 3) POS hardware for Home Assistant (same paths the stock 5.1 kiosk setup used):
#    printer /dev/ttyS1 (UART1, 115200, CTS), LEDs red = gpio124, blue = gpio106 (off at boot),
#    gpio81 (GPIO2_C1) driven high at boot exactly like the stock init-gpios (31=1, 81=1, 106=0, 124=0).
for g in 81 106 124; do
  [ -d /sys/class/gpio/gpio$g ] || echo $g > /sys/class/gpio/export
  echo out > /sys/class/gpio/gpio$g/direction
done
echo 1 > /sys/class/gpio/gpio81/value
echo 0 > /sys/class/gpio/gpio106/value
echo 0 > /sys/class/gpio/gpio124/value
chmod 666 /sys/class/gpio/gpio106/value /sys/class/gpio/gpio124/value /dev/ttyS1
stty -F /dev/ttyS1 115200 raw -echo crtscts 2>/dev/null
# 3b) 4G modem: Fibocom NL668-EAU on the internal USB hub (1-1.1). Nothing in the PX5 port powers it; the stock
#     3.10 DT drove it through rk_bp_auto: power key gpio0 D4 (28), reset gpio3 B5 (109), W_DISABLE gpio3 B1 (105),
#     all active-low. Driving all three high (key released, out of reset, radio enabled) brings it up on USB about
#     14 s later: option -> /dev/ttyUSB0-3 (AT commands on ttyUSB2), qmi_wwan -> wwan0 + /dev/cdc-wdm0.
#     Its ttys come up with iuclc set (AT replies arrive lowercased), so set them raw without case mapping, and
#     world-writable like the printer port so Home Assistant can use them over adb. See docs/MODEM.md.
#     Create /data/citaq/no-modem to leave the modem switched off.
if [ ! -f /data/citaq/no-modem ]; then
  for g in 28 109 105; do
    [ -d /sys/class/gpio/gpio$g ] || echo $g > /sys/class/gpio/export
    echo high > /sys/class/gpio/gpio$g/direction
  done
  ( for i in $(seq 1 60); do [ -c /dev/ttyUSB2 ] && break; sleep 1; done
    for t in /dev/ttyUSB*; do
      [ -c $t ] || continue
      chmod 666 $t
      stty -F $t 115200 raw -echo -iuclc -olcuc -icanon 2>/dev/null
    done
  ) &
fi
# 3c) Headphone jack. The jack and the built-in speaker amp share the codec's headphone output, so the speakers can
#     only be muted with the amp's enable pin (gpio19, active high), which the DTB takes away from the codec driver.
#     Jack detect = gpio15 (active low; the DTB turns its pull-up on): 0 = something plugged in.
#     /data/citaq/speaker overrides it: "on" or "off" (no file = automatic). Without the matching DTB gpio19 is
#     still held by the codec driver, the export fails and this does nothing.
( cd /sys/class/gpio
  for g in 15 19; do [ -d gpio$g ] || echo $g > export; done
  [ -d gpio15 ] && [ -d gpio19 ] || exit 0
  echo in > gpio15/direction
  echo high > gpio19/direction
  while :; do
    m=$(cat /data/citaq/speaker 2>/dev/null)
    case "$m" in
      on)  a=1 ;;
      off) a=0 ;;
      *)   [ "$(cat gpio15/value)" = 0 ] && a=0 || a=1 ;;
    esac
    [ "$(cat gpio19/value)" = $a ] || echo $a > gpio19/value
    sleep 1
  done
) > /dev/null 2>&1 &
# 4) adb over the network on port 5555 (HA's Android Debug Bridge integration). Takes effect when adbd
#    next starts; set once, it persists.
[ "$(getprop persist.adb.tcp.port)" = 5555 ] || setprop persist.adb.tcp.port 5555
# 4b) Wall kiosk: open the Home Assistant app once Android has finished booting, so the dashboard comes back
#     by itself after a power cut. (Full or minimal Companion flavour, whichever is installed.)
( for i in $(seq 1 180); do [ "$(getprop sys.boot_completed)" = 1 ] && break; sleep 1; done
  # Screen orientation: the panel is mounted upside down, so Android runs rotated 180 (user_rotation 2) with
  # auto-rotate off. It's a normal Android setting, but it got lost once after a run of hard power cuts -
  # re-assert it every boot. (Change the 2 to 0 for the panel's native way up.)
  settings put system accelerometer_rotation 0
  settings put system user_rotation 2
  # No GPS on the Citaq (its HAL points at a dummy pty, see 00b5): keep the GPS location provider off, or
  # every location request blocks the system foreground thread for 5 s waiting on the dummy port.
  settings put secure location_providers_allowed -gps
  sleep 5
  for p in io.homeassistant.companion.android io.homeassistant.companion.android.minimal; do
    pm path $p > /dev/null 2>&1 || continue
    # (monkey can't be used: on this build it aborts with "SYS_KEYS has no physical keys")
    a=$(cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $p | tail -n 1)
    echo "$(date) launching $a"
    am start -n "$a"
    break
  done
) > /data/citaq/launch.log 2>&1 &
# 4c) Power off properly. Back power switch = main DC input (it also powers the printer). Stock firmware's RK818
#     driver shut Android down cleanly when DC went away and then told the PMIC to cut power. We have no RK818
#     driver: poll RK818 SUP_STS (0xa0) bit1 (input present: 0xbf on DC, 0x8c on battery); once DC has been seen,
#     5 s without it -> our own shutdown: ACTION_SHUTDOWN broadcast (apps save), stop the framework, sync, emergency
#     read-only remount (sysrq u), sync, then RK818 DEVCTRL (0x4b) DEV_OFF (bit0) - what the mainline rk808 driver's
#     pm_power_off does for the RK818. (`svc power shutdown` alone halts the SoC with the PMIC still on: backlight
#     lit, battery draining - and init never gave this service a SIGTERM to hook.)
#     (A PC on the USB/adb lead also counts as input, so it won't shut down on the bench.)
#     The TERM trap is kept as a best-effort hook for "Power off" from the Android menu.
( poweroff() {
    case "$(getprop sys.powerctl)" in
      shutdown*) echo "$(date) PMIC power-off" >> /data/citaq/power.log
                 sync; echo u > /proc/sysrq-trigger; sleep 1; sync
                 i2cset -f -y 0 0x1c 0x4b 0x01 b ;;
    esac
    exit 0
  }
  trap poweroff TERM
  seen=0; off=0; done=0
  while :; do
    s=$(i2cget -f -y 0 0x1c 0xa0 2>/dev/null)
    if [ -n "$s" ] && [ $done = 0 ]; then
      if [ $((s & 2)) = 2 ]; then seen=1; off=0
      elif [ $seen = 1 ]; then off=$((off + 1))
      fi
      if [ $off -ge 5 ] && [ "$(getprop sys.boot_completed)" = 1 ]; then
        echo "$(date) main power off (0xa0=$s) - shutting down" >> /data/citaq/power.log
        done=1
        am broadcast -a android.intent.action.ACTION_SHUTDOWN
        sleep 3
        stop
        sleep 2
        echo "$(date) PMIC power-off (switch)" >> /data/citaq/power.log
        sync; echo u > /proc/sysrq-trigger; sleep 1; sync
        i2cset -f -y 0 0x1c 0x4b 0x01 b
      fi
    fi
    sleep 1
  done
) > /dev/null 2>&1 &
# 5) Touch daemon (the real binary).
exec /data/citaq/ilits.bin "$@"
