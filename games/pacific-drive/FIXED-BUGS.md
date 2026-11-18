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

## 2026-11-17 - the action audit crashed at startup and test processes stayed open
Symptom:   CoopSync died in construct_fname before "[CoopSync] loaded"; CrashReportClient and test games stayed until
           the user closed the report window by hand.
Cause:     audit.event called CoopSync.worldName before the first UWorld existed. start-zone also had no failure
           cleanup, and repeated launches accumulated copies with the same -userdir.
Found by:  the startup dump and A/B file groups; dofile/start after the fix and audit-test.
Fix:       audit reads only session S.world (assigned at a normal session tick), with no engine lookup at startup;
           CoopDev starts the audit for bots too. start-zone kills only the same tag's old processes and catches errors
           by closing the new process and CrashReportClient.
Commit:    -    Test: audit-test.ps1 (4/4, in the quick suite); real report ZIP contains audit.log/.1/.2.
           Note: crash-path cleanup has not been exercised by another deliberate crash; do not claim that separately.

## 2026-11-17 - the host's drop waited for full zone rescans
Symptom:   the host dropped an item and the guest saw it 1.8-3.2 s later; the target was 1 s.
Cause:     an inventory change forced three root scans and a serialization pass after each; the new item had no host
           event until that pipeline reached it.
Found by:  loot-live timings plus the hostLive / invScan / scanFrame path in statesync.
Fix:       statesync hostLiveDrop sends a new nearby world item directly now, +0.3 and +1 s; hostPathAdd puts its key
           into the pass cache so the next pre-scan pass cannot send D. The extra invScan rounds were removed.
Commit:    3d9f570    Test: loot-live 15/15 repeatedly and in the quick suite; host drop 405-427 ms

## 2026-11-17 - a second visit spawned runtime actors already loaded from the save
Symptom:   revisit applied bursts of S at 30-600 ms each; duplicate wreck spawns could end in a game crash.
Cause:     actors loaded from the host's zone save had new local paths and no host-key mapping; a runtime S spawned
           another copy. W| adoption also serialized every unmapped world item instead of only predicted drops.
Found by:  revisit's per-S adopt/spawn+loot hitch records; failed alternatives and two matching experimental dumps
           are documented in NOTES (normal Sync.deref replacement-at-path must be retained).
Fix:       statesync adoptExisting reuses the nearest unmapped same-class runtime actor within 50 cm, with an
           event-frame-only cache; adoptPredicted checks only actual dropAsked items.
Commit:    3d9f570    Test: revisit functional checks pass and the long duplicate S bursts are gone; its total < 8 ms
           budget remains open (players / session / arrival work included)

## 2026-11-16 - the test saves were rejected when Steam was not running
Symptom:   every reference-save load stopped after "CheckRootBlockDLC: Missing mounted DLC" and "SAVEFILE CONTAINS
           MISSING ENTITLEMENTS"; start-zone then spent four minutes waiting and continued in RB_MainMenu, making the
           quick suite's results meaningless.
Cause:     Steam was not running. The DLC pak was mounted, but PlatformIntegrationSteam failed SteamAPI_Init, so the
           game reported that the player did not own PDFeature_Fig and refused saves carrying its entitlement.
Found by:  the current and previous game logs compared: the working load had "Successfully initialized
           PlatformIntegrationSteam" and "Entitlement checks out ... PDFeature_Fig"; the failed one had neither.
Fix:       game-args.ps1 starts Steam when needed and waits for its ActiveProcess pid; start-zone.ps1 checks Steam
           initialization and the PDFeature_Fig entitlement before UserLoadGame and stops at once with a clear error.
Commit:    5e20e9e    Test: start-zone.ps1 after steam.exe -shutdown: Steam auto-started, the reference zone loaded

## 2026-11-15 - the other's car tipped nose down / jolted round at a hand-over to the driver
Symptom:   the guest takes the host's wheel: the host's car (both sides) thrown tail up ~1 m, nose down 20-34 degrees
           for a second (1 in 2 at one spot); with that held off, a sideways jolt (2.4 m/s, turning 255 deg/s) the
           moment the driver's door shut at the end of the entry.
