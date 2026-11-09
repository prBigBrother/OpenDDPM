# ESP32 BT Wakeup

ESP-IDF 5.5.x firmware for the ESP32-D0WD-V3 board. The local web UI is at
http://bt-wakeup.local, with no authentication as requested for this LAN test.
Firmware version: `2026-10-21-retry-5`.

## Web interface

The UI is in English, with a main Wake all action and individual device cards.
Saved disconnected Macs stay visible. The firmware reads the Mac's actual BLE
Device Name (0x2A00) after the encrypted HID link is ready, using a long read for
UTF-8 names. Discovered names are cached in a separate `peer_names` NVS namespace,
keyed by bond identity address and type; unchanged names do not rewrite flash.
An unavailable name never blocks wake or replaces a previously cached name.
Name priority: browser Rename override, live/cached BLE name, short address.
Diagnostics reports live lookup status and whether a cached name is being shown. Rename stores an alias per Bluetooth
address in this browser only (localStorage); it does not change ESP bond records.
Pair a Mac / Finish pairing controls the pairing mode. Technical key and radio
status is available under Diagnostics. Network failures disable wake controls
until a fresh state is received. The page requires no external assets.

## Controls

- BOOT (GPIO0): five Left Shift press/release pairs to all ready connected Macs.
- Web: individual wake and **Разбудить всех**, plus open/close pairing.
- Presses start 500 ms apart; each key is held for approximately 100 ms.
- A ready Mac has a live encrypted bonded connection and an active subscription
  to the HID input report. Saved pairing alone is not an active connection.
- The central gets one second to restore encryption before the ESP requests it.
  A failed redundant security procedure does not terminate an already encrypted link.
- Only one wake sequence runs at a time. Disconnect/reconnect invalidates its
  target even if the controller reuses the same handle or slot. Generation numbers
  start from a random boot seed so an old browser target is also invalid after reboot.
- Pairing starts closed after power-on/reset. There is no expiry timer. An internal
  BLE host reset preserves the current pairing mode. The UI shows the last mode
  change reason, uptime, boot reason, advertising error and last command result.
- The bond store has two slots. Full storage rejects new records instead of
  silently deleting another Mac. Re-pairing may replace only the requesting
  peer's bond while pairing is explicitly open. There is no erase-all endpoint.

## Configuration and build

Copy `main/wifi_config.example.h` to ignored `main/wifi_config.h` and configure
2.4 GHz Wi-Fi. Existing local credentials must be preserved. The header is
required at build time; credentials are compiled into the private firmware image.

```sh
idf.py build
idf.py -p /dev/cu.usbserial-210 app-flash
```

Use `app-flash` to update only the application. Do not erase NVS: it contains
BLE encryption and identity keys and notification subscriptions. The board uses
4 MB flash and the single large application partition. This layout has no OTA
rollback. `prebuilt/bt_wakeup.bin` is the private image built for this local
configuration. It contains Wi-Fi credentials and is excluded from Git.

## Implementation

All BLE operations and mutable BLE state are owned by the NimBLE host task.
CCCD subscriptions restored before CONNECT are held by handle until that connection
is registered, then cleared on disconnect/reset to prevent reuse.
HTTP and BOOT submit bounded commands; HTTP reads a locked complete snapshot.
Advertising restart runs in a separate delayed host event after advertising stop.
Advertising errors are reported and retried after one second. Full connection
capacity is displayed separately from an advertising failure.

Wake uses one host callout for both presses and releases, without per-key tasks.
Every report revalidates the connection generation, encryption and subscription.
If a release fails, it is retried; if that also fails, the link is terminated.
Success counters mean accepted by the BLE stack, not proof a sleeping Mac woke.

HID is Report-only, with RemoteWake and NormallyConnectable flags set. Protocol
Mode and unsupported Boot Keyboard Input are omitted. Service Changed is marked
on host synchronization so previously bonded clients can rediscover the updated
attribute table. The existing Service Changed handles stay before HID. If a host
ignores Service Changed and retains the old report handle, it will remain not
ready; a one-time re-pair may be needed on that host.

Identity and encryption key distribution is enabled in both directions. The UI
shows presence of LTK and peer IRK, never key bytes. Legacy bonds created before
key distribution was enabled cannot gain missing IRKs without a new pairing.
Missing IRK was observed on both old records; it does not by itself prove every
past reconnection failure was caused by private address rotation.

HTTP and mDNS initialization is idempotent across Wi-Fi reconnection. HTTP checks
allocation/startup/route errors; Wi-Fi configuration uses RAM storage to avoid
rewriting credentials in NVS on every start. Existing NVS data is not erased.
The page polls without overlapping requests, handles network/API errors, disables
stale controls and binds commands to a connection generation. POST returns 202
for queue acceptance; `/api/status` reports execution outcome.

## Verification

```sh
python3 tests/check_api.py --base http://bt-wakeup.local --expect-ready 2
python3 tests/check_api.py --base http://bt-wakeup.local --pairing
# Sends five Shift taps to all ready devices:
python3 tests/check_api.py --base http://bt-wakeup.local --wake
```

The default checks validate status, malformed target rejection and stale
connection protection. `--pairing` restores the initial pairing mode afterward.
The physical acceptance check is: put both Macs to sleep, press BOOT once, and
confirm both wake. Repeat after an ESP power cycle. BLE peripherals advertise;
the Mac must initiate reconnection before a wake report can be delivered.
Do not hold BOOT during power-on/reset: GPIO0 selects bootloader mode.

## Connection retry

When a saved Mac is disconnected and pairing is closed, refresh connectable
whitelist advertising every 30 seconds. Each refresh stops advertising, waits
200 ms in a separate host event, and resumes at the normal 20 ms interval.
It does not restart the host/controller, disconnect another Mac, erase bonds,
open pairing, or send keyboard input. Retries pause during a wake sequence
and stop when all saved peers are connected. A disconnected card offers
Retry connection (`POST /api/reconnect`) for the same immediate refresh.

This is an advertising refresh, not a peripheral-initiated connection. macOS
must still initiate the BLE link. A full ESP reboot has other effects, so the
refresh is not yet proven to reproduce recovery from the observed sleep issue.

Diagnostics exposes retry count, next delay, last attempt, and failures. Each
bond records disconnect reason, uptime at disconnect, and count in RAM for this
boot. These records are matched by identity across bond-list refreshes.

`python3 tests/check_retry_policy.py` compiles the actual firmware policy with
stubbed radio/clock functions and checks timing, gating, and preservation of
existing connection handles. The device integration check requires a saved Mac
to be disconnected: verify attempts increase after 30s, advertising resumes,
and the other Mac retains its connection generation. A successful recovery from
the original sleep failure still requires a real sleep/wake test.
