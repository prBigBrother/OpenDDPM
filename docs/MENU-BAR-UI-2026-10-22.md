# Menu bar UI and brightness path correction

## User-observed behavior

The menu used discrete SwiftUI sliders with a dotted tick rail and automatically focused the first preset, displaying an accent-colored focus rectangle unrelated to the active preset. The selected preset's checkmark was on the right. The requested reference was the macOS Sound menu, including its smooth sliders, endpoint icons and Listening Mode rows.

The user clarified that brightness keys change brightness with HDR on, while OpenDDPM sliders fail. HDR alone therefore must not disable brightness. The temporary HDR veto was removed before shipping this change.

## Changes

- The quick menu uses unticked native NSSlider controls, endpoint brightness/speaker icons, compact headings and percentages.
- Native pointer tracking updates the draft smoothly and commits on release; keyboard actions use the same commit callback. Programmatic readback does not recursively send writes.
- Presets use full-width rows, a dedicated left checkmark column, layout icons and neutral hover backgrounds. Opening the popover clears its initial first responder so the first preset is not falsely highlighted.
- Settings and quick menu share a MonitorControls model extracted into MonitorPictureController.swift.
- The HDR state is shared between settings and background discovery. It is informational for brightness; automatic brightness still disables manual changes.
- NativeBrightnessBridge dynamically loads DisplayServicesCanChangeBrightness/GetBrightness/SetBrightness. Where supported, both reads and writes use this native macOS backend, including the brightness-key callback. Displays without support keep the existing DDC fallback.
- Before native access, the engine revalidates the selected display ID against the helper's serial-bound discovery. It never picks the first online display. Native writes require two matching native readbacks; a fixed DDC 0x10 value is no longer used to reject a native brightness change.
- Native brightness reads/writes/verification are logged separately in the existing transition journal.

## Evidence and validation

A read-only probe of the connected external display returned `display=3 nativeCanChange=true nativeReadResult=0 nativeBrightness=1.0`. No brightness, HDR or other display setting was changed during this investigation. The previous DDC failure after a requested brightness 56 is retained in the app journal and user screenshot; it does not prove that macOS-native brightness is unavailable.

