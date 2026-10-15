#!/bin/bash
# Checks build/LaptopAlarm.app. Run after ./build.sh app.
set -u
cd "$(dirname "$0")/.."
APP=build/LaptopAlarm.app
PLIST=$APP/Contents/Info.plist
fails=0

check() {
    local name=$1
    shift
    if "$@" > /dev/null 2>&1; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        fails=$((fails + 1))
    fi
}

plist_is() {
    [ "$(plutil -extract "$1" raw "$PLIST" 2> /dev/null)" = "$2" ]
}

check "app binary is executable" test -x "$APP/Contents/MacOS/LaptopAlarm"
check "engine binary is executable" test -x "$APP/Contents/Resources/laptop-alarm"
check "LSUIElement is true" plist_is LSUIElement true
check "CFBundleIdentifier" plist_is CFBundleIdentifier com.laptopalarm.LaptopAlarm
check "LSMinimumSystemVersion is 14.0" plist_is LSMinimumSystemVersion 14.0
check "CFBundleIconFile is AppIcon" plist_is CFBundleIconFile AppIcon
check "AppIcon.icns exists" test -s "$APP/Contents/Resources/AppIcon.icns"
check "AppIcon.icns is a Mac icon" bash -c "file '$APP/Contents/Resources/AppIcon.icns' | grep -q 'Mac OS X icon'"
check "codesign verifies" codesign --verify --deep "$APP"

if [ "$fails" -ne 0 ]; then
    echo "$fails check(s) failed" >&2
    exit 1
fi
echo "bundle ok"
