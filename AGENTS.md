# Agent guide

MacWindowHide is a native macOS menu bar utility. The current product is a local, English-language personal app with a universal binary. Keep changes within the requested feature; a backend, storefront, licensing system, or new framework requires an explicit product requirement.

## Read the relevant reference

- When starting or resuming a task, read [HANDOFF.md](HANDOFF.md) for the last recorded state, evidence and suggested next actions; confirm it against the current checkout.
- Before changing lifecycle, switch behavior, ownership, timers, persistence, or automation, read [ARCHITECTURE.md](ARCHITECTURE.md).
- For toolchain requirements, build commands, installation, and isolated smoke testing, use [README.md](README.md).
- Before claiming OS or hardware compatibility, consult [docs/VERIFICATION.md](docs/VERIFICATION.md). Compilation and mock tests do not establish physical device support.
- For UI changes, read [docs/DESIGN.md](docs/DESIGN.md). For menu bar compatibility or borrowed code, consult [docs/VISUAL_SOURCES.md](docs/VISUAL_SOURCES.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Change the right layer

- `MacWindowHide/Core/Models.swift` owns stable switch identifiers, adapter contracts, preferences, and settings storage. Preserve persisted raw values and snapshot meanings; schema changes need a compatibility decision and recovery tests.
- `MacWindowHide/Core/MutationCoordinator.swift` owns recording and standalone switch mutations. `MacWindowHide/Core/JournalStore.swift` owns the durable recovery file. Keep view actions, hotkeys, and App Intents on this shared path.
- `MacWindowHide/Platform/` owns OS APIs, permission checks, native windows, audio/Bluetooth, keyboard filtering, and runtime bridges. Keep hardware and private-API details out of SwiftUI views.
- `MacWindowHide/Presentation/` owns the app lifecycle, observable UI state, native views, hotkeys, and App Intents. Preferences and setup/menu-layout actions use `SettingsStore` and `AppModel` controller helpers.
- `scripts/generate_project.py` owns project membership and build settings. Update the generator for build-setting/resource changes, then regenerate the checked-in project. Direct project-file edits are overwritten.
- Keep vendored KeyboardShortcuts source and its license together. Update notices when introducing or adapting third-party code.

## Preserve restoration and safety

- Persist the original snapshot and requested operation before touching the OS. Verify the resulting state, then persist the applied snapshot. Keep journal write failures actionable.
- Restore owned changes in reverse, using the adapter's `matches()` semantics. Preserve detected user changes and unreadable recovery evidence. Never clear a user's journal merely to make startup succeed.
- Preserve the distinction between recording and standalone owners, deferred timer expiry, and exact audio baselines. Release only the relevant owner's transient resources.
- Keep `@MainActor` boundaries and the coordinator's operation guards: actor isolation alone does not prevent reentrancy across `await`. Run blocking processes and event filtering off the main actor.
- Capability/status queries must remain read-only and must not prompt at launch. Request permissions through explicit setup actions; report unknown, partial, unsupported, and permission states accurately.
- Runtime-check private symbols and signatures. Keep OS-specific menu bar paths and a clear unavailable result when an interface changes.
- Keep keyboard filtering fail-open, with timeout, Escape, and mouse release paths. Never resume a keyboard lock after relaunch.
- Preserve Finder, the foreground application, exclusions, and live process identity when hiding/restoring other apps. Recovery must not reopen terminated applications.

## Validate the change

Run commands from the repository root:

| Change | Required check |
| --- | --- |
| Coordinator, adapter, persistence, or automation behavior | `./scripts/test.sh`; use fake adapters and temporary data for unit tests. |
| Application code or build configuration | `./scripts/build.sh`; check the actual compiler/signing result. |
| Native UI | Inspect the running affected view and its error/setup states. |
| Installer or release scripts | Build first, then `./scripts/package.sh` and `./scripts/verify-package.sh`. Packaging reuses an existing app and does not detect stale source. |
| Documentation only | Check local links and compare described behavior with source; a rebuild is unnecessary. |

Keep the XCTest startup guard in `MacWindowHide/Presentation/AppLifecycle.swift`: hosted unit tests must not initialize real app controls. Tests for recovery, keyboard safety, or app identity must not mutate the user's desktop or devices.

Use `MACWINDOWHIDE_DATA_DIR` for isolated native runs. The integration smoke command changes real desktop covers/backdrop and Keep Awake for a short session; finish restoration and close the test app. The override redirects application files, not UserDefaults or OS state.

Leave build caches outside cloud-synced Documents. `build/Products/MacWindowHide.app` is a symlink to a temporary signed bundle; the DMG is the durable installer. Preserve security-related file attributes when addressing signing issues.

## Handoff

For parallel work, agree on shared contracts first and assign one owner to `Models.swift` and the project generator. Keep independent subsystem edits in separate files.

Describe what changed, checks actually run, and unverified OS/device cases. Update architecture or setup docs when their contracts change; keep dated execution evidence in `docs/VERIFICATION.md` rather than copying test counts into this guide.

At a meaningful task boundary, update [HANDOFF.md](HANDOFF.md) with the current goal, completed/in-progress work, evidence and next action. Its final section defines the update format.
