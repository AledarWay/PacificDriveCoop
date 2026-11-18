# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CoopSync is an unofficial two-player co-op mod for Pacific Drive (UE4 4.27, project name `PenDriverPro`). It is built on UE4SS and ships as a zip with an installer. The host and guest each play in their own car; the mod replicates the zone, loot, hazards, and both cars over a Steam P2P lobby embedded in the game.

**Current alpha:** 0.1.0-alpha22 (being prepared). `mod/release/CHANGELOG.txt` is the authoritative version log. Update it and check `mod/release/README.txt` before every build.

## Repository layout

| Path | Contents |
|---|---|
| `mod/CoopSync/Scripts/` | Mod Lua: session, link, hooks, spawnsync, lootsync, statesync, playersync, twincar, runsync, mapsync, weathersync, carghost, menu, panel, checklist, hitch, loc, trace, config |
| `mod/CoopSync/Scripts/lang/` | Localisation files, one per game language code (`en.lua` = reference) |
| `mod/CoopNative/` | C++ half (`main.dll`): Steam lobby + P2P, world helpers, Wwise audio, save splice, weak handles |
| `mod/native/` | CMake tree and `build.bat` (builds CoopNative + UE4SS from source into `local/native-build/`) |
| `mod/vendor/ue4ss/` | UE4SS release files (settings, shared mods, LICENSE) packed into the zip |
| `mod/tools/` | PowerShell test suite, deploy, build-alpha, start/send helpers, all the probe scripts |
| `mod/tools/cmds/` | One-shot Lua snippets loaded into a running game via CoopDev |
| `mod/release/` | Installer scripts, README.txt, CHANGELOG.txt |
| `mod/CoopDev/` | Test-control mod: polls `local/instances/<tag>/coopdev/cmd.lua`, runs it on the game thread |
| `mod/net/` | Legacy C# relay network (CoopNet.exe, not shipped since alpha 8) |
| `games/pacific-drive/` | `HANDOFF.md` (current state, read first in a new session), `NOTES.md` (full engineering log) |
| `testgame/` | A copy of the game used only for tests (our UE4SS build injected here) |
| `local/` | Not in git: instances, saves, builds, reports, ue4ss-src, native-build |
| `tools/lua/` | `luac54.exe` used by the linter |

## Commands

### Lint (fast, < 1 s, no game required)
```powershell
powershell -File mod\tools\lua-lint.ps1
```
Checks syntax, UTF-8 BOM, unknown globals, and localisation keys. `deploy.ps1` runs this first and aborts on failure.

### Deploy Lua to the test copy
```powershell
powershell -File mod\tools\deploy.ps1
```
Lints, then copies all Lua from `mod/CoopSync/Scripts/` and `mod/CoopDev/Scripts/` into `testgame/`. Also copies `main.dll` and `UE4SS.dll` if they changed. Run before every test.

### Build the native half (C++)
```cmd
mod\native\build.bat
```
Needs VS 2022 Build Tools, CMake, Rust, and `local/ue4ss-src` (clone of RE-UE4SS at the commit in `mod/native/ue4ss-commit.txt`, with submodules including the Epic-linked `UEPseudo`). Output goes to `local/native-build/`.

### Build an alpha zip
```powershell
powershell -File mod\tools\build-alpha.ps1 -Version 0.1.0-alphaNN
```
Lints, builds native, assembles `local/release/PacificDriveCoop-<version>.zip`, saves symbols to `local/release/symbols/<version>/`. Requires the CHANGELOG entry for that version to already exist.

### Run the quick test suite (run after every change)
```powershell
powershell -File mod\tools\run-all-tests.ps1 -Quick
```
Runs the core two-instance tests in sequence (never in parallel), deploys first. Full suite (no switch) only at stage boundaries. Run a single test with `-Only <name>`:
```powershell
powershell -File mod\tools\run-all-tests.ps1 -Only cars
powershell -File mod\tools\run-all-tests.ps1 -Only cars,drive
```
Test logs land in `local/instances/all-<name>.log`; summary in `local/instances/all-summary.txt`.

