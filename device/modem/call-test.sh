#!/system/bin/sh
# Citaq H10-3: test voice-call audio through the 4G modem (Fibocom NL668 + RT5651 codec).
# Dials a number, holds the call, routes the call audio through the codec and hangs up. See docs/MODEM.md
# ("Voice calls") first: the SIM's carrier must take VoLTE calls from the modem (IMS profile), and the boot hook's
# 48 kHz audio fix (section 2d) must be on, or Android's sound breaks after the call until a reboot.
#
#   su 0 sh /data/local/tmp/call-test.sh +61400000000 [seconds] [tone|silence|mic]
#
#   tone     (default) the kiosk sends a steady 400 Hz hum down the line: you should hear it on your phone,
#            and the caller's voice comes out of the kiosk speakers.
#   silence  same, without the hum (to judge the caller's voice on its own).
#   mic      UNTESTED: a headset microphone on the 3.5 mm jack (IN1P, MICBIAS1) goes down the line instead.
#            Use a phone headset: the jack mutes the speakers, so there's no echo. Gain: MICBOOST=0..8 (default 2).
#
# The call ends after [seconds] (default 60) or when the other end hangs up. Prints a short report; the
# caller's audio is also recorded to /data/local/tmp/call-test.wav (48 kHz stereo, right channel = caller).
# Phone numbers are hidden in the output, so it can be posted as is (still check it first). Run as root.
N=$1; SECS=${2:-60}; MODE=${3:-tone}
T=/data/local/tmp
REC=$T/call-test.wav
OUT=$T/call-test.at
RM=/sys/kernel/debug/regmap/1-001a/registers
log() { echo "$(date +%H:%M:%S) $*"; }
case $MODE in tone|silence|mic) ;; *) N=;; esac
[ -n "$N" ] || { echo "usage: call-test.sh +61400000000 [seconds] [tone|silence|mic]"; exit 1; }

# --- checks ---------------------------------------------------------------------------------------------
tinymix 'RT5651 ASRC Switch' > /dev/null 2>&1 || { log "no RT5651 codec: call audio needs its second I2S port (ES8316 units have none)"; exit 1; }
[ -f $RM ] || { log "no $RM (needs root and debugfs)"; exit 1; }
grep -q "48 kHz HAL mounted" /data/citaq/audio/audio.log 2>/dev/null || \
  log "WARNING: the boot hook's 48 kHz audio fix (section 2d) isn't active: Android's sound will stop working after this test until a reboot"
held() { ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q -- "-> $1\$"; }
P=$PORT
if [ -z "$P" ]; then              # the RIL (mobile data) may hold ttyUSB2, and PPP data ttyUSB3
  for p in /dev/ttyUSB2 /dev/ttyUSB3; do [ -c $p ] && ! held $p && { P=$p; break; }; done
fi
[ -n "$P" ] && [ -c "$P" ] || { log "no free AT port (ttyUSB2/3 missing or both in use; set PORT=/dev/ttyUSBn)"; exit 1; }
log "AT port $P, mode $MODE, up to $SECS s"

# --- what we play to the codec's first port (also keeps the playback side clocked) ----------------------
if [ $MODE = tone ]; then
  W=$T/call-test-400.wav
  if [ ! -s $W ]; then             # one period of 400 Hz at 48 kHz stereo, doubled 15 times (about 82 s)
    echo AAAAAEUDRQOIBogGxgnGCf4M/gwtEC0QUBNQE2UWZRZrGWsZXxxfHD8fPx8KIgoivCS8JFUnVSfSKdIpMSwxLHIuci6SMJIwkDKQMmo0ajQgNiA2sDewNxg5GDlZOlk6cDtwO148XjwiPSI9uz27PSg+KD5qPmo+gD6APmo+aj4oPig+uz27PSI9Ij1ePF48cDtwO1k6WToYORg5sDewNyA2IDZqNGo0kDKQMpIwkjByLnIuMSwxLNIp0ilVJ1UnvCS8JAoiCiI/Hz8fXxxfHGsZaxllFmUWUBNQEy0QLRD+DP4MxgnGCYgGiAZFA0UDAAAAALv8u/x4+Xj5OvY69gLzAvPT79PvsOyw7Jvpm+mV5pXmoeOh48HgweD23fbdRNtE26vYq9gu1i7Wz9PP047RjtFuz27PcM1wzZbLlsvgyeDJUMhQyOjG6ManxafFkMSQxKLDosPewt7CRcJFwtjB2MGWwZbBgMGAwZbBlsHYwdjBRcJFwt7C3sKiw6LDkMSQxKfFp8XoxujGUMhQyODJ4MmWy5bLcM1wzW7Pbs+O0Y7Rz9PP0y7WLtar2KvYRNtE2/bd9t3B4MHgoeOh45Xmleab6ZvpsOyw7NPv0+8C8wLzOvY69nj5ePm7/Lv8 | base64 -d > $T/b.raw
    i=0; while [ $i -lt 15 ]; do cat $T/b.raw $T/b.raw > $T/b2.raw; mv $T/b2.raw $T/b.raw; i=$((i + 1)); done
    echo UklGRiQA8ABXQVZFZm10IBAAAAABAAIAgLsAAADuAgAEABAAZGF0YQAA8AA= | base64 -d > $W; cat $T/b.raw >> $W; rm -f $T/b.raw
  fi
