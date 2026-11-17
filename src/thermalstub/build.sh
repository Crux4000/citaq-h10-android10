#!/bin/sh
# Build thermalstub.jar (dex inside) for the Citaq H10-3 Android 10 port.
# Needs a JDK (javac) and d8 from the Android SDK build-tools (or dalvik "dx").
# The stub/ classes are compile-time stand-ins only - just com/citaq goes into the jar,
# so at runtime the device's real android.os classes are used.
set -e
cd "$(dirname "$0")"
rm -rf out && mkdir -p out/classes out/dex
javac --release 8 -d out/classes -sourcepath stub com/citaq/ThermalStub.java
rm -rf out/classes/android                                   # never ship the stand-ins
if command -v d8 >/dev/null; then
  d8 --min-api 26 --output out/dex $(find out/classes -name '*.class')
elif command -v dx >/dev/null; then
  dx --dex --min-sdk-version=26 --output=out/dex/classes.dex out/classes
else
  echo "need d8 (Android SDK build-tools) or dx on PATH" >&2; exit 1
fi
(cd out/dex && jar cf ../../thermalstub.jar classes.dex)
echo "built $(pwd)/thermalstub.jar"