**Network / fps variants:**
```powershell
powershell -File mod\tools\run-all-tests.ps1 -Quick -Lag 150,60,1   # 150 ms delay, 60 ms jitter, 1 % loss
powershell -File mod\tools\run-all-tests.ps1 -Quick -Fps 15          # cap every game at 15 fps
```

### Start a single test game instance
```powershell
powershell -File mod\tools\start-zone.ps1 -Tag host     # starts in a zone
powershell -File mod\tools\start-zone.ps1 -Tag host -StopInGarage
```
Instances live under `local/instances/<tag>/`. Reference saves are in `local/advsave/`. The launcher starts Steam if
needed and checks Steam plus the `PDFeature_Fig` entitlement before loading a reference save; a failure aborts early.

### Send a Lua snippet to a running instance
```powershell
powershell -File mod\tools\send.ps1 -File cmd.lua -Dir local\instances\host\coopdev
```

### Verify localisation
```powershell
powershell -File mod\tools\loc-check.ps1
```

### Crash dump analysis
```powershell
powershell -File mod\tools\crash-stack.ps1 -Report <report.zip>
```
Needs symbols for the build in `local/release/symbols/<version>/`.

## Architecture

### Two halves

The mod splits into a Lua half (`CoopSync`) and a C++ half (`CoopNative`). UE4SS loads the DLL from `Mods/CoopSync/dlls/main.dll` and registers its functions into every Lua state before the Lua mod starts. The Lua code calls them as plain globals (`CoopNative_NetSend`, `CoopNative_HasPath`, etc.).

### Module responsibilities (Lua)

- **main.lua** — entry point; loads all modules, sets up the per-game log (`<chan>/coopsync.log`), exposes `Dev.*` for test commands.
- **hooks.lua** — the only place hooks are registered (`CoopSyncHook`). Waits until the UFunction exists before calling `RegisterHook` (a failed hook degrades the Lua state even under pcall). Also owns `CoopSyncAfter` (game-thread timer) and `CoopSyncOnKey` (polled keys, never `RegisterKeyBind`).
- **link.lua** — network layer; wraps CoopNative's `NetSend`/`NetRecv` into named channels; delivers documents (large one-shot payloads: zone list, run descriptor, map, gates).
- **session.lua** — session state machine (idle → lobby → host/guest role → zone → home). Driven by `CoopNative_NetSession` or a test's `control.txt`.
- **spawnsync.lua** — host publishes the zone's actor list; guest imports it and runs cleanup jobs spread over frames.
- **twincar.lua** — the other player's car replica: a real game car (clean spawn), kinematic, driven by the pose stream. All car workarounds live here.
- **playersync.lua** — puppet players, seat state, car entry/exit, own-car mode.
- **statesync.lua** — host events (hazards, mines, loot pickups, knocked/kicked objects, fuel, ARC).
- **lootsync.lua** — shared loot: container hooks, PUT/TAKE/MOVE requests, ACKs.
- **audit.lua** — opt-in action audit (`audit.log`): player input, interactions and their effects. Starts before the
  world exists; it must not call engine getters during startup (world is read later from `session.state().world`).

### Native half (C++)

