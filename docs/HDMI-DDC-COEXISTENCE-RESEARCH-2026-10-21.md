# Shared HDMI DDC access for ESP32 and PS5

Date: 21 October 2026. Target: Dell U4025QW, original ESP32, PS5.
This is an architecture investigation. No new hardware commands were sent during
this research. The coexistence firmware and electrical design are not implemented.

## Resume checkpoint — awaiting the ordered board

**21 October 2026: at the user's request, work is on hold until the HDMI
male-to-female pass-through board with 19 breakout contacts arrives.** This is
the main report for resuming the investigation. No reminders were scheduled.

### Objective and agreed decisions

- Build an autonomous Dell U4025QW remote with Apple Home support, without an
  always-running MacBook. Use the existing **original ESP32**; the exact board
  model has not been recorded. HomeSpan is the HomeKit candidate, without
  requiring Homebridge.
- Controls: main/secondary input selection, PiP/PBP, sleep and wake.
- The user ruled out USB-C upstream as the main transport: management HID
  interfaces disappeared when Thunderbolt became the full-screen input.
- The HDMI switch is excluded from the current topology. The source is **PS5**.
  The pass-through board is intended to plug directly into the PS5, with an
  HDMI cable connecting its female socket to the Dell.
- The ordered board was identified from a photograph. Its exact model,
  schematic, routing, and header-to-connector pin mapping remain unverified.
  It appears to be a passive breakout, not a complete DDC controller.
- Do not cut traces or solder before inspecting the board and taking
  measurements. The preliminary “about 80%” estimate is not a compatibility
  guarantee.

### Findings and supporting material

| Question | Status and material |
| --- | --- |
| USB HID reads, brightness, PBP and input swapping | Worked while the upstream remained available; [USB report](USB-CONTROL-PROBE-2026-10-20.md) |
| Full-screen Thunderbolt over USB | The channel disappeared; manual DP selection restored it, followed by verified readback |
| HDMI → Thunderbolt → HDMI through HDMI DDC | Successful with state readback; [HDMI report](HDMI-CONTROL-PROBE-2026-10-20.md) |
| Sleep D6=4 → wake D6=1 | Confirmed from the Mac over HDMI, including 10 seconds of sleep; [power report](HDMI-POWER-PROBE-2026-10-20.md) |
| D6=5 → wake | Failed through the tested Mac/HDMI path; do not use for the remote |
| OpenDDPM/HomeKit power implementation | Described in the [power audit](HDMI-POWER-AUDIT-2026-10-20.md); this is the Mac implementation, not ESP32 firmware |
| Shared PS5 + ESP32 access | Untested; architecture and references are documented below |
| Operation with the PS5 asleep/off | DDC power availability and effects on the console are unknown; measurements are required |
| Verified ESP32 operation | None yet: no completed electrical design or firmware, and no ESP32 flashing |

Raw logs are in `validation/`; probes are in `scripts/`. Diagnostic files dated
2026-10-20 are historical results, not the monitor's current state. Rediscover
the device and read its actual state before further operations.

### First steps when the board arrives

1. Obtain photographs of both sides of the actual board and the ESP32 markings.
   Check continuity for contacts 15/16/17/18/19 and check for shorts, with all
   devices disconnected.
2. Insert **only the breakout**, without ESP32 wiring: PS5 → board → Dell.
   Check the normal video mode, audio, HDR/VRR, and protected video with HDCP.
3. Measure DDC voltage levels/edges and +5 V with the PS5 on, in Rest Mode,
   and off.
4. Complete the level-shifting and branch-disconnect design from those
   measurements, then observe DDC passively. Do not inject external 5 V into
   the continuous pin-18 connection.
5. Verify arbitration handling in the chosen firmware/driver **before active
   attachment**. Do not treat stock ESP-IDF v5.5.2 as a ready-made shared-bus
   solution without reviewing its error handling.
6. Follow the detailed validation plan at the end: GET first, then a reversible
   brightness change, followed by inputs/PBP and D6=4/1.

Avoid buying additional parts before selecting the actual modules. PCA9306 is
still a candidate, not a completed electrical design. Mouse-triggered wake in
the current application is performed by the Mac; an autonomous controller
needs its own event source to reproduce that behavior.

## Recommendation

For the first prototype, use a parallel branch from continuous SDA/SCL through
an enable-controlled bidirectional level translator, hardware multi-controller
I2C, and specifically verified arbitration-loss handling. This is a candidate
for compatibility testing with this PS5, not a guarantee of uninterrupted HDMI.

A simple parallel connection is insufficient to guarantee compatibility with
arbitrary HDMI sources in advance. That would require a validated active DDC
bridge/arbiter with separate ports and compatible wait handling. An original
ESP32 acting as a software transparent bridge is not the selected architecture.

The earlier success estimate was preliminary: successful monitor commands from
a Mac do not test simultaneous operation of two independent controllers.

## Actual topology

The user confirmed that only the PS5 is connected; the HDMI switch is excluded.
The breakout will plug into the PS5, with its female socket feeding the cable
to the Dell.

