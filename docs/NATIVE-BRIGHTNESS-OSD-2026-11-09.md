# Native brightness indicator investigation

Current host: macOS 27.2, build 26B123.

## Observed native classic route

An isolated Objective-C client sent `showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:`
to `com.apple.OSDUIHelper`, using image 1, the connected display ID 2 and
40/100 chiclets. Computer use observed the real `OSDUIHelper` window with
the Brightness accessibility image: it is the classic square indicator,
not the modern Control Center panel. The test sends no monitor writes.
OpenDDPM already exposes this route as the Classic system indicator.

## Modern native route

The current ControlCenter executable differs from the artifact examined on
October 22. It was inspected afresh with REA/Hopper. Its SHA-256 is
`78e729cc88503073c448a3ba8e832416aecd791e99971c514e4ce5b4043a868d`.

`SystemBannerServiceDelegate.listener:shouldAcceptNewConnection:` at
`0x10041cbdc` calls `sub_10041ca74`, which checks the connecting process's
`com.apple.private.system-banner-client` entitlement and accepts/resumes
the connection only when its boolean value is true.

Evidence:

- Listener: `ev_816a36065198d4bd0e2649a86599806062eceefb5838cb61f0f68ac6dc2f0e68`.
- Entitlement check: `ev_129773b3f3034542c29a7e80b9591825b5e96ffe91fa006a07a78806580bb148`.
- Bundle: `validation/native-system-banner-rea-2026-11-09.json`.

A direct `com.apple.SystemBanner` probe was invalidated. A separate
OSDManager compatibility request did not establish a working modern indicator.
These probes did not change brightness. The direct probe uses the legacy OSD
protocol, so its invalidation alone is not proof of the failure's cause; the
entitlement check above is static evidence from the native banner listener.

No working modern-native invocation for the current DDC-controlled monitor
was established. This is a bounded finding for the inspected paths, not a
claim that every possible private interface has been excluded. No system
binary, entitlement, or system security setting was modified.

The current native-OSD limitation is also discussed by the MonitorControl
maintainer: https://github.com/MonitorControl/MonitorControl/discussions/1873 .
The September 15, 2026 update describes restoring the traditional indicator
for macOS 26 and 27; it does not establish availability of the modern banner.
