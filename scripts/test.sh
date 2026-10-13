#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Shortcut.swift tests/CoreTests.swift -o build/CoreTests
build/CoreTests
clang -fobjc-arc -fmodules -framework Foundation -framework IOKit -framework CoreGraphics Sources/NativeDDC/main.m -o build/NativeDDCTests
build/NativeDDCTests --self-test
