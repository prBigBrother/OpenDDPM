# Brightness with Thunderbolt primary and DisplayPort secondary

Observed on Dell U4025QW, serial BX74LJ4, 2026-10-22. This Mac was on the secondary DP input; no input, layout, or HDR setting was changed during diagnosis.

## Evidence

- Discovery identified display ID 3 and the selected serial.
- Raw registers: E9 = 42 (0x2A, 75/25 PBP), 60 = 3865 (0x0F19), E8 = 15 (DP).
- DisplayServices reported `CanChangeBrightness=false`, and its brightness read returned status 1000. Native brightness is unavailable on this connection, so the application uses DDC.
- A controlled DDC test read the original brightness 100, wrote 99 once, and eventually read 99. Three intervening brightness reads failed. Restoration to 100 was confirmed by two successful reads, also after an intervening failed read.
- These are monitor register confirmations; no optical measurement was performed.

Local diagnostic records: `validation/dp-secondary-brightness-readonly-2026-10-22.json` and `validation/dp-secondary-brightness-test-2026-10-22.json`. The read-only native probe source is `validation/probes/NativeBrightnessRead.swift`.

## Fix

Previously, picture-setting verification stopped on the first failed read, even if the monitor had already accepted the write. The model then discarded the confirmed brightness and disabled the slider.

DDC picture writes now send the command once and retry readback within the existing eight-second operation budget. Two matching valid replies are required; a contradictory valid reply resets confirmation. Transient read errors do not resend the command. Timeout remains an explicit failure rather than an optimistic success.

The shared controls model retains the last confirmed brightness after a failed refresh or unverified write, while reporting the error and permitting retry. It never publishes the requested value as confirmed without successful readback. Other settings retain their previous unavailable-state behavior.

Regression coverage includes three consecutive read failures recovering with exactly one write, rejection of an ignored write, and preservation of confirmed brightness with visible errors after refresh/write failures. Physical slider behavior still requires user confirmation with the updated installed application.
