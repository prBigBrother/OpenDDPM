# DDPM monitor control evidence

Inspected 2026-10-21 using REA 6.7.0 / Hopper, read-only static analysis. No DDPM command was executed and no monitor state was changed during this investigation.

Target: `/Applications/DDPM/DDPM.app/Contents/MacOS/DDPM`, universal Mach-O, arm64 slice, SHA-256 `7c33b475ce4736996cba27d860ec468e6ca386d4fcfdad0d7b489ef2f75dbe7b`. This differs from the executable identity in the older USB evidence bundle; that bundle was not reused as current binary evidence.

Full records are retained in `validation/ddpm-monitor-evidence-2026-10-21.json`. Pseudocode is reconstructed analysis, not Dell source. The following are observations of constant values and calls; actual acceptance by the connected monitor still requires hardware readback.

## Automatic brightness

`StringUtil updateAutoBrightness:setvalue:error:` at `0x10027638c` checks `supportsALS`, reads VCP `0x66`, and preserves all except bits 0–1. On writes `(old & 0xFFFC) | 2`; off writes `(old & 0xFFFC) | 1`. Exact bit operations are visible in assembly (Hopper pseudocode omits these arithmetic assignments).

Evidence: `ev_ddcb83047353301b7184e81a530a7a873dbe2efebb9dfde1bc3a684c4345b225`.

`StringUtil updateAutoBrightnessRangeLevel:setvalue:error:` at `0x100276c84` uses the same register. Low=0, mid=1, high=2; write `(old & 0xFF3F) | (level << 6)`, preserving the automatic-brightness bits and other functions.

Evidence: `ev_ff5145b0f5bdcc077d06e21c0c1dbda92a782999a3154b15b79bd9e1f579b757`.

## Color presets: capability IDs differ from write commands

`AMControl init_ColorPresetDictionary` at `0x10045c498` maps E2 capability IDs to labels. `CreateColorPresetDictWithE2h:andModelName:` filters that dictionary against supported E2 IDs and adjusts some names by model. These IDs must not be sent directly to VCP DC.

`AMControl init_AMDictionary` at `0x10045886c` maps labels to the actual register/value command. `StringUtil updateColorPreset:setvalue:error:` obtains that command through `getColorPresetVCP:` and parses its two hex components before calling the monitor SDK Set method.

| Label | E2 capability/current-preset ID | Write register | Write value |
| --- | --- | --- | --- |
| Standard | 00 | DC | 00 |
| Movie | 02 | DC | 03 |
| Game | 04 | DC | 05 |
| 5000K | 0C | 14 | 04 |
| 5700K | 0D | 14 | 0B |
| 6500K | 0F | 14 | 05 |
| 7500K | 10 | 14 | 06 |
| 9300K | 11 | 14 | 08 |
| 10000K | 13 | 14 | 09 |
| sRGB | 0B | 14 | 01 |
| BT.709 | 1A | F0 | 09 |
| DCI-P3 | 1B | F0 | 0A |
| Display P3 | A1 or generic 3D | F0 | A1 |
| Custom Color | 14 | 14 | 0C |

Dictionary evidence: `ev_1598ca3285bb1d215778aec7113ec1131448e02d4f61abdf0907f6b17224a80b`, `ev_74f9e65cf02232ede629ab2b55cd69e50194588ef0850c253008bfaaf0c7b8df`. Command evidence: `ev_634365bd8c078ec54c2795715319d4067753a556f73553425e965d7b4eb45508`, `ev_c8ee9313037b78a1a20fb9b140a5b7991f578e78cd4a5056cfdc64deef6feb0e`.

Follow-up: `StringUtil fetchColorPreset:` at `0x1002708d8` explicitly reads E2 through SDK `Get::::`, formats the low byte as `%02X`, constructs the supported preset dictionary from capability text `E2(...)`, and looks up that byte. E2 is therefore used as an actual current-state GET in DDPM, not just as a capability list. This path has no DC/14/F0 fallback. A failed native E2 GET does not prove color writes are unsupported: represent current selection as unknown and verify a readable write register where possible, otherwise report the operation as unverified. Focused records are in `validation/ddpm-monitor-color-get-2026-10-21.json`.

## HDR needs both monitor and macOS state

`StringUtil updateHDRWithError:setvalue:error:` at `0x100289104` checks model/firmware support and HDRMode. For HDRMode 1 and 2, it sends VCP `EA=FE01` for on or `EA=FE00` for off. HDRMode 3 additionally sets F4 to a supported capability entry. The U3226Q has a distinct macOS-only path. After successful monitor writes it reacquires MPDisplay, waits for `hasHDRModes` when enabling, and calls `setPreferHDRModes:` with a Boolean.

`AllowList getCapHDRMode:` at `0x1004a5398` derives the mode from capabilities: E2 HDR IDs 23–27 or 3A–3C imply type1; EA capability FE/FE00/FE01 implies type2; F4 41–46 implies type3.

`displayInfo isHDROn` at `0x10051c9c8` returns `hasHDRModes && preferHDRModes`. DDPM's FetchHDR calls that method; it does not establish an EA GET/readback encoding.

Evidence: `ev_4e917da5e0c05fcddec24f4d0a2cc006819ed5b517e629a1671be2eb236a948b`, `ev_f07752b53e4e5e8bbcdfbf5c351370bff4277690b61d9ec5eaf499d67bd6dc8d`, `ev_73cc61c57c46d71061a1b99d825b142522345022f9dfb62152a4adc42284e630`, `ev_e1070c4e0b6a0d38860e043b29e563dcb90099df66727d6a6c69d3cb534f6149`.

DDPM links `/System/Library/PrivateFrameworks/MonitorPanel.framework/Versions/A/MonitorPanel`. Its `displayInfo getMPDisplay:ForceReGet:` at `0x10051c320` constructs `[[MPDisplay alloc] initWithCGSDisplayID:(UInt32)displayID]`. It caches by display number and UUID; a fresh instance avoids keeping an object associated with an obsolete display identity. Framework, class and selectors are private API and need guarded availability checks on other macOS versions.

Acquisition evidence: `ev_08e4a35364f5771387dbea18efadcb64e1afc5d2ea121d99c86c7c12820bf08f`; framework linkage corroborated with read-only `otool -L`.

## Remaining verification boundaries

- Monitor writes, color readback, auto-brightness behavior and HDR switching were not exercised by this static investigation.
- The screenshot establishes requested UI choices; hardware capabilities should constrain what is enabled.
- EA write command values do not establish its GET response format. Verify final HDR using macOS state, and preserve unsupported/failed DDC responses explicitly.
- Resolution, refresh rate, HiDPI and native key/OSD behavior are separate macOS implementation work; no claim that they were observed at runtime is made here.
