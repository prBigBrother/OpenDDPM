# OpenDDPM 0.5.1

This maintenance release packages the merged fixes for preset control after
sleep and the Previous action after restarting OpenDDPM.

## Fixes

- **Control after waking:** check the live macOS console session before preset,
  status and power requests. A missed unlock notification no longer leaves
  control blocked until the app is restarted. Commands remain blocked while
  the Mac is asleep, locked or in an inactive session. ([#1](https://github.com/prBigBrother/OpenDDPM/issues/1))
- **Previous after launch:** prefer the previous confirmed preset when available;
  otherwise select another allowed preset in configuration order. With two
  presets, Previous switches between them without needing a manual switch
  first. Deleted presets and presets blocked by Keep this Mac visible are
  skipped. ([#2](https://github.com/prBigBrother/OpenDDPM/issues/2))
- Record session availability changes and rejected preset requests in the local
  transition journal, even when no transition is running.

A big thank you to [@farmerpaul](https://github.com/farmerpaul) for the detailed
reports, clear reproductions and suggested fixes for both issues!

## Downloads and compatibility

- **DMG:** open it and drag OpenDDPM to Applications.
- **ZIP:** unpack it and move OpenDDPM.app to Applications.
- Universal build for Apple Silicon and Intel; macOS 13 or later.
- Existing presets, hotkeys, monitor settings and HomeKit configuration are
  preserved when upgrading.

Release builds are ad-hoc signed and are not Apple Developer ID signed or
notarized. If macOS blocks first launch, use Privacy & Security → Open Anyway
after attempting to open the app. Keep the system's security protections enabled.
