#!/system/bin/sh
# Citaq H10-3: test mobile data at the Linux level by dialling PPP on the 4G modem, pinging out through
# that link only, then hanging up. Wi-Fi, Ethernet and Android's own routing are left alone: no default
# route is added; a temporary rule sends only traffic bound to ppp0 out of it, and is removed afterwards.
# Needs an active SIM that has registered with data (+CGACT: 1,1). Uses context 1 (its APN from +CGDCONT).
# Run as root:  su 0 sh /data/local/tmp/ppp-test.sh      (PORT=/dev/ttyUSB2 to dial on another port)
# Log: /data/local/tmp/ppp-test.log  (IP addresses shown as [ip])
# pppd runs in its own session (setsid): otherwise the adb session closing sends it SIGHUP and it hangs up.
L=/data/local/tmp/ppp-test.log
O=/data/local/tmp/pppd.out
P=${PORT:-/dev/ttyUSB3}
exec > $L 2>&1
mask() { sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/[ip]/g'; }

echo "== $(date) PPP test on $P"
[ -c $P ] || { echo "no $P"; exit 1; }
: > $O
setsid /system/bin/pppd $P 115200 nodetach noauth nodefaultroute noipdefault usepeerdns nocrtscts local \
  novj nobsdcomp nodeflate noccp debug maxfail 1 logfile $O \
  connect "/system/bin/chat -v -t 20 '' AT OK 'ATD*99***1#' CONNECT" &
PID=$!
i=0
while [ $i -lt 40 ]; do
  sleep 1; i=$((i + 1))
  ip addr show ppp0 2>/dev/null | grep -q 'inet ' && break
  kill -0 $PID 2>/dev/null || break
done
echo "== ppp0 after ${i}s"
ip addr show ppp0 2>&1 | grep -E 'inet |state|ppp0:' | mask
if ip addr show ppp0 2>/dev/null | grep -q 'inet '; then
  ip route add default dev ppp0 table 1999
  ip rule add oif ppp0 lookup 1999 pref 99
  echo "== ping 1.1.1.1 through ppp0"
  ping -I ppp0 -c 4 -W 3 1.1.1.1 2>&1 | tail -3
  echo "== ping 8.8.8.8 through ppp0"
  ping -I ppp0 -c 2 -W 3 8.8.8.8 2>&1 | tail -2
  ip rule del oif ppp0 lookup 1999 pref 99
  ip route flush table 1999
  echo "== rx/tx bytes: $(cat /sys/class/net/ppp0/statistics/rx_bytes) / $(cat /sys/class/net/ppp0/statistics/tx_bytes)"
fi
kill $PID $(pidof pppd) 2>/dev/null; sleep 3; kill -9 $PID $(pidof pppd) 2>/dev/null
echo "== pppd log"
mask < $O | grep -v -i -E 'secret|password' | tail -30
ip addr show ppp0 >/dev/null 2>&1 && echo "WARNING: ppp0 still up" || echo "== hung up, ppp0 gone"
