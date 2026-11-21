# CoopSync (Pacific Drive co-op) — handoff for a new chat (2026-10-27)

Read this first, then `NOTES.md` (same folder: the full engineering log, newest sections at the end).
The owner writes in Russian; answers, task lists and summaries in Russian. Code, comments, NOTES in English.

## Latest (2026-11-20) - back-seat exit by the in-car E fixed (live joint test)
**Commit: (pending) - playersync TD.backSeatExit + GetFLDoorAngle pre-hook; backseat-test in-car E coverage.**
The owner's live two-window test (garage, reference saves, channel chan-manual-20261120-a) found the alpha22 back-seat
exit fix did not hold: exiting the own car's back seat by the in-car E opened the driver's door together with the back
door. Root cause: the game hardcodes the front-left (driver) door for the in-car exit and opens it with a physics
impulse; alpha22's rotation hold lost to the simulating mesh. The ExitDoor-highlight test path did not reproduce it
(the owner exits by the in-car E, carInteract). Safe fix found by live experiments (NOTES "Live two-window test:
back-seat exit STILL opens the driver's door"): hold D1 shut with the game's OWN AttemptShut (~10 ms) for the exit
window + a PRE-hook on BP_CarPart_Door_Base_C:GetFLDoorAngle returning 90 for D1 during the window, so the game's exit
safety trace does not treat the shut door as a blocked exit (which fades to black). The back door opens for the exit.
Owner confirmed the fix works in the real build. Remaining imperfection (documented in README Known issues): D1 twitches
~8 deg / 0.25 s from the game's open impulse before AttemptShut brakes it - the safe floor; zero is unsafe (kinematic
breaks/destroys the door, physics velocity setters crash, target-angle/rotation holds leave the impulse twitch).
backseat-test gained an in-car E exit section (angle1 < 12 allows the twitch). Failed approaches recorded in NOTES.
UE4SS lessons: POST-only hooks (pre=nil) do NOT fire here - use PRE hooks; a pre-hook return overrides only the return
value, not a void body; hook params are Param userdata (:get()). Restorable saves before state-changing probes:
local/advsave/coop-backseat2-host.sav / -client.sav.

## Before (2026-11-20) - live-findings fix round
**Commit: 0b2e415 — four verified fixes; 7baf7f4 — Mechanic UI.** GenericBar's Blueprint
read the manager's local equipped-car state despite a correct twin Current Instance. UMG hooks accepted but never
fired (fixed=0). TD.mechanicUITick now updates only twin items directly from Current Instance every 100 ms; own-car
native UI is untouched. Real Scrapper-hit regression twin-state 15/15 (health 0, break 40), plus native/twin
screenshots with matching red bars. Quick-suite plus reruns are green except the known unrelated cars 38/39 bot/physics
flake. Alpha22 ZIP built locally (8.8 MB), install-test 10/10; tag v0.1.0-alpha22 is authorized and is the next step. Earlier four fixes:
- Installed item ActiveEffects sync through ES field 8 and EF repair/driving return (SE_Cracked / SE_FlatTire included);
  all 14 non-UI twin-state checks pass headless and graphics.
- Exact-match world-item adoption within 50 cm plus immediate authoritative S for guest DROP: interact LOOT PASS,
  no previous client-only wheels; loot-live 15/15 and revisit 11/11.
- BP_WorldManifestation_Anchor joins normal DROP/S/D replication; anchor-test 14/14 (throws both ways, ownership,
  original GRAB, ARC and fuel).
- Own back-seat exit holds the visible driver's mesh rotation and omits D1 from the outgoing pose briefly; physics
  remains the game's. backseat-test 19/19, local and remote D1 angle 0, no hidden frame, correct rear exit.
Full evidence and failed variants: NOTES "Fixes from the owner's live findings". No release/tag.

## Before (2026-11-19) - owner-driven two-window test, findings recorded, fixes pending
**No mod-code fix from this session is committed yet.** Two graphics instances used reference garage saves and the
manual channel `local/instances/{host,client}/chan-manual-20261119-194349`; action audit captured the owner's real
inputs. Both game processes are now stopped. Detailed object-level evidence is at the end of NOTES in the sections
"Live two-window test"; the findings are:
1. Cracked glass and flat installed tires share one missing mechanism: item status-effect sets are not synced by
   twincar ES (SE_Cracked_C / SE_FlatTire_C; include initial state and removal after repair; detached items too).
2. The red break-health bar DOES reach the right twin (h=0, k about 1.4, breaking=true), but mechanic UI reads the
   guest's local own-car item. Fix the selected-car widget binding, not the k sender. Probes must use Twin.isTwin:
   CarManager.NewCarActor switches and can reverse naive OWN/OTHER labels.
3. Four load-time guest-only spare wheels survive because the stray sweep names only BP_WorldItem_C and excludes car
   items / near-player objects. A detached-then-harvested Basic wheel also leaves a separate unmapped local guest
   actor after all S/D queues drain. Fix without deleting genuine dropAsked items; add detach -> Scrapper regressions.
4. Own back-seat exit still animates the driver's door. TD.backSeatExit deliberately hides its mesh for 2.7 s and can
   reveal it open: replace the visual workaround, do not extend the timer; test visibility / mesh pose every <=50 ms.