Cause:     the twin's doors' hinges (PhysicsConstraint, door mesh - chassis). Kinematic, the twin's doors are put by
           the owner's pose stream (doorEase) and the mod's own eased shut (TD.onDoorCall), off the frames the hinges
           were made with; the first physics step of the chassis (Twin.setDriven) pulled the car onto its doors, and
           a door the mod still moved on the driven car pulled it every frame. Not a contact: no hit event at all.
Found by:  mod/tools/dive-probe.ps1 (per-frame physics of the twin, first-frame overlaps, observing hooks on the
           exit's and the chassis' hit events), after ruling out capsule, stale velocity, controller state, lever,
           world-dynamic objects, wheels, ground (NOTES 2026-11-15); the shut doors' constraints broken by hand: none.
           Reseating a hinge while the chassis simulates threw the car 8.6 m up - only on a kinematic one.
Fix:       twincar.reseatDoors (shut doors' hinges set again where they stand, the twin still kinematic, in
           setDriven on); doorEase and the eased shut skip a simulating twin (M.simulating: its doors the game's);
           playersync TD.entrySettled: the drive starts once the player is seated (PercentInCar) and no mod-driven
           door ease is still running (Twin.doorsSettled), 4 s at most; an open door simulating by the game is left
           to the game and does not block the hand-over.
Commit:    5e20e9e    Test: dive-probe.ps1 (8 entries, 0.6 deg at most), entry-spin-test.ps1 (5/5, in the quick suite)
Update:    2026-11-17 - a residual repeated-entry dive reproduced later (21-30 deg). Three new hypotheses were
           disproved and reverted; this entry is only a reduction, not a complete fix. See NOTES "Residual nose dive".

## 2026-11-15 - "the car turns on the spot as I get in" (owner's item j)
Symptom:   now and then a car turned round, jumped or tipped as a player got into a car; entry-spin-test (new) saw a
           car moved 2.75 m and turned 22.5 degrees in one frame, cars thrown at up to 28 m/s, one rolled 131 degrees.
Cause:     three things, each found by sampling both cars on both sides every frame around the entries:
           1. TD.clearOwnCar (the guest's car out of the host's twin, 30 s after a twin spawn) took centres under 4.5 m
              apart for "inside": a car parked beside the host's was moved and turned to the host's car's yaw;
           2. a hit (bumpTick) was read from any jump of the own car's speed within 9 m of the twin, even with the cars
              not closing and with the own car kinematic (the other player driving it) - the shared speed went to
              the other side's car;
           3. a player turned down at the other's wheel (ghostLeave): the manager went back to the own car at once and
              the game's exit finished on it - the player put at the own car's exit, in its body, throwing it about.
Found by:  entry-spin-test.ps1 (every way in, both sides, the series around the worst frame), probes of the drive
           hand-over, the context switch and the own car's speed (TD.spinWatch now notes any such turn: "spin:" in
           the hitch log, the report).
Fix:       runsync.clearOfTwin: inside = the centre within the twin's footprint (460 along, 200 across), the car keeps
           its own yaw; twincar.bumpTick: the cars closing by >= 150 cm/s, and never for an own car not simulated here;
           ghostLeave (native cars): the other's car stays the context through the game's exit, no detach / teleport
           of the mod's unless still attached 2.5 s on. The nose dive at a hand-over: the entry above.
Commit:    9fcaa3f    Test: entry-spin-test.ps1 (5 of 6), cars, collide

## 2026-11-15 - the guest's game crashed in a wreck's SetupMaterials after a join
Symptom:   the guest's game died 2-6 s after a join (startflow, nextzone, revisit: 4 of ~12 runs), an access violation
           in a game function called from Lua, "MaterialInstanceDynamic ... is not a valid parent" right before.
