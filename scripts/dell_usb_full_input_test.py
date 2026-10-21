#!/usr/bin/env python3
"""Full-screen DP -> Thunderbolt -> DP, using USB only.
SPDX-License-Identifier: LGPL-2.1-or-later
"""
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from dell_usb_input_test import InputProbe, base


class FullInputProbe(InputProbe):
    def send(self, frame):
        f = bytes(frame)
        if (len(f) == base.SIZE and f[1] == 0xC6
                and f[64:67] == bytes.fromhex('51 84 03') and f[67] != 0x60):
            raise ValueError('This test may write main input only')
        super().send(frame)

    def wait_full(self, main):
        last = None
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            try:
                last = {'layout': self.get_vcp(0xE9), 'main_input': self.get_vcp(0x60)}
                if last['layout']['current'] == 0 and last['main_input']['current'] == main:
                    return last
            except (RuntimeError, OSError) as exc:
                last = {'error': str(exc)}
            time.sleep(.3)
        raise RuntimeError(f'Full-screen readback failed: {last}')


def main():
    output = Path(__file__).resolve().parents[1] / 'validation/usb-full-input-test-2026-10-20.json'
    record = {'timestamp': datetime.now(timezone.utc).isoformat(),
              'transport': 'USB HID 0bda:1100', 'write_vcp': '0x60',
              'restored': False, 'reconnect_attempts': 0}

    def save():
        output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps(record, indent=2) + '\n')

    probe = FullInputProbe()
    attempted = False
    try:
        probe.start()
        record['before'] = before = probe.snapshot()
        if before['layout']['current'] != 0 or before['main_input']['current'] != 15:
            raise RuntimeError('Expected full-screen DP; no write sent')
        if before['secondary_input']['current'] != 25:
            raise RuntimeError('Expected stored TB secondary for bounded restoration')
        probe.input_test_enabled = True
        save()
        try:
            attempted = True
            probe.set_main(25)
            record['full_thunderbolt_readback'] = probe.wait_full(25)
            record['usb_available_with_dp_excluded'] = True
            save()
            print(json.dumps({'full_thunderbolt_readback': record['full_thunderbolt_readback']}), flush=True)
            time.sleep(2)
        finally:
            if attempted:
                restore_error = None
                for attempt in range(4):
                    try:
                        if attempt:
                            record['reconnect_attempts'] += 1
                            try:
                                probe.active = False
                                probe.dev.close()
                            except Exception:
                                pass
                            time.sleep(.5)
                            probe = FullInputProbe()
                            probe.start()
                            probe.input_test_enabled = True
                        probe.set_main(15)
                        record['full_dp_restored'] = probe.wait_full(15)
                        record['restored'] = True
                        save()
                        print(json.dumps({'full_dp_restored': record['full_dp_restored']}), flush=True)
                        break
                    except (RuntimeError, OSError) as exc:
                        restore_error = exc
                        record['restore_last_error'] = str(exc)
                        save()
                if not record['restored']:
                    raise RuntimeError(f'USB restore failed; select DP with monitor joystick: {restore_error}')
        record['after'] = after = probe.snapshot()
        record['all_current_values_restored'] = all(before[k]['current'] == after[k]['current'] for k in before)
        if not record['all_current_values_restored']:
            raise RuntimeError('Final current values differ from initial snapshot')
        record['success'] = True
    except BaseException as exc:
        record['error'] = f'{type(exc).__name__}: {exc}'
        raise
    finally:
        try:
            probe.close()
            record['session_closed'] = True
        except Exception as close_error:
            record['session_close_error'] = str(close_error)
        finally:
            save()
    print(json.dumps({'success': record['success'], 'restored': record['restored'],
                      'usb_available_with_dp_excluded': record['usb_available_with_dp_excluded'],
                      'reconnect_attempts': record['reconnect_attempts'],
                      'all_current_values_restored': record['all_current_values_restored']}), flush=True)


if __name__ == '__main__':
    main()