5. Guest anchor throw is not sent: BP_WorldManifestation_Anchor_C is a valid serializable item/root but
   CoopSync.matches=false (PATTERNS only has BP_WorldItem), producing drop_unmatched. Add it to item collection and
   test throw both ways / re-pickup. Ownership contract: only the grabber's local hands/inventory get the anchor;
   the other screen may show it only in the remote puppet's hands. Current host inventories have zero anchors.
6. Owner's standing safety instruction: make separate restorable saves in BOTH copies before potentially crashing or
   state-changing diagnostics. In this session read-only probes needed no saves; slot 8 was saved before giving items.

**Resume point before item grants, already inside Wilderness_Forest_15:** `local/advsave/coop-preitems-host.sav` and
`local/advsave/coop-preitems-client.sav` are byte-verified 20:25 saves before the 20:28 item grants. Host odsave8 was
automatically overwritten at 21:20, so the preserved host copy comes from its exact automatic
odsave8-backup-2026.11.19-20.25.19.sav (789487 bytes), not the later odsave8. Guest odsave8 was still the 20:25 save.
Keep both resume files unchanged for future tests. Basic items were then granted and count-checked; those later items
are NOT in this resume point. The live findings docs are currently uncommitted.

## Before (2026-11-18) - player action audit
**Commit: 346623f**: audit.lua (new) + audit-test.ps1 (new, in the quick suite), config/hooks/
session/playersync/statesync/menu/CoopDev + localization + collect-report + start-zone.
Opt-in (`audit=1` in config.txt or F7 -> Debug "Action audit"): audit.log records key down/up, Command Interact,
doors, seats, drive hand-overs, loot requests and session changes with world/role/state. CoopDev records bot actions too.
The report includes audit.log/.1/.2; a real ZIP was inspected and contains all three. Startup bug fixed: audit initially
called CoopSync.worldName before the first UWorld (construct_fname crash); it now reads only S.world, assigned at the
session tick. start-zone cleans the same tag's stale processes and CrashReportClient on startup/failure. audit-test 4/4;
lua-lint 234 files, PowerShell syntax and diff checks pass.
Focused rerun: runover 8/8, nextzone 19/19, instability 8/8, part-break 8/8, backseat 17/17; no Steam aborts and no
nextzone crash this time. OPEN: interact (two client-only wheel world items), seat-measure 1/2 (first x=49.2 vs >=50),
cars 38/39 (own car moved 11), revisit 10/11 (guest 26.4 ms total). See NOTES "Action-audit validation".

## Before (2026-11-17) - direct host drops, second-visit adoption and paint caches
**Commit: 3d9f570**: statesync.lua + revisit-test.ps1 + CHANGELOG + NOTES + FIXED-BUGS.
The host's new drop is sent directly now / +0.3 / +1 s instead of three root rescans (loot-live 15/15, 405-427 ms).
Runtime S adopts an existing same-class actor within 50 cm instead of spawning a duplicate; adoptPredicted only scans
actual dropAsked items. Failed approaches are documented and reverted: a full per-frame collect index, cached-only weak
resolve (two matching experimental CivCar crashes), tint-property-only skipping (paint-test 23/102), explicit constraint
frames and once-per-mesh door reseat. Normal Sync.deref and mandatory SetPaint are retained.
CoopSyncPaint.pal / tintCls reset on every world start: paint 2/2 and startflow 30/30 x8, no new dumps.
Full quick suite: all tests passed except drive (brake speed 50, threshold <50), cars (3 known bot/physics failures),
entry-spin (residual 21.8 deg nose dive on a repeat entry) and revisit (total frame budget; state 4.26, players and
session still over). The residual nose dive is OPEN: three new hypotheses were disproved and reverted; the previous
"fixed" claim was too strong. See NOTES "Live drops..." and "Residual nose dive...".

## Before (2026-11-17) - nose dive reduced; test launcher checks Steam / DLC
**Commit: 5e20e9e**: `twincar.lua` + `playersync.lua` + `game-args.ps1` + `start-zone.ps1` + `entry-spin-test.ps1` +
`run-all-tests.ps1` + CHANGELOG + FIXED-BUGS. The nose dive was reduced by re-seating the twin's shut door hinges before
physics starts and leaving a driven twin's doors to the game. `TD.entrySettled` waits only for mod-driven door
animations. Final entry-spin-test 5/5: all 12 entries succeeded, worst 0.3 deg / 1 cm; it is in the quick suite now.
The harness parks between rounds, requires every entry and uses the real camera highlight for another player's door.
game-args auto-starts Steam; start-zone checks Steam + PDFeature_Fig before loading. Cold-Steam smoke test PASS.
NOTES "The nose dive fixed" and "Test launchers". Current alpha: 0.1.0-alpha22 (being prepared).
The valid full quick suite was 33/44. Reruns recovered knock, twin-equip, twin-ctl, instability, esc, f7, runover
(8/8) and startflow (30/30). Current cars 38/39: only step 9 moved 8; the A/B run on HEAD also failed step 9
(moved 11), while all doors stayed in the current run. Still open, not regressions of this patch: loot-live's host
drop took 1.8-3.2 s (known before this patch), and revisit's frame-cost checks vary widely under load. One startflow
run died in state ev VP after the late join (hash 971387F09E1673DE36528E1F74FB68ECEFBFAFB4); the rerun passed 30/30,
so the rare paint crash remains open. See NOTES "Validation of the nose-dive / Steam round".