Cause:     every host VP line (a wreck's paint, all every 20 s) ran SetupMaterials / SetupTintOnVehicleAndParts on the
           guest's wreck again; after a join from the host's zone save the wrecks already carry the host's palettes,
           and doing it again made MIDs of their MIDs - the crash inside it (crumb.txt: "state ev VP").
Found by:  hitch.lua crumbs (the step's name written before it runs, for 30 s after a sync start).
Fix:       statesync CoopSyncPaint.handle: the same palettes and the dynamic materials there - nothing set up again
           (ap_VP_same); the parts' paint as before. No crash in the runs since (startflow, nextzone, revisit,
           part-break, paint).
Commit:    9fcaa3f    Test: paint-test.ps1, startflow-test.ps1, nextzone-test.ps1

## 2026-11-15 - the guest's car stood with its engine off after the one load
Symptom:   knock-test: the guest's car did not drive; a player who drove out of its garage arrived with the engine off.
Cause:     a zone save loads the car with the ignition off; the travel used to bring it running.
Fix:       zonesave: the ignition at the drive-out kept (wasIgn); running then, the engine started again after the load
           (M.engineBack, the game's ToggleIgnitionState(2)).
Commit:    9fcaa3f    Test: knock-test.ps1

## 2026-11-15 - tests: collide's striker curved past, trunk's sample count, cars' brakes
Symptom:   collide: the striker passed the twin by 280 or rode up on it (centres 70 apart in the plane); trunk: the
           host's lid "not watched long enough" at 9 fps; cars 8b: the car still rolling when the host got out.
Fix:       collide-probe: the striker turned to face the twin at the launch, the closest approach in 3D; trunk-test:
           > 40 samples; cars-test: the foot brake through the pedal stage too, up to 20 s to stop.
Commit:    9fcaa3f    Test: collide, trunk, cars

## 2026-11-14 - the guest's detection pass ran back to back; its drops reached the host late
Symptom:   revisit: the mod's state sync took 4.5-26 ms a frame on the guest; loot-live: the guest's dropped item
           reached the host 1.2-4.5 s late (limit 1 s), the step flaky for weeks.
Cause:     the guest's detection pass (every mapped actor, 2 ms a frame) started TICK_MS after the last one STARTED;
           ~1100 actors took ~2.5 s at 25 fps, so a new pass began the moment one ended - for good - and drops
           were only looked for at a pass's end.
Found by:  timing every sub-tick of the state loop (M.profile t_*), in the real session's Lua state (send -Session).
Fix:       the next pass TICK_MS after the last one ENDED; a change of the player's inventory looks for drops at
           once and 0.3 / 1 s on (not at the pass's end). Host: the roots' filtered list cached per root scan
           (rebuilt every pass, part of its 15 ms), a third root scan 0.8 s after its own drop. Guest state
           3.1-3.3 ms a frame now; the guest's drop on the host 375-747 ms. Still flaky: the host's drop on the
           guest, 391-1240 ms (1 of 3 runs over).
Commit:    a66c4b9    Test: loot-live-test.ps1, revisit-test.ps1

## 2026-11-14 - zone to zone: the guest generated the next zone, then loaded the host's over it
Symptom:   nextzone / staybehind: from the guest's zone exit to playing in the next zone 57-62 s - the game's travel
           generated the zone (~20 s), then the host's zone save was loaded over it.
Cause:     the one load (own save + the host's Map spliced in) was only done from the garage; a zone exit followed
           the host by the game's travel (Run.follow).
Found by:  the guest's timelines in nextzone / staybehind after the garage join was made one load.
Fix:       session.lua zoneExitTick: at the exit the guest waits for the host's zone save and its file, then
           Run.prepareLeg (the leg only, no car insurance mid-run) + ZoneSave.directStart(path, "zone"); the arrival
           is the garage's one-load arrival. Fallback: the old follow if the load fails or comes back to this zone.
           40-42 s now. Also weathersync: after the one load the host's random north pick gave the guest 180 off -
           the host's north is set as it is when RandomizeNorth leaves it off.
Commit:    c51a736    Test: nextzone-test.ps1, staybehind-test.ps1

## 2026-11-14 - slow guest join: two loads when the guest drove out early
Symptom:   owner's two-games test: the guest's load was slow. The game logs: the guest drove out 0.4 s before the
           host's zone save, travelled (4.3 s), generated the zone itself (~14 s), then loaded the host's save
           (9.5 s) - in startflow 56 s from the host's arrival to the guest playing, "LOAD V4 Map 2, FAILED 1".
Cause:     session.lua took the one load from the garage only when the host's session line already named its zone
           save AND its file had arrived; otherwise it fell back to the old travel at once. The host publishes the
           line with list=- on arrival (from before zone saves: the guest generated meanwhile), and the save's file
           comes a moment after the line.
Found by:  the report's game logs (LoadMap / SAVE V4 times on both sides), then startflow's "one load not started:
           no host zone save yet".
Fix:       the drive-out waits (under the cover, SAVE_WAIT_S 90 s at most) for the host's save and its file
           (ZoneSave.hostSaveReady), then the one load; the old travel stays the fallback. startflow: 29 s, one load.
Commit:    c51a736    Test: startflow-test.ps1

## 2026-11-14 - the guest arrived in the host's zone standing beside its car
Symptom:   startflow-test (2 of 2 runs): the guest drove out of its garage seated, joined, and stood by its car.
Cause:     the zone save load re-seats the player only if it sat at the wheel when the load began; on arrival the
           mod moves the car to the host's entrance (2 km here) first, and the player was off the seat by then.
Found by:  startflow's "seated=false" with "car moved 2058 m to the host's entrance" just before "zone save load".
Fix:       session.lua records at the garage exit whether the guest sat at the wheel (ZoneSave.droveOutSeated);
           zonesave.lua re-seats after the load if it sat then or sits now (M.seatedNow).
Commit:    f6975c7    Test: startflow-test.ps1

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
Commit:    f6975c7    Test: drive-test.ps1, wheel-test.ps1, cars-test.ps1

## 2026-11-14 - back seat: the exit lit only when looking straight at the side
Symptom:   owner's two-games test: on a back seat the door highlight came up only looking right at the door.
Cause:     the exit's highlight boxes (UICollision_ExitHandle / 2, 62 long) were moved to the back door hinge to
           hinge (dx = -123): centred at X -65, while the back door's own box spans -72..8 - half the box stood past
           the door's back edge and the door's front half had none.
Found by:  live probes of the boxes' places / extents on a reference car (the door's Interactive box, the handles).
Fix:       playersync.lua TD.placeExit: for seats 3 / 4 the handles go to the door's middle (40 behind the hinge,
           TD.BACK_DOOR_MID); the exit's points keep the hinge-to-hinge move. Not verified by a look from inside (the
           seated camera does not follow the control rotation in a test) - owner to check.
Commit:    f6975c7    Test: backseat-test.ps1 (the way out by the back door)

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
Commit:    f6975c7    Test: backseat, gascap, knock, loot-live, drive, wheel, twin-ctl, collide, owncar

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
Commit:    f6975c7    Test: part-break-test.ps1

## 2026-11-14 - back seat: the camera looked through the back of the car
Symptom:   owner's two-games test: on a back seat the player sat too far back, the camera in the rear of the car.
Cause:     playersync.lua BACK_X = -60 was a guess ("headless: nobody looked at it").
Found by:  the devices the back seats hold, probed in the Quick start car: battery X +12..-64, fuel tank +7..-92 -
           the back rest at about -64; the hips ~20 in front of it.
Fix:       BACK_X = -45 (tests' seat tables too). Needs the owner's look in a real game.
Commit:    f6975c7    Test: drive-test, seats-test, anim-test (seat places)

## 2026-11-14 - after a first sit on a back seat the driver's door seated the player at the back
Symptom:   owner: "the host can't get to the wheel, the driver's door sits him at the back, even on a seat with a
           fuel tank" - in both cars.
Cause:     playersync.lua measured the driver's seat from the player's first seated frame of a session and built all
           seats from it; a first sit on a back seat was taken for the driver's (-60,-45.8 measured).
Found by:  live in the owner's session: selfInfo driver_seat_measured=-60.0,-45.8; reproduced with the host (back
           left first -> -60; driver's door first -> 46.5).
Fix:       seats are constants (seatRel: 46.2,-45.8,-12.3 mirrored, BACK_X behind), the socket delta from
           TempSocket_Seat's class default 27,-46,-16; the measure stays for diagnostics only.
Commit:    f6975c7    Test: seat-measure-test.ps1 (back seat first, then the driver's door)

## 2026-11-14 - the guest's garage took the host's zone weather
Symptom:   owner: when the host loaded into the zone before the guest left the garage, the guest's garage got the
           host's run weather.
Cause:     weathersync.lua applied every W line whatever the two sides' worlds.
Found by:  reading weathersync after the owner's report.
Fix:       weathersync.lua garageApart: this side in a garage, the host's world (W field 19) not one -> skip and drop
           the override once.
Commit:    f6975c7    Test: -

## 2026-11-14 - the guest's car arrived inside the host's car
Symptom:   owner: loading into the zone, the guest's car spawned exactly inside the host's car, the two flew apart.
Cause:     not found (the report had no mod log of that start - see the log rotation entry). The gate check works
           on the saved positions; the host's real car can stand elsewhere.
Found by:  the owner's report; the root cause still open.
Fix:       safety net: playersync.lua TD.clearOwnCar (30 s after the twin spawns, the guest's own car within 4.5 m of
           the host's twin is moved beside it: runsync.lua M.clearOfTwin / M.moveCar).
Commit:    f6975c7    Test: -

## 2026-11-14 - the driven car's parts' damage differed after a crash
Symptom:   owner: driving the host's car as the guest and crashing, a panel was full red on the guest, white on the
           host.
Cause:     the host's game also crashed its copy (the twin there, kinematic) and its own values went back over the
           driver's; both sides were authoritative for the same part.
Found by:  reading twincar watchState / applyState after the report.
Fix:       twincar.lua M.drivenHere: the side whose player drives the twin (it simulates there) sends its state and
           does not take the owner's.
Commit:    f6975c7    Test: carswitch-test.ps1

## 2026-11-14 - the report had no mod log of a crashed game
Symptom:   the owner's report after a crash and restart: coopsync.log / hitches.log only of the new start.
Cause:     main.lua and hitch.lua opened their logs with "w" at every start.
Fix:       the logs rotate (.1, .2) before they are opened; collect-report.ps1 takes them.
Commit:    f6975c7    Test: -

## 2026-11-14 - tests: the player stood beside the car, the guest's zone was another map
Symptom:   the first suite on the reference saves: drive / wheel / cars failed "own character on seat 1", the
           client's car copy 35 km off.
Cause:     a zone save loads the player on foot (a departure seats it); the guest's zone save was another map, and
           sync-test imports the host's world over it (the old start had both in the story's first zone).
Fix:       start-zone.ps1 seats the player (CommandEnterCar) after a zone load; make-zone-saves.ps1 puts both roles'
           zones on the host's map; revisit-test pins the second trip's map; car-store / twin-state start from the
           Quick start car's contents (trunk emptied of the test's kinds, a fuel can fitted, the wheel compared
           with what it was).
Commit:    f6975c7    Test: the suite

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
Commit:    f6975c7    Test: every test booted through start-zone.ps1

## 2026-11-14 - garage dialogue never advanced, no subtitles, quest not updated
Symptom:   in a test game the garage conversation after Quick start never started, the quest did not update.
Cause:     the test games ran with -nosound; the dialogue waits for its voice line to finish playing.
Found by:  the owner noticed it in a manual Quick start; same build with sound worked.
Fix:       tools/game-args.ps1: sound on by default (COOPTEST_SOUND=0 turns it off).
Commit:    f6975c7    Test: -

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
