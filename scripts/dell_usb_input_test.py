#!/usr/bin/env python3
"""Swap DP/TB main input in PBP over USB, then restore full-screen DP.
SPDX-License-Identifier: LGPL-2.1-or-later
"""
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from dell_usb_layout_test import LayoutProbe, base


class InputProbe(LayoutProbe):
    def __init__(self):
        self.input_test_enabled = False
        super().__init__()

    def send(self, frame):
        f = bytes(frame)
        if len(f) == base.SIZE and f[1] == 0xC6:
            data = f[64:71]
            if data[:3] == bytes.fromhex('51 84 03'):
                value = int.from_bytes(data[4:6], 'big')
                expected = bytearray(base.SIZE)
                expected[0] = 0x40
                expected[1] = 0xC6
                expected[6] = 7
                expected[8] = 0x6E
                expected[64:71] = data
                allowed = {0x60: (0x0F, 0x19), 0xE9: (0, 0x24)}
                if (not self.input_test_enabled or value not in allowed.get(data[3], ())
                        or f != expected or base.checksum(data, 0x6E) != 0):
                    raise ValueError('Only DP/TB main and off/50-50 layout writes permitted')
                n = self.dev.write(bytes([0]) + f)
                if n not in (base.SIZE, base.SIZE + 1):
                    raise RuntimeError(f'Short input-test write: {n}')
                return
        super().send(frame)

    def set_main(self, value):
        self.handshake()
        data = bytes((0x51, 0x84, 3, 0x60, 0, value))
        data += bytes((base.checksum(data, 0x6E),))
        f = bytearray(base.SIZE)
        f[0] = 0x40
        f[1] = 0xC6
        f[6] = 7
        f[8] = 0x6E
        f[64:71] = data
        self.send(f)
        time.sleep(0.7)


def main():
    output = Path(__file__).resolve().parents[1] / 'validation/usb-input-test-2026-10-20.json'
    record = {'timestamp': datetime.now(timezone.utc).isoformat(),
              'transport': 'USB HID 0bda:1100', 'write_vcps': ['0xe9', '0x60'],
              'restored': False}

    def save():
        output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps(record, indent=2) + '\n')

    def checkpoint(name, state):
        record[name] = state
        save()
        print(json.dumps({name: state}), flush=True)

    probe = InputProbe()
    layout_attempted = False
    input_attempted = False
    try:
        probe.start()
        record['before'] = before = probe.snapshot()
        if (before['layout']['current'] != 0 or before['main_input']['current'] != 15
                or before['secondary_input']['current'] != 25):
            raise RuntimeError('Expected full DP with stored TB secondary; no writes sent')
        probe.input_test_enabled = True
        save()
        try:
            layout_attempted = True
            probe.set_layout(0x24)
            checkpoint('pbp_dp_main', probe.wait_layout(0x24, 15, 25))
            input_attempted = True
            probe.set_main(25)
            checkpoint('pbp_thunderbolt_main', probe.wait_layout(0x24, 25, 15))
            time.sleep(2)
        finally:
            if layout_attempted:
                # Return DP to main before disabling the split. If restoring the
                # main input fails, retain PBP so DP has a visible region.
                if input_attempted:
                    probe.set_main(15)
                checkpoint('pbp_dp_restored', probe.wait_layout(0x24, 15, 25))
                probe.set_layout(0)
                checkpoint('full_dp_restored', probe.wait_layout(0, 15, 25))
                record['restored'] = True
                save()
        record['after'] = after = probe.snapshot()
        record['all_current_values_restored'] = all(before[k]['current'] == after[k]['current'] for k in before)
        if not record['all_current_values_restored']:
            raise RuntimeError('Final values differ from original snapshot')
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
    print(json.dumps({'success': record['success'], 'restored': record['restored'],
                      'all_current_values_restored': record['all_current_values_restored']}), flush=True)


if __name__ == '__main__':
    main()
