#!/system/bin/sh
# Undo debloat.sh: reinstall every removed package for user 0
for p in \
  com.microntek.radio com.microntek.music com.microntek.media com.microntek.carcd com.microntek.dvd \
  com.microntek.dvr com.microntek.avin com.microntek.backview com.microntek.frontview com.microntek.travel \
  com.microntek.tv com.microntek.bluetooth com.microntek.btmusic com.microntek.usbipod com.microntek.civxusb \
  com.microntek.sync com.microntek.tpms com.microntek.ampsetup com.microntek.navisettings \
  com.microntek.screenclock com.microntek.controlinfo com.microntek.controlsettings com.microntek.FileBrowser \
  com.microntek.hctwidget android.microntek.canbus com.hct.screenbutton com.hct.wheelstudy com.hct.apkinstall \
  com.hct.factory android.rockchip.update.service com.cghs.stresstest com.DeviceTest com.goodocom.gocsdk \
  com.suding.speedplay net.easyconn com.zjinnova.zlink org.prowl.torque com.switch_pros.switch_pros_sp8100 \
  com.google.android.apps.maps com.google.android.gm com.google.android.googlequicksearchbox \
  com.google.android.gms.location.history com.android.se com.android.smspush com.android.nfc \
  com.android.dreams.phototable com.android.egg com.android.wallpaper.livepicker com.android.gallery3d \
  com.android.calendar com.android.contacts \
; do cmd package install-existing $p; done
