# Dell U4025QW: HDMI Power Control (VCP 0xD6) and HomeKit Integration Audit

Date: 2026-10-20, Europe/Chisinau.
Target hardware: Dell U4025QW on Apple Silicon via HDMI.
Transport: Native macOS Apple Silicon DDC (`IOAVService` / I2C).

---

## 1. Summary of Hardware Tests (VCP 0xD6 Power States)

We systematically tested all standard VESA MCCS 2.2 power modes on the physical Dell U4025QW monitor over HDMI DDC:

| VCP 0xD6 Value | Mode Name | Transport Accepted | Panel State | DDC Communication | Wakes via DDC (`0xD6 = 1`) | Notes |
|:---:|:---:|:---:|:---:|:---:|:---:|:---|
| **`1`** | **Active / On** | Yes | On | Fully functional | N/A | Normal working state. |
| **`2`** | **Standby** | Yes (`ret = 0`) | Stays On | Active | Ignored | Firmware ignores value 2; reads back `1`. |
| **`3`** | **Suspend** | Yes (`ret = 0`) | Stays On | Active | Ignored | Firmware ignores value 3; reads back `1`. |
| **`4`** | **DPMS Off** | Yes (`ret = 0`) | **Off (Sleep)** | **Active & Powered** | **YES (Attempt 1)** | Panel off; registers `0x60`, `0xe9`, `0xd6` respond; wakes instantly. |
| **`5`** | **Power Off** | Yes (`ret = 0`) | **Off (Dead)** | **Disconnected** | **NO** | Soft power off; HPD de-asserted; requires physical power button. |

### Key Hardware Findings:
1. **Values `2` and `3` are obsolete in modern LCD firmware**: The scaler accepts the I2C packets over the wire, but internal logic ignores them because LCDs have no CRT heaters or intermediate deflection states.
2. **Value `5` completely shuts down DDC**: When put into state `5`, the monitor cuts power to the HDMI DDC receiver and de-asserts Hot Plug Detect (HPD). macOS drops the display, and DDC wake is physically impossible.
3. **Value `4` is the only functional software sleep mode**: The panel and backlights shut down immediately, but the monitor maintains DDC power from the HDMI +5V rail. All DDC registers remain readable, and command `0xD6 = 1` wakes the monitor immediately.

Evidence files:
- State 5 test: `validation/hdmi-power-cycle-2026-10-20.json`
- State 4 test: `validation/hdmi-dpms-cycle-2026-10-20.json`

---

## 2. Analysis: The Mouse Movement Wake Problem

When sending DDC `0xD6 = 4` directly to the monitor:
- **The Issue**: Moving the mouse does not wake the monitor.
- **Root Cause**: The mouse is connected to the Mac (USB/Bluetooth), not to the monitor. When DDC `0xD6 = 4` is sent, macOS has no idea the monitor is asleep and continues streaming full 60/120 Hz HDMI video. Moving the mouse merely updates the cursor in the Mac's frame buffer without modifying the HDMI video clock. The monitor firmware is in an explicit DDC sleep override and ignores the ongoing video feed.

---

## 3. Implemented Solution Architecture

To achieve clean integration with Apple Home, hotkey/remote control, and automatic mouse-wake behavior:

### A. Native DDC Driver Safety (`Sources/NativeDDC/main.m`)
- Writing to VCP register `0xD6` is strictly bounded to values `1` (On) and `4` (DPMS Standby).
- Any attempt to write dangerous or unsupported values (such as `5`, `2`, `3`) is rejected with exit code 2.

### B. OpenDDPM Engine & Coordinator (`Engine.swift`, `Coordinator.swift`, `Core.swift`)
- `MonitorStatus` tracks live power: `power` (`1` vs `4`) and computed `isPoweredOn`.
- `statusOnce` continuously reads `0xD6`.
- `setPower(_ on: Bool, serial: String)` writes `0xD6 = 1` or `0xD6 = 4`.
- Auto-wake on preset change: applying any preset while the monitor is in state `4` automatically wakes the monitor first.

### C. Automatic Mouse/Keyboard Wake Watcher (`AppStore.swift`)
- While `isPoweredOn == false` (monitor in state `4`), `AppStore` runs a lightweight 250ms activity watcher using `CGEventSource.secondsSinceLastEventType`.
- No Accessibility or Input Monitoring permissions required.
- Debounced by 1.5 seconds after sleep to prevent the triggering click from waking the display.
- As soon as mouse motion, click, or keystroke is detected (`idle < 0.25s`), OpenDDPM automatically issues `0xD6 = 1` and stops the watcher.

### D. Apple Home / HomeKit Integration (`homekit/bridge.mjs`)
- `Television.Active` characteristic:
  - `onGet`: Returns `ACTIVE` (1) if powered on, `INACTIVE` (0) if in state 4.
  - `onSet`: Toggling power in the Home app calls `POST /power` (`active: true/false`).
  - Selecting an input/preset in the Home app automatically wakes the monitor if asleep and applies the layout.
  - `acceptStatus`: Live polling updates the accessory in Apple Home when the monitor changes state.

### E. User Interface (`Application.swift`, `RemoteView.swift`)
- Menu Bar item: *«Turn monitor off (Standby)»* / *«Turn monitor on»*.
- Preset Remote button: *Sleep / Wake* toggle with live moon/sun icon.

---

## 4. Verification & Automated Test Status

- **Unit tests**: `scripts/test.sh` passed (10 HomeKit health assertions, 4,204 core assertions, 32 coordinator assertions, native packet tests).
- **HomeKit tests**: `node --test homekit/bridge.test.mjs` passed (input mapping, power get/set, client authentication).
- **Universal Build**: `scripts/build.sh` built universal `arm64` + `x86_64` bundle.
- **Hardware test**: Verified live with Dell U4025QW via local API `POST /power` and Apple Home.