```text
PS5 -- male/female breakout ---------------- HDMI cable -- Dell U4025QW
            |
            +-- SDA/SCL -- switchable 5 V/3.3 V translation -- ESP32
            +-- DDC ground -------------------------------- GND
```

Video lanes, shields/grounds, HPD, CEC, and the existing +5 V connection remain
continuous. New wires attach only to the DDC branch, kept as short as practical.
Power the ESP32 from a separate USB supply. Initially, inject nothing into pin 18.

## What is already established on this Dell

- HDMI DDC remains available with Thunderbolt selected and can return to HDMI:
  `validation/hdmi-thunderbolt-cycle-2026-10-20.json`.
- DPMS off/on through D6=4/1 worked in the tested cycle:
  `validation/hdmi-dpms-cycle-2026-10-20.json`.
- These results do not establish PS5 compatibility with an additional controller,
  the breakout's high-speed signal quality, or DDC power with the PS5 off.

## Why HDMI sideband communication must remain intact

DDC/SCDC participate in EDID exchange and HDMI configuration, including HDMI 2.1
FRL. Leaving the video pairs unchanged does not by itself preserve the HDMI link.
[TI Precision Labs: HDMI interface and DDC/SCDC](https://www.ti.com/content/dam/videos/external-videos/en-us/11/3816841626001/overview-ddc-bus-hdmi-systems.mp4/subassets/overview-ddc-bus-hdmi-systems-presentation.pdf).

HDCP uses the same I2C bus. HDCP 2.3 describes RxStatus polling even after
session establishment: DDC cannot be assumed permanently idle after EDID.
[HDCP on HDMI 2.3, section 2.14](https://www.digital-cp.com/sites/default/files/specifications/HDCP%20on%20HDMI%20Specification%20Rev2_3.pdf).

Address notation matters: HDCP `0x74/0x75` in that document are **8-bit** address
bytes. Their 7-bit address is `0x3A`, not `0x74`. Our monitor's DDC/CI address
is 7-bit `0x37` (address bytes `0x6E/0x6F`). EDID normally uses 7-bit `0x50`:
[Linux drm_edid.h](https://github.com/torvalds/linux/blob/master/include/drm/drm_edid.h).

Different target addresses do not prevent simultaneous START conditions or
controller contention.

## Options considered

| Option | Assessment |
| --- | --- |
| Direct ESP32 GPIO attachment to DDC | Unsuitable voltage levels and contention handling |
| Parallel branch with level translation and proper arbitration | Recommended experimental prototype |
| Wait for a quiet interval and transmit through ordinary Wire | Reduces collision probability but does not eliminate the START race |
| Disconnect PS5 SDA/SCL while sending commands | Can disrupt EDID/HDCP/SCDC; fails the transparency requirement |
| Ordinary PCA954x/TCA954x mux | Selects connections; does not coordinate independent controllers |
| PCA9641 | Requires software ownership requests; the PS5 does not implement that protocol |
| Active two-port DDC proxy | Possible but complex; requires separate development and validation |

PCA9641 is an arbiter, but its LOCK_REQ/LOCK_GRANT protocol assumes controller
software participation. It cannot simply be placed in front of the PS5 to
provide automatic transparent access without adaptation.
[PCA9641 datasheet: control register and request/grant examples](https://www.nxp.com/docs/en/data-sheet/PCA9641.pdf).

An active bridge must preserve repeated START, ACK/NACK, reads, clock stretching,
and source timing limits. Caching EDID alone does not replace HDCP/SCDC.
The original ESP32's slave I2C does not support clock stretching, which hinders
a simple bridge that waits for the Dell's response before replying to the PS5.
[ESP-IDF ESP32 I2C documentation](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/i2c.html).

## ESP32 support and the stock driver issue

The original ESP32 TRM specifies multi-master/multi-slave operation, open-drain
signaling, and synchronization/arbitration. The hardware is a suitable subject
for investigation.
[ESP32 Technical Reference Manual: I2C chapter](https://documentation.espressif.com/esp32_technical_reference_manual_en.pdf).

However, the inspected ESP-IDF **v5.5.2** driver groups arbitration loss with
timeout. Timeout/busy handling paths call reset with `clear_bus=true`; bus
clearing can generate SCL pulses and STOP. That is unwanted interference if
the PS5 owns the bus. This conclusion applies to the inspected source version;
other versions require their own review.
[Inspected i2c_master.c](https://github.com/espressif/esp-idf/blob/v5.5.2/components/esp_driver_i2c/i2c_master.c).

Use a separately verified driver/LL path that distinguishes arbitration loss
from a faulty bus. A losing controller must not clear the bus or generate STOP;
it must release its outputs and wait for the other transaction to finish.

## Electrical candidate

HDMI contacts: 15=SCL, 16=SDA, 17=DDC ground. Verify the actual breakout mapping
by continuity measurement. Measure levels and pull-ups before attaching the
ESP32; its GPIOs are not 5 V tolerant.

PCA9306 is a candidate: bidirectional open-drain translation, multi-controller
support, and branch disconnection through EN. It is a **translator, not an
arbiter**. EN=low disconnects only the ESP32 branch while PS5—Dell stays intact.
The circuit must disconnect the branch in hardware during ESP32 reset or power
loss; the EN circuit and back-power protection still require design.
[TI PCA9306, sections 8.1.2, 8.3 and 9](https://www.ti.com/lit/ds/symlink/pca9306.pdf).

Do not wire EN/VREF2 arbitrarily as a normal GPIO signal: the circuit depends
on the translation configuration. Follow TI's 3.3 V/5 V recommendations.
Do not add another pair of strong 5 V pull-ups without measuring the existing
ones. Do not substitute an automatic push-pull UART translator for an I2C circuit.
Use an oscilloscope to check edge timing and VOL with the branch connected.

## Bus-access algorithm: design requirements

1. Keep the branch disconnected at startup. Initialize the local I2C hardware
   without sending bus-clear pulses onto HDMI.
2. Observe START/STOP/repeated START passively, rather than checking HIGH levels
   alone: both lines can be high within an active byte.
3. Do not start a transaction while the PS5 is communicating. Waiting respects
   its active transaction; simultaneous START priority is determined by bit
   arbitration, not a software priority setting.
4. Start only after confirmed bus release and the required bus-free interval.
   Add a small randomized backoff before retries.
5. Use hardware SCL synchronization and arbitration. On arbitration loss,
   immediately release the lines; do not generate STOP or reset the shared bus.
6. End successful transactions with STOP. An error/timeout does not authorize
   forcibly clearing the shared bus; disconnect our branch and report the error.

These requirements follow multi-controller I2C rules. The PS5 HDMI controller's
behavior during another controller's transaction or after losing arbitration
is still unknown.
[NXP UM10204, sections 3.1.7–3.1.9](https://community.nxp.com/pwmxy87654/attachments/pwmxy87654/nxp-designs/931/1/UM10204.pdf).

There is no guarantee that “PS5 always wins”: standard arbitration has no such
priority. Even a correct ESP32 implementation cannot compensate for a source
that does not tolerate additional controllers. This is the decisive hardware test.

## DDC/CI reads and writes

Start at 100 kHz. Do not scan every address; use only the verified `0x37`.
VCP writes and read requests are short I2C transactions. GET request:
`0x37 W: 51 82 01 <VCP> <checksum>`, followed by STOP. Release the bus while
the monitor prepares its reply; do not hold SCL for tens of milliseconds.
Read the response in a separate `0x37 R` transaction. Validate its header,
VCP code, status, and checksum as in our NativeDDC implementation.

If the PS5 itself uses DDC/CI at `0x37`, bit arbitration alone is insufficient:
it may send its own request between our GET and response read. Coordination,
command observation, or an architecture change would then be required.
An ESP32-local mutex does not lock out the PS5.

Send commands on events rather than polling frequently. Verify targets by
readback. After an ambiguous write, retry based on actual state rather than
blindly repeating toggle commands. Power control uses only D6=4/1.

## Power with the PS5 off: a separate validation

It is unknown whether HDMI +5 V and the pull-ups remain available on this PS5
in Rest Mode or when off. Measure this rather than assuming it.
If the Dell requires source +5 V for DDC, the HDMI sideband circuit may need an
external supply. Direct injection into continuous pin 18 is unacceptable because
it would connect two power sources. It requires separating that line, reverse-
current protection, and checking back-power through SDA/SCL as well.
This circuit must follow measurements; the translator alone does not solve it.

## Compatibility validation plan

1. Breakout without the branch: verify the same resolution/frame rate, HDR/VRR,
   audio and HDCP. PS5 supports 4K120; check the actual output mode in settings.
   [Official Sony guide](https://www.playstation.com/en-us/support/hardware/ps5-4k-resolution-guide/).
2. Measure +5 V, SDA/SCL, and pull-ups with the PS5 on, in Rest Mode, and off.
3. Use a logic analyzer rated for the measured levels to capture DDC passively
   during PS5 startup, video-mode changes and protected playback. Identify
   frequencies, addresses and intervals; avoid retaining unnecessary HDCP data.
4. Connect the translation branch with the ESP32 silent: HDMI must behave as in
   the baseline test, including during ESP32 reset/power loss.
5. Send infrequent GETs to `0x37`, then change brightness with restoration. Log
   arbitration losses and confirm the absence of bus-clear. Exercise overlap
   with EDID/HDCP traffic, not just a quiet desktop.
6. Test games and protected playback with HDCP enabled: command sequences,
   hot-plugging, 60/120 Hz, and supported HDR/VRR modes. Check for black screens,
   reauthentication, audio disruption, and resolution changes.
7. Test HDMI/Thunderbolt transitions, D6=4/1, and PS5 Rest Mode/off only after
   validating power behavior.

Acceptance criterion: repeatable GET/SET with valid responses, preserved
HDMI/HDCP behavior, and an intact direct link when the ESP32 fails. Until these
tests pass, “does not disrupt HDMI” is a goal rather than a demonstrated result.
