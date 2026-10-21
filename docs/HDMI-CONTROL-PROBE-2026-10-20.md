# Dell U4025QW: HDMI DDC while another input is active

Date: 2026-10-20, Europe/Chisinau.

The user connected this Mac over HDMI and explicitly requested a switch to
Thunderbolt and back to HDMI. USB upstream was absent from enumeration.
The native project's DDC transport discovered one Dell U4025QW; input readback
was 0x1111 (HDMI local context, HDMI selected), with PIP/PBP off (0).

## Successful hardware test

`scripts/dell_hdmi_cycle_test.m` retains the HDMI IOAVService before switching,
rather than depending on CG display rediscovery after the Mac's input is hidden.
Its only setting-write operation is VCP 0x60, limited to Thunderbolt 0x19 and
HDMI 0x11. No layout, power, brightness or USB-setting writes were made.

1. Send main=Thunderbolt over HDMI DDC.
2. With Thunderbolt selected, read VCP 0x60 through the retained HDMI channel:
   0x1119. Valid DDC reply and checksum prove that the channel stayed available.
3. Send main=HDMI through that same channel.
4. Read 0x1111, confirming automatic return to HDMI.

The process exited 0. Evidence:
`validation/hdmi-thunderbolt-cycle-2026-10-20.json`.
Native packet-validation self-test passed before the run.

## Interpretation and limits

This confirms DDC/CI reachability through the connected HDMI path while this
monitor displays Thunderbolt. It avoids the observed USB upstream/KVM loss.
The result supports prototyping an independent ESP32 HDMI DDC controller.
It does not validate an ESP32's electrical connection, the HDMI switch's DDC
routing, coexisting HDMI bus masters, or power-off/standby wake-up behavior.
The monitor state was confirmed by protocol readback, not by visual inspection
of the Thunderbolt video content.

The installed app was not replaced and its source was not changed by this test.