## Before (2026-11-15): nose dive narrowed (not fixed), dive-probe.ps1 added
See NOTES "The nose dive at a hand-over to the driver (2026-11-15, not fixed)" and the follow-up section.

## Before (2026-11-07) - the project is on GitHub: https://github.com/AledarWay/PacificDriveCoop (public)
C:\PacificDriveCoop is the git repo (main). Not in it: `local/` (saves, dumps, reports, builds, ue4ss-src) and
`testgame/`. The native build moved: CMake tree `mod/native/` (build.bat finds MSVC via vswhere), build dir
`local/native-build` (was local/cppbuild); the UE4SS release files the zip needs are in `mod/vendor/ue4ss`; the UE4SS
commit is `mod/native/ue4ss-commit.txt`. CI `.github/workflows/build.yml` (windows-2022): clones RE-UE4SS + submodules
with the secret UE4SS_TOKEN (classic token of the owner's Epic-linked account, for UEPseudo), runs mod/native/build.bat
and build-alpha.ps1 with the newest CHANGELOG version. Push to main -> zip as a workflow artifact; tag
`v<version>` (must match CHANGELOG) -> a GitHub pre-release with the zip. Publishing a release = ask the owner first.
Texts: one file per language, `mod/CoopSync/Scripts/lang/<code>.lua` (keys; en.lua = reference, ru.lua complete),
`L(key, ...)` in loc.lua; NOTES "The texts: one file per language". CHANGELOG has "0.1.0-alpha21 (being prepared)".

## Before (2026-11-05): alpha 20 built, the owner tests it
`local/release/PacificDriveCoop-0.1.0-alpha20.zip` (install-test 10/10): all 18 items of the owner's alpha 19
report (NOTES "The owner's alpha 19 test" and after). The full suite and its reruns: NOTES "Alpha 20 built". Open:
the guest/leg-seated "extra" right after the test's import (alpha 19 fails the same), two rare guest crashes on
entering / following into a zone, the dash's overall status text / clock, extra 0,0 portals. Next: the owner's
alpha 20 report.

## Before (2026-11-04): the owner's alpha 19 report worked through, alpha 20 next
The owner's 18 items (report local/reports/a19-owner-1): NOTES "The owner's alpha 19 test (2026-11-03, two copies
on one PC)" and the entries after it. All 18 done and tested (item 12, the dash, with a graphics run:
COOPTEST_GRAPHICS=1). Still open: the dash's overall status text / clock (this side's), extra portals at 0,0 on the
guest, the host's BP_Boon_LootCreature_C missing on the guest. CHANGELOG alpha20 "being prepared" lists the changes.
Next: the full suite, then build-alpha 20 (ask the owner before sending / publishing).

## Before (2026-11-03): alpha 19 built, the owner tests it
`local\release\PacificDriveCoop-0.1.0-alpha19.zip` (install-test 10/10). The full suite on the zone save and its
reruns: NOTES "The full suite on the zone save (2026-11-03)" - the test fixes (session drive-out, the sleeping car
after a teleport, write retries) and what stays open: the guest's game dying on the way home (3 of ~9 runs, a Lua
call on a freed UObject in a game-thread loop; trace.lua + trace-on.ps1 are there to catch it), extra portals at
0,0 (sometimes), ghostseat-old (the ghost path no game uses). Next: the owner's alpha 19 report.