else
  W=$T/call-test-silence.wav       # 130 s of silence
  [ -s $W ] || { echo UklGRiTcfAFXQVZFZm10IBAAAAABAAIAgLsAAADuAgAEABAAZGF0YQDcfAE= | base64 -d > $W
                 dd if=/dev/zero bs=192000 count=130 >> $W 2>/dev/null; }
fi

# --- codec setup, all BEFORE dialling (changing the codec mid-call can reset the modem) -----------------
# Registers written directly (byte-swapped words); the driver doesn't know about these, so afterwards the chip
# is set back to the driver's own copy of each one (regmap cache).
rr() { printf %d 0x$(grep "^0$1:" $RM | cut -d' ' -f2); }
wr() { v=$2; i2cset -f -y 1 0x1a $1 $(printf 0x%04x $(( ((v & 255) << 8) | (v >> 8) ))) w; }
REGS="61 62 64 71 73 84"
SW="DD MIXL DAC L1 Switch:DD MIXR DAC R2 Switch:Stereo1 ADC MIXL ADC2 Switch:Stereo1 ADC MIXR ADC2 Switch:Stereo DAC MIXL DAC L2 Switch:Stereo DAC MIXR DAC R2 Switch"
[ $MODE = mic ] && SW="$SW:RECMIXL BST1 Switch:RECMIXR BST1 Switch:Stereo1 ADC MIXL ADC1 Switch:Stereo1 ADC MIXR ADC1 Switch"
setsw() { echo "$SW" | tr ':' '\n' | while read c; do tinymix "$c" $1 > /dev/null; done; }
DACV=$(tinymix | grep -a 'DAC1 Playback Volume' | awk '{print $(NF-1)}'); DACV=${DACV:-127}
BST=$(tinymix | grep -a 'IN1 Boost' | awk '{print $NF}'); BST=${BST:-0}
setsw 1
tinymix 'IF2 ADC' 'IF1 ADC1' > /dev/null                 # modem uplink = Stereo1 ADC (48 kHz side, via ASRC)
tinymix 'ADC IF2 Data Switch' 'left copy to right' > /dev/null
tinymix 'DAC IF2 Data Switch' 'left copy to right' > /dev/null
tinymix 'DAC1 Playback Volume' 175 175 > /dev/null       # 0 dB while the call is up
[ $MODE = mic ] && tinymix 'IN1 Boost' ${MICBOOST:-2} > /dev/null

tinycap $REC -D 0 -d 0 -c 2 -r 48000 -b 16 > /dev/null 2>&1 & TC=$!
sleep 1
tinyplay $W > /dev/null 2>&1 & TP=$!
sleep 2
tinymix 'RT5651 ASRC Switch' Enable > /dev/null          # sysclk = PLL1 (2 x MCLK), ASRC for both ports
tinymix 'IF2 ASRC Switch' 1 > /dev/null
a=$(rr 61); b=$(rr 62); c=$(rr 84); d=$(rr 64)
wr 0x71 32898                    # IF2: slave, PCM mode A, BCLK inverted, 16 bit (the modem is PCM master)
wr 0x61 $((a | 16384))           # I2S2 power
wr 0x62 $((b | 52224))           # stereo1/2 ADC + stereo2 DAC filters
wr 0x84 $((c | 18432))           # IF2 ASRC + ADC ASRC mode
wr 0x73 5636                     # pre-div1 /2 (IF1 48 kHz), pre-div2 /12 (IF2 8 kHz = 2.048 MHz)
[ $MODE = mic ] && wr 0x64 $((d | 2048))   # MICBIAS1 (no DAPM route to it in this DT)

