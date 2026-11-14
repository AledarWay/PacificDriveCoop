# Fixed bugs: symptom, cause, fix

One entry per fixed bug, newest first. Written for the next time something similar shows up: what it looked like,
what it really was, how it was found, what was changed. The engineering log with the whole story is NOTES.md; the
player-facing text is mod/release/CHANGELOG.txt.

Format:

```
## YYYY-MM-DD - short name
Symptom:   what the player / the test saw
Cause:     what was really going on
Found by:  how (probe, recording, test), so the method can be reused
Fix:       what changed (file:function)
Commit:    hash    Test: which test covers it now
```

---

## 2026-11-14 - the guest arrived in the host's zone standing beside its car
Symptom:   startflow-test (2 of 2 runs): the guest drove out of its garage seated, joined, and stood by its car.
Cause:     the zone save load re-seats the player only if it sat at the wheel when the load began; on arrival the
           mod moves the car to the host's entrance (2 km here) first, and the player was off the seat by then.
Found by:  startflow's "seated=false" with "car moved 2058 m to the host's entrance" just before "zone save load".
Fix:       session.lua records at the garage exit whether the guest sat at the wheel (ZoneSave.droveOutSeated);
           zonesave.lua re-seats after the load if it sat then or sits now (M.seatedNow).
Commit:    pending    Test: startflow-test.ps1

## 2026-11-14 - throttle written by the mod never reached the car (the pedals' own stage overwrote it)
Symptom:   with the reference saves every driving check moved 0: the other player's throttle arrived (in_applied
           counted) but the car stood; the host read throttle 0 with the client's steer 0.25 next to it.
Cause:     the car BP has a pedal stage of its own: raw axis (RawThrottle) -> ThrottleTarget / ThrottleCurrent ->
           UserThrottleInput -> the vehicle controller. Headless with -nosound it did not run, so writing the User*
           fields drove the car. With sound on (the tests' new default, as a real game) it runs every frame and
           rewrote UserThrottleInput from its own 0. The same in a real game: the mod's hold-off of the pedals for a
           back-seat player (ZERO every frame) lost to it too.
Found by:  throttle-probe.lua: User* written 1 -> controller 0, moved 0; the game's own AccelerateBrake(1) -> moved;
           User + Raw + Target + Current written -> controller 1.0, moved 2664 in 3 s.
Fix:       playersync.lua writeInput also writes RawThrottle / ThrottleTarget / ThrottleCurrent and BrakeTarget /
           BrakeCurrent; the tests' own throttle loops (cars, carswitch, owncar) the same.
Commit:    pending    Test: drive-test.ps1, wheel-test.ps1, cars-test.ps1

## 2026-11-14 - back seat: the exit lit only when looking straight at the side
Symptom:   owner's two-games test: on a back seat the door highlight came up only looking right at the door.
Cause:     the exit's highlight boxes (UICollision_ExitHandle / 2, 62 long) were moved to the back door hinge to
           hinge (dx = -123): centred at X -65, while the back door's own box spans -72..8 - half the box stood past
           the door's back edge and the door's front half had none.
Found by:  live probes of the boxes' places / extents on a reference car (the door's Interactive box, the handles).
Fix:       playersync.lua TD.placeExit: for seats 3 / 4 the handles go to the door's middle (40 behind the hinge,
           TD.BACK_DOOR_MID); the exit's points keep the hinge-to-hinge move. Not verified by a look from inside (the
           seated camera does not follow the control rotation in a test) - owner to check.
Commit:    pending    Test: backseat-test.ps1 (the way out by the back door)

## 2026-11-14 - tests: a zone save starts with the engine off, back doors aimed at their hinge
Symptom:   (tests only) driving checks with the engine off; the guest's back door never lit in backseat-test, and its
           driver's door got taken off.
Cause:     a zone save loads the car with the ignition off (a departure arrives with it running); the look probe aimed
           at the door actor - the hinge, the box's very edge - from an eye 60 too high (before the character landed);
           the test pressed the seat exit with the player already on foot (that takes the driver's door off).
Found by:  throttle-probe (ign=0), the highlight manager's CacheHits (the seat slots' boxes instead of the door's).
Fix:       start-zone.ps1 starts the engine; twin-parts-look.lua aims at a back door's middle and re-aims from the real
           camera after landing; backseat-test uses Out (exit only when seated); gascap-test sums the car's tanks
           (an internal one and BP_CarPart_FuelTank_Base_Backseat); knock-probe falls back to young pines / small oaks
           and kicks the one nearest the guest (its side swaps in only those near its player); loot-share picks doors
           near the player and loot-live only doors both sides have loaded (a zone's doors can all sit in an
           underground site 30 km off); drive / wheel get the client out first (a zone start seats it on a back
           seat); twin-ctl starts the guest's engine before its wipers; the driver's-seat measure (diagnostics) no
           longer takes a back seat for the wheel. Since the throttle goes through the pedals' stage: collide-test
           no longer holds the gas 5 s before its launch (the car drove ~1500 past the aim spot, beside the twin, the
           launch missed it); the tests' brakes set BrakeTarget / BrakeCurrent too (owncar's car never braked and was
           still moving at the comparison).
