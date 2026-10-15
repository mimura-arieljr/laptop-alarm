#!/bin/bash
# Usage: ./build.sh engine | app-dev | test | clean
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
engine)
    mkdir -p build
    swiftc -O Sources/Shared/*.swift Sources/Engine/*.swift -o build/laptop-alarm
    ;;
app-dev)
    mkdir -p build
    swiftc -O Sources/Shared/*.swift Sources/AppLogic/*.swift Sources/App/*.swift -framework AppKit -o build/LaptopAlarmApp-dev
    ;;
test)
    mkdir -p build
    swiftc Sources/Shared/*.swift Sources/AppLogic/*.swift tests/*.swift -o build/tests
    ./build/tests
    ;;
clean)
    rm -rf build
    ;;
*)
    echo "Usage: ./build.sh engine | app-dev | test | clean" >&2
    exit 1
    ;;
esac
