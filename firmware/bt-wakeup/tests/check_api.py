#!/usr/bin/env python3
"""Live regression checks. --pairing toggles pairing; --wake sends five Shift taps."""
import argparse
import json
import time
import urllib.error
import urllib.request

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base', default='http://bt-wakeup.local')
p.add_argument('--pairing', action='store_true')
p.add_argument('--wake', action='store_true')
p.add_argument('--reconnect', action='store_true')
p.add_argument('--expect-ready', type=int, choices=(0, 1, 2), default=None)
a = p.parse_args()
base = a.base.rstrip('/')

def api(path, post=False):
    req = urllib.request.Request(base + path, method='POST' if post else 'GET')
    try:
        with urllib.request.urlopen(req, timeout=6) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)

def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print('PASS:', message)

def wait_for(predicate, seconds=6):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        _, state = api('/api/status')
        if predicate(state):
            return state
        time.sleep(.08)
    raise AssertionError('Timed out waiting for state transition')

if a.expect_ready is not None:
    wait_for(lambda s: sum(d['ready'] for d in s['devices']) == a.expect_ready)
    print('PASS: Expected HID devices are ready:', a.expect_ready)
code, initial = api('/api/status')
check(code == 200 and initial['ble_ready'], 'BLE status is available')
check(initial['firmware'] == '2026-10-21-retry-5', 'Correct firmware is running')
check(len(initial['paired']) == len(initial['bonds']), 'Bond summaries agree')
check(all(isinstance(b['name'], str) for b in initial['bonds']), 'Bond cache exposes device names')
check(all(isinstance(d['name'], str) and d['name_status'] in ('pending', 'available', 'unavailable') for d in initial['devices']), 'Live BLE name lookup status is valid')
check(all(d['ready'] == (d['encrypted'] and d['bonded'] and d['subscribed'])
          for d in initial['devices']), 'HID readiness reflects encryption and subscription')
for query in ('', '?id=oops', '?id=-1', '?id=2', '?id=0junk',
              '?id=0', '?id=0&generation=-1', '?id=0&generation=4294967296'):
    code, body = api('/api/wake' + query, True)
    check(code == 400 and 'error' in body, 'Invalid wake target is rejected: ' + (query or '(missing)'))
code, body = api('/api/wake?id=0&generation=0', True)
check(code == 409 and body['error'] == 'connection_changed', 'Stale connection cannot receive wake')
check(initial['reconnect_interval_s'] == 30, 'Automatic retry interval is 30s')
check(all('last_disconnect_s' in b and 'disconnect_reason' in b for b in initial['bonds']), 'Per-device disconnect diagnostics available')
if a.reconnect:
    code, body = api('/api/reconnect', True)
    connected = {d['address']: d['generation'] for d in initial['devices']}
    if len(connected) == len(initial['bonds']):
        check(code == 409 and body['error'] == 'already_connected', 'Retry is a no-op when all saved Macs are connected')
    else:
        check(code == 202 and body['accepted'], 'Missing-peer retry accepted')
        updated = wait_for(lambda s: s['reconnect_attempts'] > initial['reconnect_attempts'])
        time.sleep(.5)
        _, updated = api('/api/status')
        active = {d['address']: d['generation'] for d in updated['devices']}
        check(all(active.get(address) == generation for address, generation in connected.items()), 'Advertising retry preserves active connection generations')
        check(set(updated['paired']) == set(initial['paired']), 'Retry preserves all bonds')
if a.pairing:
    old = initial['pairing']
    try:
        for path, expected in (('/api/pair', True), ('/api/stop', False)):
            code, body = api(path, True)
            check(code == 202 and body['accepted'], 'Pairing command returns queued acceptance')
            state = wait_for(lambda s: s['pairing'] == expected)
            check(set(state['paired']) == set(initial['paired']), 'Pairing toggle preserves both bonds')
        if len(initial['devices']) < 2:
            state = wait_for(lambda s: s['advertising'] or not s['paired'])
            check(not state['advertising_error'], 'Advertising restarts after closing pairing')
    finally:
        api('/api/pair' if old else '/api/stop', True)
        wait_for(lambda s: s['pairing'] == old)
if a.wake:
    targets = sum(d['ready'] for d in initial['devices'])
    check(targets > 0, 'At least one HID target is ready')
    code, body = api('/api/wake?id=all', True)
    check(code == 202 and body['accepted'], 'Wake-all accepted')
    wait_for(lambda s: s['wake_busy'])
    code, body = api('/api/wake?id=all', True)
    check(code == 409 and body['error'] == 'wake_busy', 'Overlapping wake is rejected')
    done = wait_for(lambda s: not s['wake_busy'] and s['last_result'].startswith('Wake finished'))
    check(f'presses={5*targets} releases={5*targets} errors=0' in done['last_result'],
          'Exactly five press/release pairs per ready device reached the BLE stack')
print('All selected checks passed. Physical sleep/wake requires a separate test.')
