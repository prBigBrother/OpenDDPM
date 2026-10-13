OpenDDPM 0.2.0 controls the Dell U4025QW directly and adds global preset hotkeys.

- Removes the BetterDisplay application and CLI dependency. Monitor discovery,
  layout reads, and source/layout writes use the bundled native DDC/CI driver.
- Removes the Connect BetterDisplay setup step. Setup now discovers the monitor
  and confirms this Mac's physical input.
- Adds a Hotkeys page with shortcut recording, clearing, duplicate validation,
  and macOS registration-conflict reporting. Bindings persist and travel with
  preset exports. Global shortcuts respect Keep this Mac visible.
- Preserves existing 0.1.0 presets and settings.

Validation: 940 core assertions plus native DDC packet-validation tests; universal
Apple Silicon/Intel build. Direct Dell U4025QW control is hardware-tested on
Apple Silicon. Intel DDC transport is compiled, but physical Intel validation
is still pending.

Download the universal DMG or ZIP. No external monitor app is required.
macOS 13+ required. This release is ad-hoc signed and is not Apple notarized;
if blocked, attempt launch then use System Settings → Privacy & Security →
Open Anyway. SHA256SUMS.txt contains the release asset checksums.
