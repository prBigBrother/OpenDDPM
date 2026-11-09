#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
swiftc -swift-version 5 Sources/OpenDDPM/HomeKitHealth.swift tests/HomeKitHealthTests.swift -o build/HomeKitHealthTests
build/HomeKitHealthTests
swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Wakeup.swift Sources/OpenDDPM/Shortcut.swift Sources/OpenDDPM/PictureFeature.swift Sources/OpenDDPM/NativeBrightness.swift Sources/OpenDDPM/Engine.swift tests/CoreTests.swift -o build/CoreTests
build/CoreTests
swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Wakeup.swift Sources/OpenDDPM/Shortcut.swift Sources/OpenDDPM/PictureFeature.swift Sources/OpenDDPM/NativeBrightness.swift Sources/OpenDDPM/Engine.swift Sources/OpenDDPM/Coordinator.swift Sources/OpenDDPM/HTTPRequest.swift tests/CoordinatorTests.swift -o build/CoordinatorTests
build/CoordinatorTests
clang -fobjc-arc -fmodules -framework Foundation -framework IOKit -framework CoreGraphics Sources/NativeDDC/main.m -o build/NativeDDCTests
build/NativeDDCTests --self-test

swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Shortcut.swift Sources/OpenDDPM/Wakeup.swift tests/WakeupTests.swift -o build/WakeupTests
build/WakeupTests

swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Shortcut.swift Sources/OpenDDPM/Wakeup.swift Sources/OpenDDPM/PictureFeature.swift Sources/OpenDDPM/NativeBrightness.swift Sources/OpenDDPM/Engine.swift tests/PictureTests.swift -o build/PictureTests
build/PictureTests

swiftc -swift-version 5 -framework AppKit Sources/OpenDDPM/BrightnessKeys.swift tests/BrightnessKeysTests.swift -o build/BrightnessKeysTests
build/BrightnessKeysTests

swiftc -swift-version 5 Sources/OpenDDPM/Core.swift Sources/OpenDDPM/Shortcut.swift Sources/OpenDDPM/Wakeup.swift Sources/OpenDDPM/PictureFeature.swift Sources/OpenDDPM/NativeBrightness.swift Sources/OpenDDPM/Engine.swift Sources/OpenDDPM/NativeBrightnessNotifications.swift Sources/OpenDDPM/MonitorPictureController.swift tests/MonitorPictureControllerTests.swift -o build/MonitorPictureControllerTests
build/MonitorPictureControllerTests
