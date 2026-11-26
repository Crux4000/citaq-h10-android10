#!/system/bin/sh
# Citaq H10-3: gather what's needed to plan mobile data on the 4G modem. Read-only: it changes nothing on the
# terminal or the modem (only AT queries, no dialling, no port or mode changes).
# Works with or without a SIM. Long digit runs (IMEI, IMSI, ICCID) show as [hidden] in the log, and IP addresses
# in the data-context lines as [ip].
# Still check the log before posting it, and paste it inside a ``` code block on GitHub.
# The boot hook (device/citaq-boot.sh, 3b) powers the modem. Run as root:  su 0 sh /data/local/tmp/modem-data-probe.sh
# Log: /data/local/tmp/modem-data-probe.log
L=/data/local/tmp/modem-data-probe.log
R=$L.raw
T=/data/local/tmp/at.out
exec > $R 2>&1

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
  tr -d '\r' < $T | grep -v -i -e '^$' -e "^$2\$" | sed -e 's/^/   /'
}

echo "== $(date) modem data probe"
echo "build: $(getprop ro.build.display.id)  kernel: $(uname -r)"

echo "== boot hook modem log"
cat /data/citaq/modem.log 2>&1 | tail -20

D=/sys/bus/usb/devices/1-1.1
echo "== modem on USB ($D)"
if [ -d $D ]; then
  echo "id $(cat $D/idVendor):$(cat $D/idProduct)  product: $(cat $D/product 2>/dev/null)  maker: $(cat $D/manufacturer 2>/dev/null)"
  echo "configs: $(cat $D/bNumConfigurations)  active: $(cat $D/bConfigurationValue)"
  echo "== interfaces (number class/subclass/protocol driver -> net/tty)"
  for i in $D/1-1.1:*; do
    [ -d "$i" ] || continue
    drv=-; [ -e $i/driver ] && drv=$(basename $(readlink $i/driver))
    kids=$(ls -d $i/net/* $i/tty* $i/ttyUSB* $i/usbmisc/* 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
    echo "${i##*/}  $(cat $i/bInterfaceClass)/$(cat $i/bInterfaceSubClass)/$(cat $i/bInterfaceProtocol)  $drv  $kids"
  done
else
  echo "modem not on USB (boot hook section 3b; is /data/citaq/no-modem there?)"
fi

echo "== network interfaces"
ls /sys/class/net
echo "== control nodes"
ls -l /dev/cdc-wdm* /dev/ttyUSB* 2>&1
ls /sys/class/usbmisc 2>&1

echo "== dial-up / RIL / QMI tools on the system"
for f in /system/bin/pppd /system/xbin/pppd /vendor/bin/pppd /system/bin/chat /system/bin/rild /vendor/bin/hw/rild \
         /system/bin/qmicli /system/bin/dhcpcd /system/bin/udhcpc /system/xbin/busybox /system/bin/ip /system/bin/iptables; do
  [ -e $f ] && echo "yes  $f" || echo "no   $f"
done
echo "== RIL libraries"
ls /vendor/lib64 /vendor/lib /system/lib64 /system/lib 2>/dev/null | grep -i -e ril -e qmi | sort -u
echo "== RIL properties"
getprop | grep -i -e ril -e radio -e gsm.version -e telephony -e baseband -e 'net\.ppp'
echo "== rild in init scripts"
for f in $(grep -l -i rild /vendor/etc/init/*.rc /system/etc/init/*.rc /vendor/etc/init/hw/*.rc /*.rc 2>/dev/null); do
  echo "-- $f"
  grep -i -A6 'service.*ril' $f
done
echo "== running radio processes"
ps -A | grep -i -e ril -e ppp -e qmi -e radio | grep -v grep
echo "== mobile data setting: $(settings get global mobile_data)  airplane: $(settings get global airplane_mode_on)"
echo "== PPP scripts"
ls /etc/ppp 2>&1
echo "== RIL log (does it recognise the modem?)"
logcat -b radio -d 2>/dev/null | grep -i -E 'RIL_RK|match|modem|ppp' | tail -25 | cut -c1-200
echo "== modems the Rockchip RIL knows (Huawei/Fibocom/Quectel entries)"
strings /vendor/lib64/libril-rk29-dataonly.so 2>/dev/null | grep -i -E 'ME909|MU709|ME906|E3372|fibocom|NL668|quectel|EC2' | sort -u

echo "== AT queries (read-only)"
P=
for p in /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB1 /dev/ttyUSB0; do
  [ -c $p ] || continue
  stty -F $p 115200 raw -echo -iuclc -olcuc -icanon 2>/dev/null
  at $p AT 3
  if grep -q -i '^OK' $T; then P=$p; echo "== AT port: $p"; break; fi
done
if [ -n "$P" ]; then
  at $P ATE0 2
  at $P ATI 3                  # model / revision
  at $P AT+CPIN? 3             # SIM state
  at $P AT+CEREG? 3            # LTE registration (,1 home  ,5 roaming)
  at $P AT+COPS? 3             # operator
  at $P AT+CGDCONT? 3          # data contexts / APNs stored in the modem
  at $P AT+CGACT? 3            # which contexts are active
  at $P 'AT^SETPORT?' 3        # Huawei: current USB port layout
  at $P 'AT^SETPORT=?' 3       # Huawei: port types it supports (is MBIM or ECM there?)
  at $P 'AT^NDISSTATQRY?' 3    # Huawei: NDIS (NCM) data session state
  at $P 'AT+GTUSBMODE?' 3      # Fibocom: USB mode
  at $P 'AT+GTRNDIS?' 3        # Fibocom: RNDIS/ECM data session state
  echo "RESULT: done (AT port $P)"
else
  echo "RESULT: no port answered AT (system info above is still useful)"
fi

# hide long numbers everywhere, and IP addresses in the data-context lines
sed -E -e 's/[0-9]{14,20}/[hidden]/g' -e '/CGDCONT|CGPADDR|DHCP/ s/[0-9]{1,3}(\.[0-9]{1,3}){3}/[ip]/g' $R > $L
rm -f $R $T
