#!/bin/bash
# Usage: ./build.sh engine | app | app-dev | install | test | bundle-check | clean
set -euo pipefail
cd "$(dirname "$0")"

APP=build/LaptopAlarm.app

build_engine() {
    mkdir -p build
    swiftc -O Sources/Shared/*.swift Sources/Engine/*.swift -o build/laptop-alarm
}

build_app_binary() {
    mkdir -p build
    swiftc -O Sources/Shared/*.swift Sources/AppLogic/*.swift Sources/App/*.swift -framework AppKit -o "$1"
}

build_bundle() {
    build_engine
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    build_app_binary "$APP/Contents/MacOS/LaptopAlarm"
    cp build/laptop-alarm "$APP/Contents/Resources/laptop-alarm"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LaptopAlarm</string>
    <key>CFBundleIdentifier</key>
    <string>com.laptopalarm.LaptopAlarm</string>
    <key>CFBundleName</key>
    <string>Laptop Alarm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
    plutil -lint "$APP/Contents/Info.plist" > /dev/null
    codesign --force --deep --sign - "$APP"
}

case "${1:-}" in
engine)
    build_engine
    ;;
app)
    build_bundle
    ;;
app-dev)
    build_app_binary build/LaptopAlarmApp-dev
    ;;
install)
    build_bundle
    dest="${INSTALL_DIR:-/Applications}"
    mkdir -p "$dest"
    rm -rf "$dest/LaptopAlarm.app"
    ditto "$APP" "$dest/LaptopAlarm.app"
    echo "Installed $dest/LaptopAlarm.app"
    ;;
test)
    mkdir -p build
    swiftc Sources/Shared/*.swift Sources/AppLogic/*.swift tests/*.swift -o build/tests
    ./build/tests
    ;;
bundle-check)
    bash tests/bundle-check.sh
    ;;
clean)
    rm -rf build
    ;;
*)
    echo "Usage: ./build.sh engine | app | app-dev | install | test | bundle-check | clean" >&2
    exit 1
    ;;
esac
