#!/usr/bin/env python3
"""One-step U4025QW USB brightness test with mandatory restore/readback.

SPDX-License-Identifier: LGPL-2.1-or-later
Uses dell_usb_probe.py's transport; never writes input, layout, or power VCPs.
"""
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import dell_usb_probe as base

base.VCP[0x10] = "brightness"


class BrightnessProbe(base.Probe):
    def __init__(self):
        self.brightness_targets = frozenset()
        super().__init__()

    def send(self, frame):
        f = bytes(frame)
        if len(f) == base.SIZE and f[1] == 0xC6:
            payload = f[64:71]
            if payload[:3] == bytes.fromhex("51 84 03"):
                value = int.from_bytes(payload[4:6], "big")
                expected = bytearray(base.SIZE)
                expected[0] = 0x40
                expected[1] = 0xC6
                expected[6] = 7
                expected[8] = 0x6E
                expected[64:71] = payload
                if (payload[3] != 0x10 or value not in self.brightness_targets
                        or not 0 <= value <= 100 or f != expected
                        or base.checksum(payload, 0x6E) != 0):
                    raise ValueError("Blocked: only this transaction's brightness values may be written")
                count = self.dev.write(bytes([0]) + f)
                if count not in (base.SIZE, base.SIZE + 1):
                    raise RuntimeError(f"Short brightness write: {count}")
                return
        super().send(frame)

    def get_vcp(self, code):
        # The monitor can return a preceding register's reply during a burst.
        # Keep requests separated, reject mismatched replies, and retry reads only.
        for attempt in range(3):
            time.sleep(0.2)
            try:
                return super().get_vcp(code)
            except RuntimeError as exc:
                if "Invalid VCP reply" not in str(exc) or attempt == 2:
                    raise
                time.sleep(0.2)
        raise RuntimeError("VCP read retries exhausted")

    def set_brightness(self, value):
        self.handshake()
        payload = bytes((0x51, 0x84, 0x03, 0x10, value >> 8, value & 0xFF))
        payload += bytes((base.checksum(payload, 0x6E),))
        frame = bytearray(base.SIZE)
        frame[0] = 0x40
        frame[1] = 0xC6
        frame[6] = len(payload)
        frame[8] = 0x6E
        frame[64:71] = payload
        self.send(frame)
        time.sleep(0.15)

    def wait_brightness(self, expected):
        deadline = time.monotonic() + 3
        last = None
        while time.monotonic() < deadline:
            last = self.get_vcp(0x10)
            if last["current"] == expected:
                return last
            time.sleep(0.15)
        raise RuntimeError(f"Expected brightness {expected}; last readback: {last}")


def main():
    output = Path(__file__).resolve().parents[1] / "validation/usb-brightness-test-2026-10-20.json"
    output.parent.mkdir(exist_ok=True)
    record = {"timestamp": datetime.now(timezone.utc).isoformat(),
              "transport": "USB HID 0bda:1100", "write_vcp": "0x10",
              "write_attempts": 0, "restored": False}

    def save():
        output.write_text(json.dumps(record, indent=2) + "\n")

    probe = BrightnessProbe()
    attempted = False
    try:
        probe.start()
        record["before"] = {name: probe.get_vcp(code) for code, name in base.VCP.items()}
        brightness = record["before"]["brightness"]
        original, maximum = brightness["current"], brightness["maximum"]
        if not 1 <= maximum <= 100 or not 0 <= original <= maximum:
            raise RuntimeError(f"Unexpected brightness range: {brightness}")
        target = original + 1 if original < maximum else original - 1
        probe.brightness_targets = frozenset((original, target))
        record.update(original=original, target=target, maximum=maximum)
        save()  # Preserve recovery value before attempting a write.
        print(json.dumps({"original": original, "target": target, "maximum": maximum}), flush=True)
        try:
            attempted = True
            record["write_attempts"] += 1
            probe.set_brightness(target)
            record["changed_readback"] = probe.wait_brightness(target)
            save()
            print(json.dumps({"changed_readback": record["changed_readback"]}), flush=True)
        finally:
            if attempted:
                record["write_attempts"] += 1
                probe.set_brightness(original)
                record["restored_readback"] = probe.wait_brightness(original)
                record["restored"] = True
                save()
                print(json.dumps({"restored_readback": record["restored_readback"]}), flush=True)
        record["after"] = {name: probe.get_vcp(code) for code, name in base.VCP.items()}
        record["other_settings_unchanged"] = all(
            record["before"][name]["current"] == record["after"][name]["current"]
            for name in base.VCP.values() if name != "brightness")
        if not record["other_settings_unchanged"]:
            raise RuntimeError("A non-brightness register changed during the test")
        record["success"] = True
    except BaseException as exc:
        record["error"] = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        try:
            probe.close()
            record["session_closed"] = True
        finally:
            save()
    print(json.dumps(record, indent=2), flush=True)


if __name__ == "__main__":
    main()
