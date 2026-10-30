# Verification report

Date: 31 October 2026 (latest entry). Host: macOS 27.0.1, Apple silicon. Toolchain: Xcode 27.1, Apple Swift 6.4, Swift 6 language mode, macOS 15 deployment target.

## Audit fixes F1–F6 — 31 October 2026

- Fixed audit findings F1–F6 from the 27 October review: the operation guard can no longer be cleared by a refresh started during a countdown; Quit waits for an in-flight operation and then restores, or reports failure; busy and recovery-blocked requests return `false` and App Intents throw `SwitchError.busy` or the pending-recovery issue instead of reporting success; popover "Retry restoration" runs full recovery; a successful retried Quit clears `recoveryNeeded`, and an unreadable journal no longer blocks Quit (the file is left untouched); Keep Awake clock mode never produces a past deadline. No persisted format changed.
- Added `MacWindowHideTests/AuditRegressionTests.swift` (16 tests, gated fake adapters, temporary data). Against unmodified `main` with signature-only shims, 12 of the first 14 fail. The 2 that pass are by design: the future-date F6 control and the "short operation is waited for" positive case. A review follow-up added 2 tests: Quit must process a timer deferred during recording, and must refuse to exit if that timer fails. Both fail when that step is removed from `shutdown()`.
- `./scripts/test.sh`: **52 tests passed, zero failures**. The only test-target warning is the existing `RetiredControlTests.swift:14` `var intent` notice.
- `./scripts/build.sh`: **universal Release build and signing succeeded with 0 warnings**.
- `python3 scripts/test_quit.py`: **passed**.
- Not run: the integration/native smoke test, packaging, real Shortcuts/Siri invocation, real hotkeys, and any physical device or TCC state. The race windows were forced with fake adapters only.

## Do Not Disturb removal — 25 October 2026

- Removed DND from active controls, Recording Mode defaults and saved selections, Settings, keyboard shortcut registration, App Intents choices, the system adapter factory, bundled helper definitions and setup documentation. The app now exposes fourteen controls.
- Kept its raw identifier decode-only for compatibility. Old settings retain all other choices; old journal snapshots and deadlines move to inactive evidence fields without changing Focus. Recovery continues restoring other controls.
- `./scripts/test.sh`: **36 tests passed, zero failures**, including settings migration, archival/idempotence, invalid evidence rejection, stale Shortcut rejection and mixed-control recovery. Evidence: `build/tests-remove-dnd.log`.
- Cleaned Release products before rebuilding to prevent stale helper resources. `./scripts/build.sh`: **universal Release build and strict signature verification passed**. Evidence: `build/clean-remove-dnd.log` and `build/build-release-remove-dnd.log`.
- Inspected exported App Intents metadata: exactly fourteen control choices, no `doNotDisturb` case. The signed bundle contains no `Resources/Focus` folder.
- `python3 scripts/test_quit.py`: **passed**, normal native process exit with fresh temporary data and no switch mutations. Evidence: `build/quit-remove-dnd.log`.
- Native inspection used a temporary copy with bundle ID `studio.macwindowhide.dndpreview` and isolated application data because the UI tool timed out attaching to the main bundle ID. Permissions has no DND setup section, Recording Mode has no DND action, and Shortcuts shows fourteen individual recorders. Full accessibility-tree assertions found no DND/helper labels. The preview exited through its Quit menu; no switch or permission was changed.
- `./scripts/package.sh` and `./scripts/verify-package.sh`: **passed** image integrity, mounted signature, universal architecture, notices, checksum, absence of Focus resources/setup guide and removal of DND from exported metadata. Evidence: `build/package-remove-dnd.log` and `build/package-verification-remove-dnd.log`.
- Updated `/Applications/MacWindowHide.app`, verified its signature and executable against the build, and passed an isolated normal-Quit check of the installed executable. Backup: `/private/tmp/MacWindowHide-before-dnd-removal-vs1g8hd0/MacWindowHide.app`. Personal recovery data was preserved byte-for-byte before relaunch. After restarting, the same standalone Dark Mode change and timer remained in the journal. Evidence: `build/install-remove-dnd.log`.
- This task did not exercise Recording Mode with real desktop/device mutations or run on other macOS versions or Intel hardware.

## Quit hang fix — 25 October 2026

