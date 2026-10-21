# Dell U4025QW: HDMI DDC Power & DPMS Control (VCP 0xD6)

Date: 2026-10-20, Europe/Chisinau.

Two distinct power states were tested on hardware over the native HDMI DDC channel (IOAVService):
1. **Soft Power Off (`VCP 0xD6 = 5`)**
2. **DPMS Off / Standby (`VCP 0xD6 = 4`)**

---

## 1. Test: Soft Power Off (`0xD6 = 5`)

- **Command sent**: `0xD6 = 5`
- **Immediate effect**: Panel turned off, backlights turned off, HDMI Hot Plug Detect (HPD) de-asserted.
- **DDC reachability while off**: Failed (`read_while_off_ok: false`). Monitor dropped off `CGGetOnlineDisplayList`.
- **Wake-up via DDC (`0xD6 = 1`)**: Failed across 6 attempts (`on_readback_verified: false`).
- **Conclusion**: In state `5`, internal scaler and DDC/I2C receiver are completely powered down. DDC cannot wake the monitor. Manual press of physical power button was required.
- **Evidence**: `validation/hdmi-power-cycle-2026-10-20.json`.

---

## 2. Test: DPMS Standby (`0xD6 = 4`)

- **Command sent**: `0xD6 = 4`
- **Immediate effect**: Screen goes dark / enters Standby mode.
- **DDC readback while in Standby**:
  - Raw packet reply received: `6e 88 02 00 d6 00 00 05 00 04 63`
  - Valid checksum `0x63`, confirms current value = `4` (Standby).
- **Sustained Standby duration**: 10 seconds.
- **Wake-up via DDC (`0xD6 = 1`)**:
  - Sent wake command `0xD6 = 1` over retained HDMI DDC IOAVService.
  - **Attempt 1**: Received valid readback: `6e 88 02 00 d6 00 00 05 00 01 66`
  - Verified current power value = `1` (Active / On).
  - Screen instantly woke up and returned to active display.
- **Evidence**: `validation/hdmi-dpms-cycle-2026-10-20.json`.

---

## Conclusion

| Режим | Код VCP | Выключение экрана | Пробуждение по HDMI DDC (`0xD6 = 1`) | Состояние DDC шины |
|---|---|---|---|---|
| **Soft Power Off** | `0xD6 = 5` | Да (полное) | **НЕТ** (требуется физическая кнопка) | Обесточена / HPD Low |
| **DPMS Standby** | `0xD6 = 4` | Да (спящий режим) | **ДА (мгновенно, с 1-й попытки)** | Активна |

**Итог:** Управление питанием (выключение и включение) через HDMI DDC **полностью работает**, если использовать режим **`VCP 0xD6 = 4` (DPMS Standby)** вместо жесткого `5`.