# --- the call ---------------------------------------------------------------------------------------------
at() { [ -c $P ] && printf "$1\r" > $P; }
stty -F $P 115200 raw -echo -iuclc -olcuc -icanon min 1 time 0 2>/dev/null
: > $OUT; cat $P > $OUT & CP=$!
sleep 1
at "AT+CMEE=2"; sleep 1
at "AT+CLVL?"; sleep 1
OLDV=$(tr -d '\r' < $OUT | grep -o '+CLVL: [0-9]' | tail -1 | cut -d' ' -f2); OLDV=${OLDV:-4}
at "AT+CLVL=7"; sleep 1          # modem call volume up (0-7) for the call
DEV=$(cat /sys/bus/usb/devices/1-1.1/devnum 2>/dev/null)
T0=$(date +%s)
log "dialling"
at "ATD$N;"
ACTIVE=0; i=0
while [ $i -lt 20 ]; do          # up to 60 s to answer
  sleep 2; at "AT+CLCC"; sleep 1
  grep -aq ',0,0,0,0,"' $OUT && { ACTIVE=1; break; }
  grep -aqE "NO CARRIER|BUSY|NO ANSWER" $OUT && break
  i=$((i + 1))
done
END=dropped
if [ $ACTIVE = 1 ]; then
  log "answered after $(( $(date +%s) - T0 )) s"
  A=$(date +%s); j=0
  while [ $j -lt $((SECS / 3)) ]; do
    sleep 2; at "AT+CLCC"; sleep 1
    grep -aq "NO CARRIER" $OUT && { END="the other end hung up"; break; }
    j=$((j + 1))
  done
  [ $j -ge $((SECS / 3)) ] && END="hung up after $SECS s"
  log "call lasted $(( $(date +%s) - A )) s ($END)"
else
  log "not answered"
fi
at "ATH"; sleep 2
at "AT+CLVL=$OLDV"; sleep 1
at "AT+CEER"; sleep 1
kill $CP 2>/dev/null
kill $TP 2>/dev/null; sleep 1
kill -INT $TC 2>/dev/null; sleep 2; kill $TC 2>/dev/null

# --- put the codec back ------------------------------------------------------------------------------------
setsw 0
tinymix 'ADC IF2 Data Switch' 'Normal' > /dev/null; tinymix 'DAC IF2 Data Switch' 'Normal' > /dev/null
tinymix 'IF2 ASRC Switch' 0 > /dev/null; tinymix 'RT5651 ASRC Switch' Disable > /dev/null
tinymix 'DAC1 Playback Volume' $DACV $DACV > /dev/null
[ $MODE = mic ] && tinymix 'IN1 Boost' $BST > /dev/null
sleep 5
for r in $REGS; do wr 0x$r $(rr $r); done                 # chip = driver's copy again
bad=0; for r in $REGS; do
  [ "$(grep "^0$r:" $RM | cut -d' ' -f2 | cut -c1-2)" = "$(i2cget -f -y 1 0x1a 0x$r | cut -c3-4)" ] || bad=$((bad + 1))
done

# --- report ------------------------------------------------------------------------------------------------
NEWDEV=$(cat /sys/bus/usb/devices/1-1.1/devnum 2>/dev/null)
[ "$DEV" = "$NEWDEV" ] && log "modem: no reset during the test" || log "modem: RESET during the test (devnum $DEV -> $NEWDEV)"
log "codec restored ($bad register mismatches)"
log "modem said:"
tr -d '\r' < $OUT | grep -av '^$' | grep -avE '^\+CLCC: [0-9],[01],[0-9],[01]|^OK$|^\+CLVL' | \
  sed -E 's/\+[0-9]{6,}/[hidden]/g; s/"[0-9]{6,}"/"[hidden]"/g' | uniq | tail -8
SZ=$(wc -c < $REC 2>/dev/null); SZ=${SZ:-44}; NS=$(( (SZ - 44) / 192000 ))
if [ $NS -gt 0 ]; then
  HEARD=$(od -An -v -t d2 -j 44 $REC | awk '{for(i=1;i<=NF;i++){k++; if(!(k%2)){v=$i<0?-$i:$i; s=int(k/96000); if(v>m[s])m[s]=v}}} END{for(s in m) if(m[s]>500)n++; print n+0}')
  log "recorded $NS s; caller audio present in $HEARD of them ($REC)"
fi
log "done. Please report: could you hear the kiosk (tone/mic) on your phone, and the caller on the kiosk?"
