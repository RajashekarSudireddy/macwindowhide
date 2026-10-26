# Handoff

Updated: 25 October 2026. This is a snapshot for resuming work; confirm the current checkout and available evidence before acting on it.

## Goal and current state

The project lives at `~/Desktop/Personal Projects/macwindowhide`, and Codex is using that folder. **Do Not Disturb has been removed completely from active app functionality**, including controls, Recording Mode selections/defaults, Settings, hotkeys, App Intents choices, the adapter and bundled helper/setup files. The verified build is installed at `/Applications/MacWindowHide.app` and has been restarted to preserve the user's existing Dark Mode timer. Dated execution evidence is recorded in [VERIFICATION.md](docs/VERIFICATION.md).

MacWindowHide implements a local, personal macOS menu bar utility with Recording Mode, fourteen controls, restoration, timers, backdrops, menu bar organization and automation entry points. A universal app and DMG have been built. This is an implementation ready for continued validation, not a claim that every hardware/OS combination has been exercised.

The removal passed 36 hosted tests, a clean universal Release build, strict signature checks, installer rebuild/verification, exported metadata checks and Quit process-exit checks. A temporary preview with a distinct bundle ID allowed native inspection after the UI tool timed out attaching to the main app: Permissions, Recording Mode and Shortcuts contain no DND option, and the preview quit normally. Previous installed app backup: `/private/tmp/MacWindowHide-before-dnd-removal-vs1g8hd0/MacWindowHide.app`. The updater preserved personal recovery data byte-for-byte; the restarted app still owns the same Dark Mode timer.

Old `doNotDisturb` values are decode-only and excluded from all active entrypoints. Settings filter old selections; journals preserve snapshots and deadlines as inactive evidence. No Focus helper is invoked and current macOS Focus is left unchanged. See the compatibility contract in [ARCHITECTURE.md](ARCHITECTURE.md).

The earlier Quit and **Allow System Events control** fixes are retained. Fresh-consent and previously-denied native TCC states remain untested. The optional personal `project-docs` skill remains installed outside this repository; its disposable `build/skill-validation-venv` still embeds the old location and should be recreated if needed.

## Start here

1. Read [AGENTS.md](AGENTS.md) for working rules and required checks.
2. Inspect `git status --short --branch`. At this handoff, `main` has **no commits** and the implementation/docs are untracked. An empty `git diff` would omit that work; preserve existing files and do not assume a clean or empty project.
3. Read the relevant section of [ARCHITECTURE.md](ARCHITECTURE.md) before changing a subsystem. Use [README.md](README.md) for build/run commands.
4. Choose the next task from the current user request. The recommendations below describe a continuation order when further app verification is requested.

## Verification evidence

The authoritative coverage and remaining-check matrix is [docs/VERIFICATION.md](docs/VERIFICATION.md). Existing local evidence records:

| Evidence | Recorded result | Location |
| --- | --- | --- |
| Release build | Clean universal compilation, signing and metadata export succeeded without DND resources. | `build/build-release-remove-dnd.log` |
| Unit tests | All 36 hosted tests passed, including compatibility and mixed recovery. | `build/tests-remove-dnd.log` |
| Quit regression | Real lifecycle check passed for the new build and installed copy. | `build/quit-remove-dnd.log`, `build/install-remove-dnd.log` |
| Native smoke | Desktop cover, backdrop and Keep Awake started and restored; process exited successfully. | `build/smoke-result.json` |
| Installer | Image, mounted signature, architectures, notices, checksum and absence of DND resources/metadata passed. | `build/package-verification-remove-dnd.log` |
| Native visual review | DND absent from Permissions, Recording Mode and Shortcuts in a distinct-ID preview; preview exited through Quit. | `docs/VERIFICATION.md` |

The permission fix was also inspected in the new Release Settings window with isolated application data: its button showed progress and then confirmed System Events access. No consent prompt was accepted. Native smoke evidence remains from the earlier run that day. No permissions were granted and no desktop/device controls were changed by the hosted tests.

## Recommended next work

Git still has no commits or configured remote. The updated app is already installed and running. Next concrete action: validate the remaining entry points and permission-dependent controls below. Recording Mode no longer requires DND helpers. Preserve existing TCC permissions; do not reset them merely to test.

1. **Validate user entry points on this Mac.** Use an installed Applications copy and test the menu bar popover, Option-click, global recording hotkey and Shortcuts/Siri actions. Complete when start/restore behavior and visible states agree with the selected profile and all changed resources return to the expected state.
2. **Validate permission-dependent controls.** Follow the verification matrix. Exercise granted/denied/revoked access and record actual outcomes and restoration behavior.
3. **Expand physical coverage when devices are available.** Prioritize actual microphone/AirPods behavior, keyboard emergency release, display/Space transitions, macOS 15/26 and Intel execution. Mark unavailable cases as untested rather than passed.

There is no reported active code blocker. The remaining checks depend on appropriate user setup, a GUI session, supported devices or other Macs. Confirm the current permission state when resuming; the last recorded verification did not accept permission prompts.

## Decisions and limits to retain

- Keep the current personal/local scope. Product boundaries and working rules live in [AGENTS.md](AGENTS.md); implementation contracts live in [ARCHITECTURE.md](ARCHITECTURE.md).
- DND has been removed. Retain its decode-only identifier and inactive journal evidence when changing persistence; active controls and exported actions contain fourteen choices.
- Private menu bar/display interfaces and hardware mute support have real limits. Preserve explicit unsupported/partial states. The microphone implementation does not automatically mute every newly attached input.
- `MACWINDOWHIDE_DATA_DIR` redirects application files, not UserDefaults or OS effects. Even an isolated smoke run changes real covers/backdrop and an awake assertion; finish restoration and close the test app.
- Preserve recovery journals and live-process identity. Do not bypass unresolved recovery by deleting a user's state.

## Artifacts and environment

The following local outputs existed when this handoff was written:

- `build/Products/MacWindowHide.dmg` — durable installer.
- `build/Products/SHA256SUMS.txt` — installer checksum.
- `build/Products/MacWindowHide.app` — symlink into `/private/tmp/MacWindowHideBuild-501/Build/Products/Release/`; the temporary target can disappear.
- `build/Screenshots/Backdrop.png` — native Settings preview.

Build outputs and logs are gitignored and may be absent in another checkout. Reproduce them with the scripts in the README when needed. Keep build caches/staging outside cloud-synced Documents because File Provider metadata can invalidate app signatures. `scripts/package.sh` reuses an existing app, so build before packaging changed source.

## Keeping this handoff useful

Replace outdated state at each meaningful task boundary. Record the date, current goal, completed work, work still in progress, relevant evidence and the next concrete action. Link to durable rules/design/testing documents instead of copying them. Keep this a current snapshot, not a transcript or growing session log.