- Reproduced in an isolated Release instance: the Quit menu action returned to Settings and left the process running. A one-second stack sample showed `AppModel.quit()` blocked inside `NSApplication.terminate` and its nested event loop. Evidence: `build/quit-hang-sample.txt`.
- Added `python3 scripts/test_quit.py`, which runs the real application lifecycle with fresh temporary data and no switch mutations. Before the fix it failed with **“Quit left the isolated app running for more than 10 seconds”** (`build/quit-regression-before.log`). After the fix it passed with normal exit status 0 (`build/quit-regression-after.log`).
- Quit now uses one delegate-owned shutdown task. The delegate cancels the first termination request while async cleanup runs on the normal event loop, rejects duplicate requests, and terminates synchronously only after cleanup succeeds. Busy-operation and recovery checks remain; no journal format changed.
- `./scripts/test.sh`: **31 tests passed, zero failures**, including additional checks for restoring recording changes before standalone resources and preserving failed-shutdown evidence. Evidence: `build/tests-quit-fix.log`.
- `./scripts/build.sh`: **universal Release build and deep/strict signature check passed**. Evidence: `build/build-release-quit-fix.log`.
- `./scripts/package.sh` and `./scripts/verify-package.sh`: **updated installer passed image integrity, mounted-app signature, architecture, notices and checksum verification**. Evidence: `build/package-quit-fix.log` and `build/package-verification-quit-fix.log`.
- Replaced `/Applications/MacWindowHide.app` with the verified build after confirming the old app and previews had empty recovery journals. The installed app passed deep/strict signature verification and its executable matched the build. Previous app backup: `/private/tmp/MacWindowHide-before-quit-fix-31hf_258/MacWindowHide.app`. An isolated `--quit-smoke-test` run of the installed executable exited normally with status 0. Evidence: `build/install-quit-fix.log` and `build/quit-installed-check.log`. Application settings/recovery files were preserved; the app was left closed.
- Native UI reproduction was successful before the fix. The UI tool subsequently failed to attach to relaunched preview windows (capture timeout), so the final control-panel click was not visually confirmed. The automated native process-exit check exercises the shared Quit entrypoint. Fresh temporary previews had no owned switch changes; they were stopped after verification. No desktop/device controls or permissions were changed by this task.

## Automation permission button fix — 25 October 2026

- Reproduced the reported no-feedback behavior in the app running from `/Volumes/MacWindowHide/MacWindowHide.app`: clicking **Allow System Events control** left the Settings accessibility tree unchanged. The old action discarded the result of a generic application-name script.
- Replaced that trigger with the native explicit permission API, off the main actor, with target launch confined to setup. Added progress/duplicate-request protection and visible success or actionable failure feedback.
- `./scripts/test.sh`: **29 tests passed, zero failures**, including four permission-result tests using fixed OSStatus values. No test initializes the real app model or requests permissions. Evidence: `build/tests-automation-permission.log`. The sandboxed attempt lacked Xcode cache access; the rerun with cache access passed.
- `./scripts/build.sh`: **universal Release build and deep/strict signature verification passed**. Evidence: `build/build-release-automation-permission.log`.
- `./scripts/package.sh` and `./scripts/verify-package.sh`: **updated DMG passed integrity, mounted-app signature, architecture, notice and checksum checks**. Evidence: `build/package-automation-permission.log` and `build/package-verification-automation-permission.log`.
- Native UI check used the new Release app with `MACWINDOWHIDE_DATA_DIR=/private/tmp/MacWindowHide-Automation-UI-20261025`. The button visibly entered its disabled requesting state and then displayed **“System Events control is allowed”**. A full accessibility-tree assertion passed. No OS consent prompt was accepted and no Dock, menu bar, or appearance setting was changed.
- Read-only refreshed states showed Dock Off and Dark Mode On. The isolated journal contained no changes or timers. Normal Quit actions did not exit the isolated app through the UI tool; its specific process was stopped with SIGTERM after checking that empty journal. The older user-launched DMG copy was left running.
- Fresh-consent and previously-denied TCC states remain untested in the native UI; their result handling is unit-tested. This check establishes the already-authorized outcome on this Mac, not cross-OS permission behavior or restoration of the controlled settings.

## Post-move verification — 25 October 2026

Executed from `~/Desktop/Personal Projects/macwindowhide` after Codex switched to the relocated folder. No application source changes were required.

- `./scripts/test.sh`: **25 tests passed, zero failures**, covering the current sources, including the files modified after the earlier test run. Evidence: `build/tests-relocated.log`. The XCTest startup guard remains in place.
- `./scripts/build.sh`: **Release build succeeded**, App Intents metadata exported, and the script's deep/strict signature check passed. `lipo -info` confirms `x86_64 arm64`. Evidence: `build/build-release-relocated.log`. This checks architecture inclusion, not execution on Intel hardware.
- `./scripts/package.sh`: rebuilt `build/Products/MacWindowHide.dmg` from the new build and updated `build/Products/SHA256SUMS.txt`. Evidence: `build/package-relocated.log`.
- `./scripts/verify-package.sh`: image integrity, read-only mounted app signature, both architectures, bundled notices/setup guide and SHA-256 checksum passed; the image was unmounted. Evidence: `build/package-verification-relocated.log`.

The initial sandboxed test attempt could not write Xcode/Swift package caches (`build/tests-relocated-sandbox.log`). The rerun with normal cache access passed. Xcode still emits nonfatal simulator-version and hosted App Intents registration messages; these runs do not establish user-library Shortcuts/Siri execution. Disk-image tools emit deprecation warnings but packaging and verification exit successfully.

No new native smoke, UI interaction, permission, device or cross-OS checks were performed. Those earlier results and the remaining manual matrix below keep their original scope.