## Earlier (2026-11-01): towards alpha 19 (the owner's alpha 18 test, two copies on one PC)
The owner's 40 findings + wishes: NOTES "The owner's alpha 18 test, two copies on one PC" and "Alpha 18 findings:
causes and fixes so far". Done (not built yet): the zone through the host's save integrated in the session flow
(startflow checks it, also on a late join), garage controls / lobby pause / stuck net error / guest's map look-only
(OnPlannerInteractionClicked bindings parked, mapsync checks it), localization (loc.lua + loc-check.ps1 in lua-lint,
tests force COOPSYNC_LANG=ru), the mod's own <chan>/coopsync.log, the car watch (status cars=/extra=, EXTRA CAR log
lines), status zs= / twins= / mapblock=, English scripts / README / CHANGELOG, TwoGamesTest.bat + ReportTwoGames.bat.
Also done: the "Кооператив" checklist under the driver's checklist (checklist.lua), the menu's info rows as text,
items 8 (late-join car clash), 29 (trunk), 32 (loot window), 33 (slot). Quick suite 23/24 before the last batch;
after it: startflow 23/23, mapsync, menu, esc, f7, session-net, interact, loot-live, car-store PASS. Not built.
Open: the guest's duplicate own car never reproduced (the "removed twin" in tests was a GC leftover; the car watch
logs EXTRA CAR lines for the owner's next test); items 10-28, 30-31, 34-40 need live checks.
Cars and world round (owner chose "cars and world first", 2026-11-01; NOTES "Alpha 18 items: cars and world, live
checks"): the world after the zone save matches ~99% (world-digest.lua + world-compare.ps1; only prefab rolls differ);
item 34 fixed (one shared mirror MID for every car: each car's mirror slots get their own MID / own capture target,
twincar _mirrorDoors; startflow checks mirror-rt.lua); items 13/19 (exit outline on the seat's own door,
TD.placeExit); item 10 (the host on its own back seat, TD.ownEnter, cars-test step 10; the test bot obeys the same
back-seat pedal gate as wheelFrame - with real keys not checked). Not reproduced: 21, 25-28, 35. Not looked at yet:
11, 12, 14, 17, 22, 23, 24, 30, 31, 37, 38, 39, 40. Quick suite after this round: 19/24 PASS at once; cars / contact
/ collide / anomaly (guest crash in the engine tick, new stack hash C11D81F1E410) rerun separately: anomaly, contact
PASS; collide 8/9 (slope at the test spot, not the mod); cars 24/25 (only the known step 6 lid flake) with step 8's
item 11 / 12 checks and step 8b (skipped: the test guest car has no driver's door - OPEN: no way into a car without
one, NOTES "Quick suite after the cars / world round").
Then (2026-11-01, NOTES "Item 39: anchors and the ARC"): the other's car's doors no longer break the own car's
(twincar muteDoorBreak / rejoinDoors; cars-test step 8b drives the guest's car by the host), items 24 / 17 (shut from
this side), drive-test brakes instead of coasting (the old "not stopped" flake: a downhill road). Item 39: grabbed
anchors sync (lootsync R|0/1, GRAB) and ARC deposits are repeated on the other side's ARC (GOB; charge about equal,
rolled per anchor); new anchor-test (owner's save copy) 7/7, in the quick suite. Not checked with a real hand deposit
(the hook is on the Gobbler's AddingAnchorCompleteLogic). Item 40 (2026-11-02, NOTES "Item 40: the exit home"):
exit portals in the spawn list, the ARC pick (storm manager "Select Exit Portal Actor") synced both ways (EXIT), the
closing storm follows on both; portal-test 4/4 in the quick suite. Guest crashes seen on the sync-test import of the
owner's save (three hashes, NOTES). Items 31 / 38 (NOTES "Items 31 / 38: knocked and kicked objects"): statesync
KNOCK replays each side's breaks / kicks on the other's copy (class + place); knock-test 3/3 in the quick suite.
Item 37: fuel barrels' fuel synced (statesync FUEL; anchor-test step 5, 10/10). Next: item 23 (anomalies), then
the cars (14, 22, 30, lid).
Owner's decisions (2026-11-02, work on alone): order 40, 31, 38, 37, 23, then 14, 22, 30, the trunk-lid damage;
knocked / kicked objects (31, 38) synced SMOOTHLY in real time (host drives, guest follows), not end state only;
when all are done and the full suite passes, build alpha 19 myself (CHANGELOG, zip, install-test, send the zip);
a stuck item: about half a day, then NOTES and move on.
Test pitfall: a bash `tail -F` on all-progress.txt locks it for run-all-tests (Add-Content fails) - don't.
Then (2026-11-02): items 23 (range-test: saws / geysers / tourists), 14 (part wear: twin-state 1b), 22 + 24 lid
(runover-test), 30 (smooth doors + hood: cars-test 1b) done - all owner's items now worked through. The tests moved
to the zone save (owner: "move the tests to the new mechanism"; NOTES "The tests on the zone save"): sync-test
-GuestJoin = host's ZoneSave.hostSave + guest's guestLoad + import; -OldZone / -NoImport. That found a real bug: a
save from further in the game (FText / bytes / int64 values) did not splice ("ERR host tree") - save.cpp fixed,
main.dll rebuilt. run-all-tests -Only a,b through powershell -File ran nothing - fixed. Quick suite on the new setup:
23/30 at once, cars / contact / twin-equip / mapsync / f7 PASS on rerun; runover's lid fixed (car rolled away; lid
bounce); range: the headless host's world sometimes paused by its own pause menu (cause open, test closes it).
Next: full suite, then alpha 19 (CHANGELOG checked, build-alpha, install-test, SendUserFile).

## Earlier (2026-10-31): alpha 18 built (native cars) - the owner tests it
**Alpha 18 built** (`local/release/PacificDriveCoop-0.1.0-alpha18.zip`, install-test 10/10): native cars (the
default; NOTES "Native cars: probes" ... "Native cars are the default"), the alpha 17 leftovers, low-fps / lag fixes,
two copies through the CoopNative Steam-restart patch. The owner chose "Альфа для теста" before the zone-through-save
integration (owner's plan step 2: still to do - "Ожидание хоста", buildings, host loot UI, duplicate guest car).
Ask for BOTH report zips after the test. Check by ear / eye: the door animation entering the own car, the passenger's
exit, driving the other's car.

## Earlier (2026-10-29): the owner's alpha 16 test fixed, alpha 17: the owner's alpha 16 test fixed, alpha 17 next
The owner + friend tested alpha 16 (15 problems, a guest crash). All analysed and fixed except the noted ones: NOTES
"The owner's alpha 16 test with the friend" (findings, fixes, why the tests missed them). Big ones: Lua heap crash =
UE4SS keybind thread race (keys now polled: hooks.lua CoopSyncOnKey + CoopNative_KeyDown), zone start (map published
on the host's arrival), own-car exit door (the game's lookup took the twin's door), the twin's slot spots / manager
bindings acting on the local car, driving the other's car (owner out: vehicle controller inputs), animated exit from a
twin, paint (EP), wreck trunks (contents both ways, pried / opened state), world doors (DS), radio clock / DJ stop.
New: cars-test (quick suite, 16 checks through the game's input paths), loot-live steps 6-8, startflow timing check,
"Две копии игры.bat" (two copies on one PC, local link; not run on a real install yet). **Alpha 17 built** (2026-10-29, `local/release/PacificDriveCoop-0.1.0-alpha17.zip`, install-test 10/10); every quick test passed in its last run (cars 16/16, loot-live 14/14, twin-ctl 26/26, collide 9/9 x2). Owner to test again with the friend: ask for BOTH report zips.
After alpha 17 (in the code, not in a build yet): the twin's trunk box showing the own trunk = the game's
RefreshTrunkInventory (hooked, car-store 17/17 with step 1b); the own door flags after riding restored from the real
doors (cars-test checks it, 17/17); the twin's door swinging open during the own exit investigated, not fixed (NOTES
"After alpha 17: the leftovers"). Then low fps / lag tests (NOTES "Low fps and lag tests"): run-all-tests -Fps 15 /
-Lag 150,60,1 (COOPTEST_FPS sets t.MaxFPS from session.lua); fixed: pried trunk and world-item pick at 15 fps (live
hooks), a late join stuck at 15 fps (re-join after 30 s; cause not understood), duplicate wreck part under lag (NACK
DETACH, untested path); two-games.ps1 starts the copies through a junction (the owner's copies restarted through
Steam) - fixed script sent to the owner for alpha 17. Next: the owner's report on it, radio measured, soak / death.
Two copies, 2nd try (2026-10-30): the junction did not help either - the owner's game log: "Restarting within steam,
exiting..." from the game's PlatformIntegrationSteam (SteamAPI_RestartAppIfNecessary) despite steam_appid.txt /
SteamAppId. Now two-games.ps1 sets COOPSYNC_TWO_GAMES=1 and CoopNative (start_mod, ~1.2 s before that call) patches
SteamAPI_RestartAppIfNecessary to return false (UE4SS.log "two games: Steam restart check answered 'no'"; checked
here, Steam still logs in). Not built yet; the junction code removed (the script rmdirs an old link).

### The owner's plan after the alpha 17 test (2026-10-30) - do in this order, alpha 18 only after all of it
The owner's alpha 17 findings (verbatim list in NOTES "The owner's alpha 17 test"). Order set by the owner:
1. **Zone reproducibility from the game's own save** - DONE (NOTES "The game's own zone save vs our sync",
   "Prototype: the host's zone through the game's save"): the save format is parsed (save-dump / SaveTree.cs /
   save-diff), our sync misses building variants + per-actor rolls, and the prototype works: the guest's departure
   save + the host's Map (save-splice.ps1) -> UserLoadGame -> the host's exact zone (1945/1954 matched), home works.
   The owner chose this way. Next: its integration (NOTES "Integration plan") as the core of step 2.
2. **Zone / start fixes**: loot UI opens on the host when the guest searches a container; buildings / abandoned
   houses misplaced on the guest (interiors standing outside); no junction map for the guest at departure - a loading
   screen "Ожидание хоста" instead, held until the guest is connected and synced (measure where the zone wait goes);
   a duplicate guest car on arrival (floating; three cars on the guest, two on the host).
3. **Cars rebuilt natively** (owner: too many workarounds; use the game's own interactions, only share the cars):
   audit every car workaround, design around the game's single-car assumptions (BP_CarManager_C.NewCarActor etc.),
   then rebuild. Findings to cover: no door-open animation entering the own car; driving the other's car is jerky
   and the own car drives along with it; controls / wheel repeat / "brake held" breakages; the key starts with one
   press (must be held); passenger exit from the other's car: door keeps animating, never shuts; camera stayed in
   the car after a passenger exit; passenger exit must need aiming at the door + E (now E anywhere, a teleport).
   **Started 2026-10-30** (owner: "Сначала машины" - cars before the zone integration): probes + design in NOTES
   "Native cars: probes". The levers: manager.NewCarActor + BP_Controller_PlayerCar_C.PlayerCarReference (the in-car
   input goes there, not to the manager) + the manager's delegates bound to one car at a time + the driver's side
   simulates the car. Tools: cars-test -SetupOnly -NoMute, cmds/native-car.lua, CoopNative_Trace* (trace.cpp).
   **2026-10-31: native is the default** (NOTES "Native cars are the default"); the whole quick suite passes native.
   **State (2026-10-30 evening)**: built behind `CoopSyncNative = true` (nativecar.lua + playersync TD.native*;
   cars-test turns it on, all other tests run the old mode). cars-test 19/19 now (2026-10-30 night); the open items are the last NOTES
   entry ("Built ... behind CoopSyncNative"): twin doors opened here keep simulating, the guest's exit door at the
   host, the twin's driver door not highlighted, driving the other's car (DV / VD) untested.
4. Then alpha 18 (with the leftovers / low-fps / lag / two-copies fixes above).

## Earlier (2026-10-27): the twin rework, stages A-E done, in alpha 13
**Alpha 13 built** (`local/release/PacificDriveCoop-0.1.0-alpha13.zip`, install-test 10/10, symbols in
`local/release/symbols/0.1.0-alpha13`): stages A-E below. Quick suite after stage E all PASS (drive on rerun).
The owner tests later with the friend: ask for BOTH report zips (alpha 10-13 untested in a real game).
The owner's focus: "the two cars, fully working" - the other's car like the own one, natively. Done since alpha 12
(NOTES "Twin rework" ... "stage C"):
- **Stage A, equipment**: the twin has its own named container (clean spawn), its parts are the game's own from the
  owner's items (EQ / EX lines); taking parts off / putting on works with the game's own E (twin-equip 10/10).
- **Stage B, part state**: health / fuel / battery (ES / EY lines; only increases go back to the owner) (twin-state 9/9).
- **Doors**: the alpha 12 "teleported into my car" found and fixed - the game's own E at the twin's door entered the
  OWN car and broke the owner's real door off. The twin's door handlers are unbound (UE4SS delegate GetBindings /
  Remove), the mod gets the press from the highlight; stray parts restored (ghostseat 23/23).
- **Stage C, body / levers / lights**: the twin's key / levers / top light / EnterDoor handlers muted outside (they
  acted on the own car; EnterDoor = the same teleport), levers given back inside the twin where the manager holds the
  owner's lights / top / wipers (C / G "ltw", K / KG lights|top|wipers); the twin SHOWS the owner's lights (LI lines +
  a hook on ElectronicUpdate_All) (twin-ctl 18/18).
- Old relink / unbind / restyle code removed. Quick suite after stage C: all 18 PASS.
- **Stage D, screens / radio / horn / wipers** (NOTES "stage D"): the twin's screens work by themselves since the
  clean spawn (old fixScreens removed); the radio is a 4th "ltw" digit (inside the twin its button switches the
  owner's real radio, outside it is muted); the horn in the twin honks the owner's real car (HR), the owner's horn
  honks its twin on the other side (HN); the twin's wiper blades follow the owner's timeline (pose "WT").
  twin-ctl 24/24.
- **Stage E, radio music / gear lever** (NOTES "stage E"): no stations in the game - one playlist; in the other's
  twin the radio plays the owner's track (RT lines, a playlist trick: no call plays a given track), the twin's channel
  button skips the owner's real radio (RK); the own gear lever stood still with a twin around (GetGearboxActor
  answered the twin's lever) - fixed by a hook. twin-radio 9/9 (new, sound on), twin-ctl 26/26; quick suite: see the
  last NOTES entry.
- Radio / horn sound only checkable by ear in a real game.
- **After alpha 13** (NOTES "Radio in step, live loot, the cars colliding"; not in a zip yet): the radio in step
  (Wwise seek from C++ through the exe's AK::SoundEngine exports, the owner pre-picks the next track, the garage
  stereo follows the host), the player's own files by name (position unverified), live loot (container hooks, PUT
  requests), the cars collide and damage each other's parts. New tests garage-radio 10/10, loot-live 7/7, collide 6/6.
- **Alpha 14 built** (2026-10-27, `local/release/PacificDriveCoop-0.1.0-alpha14.zip`, install-test 10/10) with that.
- **After alpha 14** (NOTES "Alpha 14; the DJ in step, the cars' storages, the hit between the cars"; not in a zip):
  DJ breaks follow the owner (RI); the other's car's trunk and storage attachments are the owner's (carstore.lua:
  CS / CX / CN / CT; before, the twin's trunk WAS the local player's own trunk); a hit sends the shared speed (BI)
  instead of the kinematic twin's all-or-nothing. Tests twin-radio 13/13, car-store 12/12 (new, quick suite),
  collide 8/8. Owner deferred: the player's own radio files.
- **Alpha 15 built** (2026-10-27) with that. **After alpha 15** (NOTES "Alpha 15; the striker keeps going ..."; not
  zipped): a hit is symmetric (either side sees it, shared speed from both cars' velocities, BI both ways, the twin
  kicked onto the shared-speed line, 1 s hold); the car channel known after a player sync restart (hits were unseen on
  that side); storage changes numbered + acked (no stale refill) and per tile (puts / takes / moves on the same tile).
  collide 9/9 x4, car-store 16/16. Next (owner 2026-10-28): more realistic tests - see the plan in the chat / NOTES.
- **Alpha 16 built** (2026-10-28, `local/release/PacificDriveCoop-0.1.0-alpha16.zip`, install-test 10/10): the
  realistic-tests stage (NOTES "Tests closer to a real game"): soak-test.ps1 (bots both sides 20-40 min, state
  comparator compare-state.ps1, lossy link -Lag), and its fixes (perf 8-10 -> 4 ms, cache crash, kinematic jumps,
  drops from storages / knocked-off parts, exit door, kick walk anim). Seed 7: 40 min, 60/60 checks alike.
- **Anomaly sync done (after alpha 16, not zipped)** - NOTES "Anomaly sync": the nearer player's side runs a moving
  hazard (statesync HZ: HCLAIM / HGRANT / HDENY / HM / HREVOKE / HDEAD), the other's copy eases onto its pose.
  anomaly-test 9/9 (quick suite; the chase scripted: the save's supercharger mines stand locked even in a single
  game); hazard / interact / loot-live / revisit / contact PASS after. Also fixed: the guest's D for non-item actors
  (never applied), a native crash in CoopNative_Under (dead class pointer). Real grabbers checked: anomaly-test -Real (forest15.sav,
  Wilderness_Forest_15) 5/5, puppet led by velocity. Leeches not met yet. The damage stays the owner game's own.
- Was the plan (owner 2026-10-28: anomaly sync). Before it: hazard positions stream host -> guest ~1 Hz (M lines, guest copies
  physics off), mines go off through the host (X / BOOM). NOT done: targeting - each side's AI only knows its local
  player (GetPlayerCharacter / own car), host hazards ignore the guest; the guest's copies run their own AI and get
  teleported back to the host's pose each second. Plan: host picks the nearest of both players (the guest's puppet /
  twin car on the host), guest copies pure puppets with smoothed, faster pose stream, damage / latches to the guest as
  events; a two-instance test. Start by reading how each hazard finds its target (BP_Hazard_Leech: Should Go After
  Car, GetPlayerLoc; BP_HazardProperty_PlayerRange; check whether they already see the twin car via GetAllCarActors).
