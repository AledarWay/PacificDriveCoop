# CoopSync — online co-op for Pacific Drive

CoopSync is an unofficial mod that lets two players go on a Pacific Drive run together over Steam. The host plays
their own run, and the guest joins it in their own car. Both players get the same zone, loot, hazards and cars.
The mod is built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) and follows the
[coop-anything](https://github.com/cranebeaker/coop-anything) playbook.

> **Status: alpha (0.1.0-alpha20).** It is playable, but desyncs and crashes can happen. Please send a report
> whenever something breaks (see [Reporting problems](#reporting-problems)).
> The versions and what changed in each one: [`mod/release/CHANGELOG.txt`](mod/release/CHANGELOG.txt).

## Features

What works now, all tested in-game:

**Session and lobby**
- A Steam friends lobby inside the game: Esc → **Co-op** in the pause menu (the **F7** panel has the same items).
  Invite a friend, or accept an invitation, without leaving the game. No open ports and no extra programs needed.
- The lobby forms in the garages. Each player stays in their own garage, with their own save and their own car,
  and sees the other player there.
- A **Co-op checklist** under the game's driver checklist shows the lobby, the players and what to do next.
- The guest's map table shows the host's map with junctions, conditions, hazards and events. The guest can look
  at it, but only the host picks where to go. The garage's time of day and weather are the host's.
- During a co-op session the pause menu does not stop the game: the other player keeps playing.

**Into the zone together**
- The host drives out as usual. Once the host has left, the guest's garage gate opens, and the guest drives
  straight into the host's zone.
- The guest's game loads the host's zone exactly as the host's game has it (it is passed through the game's own
  save), and the guest's car appears next to the host's car.
- Joining later works too. The guest never sees the junction map: while the host's game loads, the guest's
  screen stays on the loading cover, and the guest lands at the junction the host picked.
- The next zone: the host picks the junction at the zone's exit. The guest drives into the same exit and waits
  there (no map), then follows the host into the same zone.

**Cars**
- Both cars are real cars on both sides, so screens, gauges, lights, mirrors and collisions all work.
- You can use the other player's car with the game's own actions:
  - Driver's door → take the wheel, unless the other player is driving.
  - A back door → take that seat.
  - At the wheel, the key, the lever, the pedals, the steering wheel, lights, wipers, radio and horn all work.
  - Your own game drives the car, so there is no input delay.
- Doors, the trunk and the hood open and shut for both players. Paint, part wear (dents, scorch, radiation), the
  dashboard readings and the radio (the same track at the same moment) match on both sides.
- Cars collide and knock each other's parts off. A car hitting a player knocks them away and hurts them.
- The other player's trunk and racks belong to them: what you put there ends up with them.

**The zone**
- Loot is shared. Each item is there once, so what one player takes is gone for the other. Wreck trunks,
  containers, building doors and items moved between slots stay in sync.
- Anchors: one player taking an anchor takes it for both. An anchor put into the ARC charges both players' ARCs.
- Hazards and anomalies are in sync: saw blades, geysers, the anomalies that chase a player, storms, radiation
  and the zone's other events.
- Things that break (shrubs, young trees, barrels, cones, signs) break for both players. A fuel barrel holds the
  same amount for both.
- Exit portals are the same for both players. The exit one player picks on the ARC opens for both, and the closing
  storm starts for both.
- Map and story progress count for the host. The loot each player brings home is their own.

**Players**
- Each player sees the other walk, run and animate. Kicks and getting run over hurt the other player.

**Language**
- Every text of the mod follows the game's language. English and Russian are included, and any other language
  shows English until someone adds a translation (see [Adding a language](#adding-a-language)).

**Tools for testers**
- **Two copies on one PC** (`TwoGamesTest.bat`): test the co-op without a friend. Each copy plays on its own copy
  of your saves.
- **F7 → Debug**: resync the zone, restart the sync, teleport to the other player, restore car parts, leave the
  session, collect a report.

## Requirements

- Pacific Drive from Steam. Both players need the same game version.
- Steam running, and the two players must be Steam friends.
- Windows 10/11, 64-bit. Nothing else to install: UE4SS comes in the zip.
- For now the mod supports exactly two players.

## Install

1. Download the latest `PacificDriveCoop-<version>.zip` from [Releases](../../releases). Builds of every change
   are also attached to the [build runs](../../actions/workflows/build.yml) as artifacts.
2. Close the game. Unpack the zip anywhere and run **`Install.bat`**. The installer:
   - finds the game through Steam;
   - backs up your saves to `Documents\PacificDriveCoop\saves-<date>`;
   - puts UE4SS and the mod into the game folder.

   If it cannot find the game, pass the game folder:
   `Install.bat "D:\SteamLibrary\steamapps\common\Pacific Drive"`.
3. Start the game from Steam as usual.

**Uninstall:** close the game and run **`Uninstall.bat`**. It removes the mod and UE4SS. If you had your own UE4SS
before the install, it is put back. Your saves are not touched.

## How to play

1. **Host:** Esc → Co-op → *Create lobby* → *Invite a friend…* → pick the friend.
2. **Guest:** the menu shows *Invitation from … — accept*, or *Join lobby: …* if the friend is already in a lobby.
3. Both of you are now in your own garages and can see each other. The host picks the junction on the map.
4. **The host drives out first.** Then the guest's gate opens: drive out, and you arrive in the host's zone next
   to the host's car.
5. Play together. To go home, use the exit portal the host or the guest opened on the ARC.
6. To go on to the next zone, both drive into the zone's exit. The host picks the junction; the guest waits in
   the exit (a dark screen, no map) and then arrives next to the host.

Tips:
- Put the lever into park before you get out. In drive with the engine on, a car creeps away by itself (that is how
  the game works).
- A passenger can only use their own door: to get out, look at your door and press E. The levers and the key are
  for the driver only.
- Quitting to the main menu or loading a save leaves the lobby.

**Testing alone:** after installing, run `TwoGamesTest.bat` (with Steam running and the game closed). Two game
windows open, and each plays on its own copy of your saves, so your real saves do not change. Use
`TwoGamesTest.bat -Fresh` to copy your saves there again.
- Copy 1: Esc → Co-op → *Create lobby*.
- Copy 2: Esc → Co-op → *Join lobby: the second copy of the game on this PC*.

You need a strong PC for this.

## Reporting problems

- In the game: **F7 → Debug → Collect a report**. It saves `CoopSync-report-<date>.zip` to your desktop.
- If the game crashed: run **`Report.bat`** from the unpacked zip folder. For two copies on one PC, run
  `ReportTwoGames.bat` instead.
- Send the reports of **both** players, with a short note on what you did and what went wrong. The host's logs
  and the guest's logs are different. A report holds only logs and the mod's own files: no saves and no
  personal files.

## Known issues

- The guest's game can crash now and then while entering the host's zone or following the host to the next zone.
  It was seen twice in about 150 test runs. If it happens to you, please send the reports.
- Sometimes the guest has extra exit portals in the zone. The picked exit still opens for both players.
- The computer screen's overall status text and clock in the other player's car still show your own car's.
- In drive with the engine on, a car left alone creeps away. This is the game's own behaviour.
- An anchor once showed up in both players' hands (alpha 20). The tests could not repeat it; if you see it, please
  send the reports and say how the anchor was taken.
- The zone's light can look brighter in one game than in the other. The mod syncs the time of day and the
  weather; the rest comes from each player's graphics settings.
- Instability spots on the map and wreck paint were fixed in alpha 21 but are not yet checked by a real two-PC game.

## Not done yet / planned

- **The guest on foot** (riding in the host's car without bringing their own) is frozen for now. Only the
  "everyone in their own car" mode is available.
- More than two players. The design allows up to 4 players and 2 cars.
- Getting into a front passenger seat. In the game the ARC device takes that seat.
- Not tested on two real PCs over the internet as widely as with two copies on one PC.

This list changes with every alpha. The full log of findings is in
[`games/pacific-drive/NOTES.md`](games/pacific-drive/NOTES.md).

## For developers

### Layout

| Path | What |
|---|---|
| `mod/CoopSync/Scripts` | the mod (Lua, UE4SS): session, cars, loot, zone, menu |
| `mod/CoopSync/Scripts/lang` | the mod's texts, one file per language |
| `mod/CoopNative` | the native half (C++, `main.dll`): Steam lobby and P2P network, world, saves |
| `mod/native` | CMake tree: UE4SS from source + CoopNative; `build.bat` |
| `mod/release` | installer scripts, the zip's README, CHANGELOG |
| `mod/tools` | `build-alpha.ps1`, `deploy.ps1`, the in-game test suite (`run-all-tests.ps1`) |
| `mod/vendor/ue4ss` | the UE4SS release files packed into the zip (MIT) |
| `mod/net` | the first-stage relay network (legacy, not shipped) |
| `games/pacific-drive` | `HANDOFF.md` (where things stand) and `NOTES.md` (the engineering log) |

### Building

You need:
- VS 2022 Build Tools (C++), CMake and Rust;
- the UE4SS sources in `local/ue4ss-src`: a clone of UE4SS-RE/RE-UE4SS at the commit in
  `mod/native/ue4ss-commit.txt`, with its submodules. The private `UEPseudo` submodule needs a GitHub account
  linked to Epic Games.

Then run:

```
powershell -File mod\tools\build-alpha.ps1 -Version 0.1.0-alphaNN
```

This builds `local\release\PacificDriveCoop-<version>.zip`. The scripts expect the repository at
`C:\PacificDriveCoop`.

### Adding a language

Each language is one file in [`mod/CoopSync/Scripts/lang/`](mod/CoopSync/Scripts/lang/). The file is named
after the game's language code, such as `de.lua`, `fr.lua` or `pt-br.lua`, and maps text keys to texts:

```lua
return {
    ["menu.create_lobby"] = "Lobby erstellen",
    ["menu.invitation"] = "Einladung von %s - annehmen",
}
```

- Start from a copy of [`en.lua`](mod/CoopSync/Scripts/lang/en.lua). It is the reference and holds every key.
- Keep `%s`, `%d` and `%.0f` as they are and in the same order: the mod fills them in (a name, a number).
- A key you leave out shows in English.
- The mod picks the file from the game's language: first the full code (`pt-br`), then the language alone (`pt`),
  then English. To try a language without switching the game, set the environment variable `COOPSYNC_LANG=de`.
- `mod/tools/loc-check.ps1` (run by `lua-lint.ps1` and the build) checks every file: unknown keys, `%` codes that
  do not match English, and keys that are missing.

In the code a text is `L("menu.create_lobby")`, or `L("menu.invitation", name)` with values to fill in
([`loc.lua`](mod/CoopSync/Scripts/loc.lua)). A new text needs its key in `en.lua` and `ru.lua`.

### CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) does the same on GitHub and needs the repository
secret `UE4SS_TOKEN`: a classic token with the `repo` scope, from the account that is linked to Epic.
- A push to `main` builds the zip as an artifact.
- A tag `v<version>` also publishes a pre-release. The tag must match the newest entry in
  `mod/release/CHANGELOG.txt`.

## Credits and licences

- [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT): the mod loader, built from source at the same commit.
- Pacific Drive is © Ironwood Studios / Kepler Interactive. This is an unofficial fan mod, not affiliated with them.
  It needs a legitimate copy of the game.
