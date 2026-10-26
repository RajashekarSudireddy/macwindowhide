# MacWindowHide

A native menu bar utility for preparing a Mac screen before a recording or call, then restoring the changes it made. Includes Recording Mode, backdrops, menu bar shelves and fourteen controls.

Requires macOS 15 or later. The universal application contains Apple silicon and Intel code. The implementation uses Swift 6, SwiftUI, AppKit, CoreAudio, IOBluetooth and small runtime-checked Objective-C compatibility bridges.

For development in this source checkout, start with [AGENTS.md](AGENTS.md) and the current-state snapshot in [HANDOFF.md](HANDOFF.md). [ARCHITECTURE.md](ARCHITECTURE.md) explains the module boundaries, control flow, persistence, and platform integrations.

## Build and install

Use Xcode 27.1 or a later compatible toolchain (the pinned KeyboardShortcuts package requires Swift tools 6.2).

```sh
./scripts/build.sh
./scripts/test.sh
python3 scripts/test_quit.py
./scripts/package.sh
./scripts/verify-package.sh
```

Outputs:

- `build/Products/MacWindowHide.app`
- `build/Products/MacWindowHide.dmg`
- `build/Products/SHA256SUMS.txt`

Open the DMG, drag the application into Applications, then launch it. The app lives in the menu bar. On macOS 27, use an installed Applications copy for menu bar visibility testing; private system matching can behave differently for DerivedData builds. If its icon is absent, enable MacWindowHide in System Settings → Menu Bar.

Open `MacWindowHide.xcodeproj` to develop in Xcode. `scripts/generate_project.py` deterministically regenerates project membership after adding sources; it needs only Python's standard library. KeyboardShortcuts 3.1.0 is vendored locally, so package resolution does not download dependencies.

Build caches and the signed app bundle live in `/private/tmp/MacWindowHideBuild-<uid>`; the Products app path is a symlink. This avoids cloud-synced Documents attaching Finder metadata that invalidates signatures. The DMG is the durable installer; install its app into Applications. Set `MWH_DERIVED_DATA_DIR` to override the build location.

The personal build is ad-hoc signed and is not notarized. It is intended for this Mac, not general public distribution. An available Developer ID may be supplied through `MWH_SIGNING_IDENTITY` when building. Notarization, hosted updates, licensing, marketing and translations are outside this edition.

## Daily use

- Click the menu bar icon for the control panel. Option-click starts/restores Recording Mode.
- The default global shortcut is Control–Option–Command–R. Record different shortcuts in Settings → Shortcuts.
- Recording Mode checks its selected controls before making changes. Missing setup blocks Start and names the required step; deselect any unwanted action in Settings → Recording Mode.
- Default actions: desktop cover, backdrop, hide other apps, Dock, menu icons, keep awake and mute alerts.
- Optional countdown: three seconds. Recording time limits and “+15m” restore the changes when the deadline arrives.
- Configure the menu's switch groups, drag order, automatic-off defaults, backgrounds and recorder exclusions in Settings.
- Keep Awake supports durations, a clock time, indefinite use, and extensions. It does not prevent explicit Sleep or lid-close sleep.
- Screen Saver is an immediate action; keyboard locking has a short safety timeout and a mouse unlock control.

The app does not detect screen sharing automatically or record your screen. App Intents supply Recording Mode and individual control actions to Shortcuts and Siri.

## Setup and permissions

Permissions are requested by explicit setup actions, not automatically at launch:

- **Accessibility:** menu bar organization and keyboard filtering.
- **Automation → System Events:** Dock, whole menu bar and system appearance.
- **Bluetooth:** selected, already-paired headphones. Pair them in System Settings before choosing them in the app.

No Screen Recording or microphone recording access is required. The microphone control adjusts hardware properties and does not capture audio.

In Settings → Permissions, **Allow System Events control** requests Automation access and reports the result. If access was previously denied, use **Open Automation Settings** and enable System Events under MacWindowHide; macOS does not repeat a denied prompt.

## Restoration rules

Recording Mode writes an original snapshot and intended change before touching system state. It verifies the result, then restores in reverse. Restoration uses a comparison against its applied value, preserving detected user changes. An unfinished journal is reconciled on the next launch before another recording can start. Unresolved recovery stays visible and prevents a normal Quit from silently discarding it.

Standalone timers retain absolute deadlines. A timer that expires while Recording Mode owns the same resource is deferred until restoration. A manual switch change takes ownership away from the session. Keep Awake has independent standalone and recording assertions.

Hidden apps are restored only if they are the same running application instances. The app never reopens a closed application. Normal Quit also releases transient standalone covers, menu restrictions and hidden-app ownership. Persistent standalone choices, such as Dark Mode, remain as selected.

The journal cannot infer invisible user intent, and matching state alone cannot prove that an undetected change-away-and-back never happened. It reports read/restore failures instead of claiming success.

## Platform limits

- **Menu bar:** macOS 15/26 use separator geometry and Command-drag placement. macOS 27 uses a private visibility assertion, grouping icons by application. Some Apple indicators remain visible, and the restriction can affect Notification Center until icons are revealed. Notch, overflow and multiple-display behavior need physical verification.
- **Night Shift / True Tone:** use isolated private CoreBrightness interfaces with runtime checks. Unsupported hardware or OS builds display an unavailable state.
- **Microphones:** some USB, Bluetooth, virtual or fixed-gain inputs expose no writable mute/gain. Partial mute is reported with unsupported devices; this is not a universal hardware microphone disconnect.
- **AirPods:** battery fields may be missing or stale, especially for an asleep case. A successful Bluetooth connection is checked against the actual CoreAudio route.
- **Backdrops:** use wallpaper files and window metadata, not screenshots. Windowless foreground apps cannot be isolated. Fullscreen, Stage Manager, Show Desktop and extra displays require the manual matrix in [VERIFICATION.md](docs/VERIFICATION.md).
- **Keyboard:** Power/Touch ID and secure system surfaces are outside a Quartz filter's promise. Timeout, emergency release and mouse unlock remain available; the lock never resumes after relaunch.

Private APIs may stop working after macOS updates. Unsupported states remain explicit.

## Local data and verification

Settings, recovery state and imported pictures live under `~/Library/Application Support/MacWindowHide`. There is no account, analytics, telemetry or update service. Set `MACWINDOWHIDE_DATA_DIR` to a separate directory for isolated development or smoke tests.

```sh
MACWINDOWHIDE_DATA_DIR="$PWD/build/SmokeData" \
  build/Products/MacWindowHide.app/Contents/MacOS/MacWindowHide --integration-smoke-test
```

The smoke test uses only desktop cover, backdrop and Keep Awake, restores them, writes a JSON result to stdout, and exits. It does not grant permissions or change global preference controls. Use it with a visible foreground window.

`python3 scripts/test_quit.py` checks that the built app's real Quit path exits normally within ten seconds. It creates fresh temporary application data and changes no switches. Build before running it.

See [VERIFICATION.md](docs/VERIFICATION.md) for executed checks and hardware coverage. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency and source attribution.
