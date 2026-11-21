# AGENTS.md

This file provides guidance to the AI agent when working with code in this repository.

CoopSync: two-player co-op mod for Pacific Drive (UE4 4.27, project `PenDriverPro`), built on UE4SS. Lua half in `mod/CoopSync/Scripts/`, C++ half (`main.dll`) in `mod/CoopNative/`. Full guide: `CLAUDE.md`. Read `games/pacific-drive/HANDOFF.md` first in a new session; `mod/release/CHANGELOG.txt` is the authoritative version log.

## Commands (PowerShell 5.1, Windows)

- Lint: `powershell -File mod\tools\lua-lint.ps1` (syntax, BOM, globals, loc keys)
- Deploy to test game: `powershell -File mod\tools\deploy.ps1` — run before every test
- Tests: `powershell -File mod\tools\run-all-tests.ps1 -Quick` after every code change, before committing; single test via `-Only <name>`; full suite only at stage boundaries
- Native build: `mod\native\build.bat` (needs VS 2022 Build Tools, CMake, Rust, `local/ue4ss-src` at the commit in `mod/native/ue4ss-commit.txt`)
- Alpha zip: `powershell -File mod\tools\build-alpha.ps1 -Version 0.1.0-alphaNN` — requires the CHANGELOG entry for that version to already exist

## UE4SS Lua rules (violations crash the game)

- Never `ExecuteWithDelay` / `LoopAsync` / `RegisterKeyBind` — callbacks race the game thread. Use `CoopSyncAfter` / `Dev.after`; keys are polled via `CoopNative_KeyDown` in `hooks.lua`.
- Register hooks only in `hooks.lua` via `CoopSyncHook`, after the UFunction exists. A failed `RegisterHook` degrades the Lua state even under pcall.
- Never hold a Lua UObject reference across frames (GC) — use paths or `CoopNative_WeakNew`/`WeakValid`. Never key registries by object address or trust paths across world transitions.
- Never call UE4SS functions inside Lua coroutines (use `Sync.runJob`).
- `StaticFindObject` on a missing path costs ~50 ms — call `CoopNative_HasPath` first (or the `SFO` wrapper).
- `LoopInGameThreadWithDelay` ignores `return true` — it does not stop the loop.

## Testing rules

- Always launch with `-userdir` — a plain launch writes to the owner's real saves.
- Never run two test instances in parallel; the suite sequences them itself.
- Don't `tail -F` `all-progress.txt` while tests run — it locks the file for `Add-Content`.
- Crash-rate claims need 8-run batches (Lua state degradation accumulates).

## Files and localisation

- Lua: UTF-8 **without** BOM (UE4SS won't load BOM-prefixed scripts). PowerShell with Russian text: UTF-8 **with** BOM (PS 5.1 reads BOM-less as ANSI).
- Git: `* -text` in .gitattributes — no line-ending conversion; keep files byte for byte.
- New user-visible text needs a key in both `lang/en.lua` (reference) and `lang/ru.lua`; use `L("key")` via `loc.lua`.
- Don't name PowerShell helpers `R`, `Sv`, `LS`, `Kill`, or use `$args` — silent alias conflicts.

## Repo etiquette

- End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tag `v<version>` (must match newest CHANGELOG entry) publishes a GitHub pre-release — ask the owner before publishing. CI needs the `UE4SS_TOKEN` secret (Epic-linked account, for the `UEPseudo` submodule).