Commit:    pending    Test: backseat, gascap, knock, loot-live, drive, wheel, twin-ctl, collide, owncar

## 2026-11-14 - a reloaded zone's wreck parts all counted as one
Symptom:   part-break-test on the reference zone save: the wreck's parts listed as one part "None", sawing showed on
           neither side, the abort "array index evaluated to null".
Cause:     a zone loaded from a save gives every LootableTemplatePart MySocket = None (all 674 in the zone, every
           wreck class); the game does not save it. The mod keys wreck parts by socket everywhere (loot list, WRK
           health, trunk states, DETACH), so all parts of a wreck collapsed to one key. Players hit it when they
           continue a run from a save.
Found by:  the reference saves (the tests used to start in a freshly generated zone); a probe of MySocket per class,
           then each part's distance to the wreck mesh's sockets (0.0 for every part).
Fix:       lootsync.lua M.sockOf: MySocket, or (None) the parent mesh's socket at the part's place, written back to
           MySocket; statesync/lootsync and the test probes read sockets through it.
Commit:    (pending)    Test: part-break-test.ps1

## 2026-11-14 - back seat: the camera looked through the back of the car
Symptom:   owner's two-games test: on a back seat the player sat too far back, the camera in the rear of the car.
Cause:     playersync.lua BACK_X = -60 was a guess ("headless: nobody looked at it").
Found by:  the devices the back seats hold, probed in the Quick start car: battery X +12..-64, fuel tank +7..-92 -
           the back rest at about -64; the hips ~20 in front of it.
Fix:       BACK_X = -45 (tests' seat tables too). Needs the owner's look in a real game.
Commit:    (pending)    Test: drive-test, seats-test, anim-test (seat places)

## 2026-11-14 - after a first sit on a back seat the driver's door seated the player at the back
Symptom:   owner: "the host can't get to the wheel, the driver's door sits him at the back, even on a seat with a
           fuel tank" - in both cars.
Cause:     playersync.lua measured the driver's seat from the player's first seated frame of a session and built all
           seats from it; a first sit on a back seat was taken for the driver's (-60,-45.8 measured).
Found by:  live in the owner's session: selfInfo driver_seat_measured=-60.0,-45.8; reproduced with the host (back
           left first -> -60; driver's door first -> 46.5).
Fix:       seats are constants (seatRel: 46.2,-45.8,-12.3 mirrored, BACK_X behind), the socket delta from
           TempSocket_Seat's class default 27,-46,-16; the measure stays for diagnostics only.
Commit:    (pending)    Test: seat-measure-test.ps1 (back seat first, then the driver's door)

## 2026-11-14 - the guest's garage took the host's zone weather
Symptom:   owner: when the host loaded into the zone before the guest left the garage, the guest's garage got the
           host's run weather.
Cause:     weathersync.lua applied every W line whatever the two sides' worlds.
Found by:  reading weathersync after the owner's report.
Fix:       weathersync.lua garageApart: this side in a garage, the host's world (W field 19) not one -> skip and drop
           the override once.
Commit:    (pending)    Test: -

## 2026-11-14 - the guest's car arrived inside the host's car
Symptom:   owner: loading into the zone, the guest's car spawned exactly inside the host's car, the two flew apart.
Cause:     not found (the report had no mod log of that start - see the log rotation entry). The gate check works
           on the saved positions; the host's real car can stand elsewhere.
Found by:  the owner's report; the root cause still open.
Fix:       safety net: playersync.lua TD.clearOwnCar (30 s after the twin spawns, the guest's own car within 4.5 m of
           the host's twin is moved beside it: runsync.lua M.clearOfTwin / M.moveCar).
Commit:    (pending)    Test: -

## 2026-11-14 - the driven car's parts' damage differed after a crash
Symptom:   owner: driving the host's car as the guest and crashing, a panel was full red on the guest, white on the
           host.
Cause:     the host's game also crashed its copy (the twin there, kinematic) and its own values went back over the
           driver's; both sides were authoritative for the same part.
Found by:  reading twincar watchState / applyState after the report.
Fix:       twincar.lua M.drivenHere: the side whose player drives the twin (it simulates there) sends its state and
           does not take the owner's.
Commit:    (pending)    Test: carswitch-test.ps1

## 2026-11-14 - the report had no mod log of a crashed game
Symptom:   the owner's report after a crash and restart: coopsync.log / hitches.log only of the new start.
Cause:     main.lua and hitch.lua opened their logs with "w" at every start.
Fix:       the logs rotate (.1, .2) before they are opened; collect-report.ps1 takes them.
Commit:    (pending)    Test: -

## 2026-11-14 - tests: the player stood beside the car, the guest's zone was another map
Symptom:   the first suite on the reference saves: drive / wheel / cars failed "own character on seat 1", the
           client's car copy 35 km off.
Cause:     a zone save loads the player on foot (a departure seats it); the guest's zone save was another map, and
           sync-test imports the host's world over it (the old start had both in the story's first zone).
Fix:       start-zone.ps1 seats the player (CommandEnterCar) after a zone load; make-zone-saves.ps1 puts both roles'
           zones on the host's map; revisit-test pins the second trip's map; car-store / twin-state start from the
           Quick start car's contents (trunk emptied of the test's kinds, a fuel can fitted, the wheel compared
           with what it was).
Commit:    (pending)    Test: the suite

## 2026-11-14 - test games had no hotbar, no Tab inventory, no scan / take-off prompts
Symptom:   in a graphics test window the HUD was cut down: only the door prompt, no inventory bar, Tab did nothing,
           no health bar on parts, empty inventory, empty fuel tank.
Cause:     tools/start-zone.ps1 starts a game with UserNewGame(slot, STORY) and calls TravelToGarage the moment the
           opening level (Narrative_Forest_OlympicOpening_Sentry_01) loads - the opening, where the game sets up the
           HUD, the starting tools and the tutorial hints, never ran. Not a "tutorial mode" flag: IsExpeditionTutorial
           Active was false all along; GiveBasicTools / InitializeInventoryHints / StartFirstTimeExpeditionsFlow
           called by hand did not bring the HUD back.
Found by:  live probes on a graphics pair; the owner's own "Quick start" in the same build gave the full HUD.
Fix:       reference saves made by hand with the game's own Quick start (local/advsave/quickstart-host.sav,
           quickstart-client.sav); start-zone.ps1 loads them (COOPTEST_QUICKSTART=1).
