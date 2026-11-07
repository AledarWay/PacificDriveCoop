# CoopSync — online co-op mod for Pacific Drive

An online co-op mod for Pacific Drive (2 players, Steam friends lobby inside the game), built on
[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) following the
[coop-anything](https://github.com/cranebeaker/coop-anything) playbook. Alpha.

## Download and install

Ready zips are on the [Releases](../../releases) page (and as artifacts of every [build](../../actions) run).
Unpack the zip, run `Install.bat` (finds the game through Steam, backs up the saves), play; `Uninstall.bat` removes
it. Problems: `Report.bat` packs the logs into a zip on the desktop. Details: `README.txt` inside the zip.

## Layout

| Path | What |
|---|---|
| `mod/CoopSync/Scripts` | the mod (Lua, UE4SS) |
| `mod/CoopNative` | the native half (C++, `main.dll`: Steam lobby / network, world, saves) |
| `mod/native` | CMake tree: UE4SS from source + CoopNative; `build.bat` |
| `mod/release` | installer scripts, README, CHANGELOG |
| `mod/tools` | build (`build-alpha.ps1`), deploy and the in-game test suite |
| `mod/vendor/ue4ss` | the UE4SS release files packed into the zip (MIT) |
| `games/pacific-drive` | `HANDOFF.md`, `NOTES.md`: design and engineering log |

## Building

Needs VS 2022 Build Tools (C++), CMake, Rust, and the UE4SS sources in `local/ue4ss-src`: a clone of
UE4SS-RE/RE-UE4SS at the commit in `mod/native/ue4ss-commit.txt`, with submodules (the private `UEPseudo` one needs a
GitHub account linked to Epic Games). Then:

```
powershell -File mod\tools\build-alpha.ps1 -Version 0.1.0-alphaNN
```

→ `local\release\PacificDriveCoop-<version>.zip`. The scripts expect the repo at `C:\PacificDriveCoop`.

CI (`.github/workflows/build.yml`) does the same on GitHub: needs the repository secret `UE4SS_TOKEN`. A push to
`main` builds the zip as an artifact; a tag `v<version>` matching the newest `mod/release/CHANGELOG.txt` entry also
publishes a pre-release.