DisplayServices ABI references: [nriley/brightness](https://github.com/nriley/brightness/blob/master/brightness.c), [Hammerspoon brightness module](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/brightness/libbrightness.m). These interfaces are private and dynamically guarded. The current native read was observed; visual output after a native write is left for the user's test.

Tests cover native brightness taking precedence over a fixed DDC value, avoiding DDC writes on that route, native readback, rejecting a display ID bound to another serial, retaining brightness-key/slider behavior with HDR on or unknown, queued input, automatic-brightness protection, throttled refresh, and existing controls. The complete suite passes. The universal app build validates both arm64 and x86_64.

## Follow-up: popover position and footer

The popover now measures the SwiftUI content with NSHostingController.sizeThatFits before showing it, assigns the hosting view/preferred/popover size, and disables automatic hosting sizing that could grow the initially unmeasured window around the wrong origin. It retains the native status-button anchor and downward preferred edge. A non-displaying layout probe measured 310 x 425 points for the complete menu including Quit; using an unattached view's fittingSize instead yielded zero and is deliberately avoided.

The footer rows omit both the preset checkmark gutter and their icons, placing the text at 15 points from the edge, aligned with the Presets heading. Quit OpenDDPM uses the existing delegate quit action and its busy-operation guard. No monitor settings or permissions were changed for this layout-only follow-up.

## Unified click behavior

Both leftMouseUp and rightMouseUp now enter the same statusClicked handler, opening/closing the same quick popover. The existing Show presets menu command and --show-menu entry point also route to this handler, rather than opening the separate legacy NSMenu.

## Keyboard/system brightness synchronization

Visible quick-menu and monitor-settings views now start a cancellation-bound native-brightness observer. It samples DisplayServices every 250 ms, publishing external changes into the same values dictionary observed by both sliders. It does not create an event tap, require another permission, issue DDC transactions, rediscover displays on every sample, show an OSD, or send brightness writes.

The native serial/display binding is established by normal verified discovery before sampling. Changes of display ID reset the controls generation. Samples are discarded after cancellation, during a write/suspension, after a newer brightness command, or after a monitor identity change. Transient read failures preserve the last confirmed value. The existing write path still revalidates serial/display identity before a native setter.

Regression tests simulate a system/keyboard change that bypasses OpenDDPM's setter and verify automatic value updates, zero brightness writes/DDC/discovery activity during sampling, suppression while suspended, preservation on transient failure, and termination on view-task cancellation.

## Native notifications and smoother slider updates

The main observation path now uses DisplayServicesRegisterForBrightnessChangeNotifications / DisplayServicesUnregisterForBrightnessChangeNotifications, loaded dynamically. A read-only registration/unregistration probe on Dell displayID 3 returned 0 for both operations. This confirms accepted registration, not delivery during an actual physical key press.

The callback is marshalled to the main queue, coalesced through an AsyncStream with newest-only buffering, and treated only as an invalidation signal. Brightness values are read through the existing serial-bound native engine. One system registration is shared among all visible subscribers for each display; the last cancelled subscription unregisters it. View observation restarts when the selected serial/display identity changes. A five-second recovery read covers missed notifications, while the old 250 ms compatibility polling runs only if registration is unavailable or rejected.

Native reads now preserve fractional percent in preciseBrightness. Rounded integer values remain available for percentage labels and existing DDC interfaces. Incoming menu slider changes use AppKit's animator with a 140 ms ease-out transition. Pointer tracking cancels that animation and continues directly under the cursor; Reduce Motion disables animated interpolation. Settings sliders also receive fractional values and animate incoming changes when they are not being dragged.

The test suite covers immediate fake-notification delivery, fractional precision, absence of 250 ms polling after successful subscription, recovery on transient read failure, cancellation and registration-failure fallback. The user-facing physical key/animation check is left to the user.

ABI reference: [Lunar bridging header](https://github.com/alin23/Lunar/blob/master/Lunar/DDC/Lunar-Bridging-Header.h). Framework symbol availability was independently checked in the local SDK, and actual registration was probed on the connected display. These are private Apple APIs, so the fallback is retained.

## Slider commit follow-up

The quick-menu AppKit coordinator now commits the rounded NSSlider value directly. Reading the SwiftUI Binding immediately after writing it could return its previous render value, sending 100 even after moving the thumb. The installed universal build was restarted and exercised via the quick menu accessibility slider: write 90, two DDC reads of 90, visible label 90%; restoration to 100 was then requested and verified. Evidence: `validation/menu-slider-commit-2026-10-22.json`. A pointer drag still needs separate confirmation because the computer-use service could not resolve the popover coordinates.

Keyboard interception remains unresolved: the running app reports that its actual CGEvent tap cannot start. The installed app is ad-hoc signed with a designated requirement made of binary cdhash values; no usable codesigning identity was listed. Previous Accessibility approval may no longer match the rebuilt binary, but this has not been proven against the stored TCC requirement. No privacy permissions or TCC records were changed. A stable signing identity is the next build-system investigation; do not claim keys are fixed by the slider change.

## Standard slider and persistent local signing

The previous quick-menu coordinator change passed AX value-setting but did not establish pointer-drag correctness, and the user reported continuing failure. Removed the custom NSSlider/NSViewRepresentable bridge. The quick menu now uses the same SwiftUI Slider editing callback as the working settings page, without a discrete step/tick rail, preserving endpoint icons and ignoring external value changes while editing. The universal build was installed and restarted. Clicking the menu slider through its accessibility element wrote 50 and received two readbacks of 50; restoration to the newly observed baseline 95 received two readbacks of 95. Evidence: `validation/native-menu-slider-2026-10-22.json`. Direct coordinate dragging remains unverified because computer use returns windowNotFoundAtPosition for this popover.

Created a persistent self-signed local development identity in ignored `local/signing`, scoped to signing this local app; no system trust anchors or TCC entries were changed. `scripts/build-local.sh` unlocks its dedicated encrypted keychain and invokes the normal build with that identity. Ordinary `scripts/build.sh` automatically selects it when present, unless SIGNING_IDENTITY is explicitly supplied. Other machines retain the original ad-hoc default. Preserve this local signing directory when updating the checkout; do not regenerate the certificate each build. It contains private credentials and must never be committed or printed.

Both the app and helper pass strict signature validation. The app's designated requirement now uses its bundle identifier plus the certificate fingerprint, instead of changing binary cdhashes. Two different compiled probes share the same requirement and the second satisfies the first's requirement (`validation/stable-local-signature-2026-10-22.json`). This is local signing, not Developer ID notarization. Reference: Apple TN2206, https://developer.apple.com/library/archive/technotes/tn2206/_index.html .

The installed app still reports its real brightness event tap as inactive. Prior TCC approval may not match the previous ad-hoc builds; the stored TCC requirement could not be read, so causality is not claimed as proven. Re-authorizing the now persistently signed installed app is the next necessary user step. Physical brightness keys have not yet passed a live test with this identity.

## Permission recheck after user confirmation

After the user confirmed toggling the permission, System Settings (macOS 27.0.1, Device Control and Data Access) visibly showed OpenDDPM.app enabled. Its Show in Finder action selected `/Applications/OpenDDPM.app`, so a wrong app path was ruled out. OpenDDPM was restarted and still reported its real event tap inactive. Matching tccd messages for the restarted app PID 39980 show kTCCServicePostEvent and kTCCServiceAccessibility returning authValue=0, authReason=5. This establishes an OS-level denial despite the enabled UI switch, rather than merely a stale AX query. It does not establish the stored authorization requirement or a precise reason for the mismatch; reading the TCC database is unavailable. Evidence: `validation/tcc-openddpm-permission-result-2026-10-22.json`. No permission entries were altered by the agent. Next user action: remove the existing OpenDDPM permission entry and add the installed app again, rather than repeat off/on toggling.

## Permission entry recreated successfully

After the user removed and re-added the installed OpenDDPM permission entry, the agent restarted the existing persistently signed app without rebuilding it. The Monitor controls page now reports “Brightness key listener is active.” The prior failure message is absent. This confirms creation and activation of the actual CGEvent tap. The physical brightness key and system OSD test is pending user confirmation.

## Brightness keyboard event encodings

The event tap originally watched only system-defined events (type 14, subtype 8, media keys 2/3). Added keyDown/keyUp observation for Apple brightness virtual keys 144/145, without intercepting ordinary F1/F2 or other typing. Both encodings use the same modifier policy, step calculation, queued monitor write, verified readback, and OSD callback. Recognized brightness key-down decisions are logged asynchronously as `brightness-key`, identifying the format and accepted/unavailable/shortcut result; ordinary typing is neither recorded nor consumed.

Tests construct events without posting them to the system and cover both formats, fine Option-Shift steps, releasing consumed keys, preserving ordinary F1 and Command combinations, and unavailable-control pass-through. The complete test suite passes. The new universal build satisfies the installed app's existing certificate-bound designated requirement, was installed with rollback and automatically restarted, and the live controls page still reports “Brightness key listener is active.” This verifies the first real update preserving permission with the persistent signing identity. Physical keyboard/OSD confirmation remains pending. Format reference: https://github.com/MonitorControl/MediaKeyTap/blob/master/MediaKeyTap/MediaKeyTap.swift .

## HID-level keyboard diagnosis

The user reported no effect from the first expanded keyboard build, and no recognized brightness key events appeared. Added a HID-ingress tap with session fallback, exposing its actual location in the active status. Added diagnostics for regular F1/F2 and keyboard-backlight media keys (still passed through), plus a one-time aggregate stream-health message. No ordinary typing values are logged. Targeted brightness tests passed; the universal app was signed with the unchanged identity, installed and restarted. The live UI confirms “Brightness key listener is active (HID).”

The user identified the keyboard as NuPhy, directly connected to the DP Mac. hidutil lists V-NuPhy Halo75 V2 Dongle as a USB keyboard service; its absence from legacy IOHIDDevice inventory must not be treated as proof of a remote/Universal Control connection. The user's direct-connection statement supersedes that tentative inference.

After HID interception, diagnostics received repeated regular F1/F2 events. The user reports using Fn+F1. These arrive as ordinary F1, which the current policy deliberately passes through. Global com.apple.keyboard.fnState reads 0. A plain-F1 physical test is pending; do not yet claim the brightness keys or OSD work.

## NuPhy F1/F2 compatibility mode

The user reports that plain F1 also has no brightness effect. Live diagnostics after that test still show regular F1/F2 events, not media brightness commands. Added an explicit persisted “Use F1/F2 as brightness keys” setting, default off. When enabled, virtual keys 122/120 map to brightness down/up; native 144/145 and media 2/3 remain supported. It applies to all keyboards on this Mac, as the event tap has no trustworthy per-device identifier. The UI states this scope. Command, Control and Option shortcuts retain pass-through, with Option-Shift fine brightness preserved. Turning the setting off restores ordinary function keys.

Targeted tests cover the opt-in mapping, key-up consumption, shortcut preservation, persisted state, and restoring pass-through. The universal build was signed with the unchanged identity, installed with rollback, and restarted. Through the live controls UI the agent enabled the setting for the user's requested NuPhy brightness workflow. The actual listener remains active (HID), with no permission re-grant. Programmatic CUA F1 did not produce a tap event, so it is not used as proof of physical-key behavior. Physical NuPhy key and OSD confirmation remains pending.

### Follow-up: responsive brightness and independent F1/F2 registration

The user reported that the most recent physical NuPhy F1 press still produced
no brightness change. An enabled CGEvent tap is only evidence that macOS
created the tap, not evidence that this keyboard's event reached it. No accepted
brightness key event appeared in the journal for that report. A read-only Carbon
`IsSecureEventInputEnabled()` check returned `false` on this Mac.

F1/F2 compatibility now registers ordinary F1/F2 directly with WindowServer using
`RegisterEventHotKey`, separately from the HID/session media-key taps. Plain,
Shift, and Option-Shift variants are registered as one atomic group; a conflict
rolls back the group and reports its OSStatus. When registration succeeds the tap
passes ordinary F1/F2 through, preventing duplicate adjustments. Command,
Control and Option-only shortcuts remain unregistered. Turning the feature off
unregisters these keys. Journal entries distinguish registration from actual
hotkey delivery. Physical NuPhy delivery remains a separate acceptance check.

The preceding responsive brightness change writes the latest requested level
without waiting for the previous level's readback, and verifies the settled
value with two matching reads. The preview is separate from confirmed state;
failed verification restores the confirmed value. Live application slider
checks wrote 83 -> 77 -> 83 with matching readbacks. The quiet background status
refresh skips active brightness operations. Unit coverage includes coalesced
writes, superseding a pending verification, transient read failure, ignored
writes, native brightness routing, and auto-brightness gating.

Modern OpenDDPM HUD is an app-owned nonactivating panel. It is explicitly named
in settings; it is not the private modern system HUD. ControlCenter runtime
rejected the compatibility brightness request (`Ignore OSD request for:
continuousBrightness`); the private native SystemBanner interface checks an
Apple entitlement. See ignored validation evidence
`control-center-osd-rea-2026-10-22.json` and
`modern-osd-live-log-2026-10-22.txt`. No entitlement bypass was attempted.
The offscreen `cacheDisplay` image did not capture the complete glass/text
composition, so it is not sufficient evidence of the on-screen HUD appearance.
