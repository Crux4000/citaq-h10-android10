#!/system/bin/sh
# Citaq H10-3: talk to the 4G modem over AT commands (no SIM needed).
# Written for the Fibocom NL668; other modules (e.g. Huawei ME909s) answer ERROR to the Fibocom-only queries.
# Long digit runs (IMEI, IMSI, ICCID) show as [hidden] in the log. Still check it before posting it publicly.
# On GitHub, paste the log inside a ``` code block so the layout survives.
# The boot hook (device/citaq-boot.sh, 3b) powers the modem. Run as root:  su 0 sh /data/local/tmp/at-probe.sh
# Log: /data/local/tmp/at-probe.log
L=/data/local/tmp/at-probe.log
exec > $L 2>&1
T=/data/local/tmp/at.out

at() {  # at <port> <command> <seconds to wait>
  : > $T
  cat $1 > $T & C=$!
  sleep 0.3
  printf '%s\r' "$2" > $1
  w=0
  while [ $w -lt $3 ]; do
    sleep 1; w=$((w + 1))
    grep -q -i -E '^(OK|ERROR|\+CME ERROR)' $T && break
  done
  kill $C 2>/dev/null; wait $C 2>/dev/null
  echo ">> $2  (${w}s)"
  tr -d '\r' < $T | grep -v -i -e '^$' -e "^$2\$" | sed -E -e 's/[0-9]{14,20}/[hidden]/g' -e 's/^/   /'
}

echo "== $(date) AT probe"
[ -d /sys/bus/usb/devices/1-1.1 ] || { echo "modem not on USB (boot hook section 3b; is /data/citaq/no-modem there?)"; exit 1; }
P=
for p in /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB1 /dev/ttyUSB0; do
  [ -c $p ] || continue
  # plain 'raw' leaves iuclc on here (replies arrive lowercased): clear the case mapping explicitly
  stty -F $p 115200 raw -echo -iuclc -olcuc -icanon 2>/dev/null
  at $p AT 3
  if grep -q -i '^OK' $T; then P=$p; echo "== AT port: $p"; break; fi
done
[ -n "$P" ] || { echo "RESULT: no port answered AT"; exit 1; }

at $P ATE0 2                   # echo off
at $P ATI 3                    # manufacturer / model / revision
at $P AT+CGMR 3                # firmware
at $P AT+CGSN 3                # IMEI (hidden in the log; only shows the modem reports one)
at $P AT+CFUN? 3               # 1 = full functionality
at $P AT+CPIN? 3               # expect: SIM not inserted
at $P AT+CSQ 3                 # signal (99,99 = unknown / none)
at $P AT+CREG? 3               # 2G/3G registration state
at $P AT+CEREG? 3              # LTE registration state
at $P AT+COPS? 3               # current operator
at $P 'AT+GTUSBMODE?' 3        # Fibocom USB mode (which interfaces)
echo "== network scan (can take up to 3 minutes)"
at $P 'AT+COPS=?' 180          # visible operators, works without a SIM on most modules
echo "RESULT: done (AT port $P)"
