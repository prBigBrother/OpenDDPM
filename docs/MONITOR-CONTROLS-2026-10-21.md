# Monitor controls implementation checkpoint

## Implemented

- A separate Monitor controls settings page: hardware brightness, automatic brightness, Low/Medium/High automatic range, contrast, HDR, color presets, independent resolution and refresh-rate selectors, HiDPI toggle, and speaker volume.
- Left menu-bar click opens brightness/volume sliders, the first four presets in configuration order, remote access and Settings. Right click preserves the existing presets menu.
- Optional brightness media-key event tap, including repeat and Option–Shift fine adjustment. Accessibility permission is requested only when explicitly enabling this feature. Events pass through while manual control is unavailable. Repeated adjustments are coalesced while DDC is in flight.
- Native brightness OSD request through Apple's private OSDUIHelper service, after confirmed brightness readback. No custom replacement HUD.
- Display IDs are obtained from the native helper alongside the same alphanumeric serial used for DDC. Resolution, refresh rate and scale use only actual modes enumerated for that display. An unconfirmed mode change reverts after 15 seconds or on closing the section.
- HDR uses the DDPM EA=FE01/FE00 preparation path and a signature-checked private MPDisplay bridge. It verifies macOS hasHDRModes/preferHDRModes, and attempts compensation on failure. This confirms the OS preference, not measured panel HDR output. Other Dell HDR protocols, including F4-based HDRMode3, are not implemented.
- Picture writes share the existing MonitorEngine actor, restrict commands/values, and require two matching reads after a settling delay. The packed 0x66 fields use a fresh masked read-modify-write. Color capability IDs are translated to their actual register/value commands.

## Evidence and validation

DDPM static evidence and its limits are in [MONITOR-DDPM-EVIDENCE.md](MONITOR-DDPM-EVIDENCE.md). Current-profile GET E2 analysis is retained in `validation/ddpm-monitor-color-get-2026-10-21.json`.

Read-only native hardware discovery found Dell U4025QW serial BX74LJ4, CG display ID 3. DDC reads returned brightness=100, contrast=75, volume=37, automatic register=417 (0x01A1: manual, High range). No monitor settings were written by this investigation.

GET E2, 14, F0, EA and F4 did not return a valid native response in this connection. DC returned 0, but DC alone does not identify every color profile, so it is not used to invent a current selection. Color choice remains available with an unknown current state. Each selection attempts direct readback of its command register; failures explicitly invalidate the displayed value and report that the setting was not confirmed. A failed verification can follow a successful write, so the monitor may already have changed.

A read-only runtime probe exercised the exact MPDisplay bridge and CoreGraphics enumeration: the HDR interface was available, HDR initially read off, 157 modes were found, current logical mode 3840 x 1620 at 120 Hz with HiDPI on, with a same-resolution scale alternative. This probe performed no setters. The running app's settings page was also inspected visually; it is a different binary from the latest local build.

The complete existing test suite passes, plus new transport tests for packed-field preservation, invalid-write rejection, color-ID translation, actual readback mismatch and serial-bound display ID propagation. Universal arm64/x86_64 application/helper build and ad-hoc signature validation passed. The toolchain reports its pre-existing Intel compatibility-pack and deprecated framebuffer API warnings.

## Remaining live checks

- Actual brightness/contrast/volume and automatic-brightness changes, with before/after/restoration readback.
- Acceptance and readback of each non-Standard color preset over the current connection.
- HDR negotiation and rollback on the actual monitor; HDR type/capability string has not been acquired.
- Physical brightness-key handling after Accessibility permission, and visual confirmation of Apple's OSD on macOS 27. The XPC request cannot acknowledge that an overlay was rendered. The interface is private and may change.
- Real display mode changes, Keep/Revert, timeout and disconnect behavior.

The implementation leaves existing preset IDs, layouts, pairings, shortcuts and unrelated Bluetooth wake work intact. No release, commit, or installation was performed by this task.

## Continuation on 2026-10-22

The user granted Accessibility permission and confirmed that a physical brightness key changed brightness and displayed the native system indicator. Subsequent direct readback was 100; the earlier running build also reported a rejected brightness write while HDR was on. Therefore the user-confirmed OSD result does not establish that arbitrary panel brightness values work in HDR.