- **net.cpp** — Steam lobby (created inside the game's own steam_api64.dll), P2P send/recv, `two-games` patch (makes `SteamAPI_RestartAppIfNecessary` return false for a second copy on the same PC).
- **world.cpp** — fast object helpers: `CoopNative_HasPath` (avoids the ~50 ms full-object-walk on a miss), `CoopNative_Find`/`Under`/`TreePaths`/`ZoneCounts`, weak handles, actor tracking.
- **save.cpp** — `CoopNative_SaveSplice`: merges the guest's departure save with the host's zone data so the guest can call `UserLoadGame` and get the host's exact zone.
- **audio.cpp** — `CoopNative_AkPos`/`AkSeek`: reads and seeks the Wwise radio track position for radio sync.
- **trace.cpp** — crash-trace helpers: wraps game-thread loops so a crash leaves a breadcrumb.

### Test infrastructure

Each test script starts two headless game instances (`start-zone.ps1`, `-Tag host` / `-Tag guest`), connects them through a local TCP relay (`netlink.ps1`, `COOPSYNC_NET=tcp:<port>:<name>`), drives them via CoopDev commands (`send.ps1`), and reads their state from `local/instances/<tag>/coopdev/`. `run-all-tests.ps1` sequences all tests and kills leftover processes between runs.

## Rules that must not be broken

**UE4SS Lua pitfalls:**
- Never call `ExecuteWithDelay` or `LoopAsync` — their callbacks run on the mod's async thread and race the game thread's Lua registry (confirmed heap crash). Use `CoopSyncAfter` / `Dev.after` instead.
- Never register a hook outside `hooks.lua` / `CoopSyncHook`. A `RegisterHook` on a missing path raises a C++ error; even caught by pcall it degrades the Lua state, and repeated it crashes the game later.
- Never use `RegisterKeyBind` — its callback runs on UE4SS's thread and causes the same race. Keys are polled via `CoopNative_KeyDown` in `hooks.lua`.
- Never keep a Lua UObject reference across frames — the game can GC it. Use paths or `CoopNative_WeakNew` / `CoopNative_WeakValid`.
- Never key registries by object address — a new object can appear at an old address (a fresh car spawning where the old one was).
- Never trust object paths across world transitions — the same name reappears on a second visit.
- `LoopInGameThreadWithDelay` ignores a `return true` from the callback (it does not stop the loop). Use the loop helpers.
- Never call UE4SS functions inside Lua coroutines (jobs run via `Sync.runJob`).
- `StaticFindObject` on a missing path walks every object (~50 ms). Always call `CoopNative_HasPath` first (or use the `SFO` wrapper in hooks.lua).

**Testing:**
- Always use `-userdir` — a plain launch writes to the owner's real saves.
- Never run two test instances in parallel (they kill each other's games).
- Run `run-all-tests.ps1 -Quick` after every code change before committing.
- Don't `tail -F` `all-progress.txt` while a test suite runs — it locks the file for `Add-Content`.
- Crash rates need 8-run batches to be meaningful (UE4SS Lua state degradation accumulates).

**Files:**
- PowerShell scripts with Russian text: UTF-8 **with BOM** (PowerShell 5.1 reads BOM-less as ANSI).
- Lua files: UTF-8 **without BOM** (UE4SS fails to load a BOM-prefixed script).
- Never name a PowerShell helper `R`, `Sv`, `LS`, `Kill`, or use `$args` — these alias/parameter names silently conflict.

## Localisation

New user-visible text needs a key in both `mod/CoopSync/Scripts/lang/en.lua` (reference) and `ru.lua`. In code: `L("key")` or `L("key", value)` via `loc.lua`. The linter (`loc-check.ps1`) checks for missing keys, unknown keys, and mismatched `%s`/`%d`/`%.0f` codes.

## CI

`.github/workflows/build.yml` runs on `windows-2022`. It needs the repository secret `UE4SS_TOKEN` (a classic GitHub token with `repo` scope from the Epic-linked account, for the `UEPseudo` submodule).

- Push to `main` → zip as a workflow artifact.
- Tag `v<version>` (must match the newest CHANGELOG entry) → GitHub pre-release. Ask the owner before publishing a release.

## Commit conventions

End every commit message with:
```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

## Where to start

Read `games/pacific-drive/HANDOFF.md` first — it records the current state, what is open, and what was just fixed. `games/pacific-drive/NOTES.md` is the full engineering log (newest entries at the end).
