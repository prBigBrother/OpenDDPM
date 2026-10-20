<p align="center"><img src="assets/logo.png" width="128" alt="OpenDDPM icon"></p>
<h1 align="center">OpenDDPM</h1>
<p align="center">Your screen. Your way.<br>A native Mac menu bar app for Dell monitor inputs and split layouts.</p>
<p align="center"><a href="https://github.com/prBigBrother/OpenDDPM/releases/latest">Download the latest release</a> · <a href="LICENSE">MIT license</a></p>

Pick a workspace from the menu bar. Create and edit presets in a separate native
configuration window. OpenDDPM applies the monitor's real Picture-by-Picture or
Picture-in-Picture layout and assigns each video source to the correct region.

## Features

- Compact preset remote: click the menu bar icon or press Control–Option–Space.
- Latest selection wins: change your target while switching without overlapping monitor commands.
- Adaptive readiness checks, a bounded transition deadline, and a local timing journal.
- Previous verified preset and explicit retry verification.
- Apple Shortcuts URLs and authenticated loopback automation API.
- Optional local HomeKit television with preset inputs and scene buttons.
- Global hotkeys: record, change, or clear a shortcut for each preset on the Hotkeys page.
- Standalone native DDC/CI driver; no external monitor-control app required.
- Menu bar access to every saved preset, current status, and configuration.
- Visual preset editor: full screen, 50/50, 75/25, 25/75, and small/large PIP.
- DisplayPort, HDMI, and Thunderbolt input assignment.
- First-run setup discovers monitors and identifies this Mac's physical input.
- **Keep this Mac visible** blocks presets that would hide its input by default.
- Automatic configuration persistence, preset import/export, and launch at login.
- Applies only changed settings: matching presets send no writes, and layout-only changes send one layout write.
- Monitor readback verifies the resulting layout when this Mac stays visible.
- Universal binary for Apple Silicon and Intel; no Python or Homebrew required.

## Download and install