Commit:    (pending)    Test: every test booted through start-zone.ps1

## 2026-11-14 - garage dialogue never advanced, no subtitles, quest not updated
Symptom:   in a test game the garage conversation after Quick start never started, the quest did not update.
Cause:     the test games ran with -nosound; the dialogue waits for its voice line to finish playing.
Found by:  the owner noticed it in a manual Quick start; same build with sound worked.
Fix:       tools/game-args.ps1: sound on by default (COOPTEST_SOUND=0 turns it off).
Commit:    (pending)    Test: -

## 2026-11-14 - a part sawn off came back with a fresh random health on the side that sawed it
Symptom:   part-break-test step 3 "the part broke off" failed: the part was there again with new health.
Cause:     two channels: WRK (health, fast) and lootsync's template parts list (S events, slower). The side that
           broke the part off had it gone; the host had not broken its copy yet, its next S event still listed the
           part, and lootsync.applyDiff attached it again.
Found by:  part-break-test logs: the part reappeared only on the breaking side, never on the other.
Fix:       statesync.lua WRK.brokenHere (wreck address + socket, 20 s) set when a part hit on this side goes
           invalid; lootsync.lua applyDiff skips re-attaching such a socket (WRK.brokenLocally).
Commit:    056ed6e    Test: part-break-test.ps1

## 2026-11-13 - wreck parts kept each side's own random health
Symptom:   part-break-test "the wreck's parts have the host's health" failed now and then.
Cause:     the host's full list sweeps every LootableTemplatePart in the zone; lines for wrecks the guest had not
           imported yet came back "unmapped" from WRK.apply and were dropped for good (only "nopart" was retried).
Found by:  a DIAG block in part-break-test (WRK.missed, applied counts) when the check fails.
Fix:       statesync.lua WRK.apply queues "unmapped" lines into WRK.missed like "nopart".
Commit:    fc9bc38    Test: part-break-test.ps1

## 2026-11-13 - "can't get into the other's car a second time" (carswitch-test)
Symptom:   the second entry into the other player's car failed now and then.
Cause:     not the mod: (a) the test's ExitDoor press sometimes opened the door without letting the player go;
           (b) a physics bump at the test's own teleport knocked the driver's door off (EmptyDoor slot).
Found by:  -Keep runs and live probes of the door classes.
Fix:       carswitch-test.ps1: exit retried until out, ParkHome with physics off, a door check before entering.
Commit:    fc9bc38    Test: carswitch-test.ps1
