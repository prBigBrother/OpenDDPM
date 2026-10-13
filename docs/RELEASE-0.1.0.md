<img src="https://raw.githubusercontent.com/prBigBrother/OpenDDPM/main/assets/logo.png" width="112" alt="OpenDDPM icon">

# OpenDDPM 0.1.0

The first public release of OpenDDPM: a native Mac menu bar app for Dell U4025QW
input sources and PIP/PBP workspace presets.

## Download

- **OpenDDPM-0.1.0-universal.dmg** — open it and drag OpenDDPM to Applications.
- **OpenDDPM-0.1.0-universal.zip** — the same universal application bundle.
- **SHA256SUMS.txt** — checksums for both downloads.

Supports **macOS 13+**, **Apple Silicon**, and **Intel**.

## What is included

- One-click presets from the menu bar.
- A separate configuration window with a visual preset editor.
- Monitor discovery and DP / HDMI / Thunderbolt identification for each Mac.
- Full-screen, 50/50, 75/25, 25/75, and small/large PIP presets.
- “Keep this Mac visible” enabled by default.
- Preset import/export and automatic local persistence.
- Optional launch at login and live transition progress.
- A bundled, universal **betterdisplaycli** helper with its MIT license.
- OpenDDPM's new app icon and source code under the MIT license.

## First launch

1. Move OpenDDPM to Applications.
2. Install and start [BetterDisplay](https://betterdisplay.pro), version 2.2+.
   The CLI helper is included; the BetterDisplay app is a separate dependency.
3. Open OpenDDPM. Discover your U4025QW, select this Mac's physical video cable,
   and confirm it. Setup does not change monitor inputs.
4. Apply or create a preset. The split-monitor menu bar icon opens your presets.

This first release is **ad-hoc signed, not Apple notarized**. On a downloaded
copy, macOS may block first launch. Attempt to open it, then use **System Settings
→ Privacy & Security → Open Anyway** and confirm. Do not disable Gatekeeper.

## Validation and current limits

The universal app is built and tested by GitHub Actions, with 933 core assertions
covering source ordering, input visibility, persistence, discovery, and transient
register replies. Both architecture slices and the bundled helper were launched
on the development Mac (Intel via Rosetta). Real U4025QW transitions were checked
through the native UI while retaining DP, including 50/50, 75/25, and full-screen DP.

- U4025QW is the supported, validated monitor model for this version.
- Layout changes typically need 10–20 seconds for display rediscovery.
- Presets excluding this Mac's input are blocked until you disable the visibility
  setting. Once hidden, readback and switching back can require an independent
  USB control connection or the monitor joystick.
- BetterDisplay must be running with notification integration enabled. Its own
  license and feature availability apply; OpenDDPM includes no BetterDisplay license.

Source, build instructions, and issue reporting:
[prBigBrother/OpenDDPM](https://github.com/prBigBrother/OpenDDPM).
