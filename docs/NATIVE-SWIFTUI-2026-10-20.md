# Native SwiftUI UI — 20 October 2026

The settings window now uses standard macOS SwiftUI navigation and forms.
This follows the UI review and replaces its custom presentation while keeping
the coordinator and monitor-control behavior intact.

## Components

| Area | Native implementation |
| --- | --- |
| Sidebar | `NavigationSplitView` and `List(selection:)`; keyboard selection, resizing and the system sidebar toggle |
| Settings | Grouped `Form`, `Section`, `LabeledContent`, `Picker` and `Toggle` |
| Presets in settings | Native `List` rows with compact monitor previews, menu and Apply controls; `onMove` persists order through the existing store |
| Editor | Grouped form with labeled Name/Layout/Inputs, a layout preview, and standard Cancel/Save buttons with Escape/Return equivalents |
| Apple Home | Grouped sections and native `DisclosureGroup` for Advanced; existing connection and pairing logic |
| Toolbar | System sidebar, preset remote, refresh and preset-management controls |
| Appearance | System accent color, standard buttons and links; existing System/Light/Dark preference retained |
| Remote | Native compact preset list, miniatures, verified checkmarks and a unified system toolbar; see the follow-up below |

Custom drawing remains only where it communicates the product's state: the
monitor layout preview. The global-shortcut recorder remains an AppKit `NSButton` wrapper for key
capture; its forced pointing-hand cursor was removed.

Removed the custom navigation and input cards, hand-drawn section containers,
manual cursor stack, hover tracking, and custom preset drag geometry/animations.
`Views.swift` shrank from 885 to approximately 492 lines relative to the initial
review working copy.

The settings `NSWindow` uses `.fullSizeContentView` with the unified toolbar.
This is necessary for the hosting view's native navigation safe area: without
it, the upper portion of a form was covered by the toolbar's material. Minimum
settings size is 800 × 560 points; grouped forms scroll independently.

## Preserved behavior

- The shared coordinator still owns all monitor operations. Apply remains
  available for eligible presets while another target is applying.
- Selected/applying, verified and hidden-Mac states remain distinct. Verified
  indicators still require readback; the UI never invents hardware success.
- Keep this Mac visible still blocks excluding presets. An allowed excluding
  preset still displays its warning.
- Setup still records and confirms the physical cable without switching it.
- Import/export, preset editing, saved ordering, global shortcuts, Shortcuts
  links, Home connection and pairing continue through their existing models.

## Verification

- Existing tests passed: 10 HomeKit-health assertions, 4,204 core assertions,
  32 coordinator/readiness/recovery/deadline assertions and native packet tests.
- Native settings, presets, hotkeys, Apple Home, general settings, editor and
  remote were inspected through native accessibility state and screenshots.
- Confirmed toolbar safe-area repair visually, including the first form heading
  and first preset row.
- In an unsaved editor draft, Swap inputs updated both pickers and preview;
  empty Name disabled Save; Full screen removed the secondary selector and used
  Main input. Cancel discarded the draft.
- Inspected light and system-dark appearance; restored System afterward.
- No Apply/Previous, monitor-input, Home service toggle or pairing action was
  invoked during these UI checks. Real hardware transitions, a full VoiceOver
  traversal and physical Intel execution were not tested in this pass.

## Final verification — 21 October 2026

After the interrupted session, rebuilt the current working copy as
`build/native-ui-verified/OpenDDPM.app`. This includes the native UI and the
additional monitor power-control changes already present in the working copy;
those changes were preserved. No power or input commands were invoked.

The complete build succeeded, including icon generation and ad-hoc signing.
The application and helper contain arm64 and x86_64 slices. Signature checks,
the existing Swift/native test suite, and `git diff --check` passed.

The running application's accessibility tree also confirms the native sidebar,
grouped Apple Home sections, toolbar and disclosure control. Its reported
locked state was subsequently found to be stale application state, not an
actual macOS lock; see the correction below. The screenshots and editor/theme
checks above were completed before the interruption.

The verified standalone build is kept separate from the installed and currently
running applications for review. `build/native-ui-final/OpenDDPM.app` is the
earlier build from the interrupted session.

## Stale lock recovery — 21 October 2026

Live CGSession inspection confirmed an unlocked console session while the old
application still reported `phase: unavailable` and "Mac is locked". A refresh
was silently ignored by the coordinator's existing availability gate. A missed
unlock event, or an unlock callback before CGSession updates, could leave this
gate latched indefinitely. The exact notification sequence was not captured.

AppStore now reconciles a suspended session against live CGSession state on
Refresh, app activation and a two-second fallback timer. Recovery requires an
unlocked local console session and no pending system-sleep state. It clears the
availability gate and schedules a read, without replaying interrupted commands.

The standard tests passed. An isolated runtime harness simulated a stale lock
without broadcasting system notifications and verified all three recovery paths.
The corrected universal app at `build/session-recovery/OpenDDPM.app` was started
and readback returned `phase: verified`, `50 / 50 · TB + DP`, with no lock error.
The native window showed the same fresh monitor state. No power or input-write
command was requested during this verification.

## Native remote and initial focus — 21 October 2026

Replaced the remote's large bordered preset tiles with a native inset `List`.
Each row is a one-click preset action with a compact layout miniature, ordinary
system text, a hidden-Mac warning when relevant, and a checkmark for the verified
preset. A row's keyboard focus does not apply a preset. Shortcuts links remain
in its context menu.

Moved Previous, Verify, Sleep/Wake and Settings & diagnostics into the system
toolbar. The settings menu opens configuration or reveals the transition
journal. Removed the slogan, oversized tile backgrounds and bottom action bar.
The panel uses a compact unified toolbar and a full-size content view, retaining
its floating-window behavior. Minimum size is 400 × 360 points.

On opening the remote, AppKit's first responder is set to the window instead of
automatically focusing the first action. Controls remain in the native keyboard
loop; focus indicators are not globally disabled. Live accessibility inspection
confirmed initial focus on the dialog and that Tab moves focus into the preset
list. Screenshots confirmed no focus ring on the settings menu, a fully visible
first row and the expected verified checkmark. The settings menu and its link
to the configuration window were also exercised.

`build/native-remote/OpenDDPM.app` built for arm64 and x86_64, passed signature
verification, and was left running for review. No monitor power or input action
was invoked during the remote UI checks. Unit tests were not repeated for this
presentation-only follow-up; the prior session-recovery tests remain recorded
above. `git diff --check` passed.
