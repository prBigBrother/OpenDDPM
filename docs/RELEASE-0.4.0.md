# OpenDDPM 0.4.0

OpenDDPM 0.4.0 brings the preset remote and configuration windows closer to
native macOS, improves recovery after waking or unlocking the Mac, and adds a
recoverable monitor standby control.

## Changes

- Rebuilt Settings with native SwiftUI navigation, grouped forms, native preset
  reordering, and standard macOS controls.
- Rebuilt the preset remote as a compact native list and toolbar. Opening it no
  longer leaves the Settings button focused.
- Corrected session availability recovery when macOS reports a stale locked
  state. Recovery checks the active console session and never replays an old
  preset request.
- Added monitor standby and wake through the Dell U4025QW's DDC power register.
  Standby uses VCP `0xD6 = 4`; the driver rejects writes to the non-wakeable full
  power-off value `5`. User input can wake the monitor, and selecting a preset
  while it is asleep wakes it first.
- Added HomeKit TV power state and standby controls, including automatic wake
  before selecting a preset.
- Updated HomeKit status handling and expanded regression coverage for power
  state and API dispatch.
- Added documented HDMI DDC and USB HID research probes and their observed
  hardware boundaries.

## Validation

- Core, coordinator, HomeKit health, HomeKit bridge, and native DDC packet tests
  pass with `./scripts/test.sh` and `npm test --prefix homekit`.
- Universal arm64 and x86_64 app builds and ZIP/DMG packaging pass.
- On the Dell U4025QW, DDC standby (`0xD6 = 4`) turned off the panel while
  retaining DDC communication; writing `0xD6 = 1` woke it again. Full power-off
  (`0xD6 = 5`) disconnects DDC and is blocked by the production driver.
- The installed app was checked with the native remote open and the Settings
  control unfocused.

## Notes

The native Intel transport is compiled and packaged, but remains unverified on
physical Intel hardware. Standby and wake were validated on Apple Silicon with
the U4025QW over HDMI DDC. Other monitor models and transport paths may differ.
