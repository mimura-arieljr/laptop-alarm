#!/bin/bash
# Usage: ./build.sh engine | test | clean
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
engine)
    mkdir -p build
    swiftc -O Sources/Shared/*.swift Sources/Engine/*.swift -o build/laptop-alarm
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
    echo "Usage: ./build.sh engine | test | clean" >&2
    exit 1
    ;;
esac