The final local universal build was installed with signature verification and byte-for-byte executable hash equality. The previous installed app is preserved under `local/rollback-monitor-controls-20261022T092834/OpenDDPM.app`. Existing configuration and preset data were not replaced. Accessibility did not carry over to the new ad-hoc-signed binary; the updated app explicitly reports this instead of silently intercepting keys.

A real HDR-off UI test sent EA=FE00 successfully. A fresh read-only MPDisplay/CoreGraphics probe confirmed HDR off, with the original logical resolution/refresh/scale unchanged. The Mac then became locked; UI testing paused awaiting manual unlock. **Original HDR was on: restoration to on is pending unlock.** No additional monitor settings should be changed until the original HDR state has been restored or the user chooses otherwise.

A focused test against the actual MonitorControls model also passed: brightness events queued during refresh are drained, repeated keys accumulate, and queued manual changes are discarded when auto brightness becomes enabled.

### Unlocked continuation and restoration

After manual unlock, HDR off was confirmed and the native E2 current-color read returned Standard. The settings brightness slider was changed from 100 to 99; direct native DDC GET 0x10 returned 99, and the UI confirmed 99. The slider was then restored to 100. No contrast, volume, automatic-brightness, color-profile, resolution, refresh or HiDPI change was performed in this continuation.

The first HDR-on attempt did not see advertised HDR modes within the original three-second window, and monitor discovery briefly failed during compensation. After rediscovery, HDR modes were advertised. A second invocation of the actual MonitorHDR controller restored HDR on with no error. An independent fresh read-only probe confirmed HDR=true, logical 3840 x 1620, 120 Hz, HiDPI=true, displayID=3 and 157 available modes. **The original HDR-on state is restored; there is no pending hardware restoration.**

The HDR capability wait was increased from 3 to 15 seconds. The page now explains that HDR can lock hardware brightness/contrast/color settings. Automatic picture refresh is throttled to once per 30 seconds, preventing repeated status polls from keeping every slider continuously disabled. Explicit refresh/opening the page or menu still requests immediate reads. A targeted model test verifies the throttle as well as queue draining, repeat accumulation, and auto-brightness protection.

Official DDPM CLI help was readable, but bounded Capabilitiesstring and HDR GET requests timed out after 12 seconds each; no identical retry was performed. Those failures are recorded in `validation/ddpm-capabilities-readonly-2026-10-22.json`. They do not override the successful independent native HDR readback.

### Final installed build

Installed the final 2026-10-22 universal build after the live-test fixes. Verified deep/strict code signature and byte equality for both the app executable and native helper. Installed executable SHA-256: `7b40a287c5629eca270b60681ae41f754ea36dd90164a6c84db935dd970a525a`; helper SHA-256: `bfcd6ab16179ca69c569322c521347cf97b455330f91721eb5036a767f1c6df2`. Immediate preceding version is preserved at `local/rollback-monitor-controls-final-20261022T095206/OpenDDPM.app`.

Launched the installed app and verified the Monitor controls page exposes the separate controls, shows HDR on and the HDR restrictions explanation, and retains the existing monitor/input/presets/ESP32 configuration. The final binary reports Accessibility permission missing; it must be granted for this new ad-hoc signature before physical-key testing of this exact binary. No commit or release was created.

## Accessibility status handling fix (2026-10-22)

The user correctly reported that OpenDDPM was already enabled in macOS privacy settings. UI inspection confirmed that system toggle was on while the running app continued to report an AX trust failure. Refreshing the existing system entry did not clear the running process's result. This does not prove that the user failed to grant access or that a new grant is always necessary.

The controller previously used AXIsProcessTrusted as an unconditional gate before trying CGEvent.tapCreate, and only refreshed during startup or a manual preference toggle. It now attempts the actual event tap first, verifies that the tap is valid/enabled, and uses this result as the active-listener status. AX trust is only diagnostic if creation fails; permission prompts occur only after an actual failure during explicit user opt-in. Background checks retry without prompts every two seconds and when the application becomes active. Disabling the preference stops retries. An explicit status line separates the requested preference from an active listener.

`tests/BrightnessKeysTests.swift` injects a listener to verify that a stale negative AX query cannot block a working tap, permission changes recover automatically, trusted-but-unavailable listeners produce distinct diagnostics, background checks never request permission, and disabling stops attempts. The complete suite passes. Physical key/system-permission verification is intentionally left to the user, as requested; no additional UI or monitor-setting tests are performed for this fix.
