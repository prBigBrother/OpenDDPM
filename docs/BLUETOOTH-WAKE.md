# Bluetooth wake through ESP32

Setup → ESP32 · Bluetooth wake has a global Enable ESP32 support switch.
Disabling it stops status polling and prevents new wake commands; a command
already accepted by the ESP32 may finish. Bindings and names are preserved.
The section sets the controller URL,
and assigns each video input to a saved BLE identity address. Read Bluetooth
devices refreshes saved and connected devices; offline bindings are preserved.
The setup section refreshes status on entry and every three seconds while visible.
Missing or failed status reads show an unknown status, never a disconnected device.
The refresh button keeps a constant label during background polling. Device
selectors use ESP32 device/bond names, cached locally for offline display;
Bluetooth addresses remain internal binding keys.
Old configuration files remain compatible and wake is opt-in.

Selecting any preset requests wake before monitor writes, including reselecting
the current preset. Full screen wakes its main input; split/PIP wakes both inputs.
Duplicate addresses receive one command. HDMI can remain unassigned.
An explicit standby command suppresses wake from background readback, including
stale power-on responses. Only explicit power-on or a new preset selection
re-enables wake; an already accepted ESP32 command may finish.
Turning the monitor on through the app wakes the inputs from its last observed
layout (or last verified preset). A refresh that observes power returning from
standby or a changed input/layout also wakes the associated devices.

Each command uses a fresh `/api/status` snapshot and POSTs `/api/wake` with its
current slot and generation. Offline/not-ready targets produce a warning and
never fall back to waking all devices. Commands are serialized with time for the
firmware's five Shift taps. An ambiguous POST is not retried automatically.
Wake errors appear separately from monitor verification and do not block DDC.
HTTP 202 means queued, not confirmation of physical wake.

The Mac running OpenDDPM must be awake, connected to the LAN, and able to run
monitor control. Physical power/input changes are detected only when monitor
state is refreshed. There is no autonomous ESP32 monitor-power detector here:
when both Macs sleep, physical monitor power-on alone cannot trigger this app.
The firmware and existing bonds do not need modification or reflashing.

Validation: `./scripts/test.sh` includes an isolated HTTP transport test for
identity routing, fresh connection generations, split targets, deduplication,
not-ready protection, and reading legacy configuration files. Physical acceptance
still requires sleeping each Mac and observing its wake on input selection and
monitor power-on.
