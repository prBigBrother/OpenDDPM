# OpenDDPM control experience investigation

Date: 2026-10-20. Read-only investigation of source, installed Dell DDPM 2.3.0.2004, and current connected hardware. No display-setting writes, app replacement, or configuration changes performed.

## Recommendation

Keep OpenDDPM's state-aware planner. Build a single preset coordinator, adaptive readiness checks, and a compact preset remote. Add a HomeKit Television accessory whose inputs represent complete presets. Investigate independent USB HID control before committing to ESP32 hardware.

## Verified source findings

- `Sources/OpenDDPM/Core.swift:224` adds a fixed four-second delay after every write, including the last. Three writes incur 12 seconds of intentional waiting, excluding I/O and retries. Removing all delays blindly is inappropriate: monitor reconfiguration time has not been measured in this investigation.
- `Sources/OpenDDPM/AppStore.swift:98` drops incoming preset requests while busy; UI controls also disable while busy. This explains lost requests, but does not prove the reported interruptions have that sole cause.
- The planner already minimizes writes and models source swapping. Preserve it.
- Every helper invocation discovers online CG displays; hiding the Mac input can remove the control path. The helper currently permits only E9, 60, E8 writes.
- Global keyboard shortcuts exist. App Intents, apply CLI, URL handler, HomeKit/Matter and a shared automation API do not exist in the audited source.
- Same-app UI commands are gated by busy state. There is no monitor-wide exclusion against other processes. External interference remains unobserved.

## Current read-only hardware observations

- Native helper finds the selected DELL U4025QW.
- Individual reads completed in 0.18, 0.20, 0.19 seconds: E9=36 (0x24), 60=3865 (0x0F19), E8=15 (0x0F). This is equal PBP, main Thunderbolt, secondary DP, local context DP. Read latency does not establish layout-change latency.
- USB registry inventory shows ASIX AX88179A and Cable Matters billboard, with no Dell USB device in that snapshot. No usable Dell USB HID connection was established. No claim about the monitor's USB capability follows from its absence in this connection.
- Process snapshot showed OpenDDPM running; DDPM and BetterDisplay were not shown. Simultaneous DDPM activity was not established as a current cause.

## Installed Dell library findings

Target: `/Applications/DDPM/DDPM.app/Contents/Frameworks/libDellMonitorSdkLib.dylib`, SHA-256 `d7b2a5faa252d4ddc9d5813ecd32bc5c8fd7444f5962669e905a36a94412e3f6`, ARM64 slice. Static Hopper pseudocode via REA; no target calls executed.

| Finding | REA Evidence ID | Limits |
| --- | --- | --- |
| HID, I2C and DDC/CI procedure inventory | ev_ddb2fe5b841177754d0fdf7cfd514612393af2707617178ad7656381b359de09 | Names alone do not establish behavior |
| SetDDCCICommand wraps payload and calls HelperWriteEx command FE | ev_d71688dd049d1f990f844066acafb60ae9304ade434c85e9bc1e6a0ad66ad360 | Static pseudocode |
| HelperWriteEx creates vendor packet and calls WriteI2C at address 37, then polls replies | ev_736b7df9c901eff2c8dcce3c7079d36e1329c5eb7a2faaf92417dcd49b9eb210 | Pseudocode includes unresolved register artifacts; not a clean protocol specification |
| WriteI2C dispatches to several USB HID implementations | ev_8792631dbcab0929f3d65718eca804298e4d7737dc51022a3c1aa6db99cb6298 | Exact monitor family route is unknown |
| SetPxPLayout sends 0x17-byte payload through command 7A when monitorSeries==2 | ev_1f434109b89aeb2ef01baadefaab5bd0c5948fbba59ca1330ad6066b80aca527 | U4025QW support, payload semantics, atomicity and speed remain unknown |
| GetPxPLayout uses command 7A and same family gate | ev_5a6a1235cba4c9177138ebbc03a5bb0e3270bf1ac964b0c835631a086ddbc4cb | Not called on live hardware |

This supports investigating a USB transport and a possible combined layout operation. It does not prove one USB packet can atomically apply arbitrary U4025QW presets.

## Proposed product behavior

1. One click selects a complete desired preset: source(s), proportions, optionally USB/KVM/audio when supported and verified.
2. All entry points call one coordinator. Newer selections replace pending targets. Finish the current hardware transaction, read actual state and replan at a safe boundary; never overlap register writes or blindly cancel mid-packet.
3. Replace fixed waits with transition-specific readiness checks and an overall deadline. Mark desired/applying/verified/unavailable separately. Preserve a working last-confirmed preset for recovery.
4. Show named preset buttons with visual proportions. Offer a global launcher hotkey and individual preset hotkeys. Restore-last-preset is an explicit action, not an automatic rollback that could fight a newer request.
5. HomeKit Television inputs map to entire presets via ActiveIdentifier. A separate momentary switch per preset may be needed for convenient scene/Siri triggers; verify actual Apple Home UI behavior. Use native HomeKit/HAP first rather than assume Matter TV input support.
6. Initial bridge can run on an awake Mac. Reliable control while the Mac sleeps or its video input is hidden requires a separately proven control path and an always-on controller.

## Hardware topology

An ESP32-S3 plugged as a USB device into the monitor's downstream hub cannot directly command a sibling Dell USB device. For independent USB control, ESP must act as host and connect to the monitor's upstream USB path. Upstream/KVM routing, HID family/handshake, power, USB enumeration during video switches and independence from keyboard/mouse routing all require verification.

First establish USB control from a computer through the monitor's data upstream port. Enumerate VID/PID/interfaces, safely read known registers, trace the relevant protocol route, then validate across layout/input/KVM switches. Port to ESP32-S3 only after that works. A small always-on computer with USB may be a faster practical route, depending on actual available hardware.

## Next implementation and validation order

- Implement and unit-test coordinator, supersession at safe boundaries, readiness/deadlines, recovery, and one shared automation entry point.
- Measure a matrix of real transitions with timestamps and stable readback; do not promise subsecond picture switching before measurement.
- Build the remote and HomeKit preset mapping above that coordinator.
- Verify independent USB path; investigate command 7A only once family and payload support are established.

Questions answered: artificial delay and dropped requests (answered); Apple Home architecture (design supported by HAP example, not implemented); ESP topology (explained, live path unresolved); physical switching floor, USB stability, combined command support (unresolved).

## External sources

- HAP-NodeJS TV example: https://github.com/homebridge/HAP-NodeJS/blob/latest/src/accessories/TV_accessory.ts
- ESP-IDF USB host HID driver: https://components.espressif.com/components/espressif/usb_host_hid/versions/1.0.0?language=en
- ESP32-S3 USB-OTG board host/device topology: https://documentation.espressif.com/api/resource/path/docs/projects/espressif-esp-dev-kits/en/latest/esp32s3/esp32-s3-usb-otg/user_guide.html
- Installed Dell readme explicitly describes video or USB upstream connections. This is generic installed documentation, not validation of an independent route on this monitor.
