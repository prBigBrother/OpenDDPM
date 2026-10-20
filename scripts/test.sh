#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
swiftc -swift-version 5 Sources/OpenDDPM/HomeKitHealth.swift tests/HomeKitHealthTests.swift -o build/HomeKitHealthTests
build/HomeKitHealthTests
swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Shortcut.swift Sources/OpenDDPM/Engine.swift tests/CoreTests.swift -o build/CoreTests
build/CoreTests
swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Shortcut.swift Sources/OpenDDPM/Engine.swift Sources/OpenDDPM/Coordinator.swift Sources/OpenDDPM/HTTPRequest.swift tests/CoordinatorTests.swift -o build/CoordinatorTests
build/CoordinatorTests
clang -fobjc-arc -fmodules -framework Foundation -framework IOKit -framework CoreGraphics Sources/NativeDDC/main.m -o build/NativeDDCTests
build/NativeDDCTests --self-test
