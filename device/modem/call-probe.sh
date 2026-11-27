#!/system/bin/sh
# Citaq H10: read-only probe for voice-call support on hardware other than the reference terminal.
# It makes NO calls and changes NO settings: it reads system files and sends only AT queries (commands ending in
# "?" or "=?", plus ATI/AT+CGMR). Works with or without a SIM. Run as root, then post the log:
#   su 0 sh /data/local/tmp/call-probe.sh
#   cat /data/local/tmp/call-probe.log
# Takes about a minute. Long numbers (IMEI, SIM/phone numbers) show as [hidden], IP addresses as [ip] and the
# cell tower/area IDs as [cell]; check the log before posting.
L=/data/local/tmp/call-probe.log
T=/data/local/tmp/call-probe.at
# Masks: long numbers (IMEI, ICCID, phone numbers), IPv4 and dotted/colon IPv6 addresses, and the quoted hex
# cell/area IDs in +CREG/+CEREG/+CGREG replies (they can locate the terminal).
IP='(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3,}($|[^0-9.])'
hide() { sed -E "s/[0-9]{8,}/[hidden]/g; s/$IP/\1[ip]\3/g; s/$IP/\1[ip]\3/g; s/[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){4,}/[ip]/g; /REG:/s/\"[0-9A-Fa-f]{4,8}\"/\"[cell]\"/g"; }
sec() { echo; echo "== $*"; }
{
sec "build"
for p in ro.product.model ro.board.platform ro.build.display.id; do echo "$p=$(getprop $p)"; done

sec "sound chip"
cat /data/citaq/sound.log 2>/dev/null || echo "(no /data/citaq/sound.log)"
cat /proc/asound/cards 2>/dev/null
ls /sys/kernel/debug/regmap 2>/dev/null | grep -E "001a|0010" | sed 's/^/regmap: /'
n=$(tinymix 2>/dev/null | grep -ac .); echo "mixer controls: $n"
echo "second audio port controls (IF2/AIF2/ASRC):"
tinymix 2>/dev/null | grep -aiE "IF2|AIF2|ASRC|I2S2" | cut -c1-80 | head -20
echo "input/mic controls:"
tinymix 2>/dev/null | grep -aiE "RECMIX|BST1|IN1 |Mic|ADC.*Mux|PGA" | cut -c1-80 | head -20
cat /data/citaq/audio/audio.log 2>/dev/null || echo "(no 48 kHz audio log: boot hook section 2d not active)"

sec "modem"
D=/sys/bus/usb/devices/1-1.1
if [ -d $D ]; then
  echo "usb 1-1.1: $(cat $D/idVendor):$(cat $D/idProduct) $(cat $D/manufacturer 2>/dev/null) / $(cat $D/product 2>/dev/null)"
else
  echo "no modem on usb 1-1.1"
fi
ls /dev/ttyUSB* 2>/dev/null | tr '\n' ' '; echo
cat /data/citaq/modem.log 2>/dev/null | tail -3
echo "mobile data flag: $([ -f /data/citaq/mobile-data ] && echo on || echo off), rild: $(getprop init.svc.vendor.ril-daemon)"

held() { ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q -- "-> $1\$"; }
P=$PORT
if [ -z "$P" ]; then
  for p in /dev/ttyUSB2 /dev/ttyUSB3; do [ -c $p ] && ! held $p && { P=$p; break; }; done
fi
if [ -n "$P" ] && [ -c "$P" ]; then
  sec "AT queries on $P"
  stty -F $P 115200 raw -echo -iuclc -olcuc -icanon min 1 time 0 2>/dev/null
  q() {
    : > $T; cat $P > $T & c=$!
    printf '%s\r' "$1" > $P; sleep ${2:-2}
    kill $c 2>/dev/null; wait $c 2>/dev/null
    echo "> $1"; tr -d '\015' < $T | grep -av '^[[:space:]]*$' | grep -avxF "$1" | sed 's/^/  /'
  }
  # identity and network
  q 'ATI'; q 'AT+CGMR'; q 'AT+CPIN?'; q 'AT+CSQ'; q 'AT+COPS?'; q 'AT+CEREG?'; q 'AT+CREG?'
  # data contexts (an IMS/VoLTE context shows up here) and VoLTE status
  q 'AT+CGDCONT?'; q 'AT+CGACT?'; q 'AT+CAVIMS?'; q 'AT+CIREG?'; q 'AT+CEVDP?'
  # call audio: volume, mute
  q 'AT+CLVL?'; q 'AT+CLVL=?'; q 'AT+CMUT?'
  # Fibocom / Qualcomm: IMS profile config, audio mode, digital audio (PCM/I2S) interface
  q 'AT$QCPDPIMSCFGE?'; q 'AT+GTAUDMODE?'; q 'AT+MAI2SY?'; q 'AT+MAI2SY=?'
  # Huawei: PCM interface, voice support, IMS switch, VoLTE settings
  q 'AT^CPCM?'; q 'AT^CPCM=?'; q 'AT^CVOICE?'; q 'AT^CVOICE=?'; q 'AT^IMSSWITCH?'; q 'AT^VOLTECTRL=?'
  rm -f $T
else
  sec "AT queries"
  echo "no free AT port: ttyUSB2/3 missing or both held (mobile data's RIL holds ttyUSB2 on some modems)."
  echo "Turn mobile data off (rm /data/citaq/mobile-data, reboot) or set PORT=/dev/ttyUSBn and run again."
fi
sec "done"
} 2>&1 | hide > $L
echo "written to $L ($(wc -l < $L) lines)"