- Unrelated, deferred by the owner: shared loot pickups, gas station fuel, guest exit gate waiting for the host's
  documents, second arrival after a death.

## Alpha 12 (2026-10-26)
- **Alpha 12 built** (`local/release/PacificDriveCoop-0.1.0-alpha12.zip`, install-test 10/10, symbols in
  `local/release/symbols/0.1.0-alpha12`): point 3 as far as it goes without the rework - no driver seat in the
  other's car, entry through a free-seat door with the game's animation (tap; hold / taken seat = door only), the
  owner's real door opens and shows on the twin, side mirrors lit + the other car visible in the own mirrors, the
  seated puppet's legs inside the car (`M.legPose`), pose-cache fix, ExecuteWithDelay removed everywhere.
  Quick suite PASS (contact-test rewritten for the twin rules, 8/8). NOTES "Point 3" (end: "Finished for alpha 12").
- Owner still to test alpha 10/11/12 with the friend: ask for BOTH report zips; ask how the puppet's legs look.
- The twin rework followed (owner's decision; memory `twin-native-rework`): see "Latest" above.

## Where things stand (before point 3)
- **Alpha 0.1.0-alpha10** built: `local/release/PacificDriveCoop-0.1.0-alpha10.zip` (install-test 10/10). Not tested in a
  real game yet: the owner tests later with a friend - ask for BOTH players' report zips (Report.bat / F7 "Собрать
  отчёт"; hitches.log differs per side). Versions and what changed: `mod/release/CHANGELOG.txt` (Russian; add an entry
  before every build-alpha, check README.txt).
