# OpenDDPM 0.5.0

OpenDDPM 0.5.0 adds monitor picture controls, responsive keyboard brightness
and queued edits, and consolidates preset access in the menu bar and Settings.

## Monitor controls

- Adjust brightness, contrast, speaker volume, automatic brightness and color
  presets where supported by the monitor and connection.
- Use the macOS brightness backend when available, with serial-bound DDC
  fallback and verified readback.
- Keep editing while commands are running. Different controls execute in
  order; repeated pending edits to one setting keep the latest value.
- Show requested values immediately while keeping confirmed monitor state
  separate. Transient failures preserve confirmed values and allow retries.
- Queue HDR changes with picture settings. Preset transitions wait for active
  picture/HDR work, and edits made during a transition resume afterward.
- Configure resolution, refresh rate and HiDPI with a keep/revert confirmation.
- Correct full-width slider alignment and hotkey-row button alignment.

## Keyboard brightness and interface

- Handle NuPhy's F14/F15 brightness commands without holding Fn, alongside
  media brightness events and optional F1/F2 compatibility.
- Coalesce held-key updates and verify the settled brightness value.
- Display a modern indicator using native AppKit Liquid Glass on macOS 26+,
  with the monitor name, continuous scale and aligned brightness icons.
- Retain an optional classic macOS system indicator.
- Remove the separate Preset Remote window, its launcher shortcut and its
  opening commands. All presets in the quick menu opens the Presets page.
  Reopening the application opens Settings.
- Preserve existing presets, their hotkeys, monitor/input settings and
  HomeKit configuration. The obsolete remote shortcut is ignored on load.

## Bluetooth wake and builds

- Include optional ESP32 Bluetooth wake integration with per-input Mac
  assignments, device readiness and reconnection diagnostics.
- Include firmware source and retry-policy tests. Private firmware images
  containing local Wi-Fi credentials are excluded.
- Reuse a persistent local signing identity for development updates when
  configured, helping preserve macOS privacy permissions.
- Build universal Apple Silicon/Intel applications and package ZIP/DMG assets.
- Update GitHub Actions to macOS 26 for the current AppKit SDK.

## Compatibility

Requires macOS 13 or later. Liquid Glass uses macOS 26+ APIs with a material
fallback on earlier systems. Dell U4025QW is the hardware-validated model;
available controls depend on the cable, display mode and monitor settings.
Intel support is compiled but has not been verified on physical Intel hardware.

Keyboard brightness interception requires Accessibility permission; preset
hotkeys and DDC controls do not. The new macOS Control Center indicator is not
exposed through the verified native route, so the modern indicator is owned
by OpenDDPM and uses the native glass material.

Release builds are not Apple Developer ID signed or notarized. If macOS blocks
the downloaded app, use Privacy & Security → Open Anyway after the first
launch attempt. Keep the system's security protections enabled.

## Validation

- Core, coordinator, picture-control, keyboard-brightness, wake and native-DDC
  checks pass with `./scripts/test.sh`.
- HomeKit bridge tests pass with `npm test --prefix homekit`.
- The firmware retry-policy test passes without accessing hardware.
- The installed interface was checked for full-width sliders, aligned hotkey
  rows, recording cancellation and consolidated preset navigation.
