#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
swiftc -swift-version 5 Sources/OpenDDPM/Core.swift tests/CoreTests.swift -o build/CoreTests
build/CoreTests
