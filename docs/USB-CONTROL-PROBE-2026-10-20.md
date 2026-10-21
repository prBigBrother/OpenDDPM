# Dell U4025QW: independent USB diagnostic

Date: 2026-10-20, Europe/Chisinau.

## Confirmed on this monitor

A cable from this Mac to the monitor's USB-C data-only upstream exposes
Realtek HID devices 0bda:1100 and 0bda:1101. Both advertise 192-byte input
and output reports, usage page 0xffda. The diagnostic used only 0bda:1100.

The Python hidapi transport opened successfully outside the execution sandbox.
The sandboxed attempt could enumerate the device but could not open it.
No sudo, device reset, USB seizure, display-setting write, firmware operation,
or app replacement was used.

Vendor-command setup and the challenge/response handshake succeeded far enough
to send standard DDC Get VCP requests through the USB-to-I2C tunnel and receive
valid, checksum-verified replies. These reads were repeated with matching results:

| VCP | Current value | Interpretation |
| --- | --- | --- |
| 0x60 | 0x000f | Main input DisplayPort |
| 0xe8 | 0x0019 | Stored secondary input Thunderbolt; inactive with PBP off |
| 0xe9 | 0x0000 | PiP/PBP off |
| 0xd6 | 0x0001 | Power on |

This confirms an independent USB read path while the selected main video input
is DisplayPort. It does not yet establish availability across KVM changes,
monitor standby, power-off, or video-input/layout changes.

## Limitations

The vendor firmware-tag query returned a valid framed/checksummed response with
an all-0xff field. It does not identify the installed M3Txxx firmware version.
The raw hub-version report was received; applying the upstream decoder yields
1.04, retained only as a candidate because that field interpretation has not
been independently validated on this unit.

Power VCP is readable (current 1, reported maximum 5). This is not proof that
power writes work or that an off monitor remains reachable for wake-up.

## Artifacts and boundaries

- `scripts/dell_usb_probe.py`: a diagnostic-only implementation, based on the
  LGPL-2.1-or-later fwupd transport/auth source linked below. It has no Set VCP
  function and accepts only specific session, authentication, hub-version,
  firmware-tag-read and four standard Get VCP frames at the send boundary.
- `validation/usb-readonly-2026-10-20.json`: raw diagnostic replies and parsed state.
- Offline verification accepted seven safe frames and rejected all 256 standard
  Set VCP variants plus six firmware-related opcodes. No hardware was accessed
  during that verification.
- The final hardware run again confirmed all four VCP replies and closed its
  session. No monitor-setting writes were sent.

The next stage is a separately authorized, reversible setting-write test followed
by USB readback. The existing diagnostic deliberately cannot perform this stage.
No controller purchase or ESP32 firmware/flash is required to reach this checkpoint.

## Reproduce

Requires Python 3.10+ and `hidapi` (tested here with Python 3.15 and hidapi 0.15.0).
Dependencies for this session are isolated under `/private/tmp/dell-usb-python`;
that temporary directory is not part of the repository and may be removed by macOS.

```sh
PYTHONPATH=/private/tmp/dell-usb-python python3 scripts/dell_usb_probe.py --state
```

Run from the repository root. macOS accessory authorization and host access to
USB HID are required. The probe sends query packets and changes temporary
transport session state; it does not change monitor display settings.

## Source provenance

Protocol/auth reference:
https://github.com/joshperry/fwupd/tree/dell-monitor-rt/plugins/dell-monitor-rt

Author notes:
https://gist.github.com/joshperry/3ded311cc8af0b2287aabc14233722c8

Reference `fu-dell-monitor-rt-device.c` SHA-256: 1de59acb571f20781080938983f8cebb7ead13e251616d13a8e9091005801c98

The diagnostic ports only setup/auth/read framing, not the updater.

## Authorized brightness write test

After explicit user authorization, a separate bounded test wrote only VCP 0x10:

- Initial brightness: 75 / 100.
- Wrote 76; checksum-verified readback returned 76.
- Restored 75 in the transaction's finally block; readback returned 75.
- The subsequent burst of final reads returned a stale layout response for the
  brightness request; the response was rejected rather than misinterpreted.
  Therefore the original transaction log retains a verification error even
  though its change and restoration readbacks both succeeded.
- A separate read-only postcheck, with spaced requests, confirmed brightness 75,
  main DP, secondary Thunderbolt, layout off, power on. All current values match
  the pre-test snapshot.

The write path and restoration are now demonstrated for brightness on this unit.
Input, layout, power and wake-up writes remain untested. No conclusion about
standby/KVM reachability or MCU USB-host compatibility follows from this test.

