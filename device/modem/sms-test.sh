#!/system/bin/sh
# Citaq H10-3: send one test SMS through the 4G modem over AT commands (text mode, standard 3GPP 27.005,
# so it should work on the Fibocom NL668 and the Huawei ME909s alike).
# Needs an active SIM that has registered: at-probe.sh shows +CEREG: 0,1 (home) or 0,5 (roaming).
# Send it to your own phone. Run as root:
#   su 0 sh /data/local/tmp/sms-test.sh +61400000000 "Test from the Citaq"
# Phone numbers are hidden in the output, so it can be posted as is (still check it first).
N=$1
M=${2:-Test from the Citaq H10-3}
[ -n "$N" ] || { echo "usage: sms-test.sh +61400000000 [message]"; exit 1; }
P=${PORT:-/dev/ttyUSB2}
[ -c $P ] || { echo "no $P (is the modem up? see at-probe.sh)"; exit 1; }
T=/data/local/tmp/sms.out

stty -F $P 115200 raw -echo -iuclc -olcuc -icanon 2>/dev/null
: > $T
cat $P > $T & C=$!
sleep 0.3
printf 'ATE0\r' > $P; sleep 1                  # echo off
printf 'AT+CMGF=1\r' > $P; sleep 1             # text mode
printf 'AT+CSCS="GSM"\r' > $P; sleep 1         # plain character set
printf 'AT+CMGS="%s"\r' "$N" > $P; sleep 2     # the modem answers with a "> " prompt
printf '%s\032' "$M" > $P                      # message, ended with Ctrl-Z (0x1A)
w=0
while [ $w -lt 60 ]; do                        # sending can take a while on a weak signal
  sleep 1; w=$((w + 1))
  grep -q -E '^\+CMGS|^\+CMS ERROR|^ERROR' $T && break
done
kill $C 2>/dev/null; wait $C 2>/dev/null

echo "== $(date) SMS test on $P (${w}s)"
tr -d '\r' < $T | grep -v '^ *$' | sed -E -e 's/\+?[0-9]{8,}/[hidden]/g' -e 's/^/   /'
if grep -q '^+CMGS' $T; then
  echo "RESULT: sent (check the phone)"
else
  echo "RESULT: not sent (+CMS ERROR or ERROR above; 'timed out' if nothing)"
fi
rm -f $T