- Last quick suite (2026-10-26): all PASS except the known ghostseat lever flake (passes on rerun); f7 / esc / menu
  rerun PASS after the last menu fixes. Full suite (foot tests) not run since alpha 7 (on-foot mode is frozen).
- After alpha10 (2026-10-26): robustness round (NOTES "Robustness round"): hooks.lua, per-module cost in hitches.log
  F lines, host pass in C++ (state 4.4 -> 0.55 ms per frame), symbols per build + `tools/crash-stack.ps1`. Not in a
  zip yet - goes into alpha11.
- Real tests so far: alpha 4 (no connect), 6, 8 (one player), 9 (both players). Alpha 9's findings are fixed in alpha10
  (NOTES "Owner's real test of alpha 9", "The esc-test crash of this round").
- Test cases doc for the owner and friend (Claude Docs «CoopSync альфа: установка и тест-кейсы»,
  https://claude.ai/artifact/Hz1wWLEvnHgJFQiTmKSwCo): written for alpha 2-5, outdated (on-foot cases, CoopNet.exe).

## What the mod does (two players, each in its own car)
- Lobby: Steam friends-only lobby inside the game (`mod/CoopNative/net.cpp`, through the game's steam_api64.dll; the
  mod waits for the game's Steam). Menu: «Кооператив» in the pause menu (`menu.lua`: lobby, invite friends, leave) and
  the **F7 panel** (`panel.lua`: the same plus debug actions and "Собрать отчёт").
- Start flow: the lobby gathers in the garages (each sees the other's puppet; the guest's map table, time of day and
  weather are the host's); the guest's garage exit stays shut until the host leaves; driving out takes the guest to
  the host's zone (no junction pick), its car next to the host's; a run member that went home can come back.
- In the zone: the host's world list (spawns, loot, buildings' dressing) imported on the guest (~99 % of replicated
  classes, ~91-94 % of the whole zone) and cleaned up, hazards / mines / loot pickups via the host, players as puppets
  (interpolated), the other's car as a **twin** (a real car copy styled like the owner's, kinematic, driven by the
  stream; `twincar.lua`), weather / time of day from the host, next legs follow the host, going home rules.
- Everything travels in memory over the in-game network: lines (state + fast channels) and the host's documents
  (zone list, run descriptor, gates, map, session line; `link.lua` "doc:<name>"). Files only without it (relay tests).
- On-foot mode (guest riding in the host's car) exists but is frozen since alpha 7 (owner: cars only for now).

## Files
- Mod Lua `mod/CoopSync/Scripts/`: main, link (network / documents), hooks (every RegisterHook, safe), session (automation, gates, map sync), spawnsync
  (world list, import / cleanup jobs, native helpers), lootsync, statesync (host events, hazards), playersync (puppets,
  seats, cars, wheel), twincar, carghost (old ghost car, fallback), runsync (travel, insurance), mapsync, weathersync,
  menu, panel, hitch (hitches.log: G gaps, O ops, N job notes, F fps / mod ms per 10 s).
- Native half `mod/CoopNative/`: dllmain.cpp (Lua registration), net.cpp (Steam lobby + P2P, local test link,
  documents), world.cpp (class tags, Find / Under / TreePaths / ZoneCounts / OuterMap / ParentMap, HasPath, weak
  handles, TrackSet / TrackMoved / TrackNear). Built by `mod/native/build.bat` (build dir `local/native-build`) with UE4SS from source (`local/ue4ss-src`, commit 83330635);
  `UE4SS.pdb` there symbolizes crash dumps (cdb from Windows Kits\10\Debuggers\x64).
- Test-control mod `mod/CoopDev` (polls `local/instances/<tag>/coopdev/cmd.lua`). Tools `mod/tools/`:
  `run-all-tests.ps1 [-Quick|-Only a,b]` (16 quick tests incl. revisit, f7, esc, menu), `deploy.ps1` (Lua + DLLs),
  `start-zone.ps1`, `send.ps1`, `netlink.ps1` (tests' network: COOPSYNC_NET=tcp:<port>:<name>), `menu-shot.ps1`
  (screenshots of the menu), `steam-net-probe.ps1` (real Steam, one account), `build-alpha.ps1 -Version x`,
  `install-test.ps1`, `crash-stack.ps1 -Report <zip>` (dumps of a report with that build's symbols from
  `local/release/symbols/<version>`), probes in `tools/cmds/`.
- Release scripts `mod/release/` (install / uninstall / common, README, CHANGELOG); report `mod/CoopSync/tools/collect-report.ps1`.
- Old: `mod/net/CoopNet/` (C# helper, COOPSYNC_NET=exe fallback, not packed), `mod/net/relay.ps1` (relay tests).
- Test copy of the game `testgame/` (our UE4SS build; prebuilt originals in `local/ue4ss-prebuilt-backup`).
  Instances / userdirs `local/instances/`; owner's reports unpacked in `local/reports/`.

## Rules that bit before (also in memory)
- Never touch the real install / real saves: test copy + `-userdir`. One test run at a time. `-dx11` with graphics.
  Quick suite after changes. Ask before installs / downloads / accounts / publishing.
- UE4SS: `LoopInGameThreadWithDelay` ignores `return true` (use the `loop()` helpers); no UE4SS call inside Lua
  coroutines (jobs of steps: `Sync.runJob`); never keep Lua UObject objects across frames (paths or weak handles);
  in the frame a car's parts are spawned again touch nothing of that car, count frames not ms.
- UE4SS StaticFindObject on a missing path walks every object (~50 ms): use `SFO` (CoopNative_HasPath first).
- An error raised inside a UE4SS C++ call (failed RegisterHook, property of a bad object) degrades the Lua state even
  under pcall - repeated, the game crashes later somewhere in Lua: hook only through hooks.lua (CoopSyncHook), check
  before other risky calls, never let a loop repeat an erroring call. Crash rates need 8-run batches.
- Never key registries by object address (a new object can come at an old address: the own car taken for a twin);
  never trust paths across worlds (names come again on a second visit).
- PowerShell 5.1: scripts with Russian text need UTF-8 **with BOM**; Lua files **without** BOM; never name helpers
  like aliases (R, Sv, LS, Kill, $args).

## Known problems / risks (2026-10-26)
1. Unverified in a real game: alpha 8-10 network on two Steam accounts (P2P, NAT, latency), the in-memory documents,
   the second-visit fixes. The alpha 9 host showed ping 495 ms (during the 32 s freeze?) - real latency unknown; the
   puppet / twin stream assumes ~120 ms interpolation.
2. Frames still long: the arrival load (game, 12 s), the twin spawn (0.3 s), the import / cleanup spread over ~400 /
   ~80 frames (the guest plays meanwhile, the zone fills in during ~10 s); low fps under GPU load never measured here
   (headless) - the owner's F lines will tell.
3. Flaky tests: ghostseat lever (~1 in 3), drive (~1 in 4), esc / f7 key delivery (retries added).
4. Untested here: two Steam accounts, long sessions (hours), several legs in a row with cars, going home with loot in
   own-car mode at scale, death of a player in co-op.
5. UE4SS fragility: experimental build, Lua state degrades on C++ errors; the more logic moves to C++ the safer.
6. The owner's test-case doc is outdated.

## Next work (proposal, owner decides the order)
1. The owner's real test of alpha 10 -> fix from both report zips (hitches.log F lines = real fps / mod share).
2. Test gaps: a 2-hour soak (several legs, home, out again) with fps / mod ms checks; a death-in-co-op test; an
   update of the test-case doc for alpha 10.
3. Twin car of the other player: steering wheel / ignition / lights / screens as the owner drives (some done),
   collisions between the two cars.
4. Owner's list: radio sync (custom tracks), 3-4 players, on-foot mode back (riding in the host's car), ARC device
   as removable, paint.
5. Robustness: done in part (NOTES "Robustness round"); left: player sync ~2 ms per frame on the guest (twin pose,
   puppets), the guest's detection pass ~1.2 ms, single long import steps.