`scripts/dell_usb_brightness_test.py` keeps a separate send filter that permits
only brightness and only the original value or the one-step target captured by
that transaction. An offline check accepted those two frames and rejected 255
other VCP registers and six out-of-scope values. The original query-only probe
was not relaxed. The brightness test now spaces reads and retries mismatched
register responses up to three times; this read path passed the postcheck, but
the revised full write transaction was not rerun unnecessarily.

Evidence:
- `validation/usb-brightness-test-2026-10-20.json` (write and restore plus the
  original stale-response verification error).
- `validation/usb-brightness-postcheck-2026-10-20.json` (successful independent
  read-only verification).

## Authorized PiP/PBP layout write test

The user then authorized the next switching test. A layout-only transaction
through USB HID 0bda:1100 performed:

1. Snapshot: DP main (0x0f), Thunderbolt stored secondary (0x19), layout off
   (0x00), power on (1), brightness 75.
2. Write VCP 0xe9 = 0x24 (PBP 50/50).
3. Readback: layout 0x24, main DP, secondary Thunderbolt; all DDC checksums valid.
4. Restore VCP 0xe9 = 0x00.
5. Readback and complete final snapshot match all original current values.

The USB channel remained usable through this layout transition. This validates
PBP mode selection through USB; it does not prove a live video signal on the
secondary source, input switching, KVM independence, or power-off wake-up.

`scripts/dell_usb_layout_test.py` permits writes only to 0xe9 and only the
captured original mode and selected target, restores in finally, and records
readback. Its offline frame-filter check accepted two intended frames and
blocked 262 other-register/out-of-scope frames. The hardware transaction exited
0 with success=true, restored=true, session_closed=true.

Evidence: `validation/usb-layout-test-2026-10-20.json`.

## Authorized main-input swap through USB

A separate bounded test wrote only main-input VCP 0x60 and layout VCP 0xe9:

1. Original: full-screen DP, stored Thunderbolt secondary.
2. PBP 50/50: DP main, Thunderbolt secondary.
3. Write main=Thunderbolt (0x19). Readback confirms main=0x19 and
   secondary=DP (0x0f): Dell automatically swapped the regions.
4. Write main=DP (0x0f). Readback confirms main=DP and secondary=Thunderbolt.
5. Restore full-screen mode (0x00); complete final snapshot matches original
   main, secondary, layout, brightness and power current values.

USB remained available throughout the input swap. DP was retained in one PBP
region, so this does not demonstrate control with DP entirely excluded, nor
independence from every USB/KVM routing configuration. No explicit secondary
input, power or brightness writes were sent in this transaction.

`scripts/dell_usb_input_test.py` accepts only four exact register/value pairs
while its test is enabled: main DP/TB and layout off/50-50. Its offline frame
check accepted those four pairs and rejected 2044 other combinations.
The live run exited 0 with success=true, restored=true and
all_current_values_restored=true.

Evidence: `validation/usb-input-test-2026-10-20.json`.

## Full-screen Thunderbolt test: USB management became unavailable

The user explicitly authorized full-screen Thunderbolt with DP excluded and
return to DP. Initial readback confirmed full DP, stored TB secondary,
brightness 75 and power on. The test sent main=Thunderbolt (0x60=0x19).
Subsequent HID writes failed; target-state readback was unavailable.
The primary HID disappeared from enumeration. Three reconnect attempts could
not find it, so restoring main=DP via USB failed. The test log records
restored=false; no success or verified target-state claim is made.

A subsequent USB-tree snapshot still showed the first-level 4-port USB2/USB3
hubs but none of their former downstream management devices or peripherals.
This supports a USB/KVM route dependency in the current configuration, rather
than proving that USB control is independent of every video input.
The user was asked to select DisplayPort with the physical monitor joystick.
Manual recovery is pending confirmation. No power command was sent.

Evidence: `validation/usb-full-input-test-2026-10-20.json`.

The recovery code's cleanup was adjusted to avoid masking the original device-
disappearance error when closing an already closed handle; no test rerun.

### Manual recovery confirmed

The user selected DisplayPort manually. Both Realtek HID interfaces and the
previous downstream peripherals reappeared. A fresh USB-only diagnostic read
confirmed main DP (15), stored secondary TB (25), layout off (0), power on (1),
brightness 75. Every original current value was restored. This recovery check
sent no monitor-setting writes. The failed full-screen test remains recorded
as failed; manual recovery is separately documented.

Evidence: `validation/usb-full-input-recovery-2026-10-20.json`.
