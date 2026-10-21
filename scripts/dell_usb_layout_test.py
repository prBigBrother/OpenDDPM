#!/usr/bin/env python3
"""Bounded Dell USB PiP/PBP test; writes layout only, then restores it.
SPDX-License-Identifier: LGPL-2.1-or-later
"""
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from dell_usb_brightness_test import BrightnessProbe, base


class LayoutProbe(BrightnessProbe):
    def __init__(self):
        self.layout_targets = frozenset()
        super().__init__()

    def send(self, frame):
        f = bytes(frame)
        if len(f) == base.SIZE and f[1] == 0xC6:
            payload = f[64:71]
            if payload[:3] == bytes.fromhex('51 84 03'):
                value = int.from_bytes(payload[4:6], 'big')
                expected = bytearray(base.SIZE)
                expected[0] = 0x40
                expected[1] = 0xC6
                expected[6] = 7
                expected[8] = 0x6E
                expected[64:71] = payload
                if (payload[3] != 0xE9 or value not in self.layout_targets
                        or value not in (0, 0x24, 0x2A, 0x29, 0x21, 0x22)
                        or f != expected or base.checksum(payload, 0x6E) != 0):
                    raise ValueError('Only captured original/target layout writes permitted')
                count = self.dev.write(bytes([0]) + f)
                if count not in (base.SIZE, base.SIZE + 1):
                    raise RuntimeError(f'Short layout write: {count}')
                return
        super().send(frame)

    def set_layout(self, value):
        self.handshake()
        payload = bytes((0x51, 0x84, 3, 0xE9, value >> 8, value & 255))
        payload += bytes((base.checksum(payload, 0x6E),))
        frame = bytearray(base.SIZE)
        frame[0] = 0x40
        frame[1] = 0xC6
        frame[6] = 7
        frame[8] = 0x6E
        frame[64:71] = payload
        self.send(frame)
        time.sleep(0.7)

    def snapshot(self):
        return {name: self.get_vcp(code) for code, name in base.VCP.items()}

    def wait_layout(self, value, main, secondary):
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            try:
                last = {name: self.get_vcp(code) for code, name in
                        ((0xE9, 'layout'), (0x60, 'main_input'), (0xE8, 'secondary_input'))}
                if (last['layout']['current'] == value
                        and last['main_input']['current'] == main
                        and last['secondary_input']['current'] == secondary):
                    return last
            except (RuntimeError, OSError) as exc:
                last = {'error': str(exc)}
            time.sleep(0.4)
        raise RuntimeError(f'Layout did not settle; last readback: {last}')


def main():
    output = Path(__file__).resolve().parents[1] / 'validation/usb-layout-test-2026-10-20.json'
    record = {'timestamp': datetime.now(timezone.utc).isoformat(),
              'transport': 'USB HID 0bda:1100', 'write_vcp': '0xe9',
              'write_attempts': 0, 'restored': False}

    def save():
        output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps(record, indent=2) + '\n')

    probe = LayoutProbe()
    try:
        probe.start()
        record['before'] = before = probe.snapshot()
        original = before['layout']['current']
        main = before['main_input']['current']
        secondary = before['secondary_input']['current']
        if main != 0x0F or secondary not in (0x11, 0x19):
            raise RuntimeError('Expected DP main and a distinct HDMI/Thunderbolt secondary; no write sent')
        if original not in (0, 0x24, 0x2A, 0x29, 0x21, 0x22):
            raise RuntimeError('Unknown original layout; no write sent')
        target = 0x2A if original == 0x24 else 0x24
        probe.layout_targets = frozenset((original, target))
        record.update(original=original, target=target)
        save()
        print(json.dumps({'original': original, 'target': target, 'main': main, 'secondary': secondary}), flush=True)
        try:
            record['write_attempts'] += 1
            probe.set_layout(target)
            record['changed_readback'] = probe.wait_layout(target, main, secondary)
            save()
            print(json.dumps({'changed_readback': record['changed_readback']}), flush=True)
            time.sleep(2)
        finally:
            record['write_attempts'] += 1
            probe.set_layout(original)
            record['restored_readback'] = probe.wait_layout(original, main, secondary)
            record['restored'] = True
            save()
            print(json.dumps({'restored_readback': record['restored_readback']}), flush=True)
        record['after'] = after = probe.snapshot()
        record['all_current_values_restored'] = all(before[k]['current'] == after[k]['current'] for k in before)
        if not record['all_current_values_restored']:
            raise RuntimeError('Final state differs from original snapshot')
        record['success'] = True
    except BaseException as exc:
        record['error'] = f'{type(exc).__name__}: {exc}'
        raise
    finally:
        try:
            probe.close()
            record['session_closed'] = True
        finally:
            save()
    print(json.dumps(record, indent=2), flush=True)


if __name__ == '__main__':
    main()
