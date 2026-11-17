#!/system/bin/sh
# Citaq H10-3 / PX5 Android 10: remove car + bloat apps for user 0.
# Reversible: the APKs stay on /system; restore one with  cmd package install-existing <package>
# (restore.sh does all of them).
# Run as root:  adb push debloat.sh /data/local/tmp/ && adb shell sh /data/local/tmp/debloat.sh
exec 2>&1
PKGS="
com.microntek.radio com.microntek.music com.microntek.media com.microntek.carcd com.microntek.dvd
com.microntek.dvr com.microntek.avin com.microntek.backview com.microntek.frontview com.microntek.travel
com.microntek.tv com.microntek.bluetooth com.microntek.btmusic com.microntek.usbipod com.microntek.civxusb
com.microntek.sync com.microntek.tpms com.microntek.ampsetup com.microntek.navisettings
com.microntek.screenclock com.microntek.controlinfo com.microntek.controlsettings com.microntek.FileBrowser
com.microntek.hctwidget android.microntek.canbus com.hct.screenbutton com.hct.wheelstudy com.hct.apkinstall
com.hct.factory android.rockchip.update.service com.cghs.stresstest com.DeviceTest com.goodocom.gocsdk
com.suding.speedplay net.easyconn com.zjinnova.zlink org.prowl.torque com.switch_pros.switch_pros_sp8100
com.google.android.apps.maps com.google.android.gm com.google.android.googlequicksearchbox
com.google.android.gms.location.history com.android.se com.android.smspush com.android.nfc
com.android.dreams.phototable com.android.egg com.android.wallpaper.livepicker com.android.gallery3d
com.android.calendar com.android.contacts
"
for p in $PKGS; do
  r=$(pm uninstall -k --user 0 $p 2>&1)
  echo "$p: $r"
done
echo "== still running (top 25 by RSS)"; ps -A -o RSS,NAME | sort -n | tail -25
echo "== mem"; grep -E 'MemTotal|MemAvailable' /proc/meminfo