## Passed

- Universal Release compilation and App Intents metadata export for **arm64 and x86_64**. Architecture inclusion is verified with `lipo`; Intel execution is a separate hardware check.
- Ad-hoc code signing with Hardened Runtime enabled, App Sandbox disabled, and the Apple Events entitlement. The clean bundle outside cloud-synced Documents passes deep, strict code signature verification.
- **25 Xcode XCTest cases, zero failures:** 18 coordinator/journal/timer tests, four keyboard safety tests, and three hidden-application recovery tests. Tests use mocks and temporary data and do not change real hardware settings.
- Coordinator cases cover reverse restoration, permission preflight abort, detected external changes including change-away-and-back, manual takeover, partial apply failure, failed journal writes, prepared-record recovery, corrupt journals, timer expiry during recording, independent awake owners, shutdown cleanup, audio baselines across relaunch, and idle polling suppression.
- Keyboard state tests cover the 60-second timeout, holding Escape for three seconds, releasing Escape, and permission/session loss. They do not install a live keyboard event tap.
- Hidden-application tests cover independent owners, stale processes, PID reuse with a different launch date, and corrupt ledger preservation. They do not hide real applications.
- **Native integration smoke:** real desktop-cover windows, foreground-window backdrop and an IOPM Keep Awake assertion started successfully, then restored successfully. The process exited with status 0 and no reported start/restore errors. The profile and journal were isolated from personal app data.
- ProcessRunner success, nonzero exit and timeout behavior. Platform Swift 6 typechecking and Objective-C bridge syntax validation.
- Running native Settings navigation, backdrop presets and permission/setup states inspected through accessibility and app-window screenshots. No permission prompts were accepted or security permissions granted during verification.

The native smoke result is recorded in `build/smoke-result.json`; build output is in `build/build-release-final.log`, and XCTest output is in `build/tests-final.log`. These are generated artifacts, excluded from source control.

## Packaging

Final installer checks passed: DMG integrity, read-only mounted app signature, both executable architectures, bundled notices, and SHA-256 checksum. The isolated preview app was closed through its normal Quit action after visual verification.

`scripts/build.sh` keeps DerivedData and the signed app in `/private/tmp/MacWindowHideBuild-<uid>`. `build/Products/MacWindowHide.app` is a symlink to that bundle. This avoids File Provider attaching forbidden Finder metadata to app bundles under Documents. `scripts/package.sh` stages outside Documents, creates the compressed DMG, and writes a SHA-256 checksum. Install the app from the DMG into Applications for normal use.

`scripts/verify-package.sh` checks DMG integrity, mounts it read-only, verifies the app's deep/strict signature, checks both architectures and bundled notices, and validates the SHA-256 checksum. Its executed result is recorded in `build/package-verification.log`. This personal edition is not notarized and has no public update service.

## Setup and hardware checks still required

| Area | Remaining validation |
| --- | --- |
| macOS 15 / 26 | Run the app and exercise legacy menu bar separators on those systems. |
| Intel | Run the x86_64 executable on physical Intel hardware. |
| Displays | Multiple monitors, mirroring, hot-plug, notch/overflow, fullscreen, Spaces, Stage Manager and Show Desktop behavior. The smoke test verifies state and window creation, not every pixel-compositing configuration. |
| Accessibility | User must grant the app permission. Exercise real menu bar organization and the live keyboard event filter, including mouse unlock and emergency release. |
| Automation | User must grant System Events access. Test Dock, whole-menu-bar and appearance changes and restoration, including permission revocation. |
| AirPods | Select actual paired headphones, verify connect/disconnect, output routing and available left/right/case readings; exercise asleep/out-of-range devices. |
| Microphones | Exercise writable mute/gain devices, unsupported/virtual inputs, disconnected devices, changed default input and manual changes during restoration. Newly introduced inputs are reported by actual state; a partial state is not a universal mute guarantee. |
| Night Shift / True Tone | Read capability is available only where hardware and the private interface support it. Write/restore behavior needs supported physical displays. |
| Keyboard | Real interception on ordinary and secure system surfaces. Power/Touch ID are outside the filter's scope. |
| Automation entry points | App Intents metadata exports successfully; user-library Shortcuts/Siri execution requires first-launch registration/setup. Direct menu bar popover and global hotkey interactions still need a manual run; the automation surface inspected the native Settings window. |
| Recovery | Fault-injected recovery is covered. Physical power loss, a real reboot while system preferences are changed, disk-full behavior and cross-OS upgrades need a disposable test environment. |

## Known implementation limits

Private menu bar and display interfaces may change after an OS update. macOS 27 menu icon visibility groups by application and can affect Notification Center until revealed. Some Apple indicators remain visible. Some microphones do not expose writable controls, and battery fields may be absent. Windowless apps cannot be isolated by Backdrop.

Restoration preserves detected user changes and compares actual state before undoing an operation. It cannot infer changes that happened entirely between observations. Errors retain recovery evidence and are not displayed as successful restoration.
