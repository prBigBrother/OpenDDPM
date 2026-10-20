# OpenDDPM 0.3.0

Selecting a new workspace while the monitor was switching previously discarded
the new selection. Every register write also added a fixed four-second pause.
OpenDDPM now sends all controls through one preset coordinator, preserves the
latest selection, and checks monitor readiness instead of sleeping for a fixed
interval.

## Changes

- A compact preset remote opens from the menu bar or Control–Option–Space.
  Configure the launcher shortcut on the Hotkeys page. Right-click the menu bar
  icon for the preset menu and configuration.
- New selections supersede pending selections at hardware transaction boundaries.
  The next transition reads actual state before planning its writes.
- Adaptive register readback and a shared 25-second transition deadline replace
  unconditional waits and nested long retries. An ambiguously accepted write is
  read back before a repeat is attempted.
- The remote distinguishes the desired target, confirmed state, failure, and a
  sent but unverified command. Previous preset and retry verification are explicit
  actions. The last confirmed state never serves as proof of a newer request.
- Real Mac sleep and session lock interrupt monitor commands with a clear reason.
  Display sleep notifications during topology changes do not interrupt switching.
  Wake/unlock refreshes state without automatically replaying an old preset.
- A rotating private JSONL journal records request IDs, plans, I/O and timing at
  `~/Library/Logs/OpenDDPM/transitions.jsonl`.
- An authenticated API bound to IPv4 loopback supports CLI, Apple Shortcuts URLs
  and an optional HomeKit service. Request-specific receipts distinguish verified,
  unverified, superseded and failed outcomes.
- The HomeKit television exposes complete presets as inputs. A separate Scenes
  bridge exposes momentary preset switches for scenes and automations. Configuration
  includes local QR codes, install/start and stop controls.
- Original configuration, preset IDs, duplicate layouts and existing keyboard
  bindings are preserved. The launcher binding is optional in the stored schema,
  so older configurations remain readable.

## Interface and Apple Home improvements

- Drag presets to reorder them, with an opaque floating card and animated placement.
  The saved order is shared by the remote, menu and Apple Home inputs.
- System, light and dark appearance options apply to settings and the remote.
  Settings appear in the Dock and app switcher while open.
- Refined preset cards, menus, hover feedback, status banners and focus behavior.
- Apple Home settings show a connection switch and pairing state. Advanced contains
  restart controls, diagnostics, the Monitor QR code and pairing code, including
  when Monitor is already paired. Existing pairings and Monitor-only settings remain intact.
- Health reports accept timestamps with or without fractional seconds. Missing or
  expired reports no longer leave stale connection state in the interface.
- Restart waits for a new connected heartbeat, with progress shown until confirmed
  or a 30-second timeout. Transient downtime no longer appears as an immediate failure.
- Each preset offers a Shortcuts setup sheet with its stable URL and instructions.

## Validation on 2026-10-20

Hardware: Dell U4025QW, native Apple Silicon DDC/CI, local connection DP.

| Transition | Observed time to confirmed readback |
| --- | --- |
| Split to Personal full screen | 9.08 s |
| Personal full screen to Two desks | 14.20 s |
| Two desks to PS5 - Personal | 10.50 s |
| PS5 - Personal to Two desks | 10.09 s |
| Reapply already matching Two desks | 1.17–1.39 s, zero writes |

These are individual end-to-end measurements, not a performance guarantee. The
firmware and macOS display rediscovery still account for most of the delay.

- HomeKit health regression checks cover fractional and whole-second timestamps,
  expiry, invalid reports, stopped service, and old/new heartbeats after restart.
- All 4,204 existing core assertions pass, plus 32 coordinator/readiness/recovery/
  deadline/HTTP assertions and native DDC packet validation.
- Three HomeKit tests cover stable identifiers, television and scene dispatch,
  stale/unavailable state and local API authentication.
- A live rapid-selection test superseded the first two requests and verified the
  last selected preset. No intermediate request overwrote the final result.
- Previous preset was exercised twice through the CLI with request-specific
  verification, returning to the original Two desks state.
- The remote was inspected visually; closing it and pressing Control–Option–Space
  reopened it. Original presets and hotkeys were compared with the rollback copy.
- A real Apple Shortcut, **OpenDDPM — Two desks**, was created in Shortcuts. Its
  URL dispatched a new request and that request reached verified readback.
- Monitor and Scenes were paired with Apple Home. A Scenes switch selected
  Stackup - Personal and readback confirmed 75/25 TB + DP. Selecting Two desks
  from the Monitor input picker produced verified 50/50 TB + DP.
- The installed executable matches the universal build; code-signature verification
  and ZIP/DMG checksum verification pass. The build uses ad-hoc signing.

The first hardware test was interrupted by an actual Mac lock/display sleep.
During correction, a separate test caught that display-sleep notifications also
occur during a normal topology change. That notification was removed from the
interruption conditions; the corrected full-screen and split tests above passed.

Private raw test records remain under ignored `validation/`. The previous app,
configuration and original monitor registers are preserved in ignored
`local/rollback-2026-10-20/`.

## Limits

Independent USB control and ESP32 firmware are separate future work. Hiding this
Mac's video input can still remove its DDC route; such a preset is explicitly
unverified. Real hidden-input transitions were not exercised in this release
validation. The HomeKit service requires an existing supported Node.js runtime,
an awake Mac, OpenDDPM running and a reachable monitor control path. It controls
presets; monitor power switching is not implemented. Intel binaries compile but
were not validated on physical Intel hardware.