1. Download the DMG or ZIP from the [release page](https://github.com/prBigBrother/OpenDDPM/releases/latest).
2. Drag **OpenDDPM.app** to **Applications**.
3. Open OpenDDPM and use **Monitor & inputs** to discover the monitor, select the
   cable connected to this Mac, and confirm it.
4. Pick a preset from the menu bar or create your own in the configuration window.

**Release signing:** this release is ad-hoc signed and is not Apple notarized.
macOS may block a downloaded copy on first launch. After attempting to open it,
use **System Settings → Privacy & Security → Open Anyway** and confirm. Do not
disable Gatekeeper. Developer ID signing/notarization can be added when an Apple
Developer certificate is available.

## Native monitor control and hotkeys

OpenDDPM includes its own small DDC/CI driver. Apple Silicon uses IOAVService;
Intel uses IOI2CInterface. Neither transport needs another monitor-control app,
a paid license, Accessibility permission, or Input Monitoring permission.
The Apple Silicon discovery/transport implementation credits the MIT-licensed
[m1ddc](https://github.com/waydabber/m1ddc) project. See the bundled
[notice](Vendor/NativeDDC/NOTICE.md) for attribution and API limitations.

Open **Hotkeys**, click **Record…** beside a preset, then press a combination
with Command, Control, or Option. Escape cancels; **Clear** removes a binding.
Shortcuts work while another app has focus, as long as OpenDDPM is running.
Duplicate bindings are rejected and macOS registration conflicts are shown.
Presets blocked by **Keep this Mac visible** also have their hotkeys disabled.
Bindings are saved with your presets and included in preset export/import.

## Monitor support and switching behavior

The app is designed and hardware-tested with **Dell U4025QW**. Other
monitors may use different vendor-specific layout codes and are not yet supported
as validated models. Enable **DDC/CI** in the monitor's on-screen menu.

Each Mac has its own input assignment. OpenDDPM suggests the local connection
when reported by the monitor, but asks you to confirm the physical cable. Setup
does not switch the display. Preset export/import transfers layouts without
overwriting the second Mac's monitor/input setup.

Transitions wait for monitor readback instead of sleeping four seconds after every
write. A single coordinator owns all UI, hotkey and automation requests. A new
selection replaces the pending target; the current hardware operation finishes
before the next target is planned from actual state. Readiness checks and helper
calls share a 25-second transition deadline. Monitor firmware and macOS display
rediscovery still determine the physical switching time.

The remote distinguishes selected, applying, verified and unverified states.
A hidden Mac input is explicitly unverified. **Previous preset** returns to the
last confirmed preset when the control channel is available. The local journal
at `~/Library/Logs/OpenDDPM/transitions.jsonl` records request IDs, the write plan,
I/O timings and readback; it rotates at 2 MB.

If you turn off **Keep this Mac visible**, an excluding preset prepares all writes
while retaining the local input, then hides this Mac with its final write. It
cannot promise readback or switching back over the now-hidden video connection.
Returning may require the monitor joystick or an independent USB control path.

## Build from source

Requirements: macOS and Apple's Command Line Tools, or Xcode, with Swift 5.9+.
The build has no package-manager or network dependencies. Native driver source
and its third-party license notices are included in this repository.

```sh
xcode-select --install  # if Apple's tools are not already installed
git clone https://github.com/prBigBrother/OpenDDPM.git
cd OpenDDPM
./scripts/test.sh
./scripts/build.sh
./scripts/package.sh
```

Outputs:

- `build/OpenDDPM.app` — universal, ad-hoc signed app.
- `dist/OpenDDPM-0.3.0-universal.dmg` — drag-to-Applications installer.
- `dist/OpenDDPM-0.3.0-universal.zip` — portable application bundle.
- `dist/SHA256SUMS.txt` — asset checksums.

Set `VERSION=…` when building a new version. To sign with Developer ID, set
`SIGNING_IDENTITY="Developer ID Application: …"` before building; notarize the
result using your own Apple credentials. No signing credentials are in this repo.

For a read-only native-driver smoke test:

```sh
build/OpenDDPM.app/Contents/MacOS/OpenDDPM --diagnose
```

The GitHub Actions workflow builds both architectures and runs core and packet-validation tests.
Apple Silicon DDC control has been tested on a U4025QW. The Intel transport is
compiled and packaged, but has not yet been verified on physical Intel hardware.

## Configuration and privacy

Settings live at `~/Library/Application Support/OpenDDPM/configuration.json`.
OpenDDPM discovers your monitor locally, stores your presets on your Mac, and
does not upload configuration or monitor identifiers. Release/source links open
in your browser. No account, telemetry, or remote service is required for control.

## License and credits

OpenDDPM is [MIT licensed](LICENSE). Native driver attribution and the upstream
MIT license are included under [Vendor/NativeDDC](Vendor/NativeDDC/NOTICE.md).
The generated icon's source and prompt are included under `assets/`.
OpenDDPM is independent software and is not affiliated with Dell.

## Apple Shortcuts and scripting

Right-click a preset in the remote and choose **Copy Apple Shortcuts URL**. Use
that URL with the **URL** and **Open URLs** actions in Apple Shortcuts. URLs have
the form `openddpm://apply?id=PRESET-UUID`; they launch the app when needed.
`openddpm://remote` opens the remote and `openddpm://previous` selects the previous
confirmed preset. Opening a URL acknowledges dispatch, not hardware verification.

With OpenDDPM running:

```sh
APP=/Applications/OpenDDPM.app/Contents/MacOS/OpenDDPM
"$APP" --list-presets
"$APP" --status
"$APP" --apply 'PRESET-UUID-OR-UNIQUE-NAME' --wait
"$APP" --previous --wait
"$APP" --remote
```

`--wait` follows that exact request. Exit codes: 0 verified, 1 failed or unavailable,
3 sent but unverified (Mac hidden), 4 superseded by a newer request. A missing
`--wait` returns an accepted request ID immediately. `--status` requests fresh
readback; its `observedAt` field is absent when the state cannot be confirmed.

The API binds only to `127.0.0.1:57571`. Its bearer credential is stored with mode
0600 at `~/Library/Application Support/OpenDDPM/control.json`. Do not share or
commit that file. Commands: `GET /presets`, `GET /status`, `POST /apply` with
`{"preset":"UUID"}`, `GET /requests/UUID`, `POST /previous`, `POST /refresh`, and
`POST /remote`. Status is cached; refresh is queued through the same coordinator.
Request receipts retain the latest 100 requests for the current app session.

## Apple Home

Open **Configure OpenDDPM → Apple Home & Shortcuts → Install & start**. The optional
bridge uses an existing Node.js 22, 24 or 26 runtime and downloads pinned npm
dependencies. The native monitor app itself still needs no Node.js or Homebridge.

On iPhone, use **Home → + → Add Accessory** to scan the Monitor QR code displayed
in settings. Its inputs select whole OpenDDPM presets. Add the optional Scenes
QR code to expose one momentary switch per preset for scenes and automations.
HomeKit uses standard local HAP pairing. No pairing code is sent to a cloud
service. Pairing data stays in the local application support directory.

Monitor works independently of Scenes. For a Monitor-only installation, remove
Scenes in Apple Home and set `"publishScenes": false` in the local
`~/Library/Application Support/OpenDDPM/homekit/settings.json`, then restart the
HomeKit service. This preserves Monitor's identity and pairing; the Scenes QR
code is hidden and the Scenes bridge is no longer published. This preference
survives service reinstallations.

The bridge starts at login. **Stop** removes its login service but preserves
pairings. The Mac must be awake, OpenDDPM must be running, and its DDC control
channel must survive the selected layout. An independent USB controller is not
implemented in this version. Monitor power commands are unsupported; the TV
accessory exists for selecting presets. Unverified or unavailable monitor state
is reported as unavailable rather than confirmed.

HomeKit source and tests live in `homekit/`. To verify them with supported Node:

```sh
npm ci --prefix homekit --ignore-scripts
node --test homekit/bridge.test.mjs
```
