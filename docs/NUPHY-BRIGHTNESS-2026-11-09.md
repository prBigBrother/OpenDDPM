# NuPhy brightness keys and capsule indicator

## Confirmed input encoding

On this Mac, the Bluetooth keyboard identifies as `Node 75 HP-1` (NuPhy).
The user tested plain F1/F2 separately from Fn+F1/F2.

| Physical press | HID keyboard usage | macOS virtual key |
| --- | --- | --- |
| F1 without Fn | 105 (`0x69`, F14) | 107 |
| F2 without Fn | 106 (`0x6a`, F15) | 113 |
| Fn+F1 | 58 (`0x3a`, F1) | 122 |
| Fn+F2 | 59 (`0x3b`, F2) | 120 |

Read-only IOHIDManager and CGEvent probes observed the plain-key down/up
pairs, with CGEvent flags `0x800100`. The original handler recognized media
brightness, virtual brightness keys 144/145, and opt-in F1/F2, but ignored
the legacy F14/F15 pair. This explains why only Fn worked.

F14/F15 now use the existing brightness pipeline, including modifier handling,
key-up suppression, repeated presses, queued writes and confirmed readback.
They belong to the main brightness-key setting and do not depend on the
optional F1/F2 compatibility setting or its Carbon registrations. The Carbon
F1/F2 route is preserved.

The app was initially not running. Starting it restored access to the monitor,
but did not resolve the plain-key encoding mismatch. DisplayServices reports
native brightness unavailable on the current DisplayPort connection; the app
uses DDC. Fn-key testing confirmed DDC writes and matching brightness readback.

## Indicator

The Modern OpenDDPM indicator follows the user's updated macOS reference:
a 292 × 64 point rounded panel with a native AppKit `NSGlassEffectView`,
dark appearance, the selected screen's name above a continuous brightness
bar, small/large sun icons at its ends, and a subtle dotted rail below it.
Percentages are omitted. The panel remains
nonactivating, ignores pointer input, follows the selected display and fades
after a quiet interval. A presentation token prevents an old fade completion
from hiding a newer presentation.

This is an app-owned indicator using the native material. On older macOS,
`NSVisualEffectView` supplies the fallback. The optional classic system
indicator remains available in settings. Standalone on-screen previews and
the actual classic system indicator were inspected through computer use;
these previews do not write monitor settings. The modern native banner route
was investigated separately in `NATIVE-BRIGHTNESS-OSD-2026-11-09.md`.

## Validation

- The full test suite passed with the final legacy-key addition.
- Updated brightness tests pass for observed F14/F15 codes and flags, both
  directions, key-up, fine adjustment, shortcut passthrough, unavailable
  controls, optional F1/F2 disabled, and active Carbon F1/F2 registrations.
- The updated universal application is built and installed using the existing
  persistent signing identity; a rollback copy is retained locally.
- The user confirmed after installation: F1/F2 without Fn now work.
- The installed app journal records accepted keyboard events, DDC writes in
  both directions during held keys, including two matching readbacks of 100
  after a held-key burst. Further user adjustments were also recorded.
  A compact local record is saved in
  `validation/nuphy-brightness-live-2026-11-09.json`.
