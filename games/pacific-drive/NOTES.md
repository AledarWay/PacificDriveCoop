# Pacific Drive — co-op notes

Playbook: https://github.com/cranebeaker/coop-anything (AGENTS.md). No `pacific-drive` entry in
`data/directory.yaml` and no `games/pacific-drive/` folder as of 2026-10-20.

## Game identity (observed 2026-10-20)

- Store: Steam, appid 1458140, buildid 21896301
- Main exe: `<game dir>\PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe`
  - SHA-256 `568BB63476C6DE5FC2B1878572A655DD631DD25BB44FE304E3D96A51F6B98F7E`
- Launcher: `<game dir>\PenDriverPro.exe` SHA-256 `9C559F9BDB6E1C1BC848E622430A69BA80CFEC7143760E04F39B1ACD021CF462`
- Engine: Unreal Engine 4.27 (string `++UE4+Release-4.27` in the shipping exe), project name `PenDriverPro`
- Content: `pakchunk0..4-WindowsNoEditor.pak`, install size ~20.1 GB
- Notable libs: `steam_api64.dll`, PhysX3, Wwise (`AkSoundEngineDLL.dll`), Sentry crash reporter
- OS: Windows 11 Pro 10.0.26100

## Prior work (research)

Observed:
- No official co-op; devs said they focus on single player.
  Source: https://steamcommunity.com/app/1458140/discussions/0/4291439538013940878/
- One modder's co-op attempt reportedly stalled half-way: loot sync and stable player
  movement were the blockers. No repo/build link found yet.
  Source: same thread.
- Nexus Mods has cosmetic mods and a Vortex extension, no multiplayer mod found.
  https://www.nexusmods.com/pacificdrive/mods/19

Unknown:
- Who the stalled modder is, whether their code is public.
- Whether the game ships with replication-ready Blueprints (likely not — single-player).

## Derived / plan candidates

- UE4 4.27 → UE4SS (Lua/C++ hooks) is the standard base (playbook/engine-families.md).
- Biggest sync problem in this game is the car (PhysX vehicle) + the shared loot/inventory.
  First milestone candidate: second player as a puppet sitting in / walking around the car,
  host-authoritative, with car transform streamed from host.

## Test environment facts (observed 2026-10-20)

- The PC is a VMware VM: GPU `VMware SVGA 3D`, D3D feature level 11_0, 4 MB dedicated VRAM.
  - DX12: no adapter → exits. DX11: main menu and intro work, but loading `RB_Garage` crashes
    on the render thread (`CreateUnorderedAccessView ... E_INVALIDARG`, D3D11UAV.cpp:116).
  - `-nullrhi -nosound` runs fine headless through menu → intro → garage → zone. All bot tests use it.
- A plain launch writes to the owner's real `%LOCALAPPDATA%\PenDriverPro\Saved` (it replaced a
  slot-6 backup file once; restored). `-userdir=<dir>` redirects `Saved/` and `Custom/` — always use it.
- Saves from another Steam account (DLC owner) do not load here (owner report) → tests start new games.

## Agent remote control (mod/CoopDev)

UE4SS Lua mod polling `local/coopdev/cmd.lua`, runs it on the game thread, output to `out.txt`.
Tools: `mod/tools/send.ps1`, `wait-state.ps1`, `run-seed-test.ps1`, `compare-snapshots.ps1`.
Working script path to a zone, no input needed:
1. main menu: `DrivingGameInstance:SetMasterSeed(n)`; `BP_SaveGameManager_C:UserNewGame(1, 1)` → state INTRO (3),
   map `Narrative_Forest_OlympicOpening_Sentry_01`
2. `BP_ProgressionManager_C:TravelToGarage(0, true, false, false, 1, out)` → GARAGE (4), `RB_Garage`
3. `Default__BFL_ProgressionHelpers_C:TravelToNextLeg(PlayerController)` → RUN (5), `Rural_Forest_Radio_Scylla_02`
(`UBaseLevelManager.LevelTravel` is a delegate, not callable.)
EGameplayState: 1 MAINMENU, 2 LOADING, 3 INTRO, 4 GARAGE, 5 RUN, 6 DEAD.
ELoadGameFlags has `IGNORE_MASTER_SEED = 8` → the master seed is stored in saves.

## Seed test (2026-10-20, automated, headless)

Question: does the same `MasterSeed` give the same zone layout and loot?
Method: 3 fresh profiles, seed set before `UserNewGame`, path above, 30 s settle, snapshot of every
actor (class + position), matched per class within 50 units.
Observed:
- MasterSeed stayed at the set value through intro, garage and zone (12345 / 12345 / 54321).
- Same zone map each time (first story leg is fixed).
- Same seed a vs b: 55% of actors matched; different seed a vs c: 53%, b vs c: 63%. → no
  difference attributable to the seed.
- Hand-placed/level content matches 100% (building spawners, `SpawnModifierActor`, `BP_SpawnVolume_C`,
  quest items `BP_Resource_Narrative_Q01_*`, `BP_GameplayEventItem_World_C`).
- Procedural content does **not** match with the same seed: lootables 4 of 37, `BP_SpawnPoint_C` 0/41,
  `BP_Hazard_Landmine_C` 0/38, `BP_Spawn_GasBarrel_C` 0/19, `BP_WorldItem_C` 5/14, car templates mostly 0.
- Actor totals differ between same-seed runs (2787 vs 2978) — streaming level state differs too.
Conclusion: setting `MasterSeed` alone does NOT make zone generation reproducible.
Unknown: where the spawn RNG is seeded (candidates: `UBaseRandomManager.StreamSeeds`, per-leg
`UChartInstance`, `FRandomStream` inits during `TravelToNextLeg`, or time-based seeding).
Consequence for co-op (derived): either find and sync the real seeds, or the host must send
the spawned-actor list (class + transform + loot contents) to the client.

## Where spawn randomness comes from (2026-10-20, automated, headless)

Tools: `mod/CoopSeedProbe` (hooks seed-setting UFUNCTIONs, counts unseeded Kismet random calls),
`mod/tools/cmds/seeds.lua`, `pin-streams.lua`, `det-random.lua`, `spawn-inputs.lua`
(passed to `run-seed-test.ps1 -PreTravelLua`). Logs in `local/seedtest/`.

Observed:
- `BP_SpawningManager_C.CurrentSpawnSeed` = MasterSeed (12345) in every run.
- `BP_RandomManager_C.StreamSeeds` (16 channels, filled on zone load): channels 2..15 are stable
  (ch2 = 1097307663, ch3..15 = MasterSeed); **channels 0 and 1 differ every run**.
  `MyCurrentStream` and `BaseRouteState.WorldShapeRandSeed` differ every run too.
- `RandomState:SetSeed` is never called from script; `MakeRandomStream` is called only with
  constant seeds (555, 232, 1155, ... — visual flicker etc.).
- Unseeded Kismet random nodes (global FMath::Rand): ~2.9k calls (RandomFloat, RandomBool,
  RandomFloatInRange, ...) during garage + zone load.
- UE4SS `RegisterHook` can override a native UFUNCTION's return value (checked: RandomFloat → 0.25).
- Experiment A — overwrite StreamSeeds ch0/ch1 + MyCurrentStream at `K2_PostLevelChange`
  (confirmed still set at `Execute Spawn Leafs`): layout still differs (lootables 4/37 matched-ish, landmines 0).
- Experiment B — replace all unseeded Kismet random calls by a Lua LCG reset at zone
  `K2_PreLevelChange`: no improvement (60% total). Calls before spawn differ per run
  (815 vs 847) — per-tick calls interleave with spawn calls, so a global sequence can't be stable.
- Spawner inputs at `ExecuteSpawnStrategyAmortized(GlobalSpawnStrategy_C, budget 0.1 s/frame)`:
  streaming levels 3/3, SpawnModifierActor 15, BaseSiteSpawnerActor 21, LootableTemplate 13 — same
  in both runs; `BP_SpawnPoint_C` already 26 vs 27. After spawning: LootableTemplate 41 vs 41 (same
  count), BP_SpawnPoint_C 54 vs 85.

Derived:
- Non-determinism has (at least) three sources: (1) random per-run values set in native code
  (StreamSeeds ch0/1, WorldShapeRandSeed — probably FMath::Rand/time), (2) unseeded BP random
  nodes mixed with per-tick calls, (3) the native C++ spawn strategy, amortized over frames with a
  time budget, whose RNG is not visible to script (`FSpawnExecutorSettings.Seed` is set natively).
- Counts per category look budget-driven (same), positions/types are random.
Unknown: the native seed source of the spawn strategy (needs Ghidra on the shipping exe).

Conclusion: zone generation can't be made reproducible from Lua. Making it reproducible would
need native reverse engineering + a C++ patch (seed + non-amortized execution + deterministic
site spawners), and would still be fragile to timing. Recommended co-op design: **host-authoritative
spawn replication** — host generates the zone, sends the client the spawned actor list
(class, transform, loot contents); client suppresses its own spawning.

## Spawn replication prototype v1 (2026-10-20)

Code: `mod/CoopSync/Scripts/spawnsync.lua` (export / import / cleanup), test: `mod/tools/sync-test.ps1`
(two headless game instances on one PC, own `-userdir` and CoopDev dir each, ~2.3 GB RAM each),
scorer `mod/tools/sync-score.ps1`. No networking yet: the list goes host → client as a file.

How it works:
- Replicated set = in-level actors whose class matches `BP_Lootable_ / BP_WorldItem / BP_Spawn_ /
  BP_Hazard / BP_Template_ / BP_Resource_ / BP_Destruct_ / BP_TpoleTool / BP_VolCascade / BP_RoadObstruct`,
  minus `BP_Resource_Narrative_` (fixed quest items), `BP_TemplatePart_` (created by their template) and
  `BP_Spawn_PreHazardHelper_` (spawns hazards itself → duplicates). Only roots: no replicated ancestor
  in the attach chain (level containers like `ManageChildrenActor` / `BP_LeafSpawner` are fine).
- Host export: TSV of class path, location, rotation, scale, name.
- Client import: destroy its own replicated roots **and everything attached under them**, spawn the
  host list with `GameplayStatics.BeginDeferredActorSpawnFromClass` + `FinishSpawningActor`
  (missing classes via `LoadAsset("/Game/X/BP_A.BP_A")`), `KismetSystemLibrary.CollectGarbage()`.
- Client cleanup 10 s later: destroy replicated roots not created by import (side-effect spawns).

Facts learned on the way (observed):
- Each UE4SS Lua mod has its own Lua state: globals of CoopSync are not visible from CoopDev
  commands → commands `dofile` the module.
- `SpawnState` objects are gone after spawning completes; runtime-spawned actors have names ending in
  `_2147xxxxxx`; much procedural content is level-placed actors randomized in place, or pooled
  (`PooledActor`, 111 in the zone), so "runtime-spawned" alone is not the right filter.
- Destroyed actors stay visible to `FindAllOf` + `IsValid()` until GC; use
  `KismetSystemLibrary:IsValid` and skip `/Engine/Transient.*` archetypes (snapshot.lua does now).

Result, full run from scratch (02:21–02:24, host seed 12345, client seed 999, same zone map):
- before import: 141 of 844 host actors matched on the client (16.7%)
- after import + cleanup: **833 of 844 matched (98.7%)**, 11 extra; import removed 609, spawned 842,
  0 failed; cleanup removed 25 (TpoleTool 9, VolCascade 14, GasPumpHandle 2)
- QA verdict of the scorer: FAIL (gate is ≥95% matched AND 0 extra).
Known issues (observed):
- `BP_Hazard_Tesla_C` 0/5: level-placed under `BP_LeafSpawner`; a freshly spawned one disappears
  (guess: self-destroys when not chosen by a leaf spawner).
- `BP_TpoleTool_C` 9 extra: cleanup reports destroying them but they are still there (unknown why).
- `BP_WorldItem_Resource_GasPumpHandle_C` 0/2: the gas pump creates its own handle; cleanup then
  removed the pump's handles → handles should not be replicated separately.
- `BP_Hazard_PhysicsGrabber_C` 2/4, `BP_Destruct_Traffic_Cone_C` 15/17: physics movement/settling.
Not done yet: loot contents of containers, template car parts and their state, item pick-up /
destroy events after load, networking, player/car sync.

## Spawn replication v2 — fixing the leftovers (2026-10-20)

Root causes found (observed on live host/client pairs):
- **Level-placed vs runtime actors.** Many replicated actors are placed in the level with stable
  names (e.g. `..._Art_Sub:PersistentLevel.BP_TpoleTool4`, Teslas under `BP_LeafSpawner`), and the leaf
  spawners randomly keep/cull them. v1 destroyed and respawned them, which fails:
  - `K2_DestroyActor` on some level-placed `BP_TpoleTool_C` leaves them stuck with
    `bActorIsBeingDestroyed=true` but still valid (not pending kill) — destroy aborts midway (unknown why).
  - A freshly spawned `BP_Hazard_Tesla_C` disappears by itself.
  → v2 matches level-placed actors **by level path**: keep (and teleport to host transform) when the
  host has it, destroy only if the host culled it, spawn only if the client culled it.
- `FindAllOf("X")` also returns subclasses (e.g. `BP_TpoleTool_Roadside_C` under `BP_TpoleTool_C`).
- **Derived actors**: `BP_WorldItem_Resource_GasPumpHandle_C` is created by `BP_Resource_GasPumpBase_C`;
  `BP_VolCascade_Radiation_C` are created by radiation hazards (the `BP_VolumeCascadeGenerator_C`
  only renders them). v2 exports them as kind `D` (scored, never spawned or destroyed).
- **The zone keeps changing for ~20–25 s after RUN**: replicated count 904 → 447 at +23 s (leaf
  spawners culling variants), stable afterwards (watched 2 min; mines constant). v1 exported/imported
  at RUN+20 s — right on that edge, which caused the flaky landmine extras. v2 waits until the count is
  unchanged for 15 s (min 30 s) on both sides.
- Physics/AI actors move after spawning (`BP_Hazard_PhysicsGrabber_C` wanders thousands of units and
  carries traffic cones; world items settle 8–28 units) → positions are scored right after import,
  extras after the 10 s cleanup. Keeping them in sync later is the job of dynamic state sync.
- Derived actors of the client's own (destroyed) creators linger → v2 destroys all client derived
  actors before import; imported creators re-create theirs.

Results, `mod/tools/sync-test.ps1`, full runs from scratch (logs `local/instances/sync-test-run*.log`):
| run | version | matched (positions right after import) | extra after cleanup | verdict |
|---|---|---|---|---|
| 1 | v2, derived kept | 400/402 (99.5%) | 7 VolCascade | FAIL |
| 2 | v2, derived kept | 354/362 (97.8%) | 8 VolCascade | FAIL |
| 3 | v2, derived kept | 381/387 (98.4%) | 0 | PASS |
| 4 | v2 final | 390/403 (96.8%) | 0 | PASS |
| 5 | v2 final | 396/403 (98.3%) | 0 | PASS |
| 6 | v2 final | 385/394 (97.7%) | 0 | PASS |
Remaining misses in runs 4–6 (each 0–4 actors per class, observed):
- `BP_Hazard_Tesla_C` 4/5, 5/6: when the client's leaf spawner culled a Tesla the host kept, the
  spawned Tesla still disappears (level-placed Teslas the client has are now kept and match).
- `BP_VolCascade_Radiation_C` 6/9, 7/10, 9/12: imported radiation hazards re-create fewer cascades.
- `BP_WorldItem_Resource_GasPumpHandle_C` 0/1, 1/2: pump handles not always re-created.
- Physics/AI movement: `PhysicsGrabber` 2/4, traffic cones, world items (few units).
QA level for spawn replication: automated (3/3 PASS with gate ≥95% matched, 0 extra), single zone map
(`Rural_Forest_Radio_Scylla_02`), two instances on one PC, file transfer instead of network.

## Loot replication (2026-10-20)

Code: `mod/CoopSync/Scripts/lootsync.lua` (used by spawnsync export/import/cleanup), scorer
`mod/tools/loot-score.ps1` (wired into `sync-test.ps1`).

How loot is stored (observed):
- Lootable containers (`BP_Lootable_Base_C` and children): property `InventoryContainer`
  (`UItemContainer`) → `Slots[]` (`UItemTileSlot`: `Items[]`, `Location` (grid), `bRotated`, `Capacity`)
  → `UItemInstance.Archetype` (`UItemArchetype`, e.g. `/Game/Gameplay/Inventory/Items/Resources/Basic/RawTape/IA_Resource_Raw_Tape`).
  `Layout` is an `ItemTileLayout` (e.g. `CL_Lootable_Crate_Small`). Filled on spawn
  (39/39 had `Container Populated`); 12/39 also have `OnOpenItemsDecisionTree` → an extra roll when
  opened (not synced yet: must become a host-authoritative "open" event).
- Car wrecks (`ALootableTemplate`, e.g. `BP_Template_StrippedCar_01_C`): attached `ALootableTemplatePart`
  actors with `MySocket`, `ItemInstance`, `RequestedMesh`. Trunk contents part
  (`BP_TemplatePart_TrunkContents_C`) keeps its items in an `ItemContainer` whose **Outer is the
  part's ItemInstance** (`IA_Template_TrunkContents`). 36 templates / 248 parts in the test zone.
- Item creation: `UInventoryBlueprintLibrary::CreateItemInstance(WorldContext, Archetype, CreateContext=4)`
  (4 = the context of the game's own loot). Parts: `ALootableTemplate::AttachTemplatePart(Socket,
  FLootableAttachment{Archetype, ArchetypeOverride, PartClass, Mesh}, Instance)`.
Tile-container rules learned the hard way (observed):
- `SetNumSlots(n)` on tile containers inserts **null slots**; a later `RemoveAllItems` then crashes the game.
- `RemoveAllItems` removes the slots too; `AddSlot()` does nothing; `AddItem(item, true)` creates a slot
  but stacks equal archetypes into an existing slot → to rebuild separate stacks, temporarily set every
  existing slot's `Capacity` to its item count while adding the first item of a new stack.
- `slot.bRotated` and `slot.Location` are writable properties (`SnapLocation` had no visible effect).
- A re-attached trunk part re-initializes its container after attach → trunk contents are filled in a
  deferred pass (`flushPending()`, run by `cleanup()` 10 s later).
- Serialization bug to avoid: asset paths contain `/`, so it can't be a separator.

Format: lootable `C|<layout>!X_Y_R=item,item;...`; template
`T|<socket>=<partClass>@<archetype>{<sub-container>^...}@<mesh>~...`.

First result (live host + fresh client, 09:0x): loot before import 0/74 identical; after import +
cleanup **74/74 identical** (38 containers, 36 templates, incl. trunk contents, stack split, tile
positions and rotation). Spawn score in the same run 371/382 (97.1%), 0 extra → PASS.

Full runs from scratch (`sync-test.ps1`, logs `local/instances/sync-test-run7..9.log`, `sync-mines-1..3.log`):
| run | loot identical | spawn matched | spawn extra | spawn | loot |
|---|---|---|---|---|---|
| 7 | 76/76 | 396/403 (98.3%) | 1 landmine | FAIL | PASS |
| 8 | 74/74 | 409/416 (98.3%) | 5 landmines | FAIL | PASS |
| 9 | 77/77 | 367/379 (96.8%) | 0 | PASS | PASS |
| m1 (+2nd cleanup) | 67/67 | 385/399 (96.5%) | 0 | PASS | PASS |
| m2 (+2nd cleanup) | 76/76 | 380/391 (97.2%) | 0 | PASS | PASS |
| m3 (+2nd cleanup) | 70/70 | 415/422 (98.3%) | 0 | PASS | PASS |
Observed after loot import: 4–10 `BP_WorldItem_C` appear at the same spots each run (≈59.9k,-22.7k;
52.2k,-10.9k; 44.1k,-10.6k) and once a `BP_Hazard_MalfunctionMine_SuperCharger_C`; cleanup removes them
(destroy is deferred: still valid right after `K2_DestroyActor`, gone 5 s later; 2nd cleanup finds nothing).
Unknown: why landmine extras appeared in runs 7–8 and not in m1–m3 (the 2nd cleanup pass was added in
between; not proven to be the fix). Not synced yet: on-open loot rolls (12/39 containers), anything
that changes after load (pick-ups, opened containers, removed parts).

## Interaction sync after load (2026-10-20)

Code: `mod/CoopSync/Scripts/statesync.lua`; bot `mod/tools/cmds/bot-actions.lua`; test
`mod/tools/interact-test.ps1` (runs sync-test first, then host bot, then client bot, scoring each stage
with sync-score + loot-score). Transport: append-only files in `local/instances/channel/`.

Design (host authority, state based):
- Host, 1 tick/s: snapshot every replicated root (key -> loot string incl. "#O" opened flag) and
  send diffs: `U` changed, `D` gone, `S` new (spawn-list row), `M` moved (transform, also once per
  actor as baseline when sync starts).
- Client: applies events; detects its own local changes on mapped actors and sends requests
  `OPEN` / `TAKE <arch> <n>` / `PICK` / `DETACH <socket>`; the host performs them (open = HighlightInteract
  + OnRollForOpenItems, so the on-open roll is the host's) and the resulting diffs overwrite the
  client's prediction. Unconfirmed predictions are reverted after 6 s. A predicted local world item
  is "adopted" when the host's S for the same item arrives within 300 units.
- Positions belong to the host: client copies that drift > 20 units are snapped back; client copies
  of physics-simulating actors get physics turned off and follow M events.
- Bot actions = the end result of player actions: open (HighlightInteract + OnRollForOpenItems, which
  the container UI triggers; headless there is no UI), take (container RemoveItem + GiveItemToPlayer),
  pick up (`ItemInstance:Remove(true)`), detach (part destroyed + `UInventorySystem::SpawnItemActor`
  of its item at the part).

Hard-won facts (observed):
- **Never use `LoopAsync` for game logic**: its callback runs on another thread on the same
  `lua_State`. Under load this corrupted the Lua registry (`[Lua::Registry::get_function_ref] Ref was
  not function`, all loops of the mod stopped) and caused random `EXCEPTION_ACCESS_VIOLATION` in
  UE4SS.dll (0xffffffffffffffff, 0x12, 0x0). `LoopInGameThreadWithDelay(ms, fn)` fixed it; CoopDev
  polling uses it too.
- **Never keep UObject references across ticks** (self-destroying actors get GC'd → stale wrapper →
  AV). Keep object paths, re-resolve with `StaticFindObject`.
- GC purges incrementally: check `HasAnyInternalFlags(EInternalObjectFlags.Unreachable)` (value
  268435456) before touching any object from `FindAllOf`; `IsValid()` only checks PendingKill.
- Native `GetAttachParentActor()` crashed on half-destroyed parents → walk
  `RootComponent.AttachParent:GetOwner()` validating every link.
- UE4SS setting `bForceGUObjectArrayForIteration = true` (test copy) — with the hash-table iteration
  the crash came within 48 s of destructive actions; with forced iteration `FindAllOf` is slow, so
  each class is searched once per tick (template parts were searched per template: 36x).
  Host tick ≈ 220 ms, client tick ≈ 215 ms (was 8 s with one StaticFindObject per mapped actor);
  first client tick with ~330 baseline teleports ≈ 10 s. Too slow for real play — optimize later.
- `UE4SS` loads a mod's `main.lua` as a string: a UTF-8 BOM (PowerShell 5 `Set-Content -Encoding utf8`)
  makes it fail ("unexpected symbol near '<\239>'"). `dofile` tolerates BOM. Write Lua without BOM.
- `SpawnItemActor` belongs to `UInventorySystem` (`DrivingGameInstance.InventorySystem`), not to
  `UInventoryBlueprintLibrary`. It returns a pooled `BP_WorldItem_*` actor.
- Pooled item actors: `bPooled` is true for **all** pool-managed actors. Idle ones have no `Instance`;
  removed ones (picked up / destroyed) are parked at exactly 0,0,0 **with** their Instance still set.
  "In pool" = no usable Instance, or at the origin.
- Destroying a pooled world item is deferred (still valid right after `K2_DestroyActor`).
- World items lie in clusters (a cabinet drops several), so the loot scorer prefers an identical item
  within tolerance before any item.
- Physics props settle differently per machine (traffic cone: 15 units in Z) → scorer tolerance 25
  for `BP_Destruct_*`, 150 for loose world items.
Results (`interact-test.ps1`, two headless instances, full runs from scratch; logs
`local/instances/interact-run8..10.log`). Each stage: spawn score (positions) / loot identical:
| run | after sync start | after host bot | after client bot (requests) |
|---|---|---|---|
| 8* | 334/337 PASS / 96/96 | 334/337 PASS / 96/96 | 334/337 PASS / 96/96 |
| 9 | 363/367 PASS / 96/96 | 363/367 PASS / 96/96 | 363/367 PASS / 96/96 |
| 10 | 349/353 PASS / 93/93 | 349/353 PASS / 93/93 | 349/353 PASS / 93/93 |
(*run 8 re-scored after adding the 25-unit physics-prop tolerance; it had failed on one cone.)
Per run, host bot: 3 opens with roll, 2 takes, 2 pick-ups, 2 wheels detached; client bot the same on
other targets via requests — host report `req_OPEN_done=3 req_TAKE_items=2 req_PICK_done=2
req_DETACH_done=2`, client `ap_S_adopted=2` (its predicted wheel items adopted), 3–7 snap-backs.
Not covered yet: denied requests (both players take the same item), the client's own inventory after a
denied take, real player input (UI / tools / animations), networking, players and the car.
## Network transport (2026-10-20)

Code: `mod/net/relay.ps1` (TCP relay, PowerShell + .NET, no install), `mod/net/relay-selftest.ps1`,
`mod/net/coop-net-test.ps1` (two-PC test: each PC runs one half), `mod/net/README.md` (how to run on two PCs).
Tests: `sync-test.ps1 -Net`, `interact-test.ps1 -Net [-DelayMs n -JitterMs n]`.

Design: UE4SS Lua has no sockets, so a sidecar relay next to the game moves the channel lines over TCP
(direct IP / LAN / Tailscale-ZeroTier — the playbook's "always keep the direct-IP path working").
The game still writes/reads local files: host relay sends `host.events` lines and appends received lines
to `client.requests`; the client relay the reverse. Files put into `outbox\` (game writes `<name>.tmp`,
then renames) arrive in the peer's `inbox\` (used for the spawn list, phase markers, test score files).
Handshake `HELLO <version> <token>` / `WELCOME`, keep-alive every 2 s, peer silent 10 s = reconnect.
Test-only latency emulation in the relay (`-DelayMs`, `-JitterMs`; delivery stays in order).

Results (all automated, this PC, two headless game instances talking only through two relays on 127.0.0.1):
| test | spawn list over net | after sync | after host bot | after client bot |
|---|---|---|---|---|
| relay self-test | 500 + 20 lines, 1 file identical; reconnect after killing the client relay delivered | — | — | — |
| `interact-test -Net` | 224 KB | 334/341 PASS, loot 89/89 | PASS, 89/89 | PASS, 89/89 (9 requests done) |
| `interact-test -Net -DelayMs 75 -JitterMs 30` | 221 KB | 326/332 PASS, loot 87/88 | PASS | PASS (snap_back 21) |
| `coop-net-test` host + client halves as separate processes | 229 KB | 356/361 PASS, loot 90/90 | PASS, 90/90 | PASS, 90/90 |
Traffic of one full run: host → client ≈ 400 KB (spawn list ≈ 300 KB as base64 + ~370 event lines),
client → host 9 request lines (+ score files in the split test).
Not tested: two real PCs, internet / VPN, packet loss (TCP), connection drop mid-session. Known gaps:
lines in flight are lost on a TCP drop (no ack/resend yet; U/M heal on the next diff, D/S do not);
movement shares the reliable TCP stream; no encryption, the token is sent in clear text.
## Players and the car (2026-10-20)

Code: `mod/CoopSync/Scripts/playersync.lua`; test `mod/tools/players-test.ps1` (+ `players-score.ps1`),
runs over the network relays (relay channel 1 = "fast": `host.fast` / `client.fast`).

Observed about the game:
- After the zone loads the player `PDP_MainCharacter_C` sits in the car, attached to `BP_PlayerCarNew_C`.
  Mesh `/Game/AdvancedLocomotionV3/Characters/Mannequin/Mannequin`, AnimBP `Mannequin_AnimBP` (ALS v3).
- `FindFirstOf("BP_PlayerCarNew_C")` returned an invalid non-level instance → always pick the live
  instance under `:PersistentLevel.`.
- Car physics = `IWCarPhysics` `UVehicleControllerComponent` on the car (`ThrottleInput`, `SteerInput`,
  `BrakeInput`, `HandbrakeInput`, `SetParkingBrakeActive`, `Wake`). Writing `ThrottleInput = 1` every
  frame drives the car with its own physics even with the engine logic off (`ManualSetIgnition_NoAnim(2)`
  alone did nothing, `CanCarStart` false). The car BP rewrites the inputs every frame, so braking must be
  held too (a single brake left the car rolling downhill for 50 s). Teleporting the car is partly undone
  by its physics (moved 1100 of 3000).
- `PDP_MainCharacter_C."Exit Car"(DipToBlack=false, Teleport=true)` leaves the car (detached, walking);
  `CommandEnterCar(Teleport, Door, DipToBlack)` exists for entering (not tested). `K2_DetachFromActor`
  alone does not free the seated character.
- `AddMovementInput(dir, 1, false)` every frame walks the character (character movement, like input).
- `KismetMathLibrary:Now()` comes back as an empty table in UE4SS; ms wall clock = `os.clock()` anchored
  to an `os.time()` second change.
- The headless game runs ~22 fps on this VM, so `LoopInGameThreadWithDelay(16/33)` really runs ~45 ms.

Design: each player owns its character; the host owns the car. 10 Hz `P` (own character: transform +
seated flag) both ways, `C` (car) host → client. The receiver shows the other player as a puppet
(`SkeletalMeshActor`, player mesh, no collision, scale copied, mesh offset from the character's mesh
component; **no animation yet**). The client's car is a puppet of the host car (its vehicle controller
tick disabled). Receiver extrapolates each sample along its velocity over the sample age (≤ 0.3 s),
smooths 0.6 per ~33 ms step, teleports above 500 units.

Result (`players-test.ps1`, two headless instances over the relays, bots use the game's mechanics):
| check | owner travel | final error | on path | median lag |
|---|---|---|---|---|
| client car follows host car (host drives 6 s on car physics) | 842 | 0.1 | 100% of 40 | 141 ms |
| host player in the car, seen on client | 842 | 0.0 | 100% of 38 | 130 ms |
| host walks 5 s, seen on client | 299 | 0.0 | 100% of 28 | 125 ms |
| client walks 5 s, seen on host | 218 | 0.1 | 100% of 40 | 106 ms |
All PASS (gates: final ≤ 15, on path ≥ 90% within 50 units, median lag ≤ 600 ms). Transport median
118–183 ms. Before extrapolation the lag was 410–780 ms. Second run (players-run4): all PASS, car 1566
units, final errors 0.0–0.1, lag 54–146 ms.
Join cost fixed: the client resolved every event with `StaticFindObject` (slow with forced iteration):
first client tick 12.8 s → 0.33 s with one per-tick path index; baseline `M` events that would not move
a copy are skipped (`ap_M_same`). Regression `interact-test -Net` after these changes: all stages PASS.
Not done: puppet animation (needs an AnimSingleNode sequence, see playbook UE4 trap b), the client
driving the car (ownership transfer), seat assignment (both characters use the driver seat), entering
the car, other players' equipment visuals.
## Puppet animation and seats (2026-10-20)

Code: `playersync.lua` (puppet states, seats), test `mod/tools/anim-test.ps1` (two headless instances over
the relays; checks read `CoopPlayers.puppetInfo()` / `selfInfo()` on both sides).

Observed:
- The game has **no full-body sitting/driving animation** (first-person): loaded for the ALS skeleton
  (`ALS_Mannequin_Skeleton`) are only ALS locomotion, idles, turns, in-air, get-up clips.
- `SkeletalMeshComponent:PlayAnimation(seq, true)` (single node, no AnimBP) works headless once
  `VisibilityBasedAnimTickOption = 0` (AlwaysTickPoseAndRefreshBones): clip position advances and the
  `foot_l` socket moves (−41 → +14 in Y within a second for `ALS_N_Walk_F`).
- Sitting pose built on a `PoseableMeshComponent` added with `AddComponentByClass`: thighs yaw −90 and calves
  yaw +90 in component space (`KML:ComposeRotators(delta, current)`) → knee 42.6 in front of the pelvis at
  hip height, foot 38.8 below the knee. (Thigh pitch ±90 / yaw ±90 / roll ±90 were probed; only yaw −90
  points the knee forward: the mannequin faces +Y.)
- Reading `SkeletalMeshComponent.AnimationData.AnimToPlay` (struct) crashed UE4SS (AV 0x18) → keep own
  record of the playing clip.
- The game seats every character as the driver (relative to the car 46.2,−45.8,−12.3) and snaps it back
  every frame, but it follows the car's `TempSocket_Seat` (26.6,−45.8,−15.6): mirroring that socket in Y
  seats the character at 46.2,+45.8 (passenger). `"Exit Car"(false, true)` / `CommandEnterCar(true, nil,
  false)` leave and re-enter the car.

Design: P carries a seat number (0 none, 1 driver = host, 2 passenger = client). The client mirrors its
own car's seat socket when seated. A seated puppet is attached to the local car at its seat (mesh offset,
yaw −90) and shows the sitting poseable mesh; otherwise it follows in world space and plays idle / walk /
run by speed (EMA-smoothed, idle only after 400 ms below threshold — the raw per-sample speed dropped to
0 mid-walk and made the clip flicker). Velocity estimate capped at 2000 units/s.

Result (`anim-test.ps1`, run 6): **26/26 PASS** — client on the passenger seat; on both sides the other
player sits on the right seat, attached to the car, sitting pose geometry OK; after leaving the car both
puppets idle (`ALS_N_Idle_Pose`, detached); while each player walks the other side plays `ALS_N_Walk_F`
and the puppet's foot moves 41 units; back to idle after stopping; after re-entering, seats and poses
again correct. (Run 5: 24/26 before the speed smoothing.) Run 7: 26/26 PASS again; regression
`players-test` after the seat change: 4/4 PASS (host player in the car now rides the client's car seat:
final error 5.1, lag 366 ms).
Not done: arms on the wheel, turning/strafing clips (only forward walk/run), the visual check itself
(headless: geometry and bone motion are asserted, nobody looked at it), first-person view of the other
player at close range.
## Sync cost optimization (2026-10-20)

Measured building blocks (one host in the zone, ~3–4k actors, ~330–830 replicated roots), ms:
| | forced GUObjectArray iteration | hash tables (default UE4SS) |
|---|---|---|
| `FindAllOf("Actor")` | 54 | 3–5 |
| `FindAllOf("ItemContainer")` / `("LootableTemplatePart")` | 54 / 54 | 0–1 / 0 |
| one `StaticFindObject(path)` | **14.7** | ~0 |
| collect() filter over all actors | 39 | 34 → 23 → 12 (see below) |
| loot pre-pass / serialize all loot actors | 111 / 89 | 5–6 / 13–19 |
- **`bForceGUObjectArrayForIteration` is back to `false`** (default). It had been turned on while hunting
  the crashes, whose real cause was the `LoopAsync` race. Destructive soak (6 min, 21 rounds of bot
  actions + forced GC) with hash tables after the race fix: no crash, three times.
- collect(): `KismetSystemLibrary:IsValid` (a UFunction call per actor) replaced by one native
  `HasAnyInternalFlags(Unreachable | PendingKill)`; class verdict cached by class object address
  (`GetClass():GetAddress()`), so no class-name string per actor; "in a level and a root" (attach-chain
  walk) cached per object path for 30 s.
- Work is spread over frames: the loop runs every frame (`LoopInGameThreadWithDelay(1)`, ~120 calls/s
  headless now) with a 3 ms budget. Host: background root scan (frame 1: FindAllOf + class verdict →
  candidate paths; later frames: per-candidate checks), state pass at most once per second over the
  cached root paths (serialize + movement per actor), diff/requests when the pass completes. The loot
  pre-pass maps hold object paths and are rebuilt only after a new root scan. Client: host events applied
  every frame (path lookups are cheap now), detection of local changes as a budgeted pass.
- Result (host, destructive soak): pass_begin 3.4 ms avg, pass_step 4.2 ms avg per frame, scan 0.1 ms
  avg; ~21 ms of sync work per second spread over ~120 frames, instead of one 220–250 ms block per
  second. Rare peaks 28–37 ms (first synchronous scan, frames with forced GC in the soak).
- Tools: `mod/tools/cmds/bench.lua` (building-block timings), `CoopSyncState.profile()` (avg/max per phase),
  `mod/tools/lua-check.ps1` (load-checks all modules in a game at the main menu; no standalone Lua here),
  `mod/tools/run-all-tests.ps1` (every two-instance test, strictly one after another).
- Pitfall seen twice: big string replacements in PowerShell glued `end` to the next line
  (`endM.readList`) and once dropped a block of functions — always run `lua-lint.ps1` after editing.
- Offline Lua 5.4.8 (LuaBinaries, unpacked to `tools/lua`, no installer). `mod/tools/lua-lint.ps1` (~1.5 s):
  `luac -p` syntax, UTF-8 BOM, unknown globals from `luac -l` (GETTABUP/SETTABUP _ENV) against an allow-list
  of Lua std + UE4SS + our `CoopSync*` names. `lua-check.ps1` runs it first. selene 0.32 was tried and dropped:
  its Windows build parses Lua 5.1 only and fails on the `|` operator.
- Side effect found by the full run: test bots fed input from a 16 ms loop. At ~120 fps (no more 250 ms
  stalls) `AddMovementInput` (consumed every frame) reached only every other frame and the walker crawled
  (31 units in 5 s instead of ~1800), so the puppet correctly showed idle. Bot input now runs every frame;
  `botWalk(seconds, scale)` takes stick deflection (character movement scales max speed by it):
  0.4 walks (~150 u/s, walk clip), 1.0 runs (~370 u/s, run clip). anim-test checks both: 29/29.

## DLC in the test copy (2026-10-20)
- The DLC is a content plugin: `PenDriverPro/Plugins/PDFeature_Fig/Content/Paks/WindowsNoEditor/
  PDFeature_FigPenDriverPro-WindowsNoEditor.pak` (5.26 GB, depot 1458142, dlcappid 3594760). Base build
  unchanged (21896301, exe SHA-256 568BB634…F7E); every other file of the install equals the test copy.
- Copied into `testgame` (hash 9B692BB7…873F verified). Both co-op players should have the same DLC set:
  zone content spawned by a DLC class cannot be recreated by a client without that pak.
- Full suite with the DLC (run-all-tests.ps1, 2026-10-20 17:34–17:58): spawn 98.0–99.1% / 0 extra, loot 100%,
  interact (file, net, net 75±30 ms) PASS, players 4/4, anim 29/29. Sync frame max 46–61 ms, avg 0–8 ms.
## Client drives the car (2026-10-20)

Code: `playersync.lua` (wheel section), probe `mod/tools/cmds/car-input-probe.lua`, test `mod/tools/drive-test.ps1`.

Observed (probes on one headless host in the zone):
- `BP_PlayerCarNew_C` input path: input events `AccelerateBrake(axis)` / `SteerLeftRight(axis)` (the game calls
  them every frame, ~134/s headless, with 0 when no key; `SteerLeftRight` stops after "Exit Car",
  `AccelerateBrake` does not) -> raw fields `UserThrottleInput`, `UserBrakeInput`, `UserSteerInput`,
  `UserHandBrakeInput` -> BP interpolation -> `VehicleControllerComponent` inputs.
- Calling `car:AccelerateBrake(1)` from Lua every frame changed nothing (fields stayed 0, car still).
- Pre-hook param write `a:set(v)` on these BP functions has no effect; a post-hook callback
  (`RegisterHook(name, pre, post)`) was never called for them in this UE4SS build.
- **Writing the `User*` fields every frame drives the car through the whole game pipeline** (vehicle
  controller followed, 2300 units in 4 s with steering). The game does not reset them: a released pedal
  must be written as 0 (the car kept T=1 after the loop stopped).
- Not checked with a real keyboard (headless VM): that the client's own keys fill the `User*` fields of
  its puppet car the same way. The bot writes the same fields the probe proved the pipeline reads.

Design: the host decides who holds the wheel; last request wins (`W take` from the client, `takeWheel()`
on the host; the F7 key calls `takeWheel()`, polled with `WasInputKeyJustPressed` in the game thread).
The host sends the driver in every `C` line (1 host, 2 client). Seats follow the wheel: the driver keeps
the car's `TempSocket_Seat`, the passenger mirrors it, both directions; puppets take the seat from `P`.
While the client drives and sits in the car it sends `I throttle brake steer handbrake` every 33 ms
(read from its own car's `User*` fields); the host writes the newest input into its car every frame and
writes 0 when the input is older than 500 ms (link loss -> pedals released) or the wheel moves back.
Physics stay on the host; the client's car copy follows the host's `C` stream as before.

Result (`drive-test.ps1`, run 1): **23/23 PASS** — start: host drives, all four seat checks; client takes
the wheel: both sides agree, own characters and puppets swapped seats; client drives 6 s (throttle 1,
steer 0.3): host applied 1.00/0.27, car drove 1138 units, pedals 0 after release, car stopped, client copy
0.2 units off; host takes the wheel back: seats swap back, client input moves the car 5.7 units (coasting)
and the client stops sending; host out of the car: client drives alone 762 units. Transport median 58 ms.
Full suite with the drive tests (run-all-tests.ps1, 18:41–19:15, with DLC): sync, interact x3, players 4/4, anim 29/29,
drive 23/23, drive with 75±30 ms lag 23/23 — all PASS.
Not done: ignition/gearbox/handbrake actions from the client (only the four axes stream; the car starts
running), input prediction on the client (its car reacts after one round trip), a real-keyboard check.
## Target design (owner's vision, 2026-10-20)

- Every player keeps an **own garage and save**. A run (expedition) starts together: everyone joins the
  host and is on the host's map. 2 players first, maybe 3–4 later.
- Two ways to join a run:
  1. **Guest**: only the host's car exists on the map; guests ride as passengers and may drive — by
     getting out and taking the driver seat (no hotkeys, for both modes). A guest leaves the garage
     without a car and comes back on foot. Successful run: the guest keeps what it picked up into its own
     inventory; failed run: it loses its things.
  2. **Full player with an own car**: the host's car and each player's car are on the map; anyone can
     drive or ride in any car (driver or passenger seats). Each player is responsible for and bound to
     its own car for a successful run.
- In both modes **zone loot is shared**: a unit can be taken by one player only; players can hand loot
  to each other.
- Leaving a zone: going on to the next location needs both players to leave the current one. One player
  can open the exit; both have to get out for a successful end of the run, or the other can leave to the
  next location and the group splits. If one player fails, the group splits and that one goes back to
  its garage.
- Car seats can be taken by devices (fuel tank, battery etc. on the seat frames); a passenger cannot sit
  there. Idea: let players remove a seat device to free the seat. The front passenger seat always holds
  the ARC device (map + anchor energy receiver); find a way to let a passenger sit in front.
- Questions to ask the owner along the way, not to guess.
- Owner's rule (2026-10-21), guest mode: if the host drives out through a gate or the exit portal while the
  guest is not in the host's car, the guest is left behind = a failed run for it (loses carried items by the
  death rules, goes home). Splitting with each player continuing is for own-car mode.

Car interior observed (probe `mod/tools/cmds/car-slots.lua`, new game, first zone; car-local X forward, Y right):
- Driver character 46,−46,−12 (`TempSocket_Seat` 27,−46,−16); front passenger place (mirrored) 46,+46 — the
  ARC device is there in the game (owner); the puppet passenger currently sits on that spot.
- Slots: `SLOT_Internal_Computer` (`BP_PlayerCar_Computer_C`, slot at 115,0,27), `SLOT_BackSeatLeft` (frame
  `BP_CarPart_FuelTank_Base_Backseat_C`, empty), `SLOT_BackSeatRight` (frame `BP_CarPart_LimBattery_Base_C`,
  empty), `SLOT_Interior_Large_01` (nothing), reserve battery/gas, side upgrades at −190,±93, roof F/R,
  CarFriend 107,−74, compass, radio, radbox.
- Second probe (`cmds/car-seats-probe.lua`, item slots read): doors front 131,±94, rear 8,±94 (four doors);
  `SLOT_BackSeatLeft` holds `IA_Attach_Fuel_Basic` (the base fuel tank), `SLOT_BackSeatRight` holds
  `IA_Attach_Battery_Basic` (the base battery) — **in a new game both back seats are taken by devices**;
  `SLOT_Internal_Computer` = `IA_Internal_Dash_HealthComputer` at 115,0,27 (dashboard centre).
  Wheels at X −100 (rear) / 197 (front), bumpers −250 / 288.
- Crashes (AV) seen while probing: `FindAllOf` over device classes (non-level template instances, bad
  `RootComponent`) and reading `UItemSlot.FilterItemType` of an empty slot (garbage pointer).
- Owner's rule for this stage (2026-10-20): a seat with a device is taken; to sit there the device is taken
  off the frame (the car loses its capacity until it is put back).

Roadmap toward the target (order by dependency; each stage with an automated two-instance test):
1. Guest joins with an own save: the guest keeps its own profile/garage, leaves on foot and arrives in
   the host's zone (host's leg + seed), spawn/loot/state/player sync on top; at the end back to its own
   garage on foot. Today both instances start a new game with the same seed — the biggest open risk.
2. Real seats: driver, front passenger, back left/right as places with occupancy (players, devices);
   getting in through the doors with the game's interaction instead of F7.
3. Own inventory + shared loot: what a player takes goes into its own inventory (the host already decides
   who gets a unit); handing items to each other; run success keeps / failure loses the guest's items.
4. Zone exits and legs: both leave to go on; one may open the exit; splitting when one fails or leaves.
5. Own-car mode: each player's car in the zone, any player drives/rides any car.
6. Seat devices removable from the seat frames; a front seat for a passenger despite the ARC device.
   Owner's choice (2026-10-20): make the ARC device itself removable/installable on another frame like
   the other seat devices (riskiest option: the ARC is tied to the map and route progress).
7. 3–4 players.
Consequences for the current code: the F7 wheel key is a dev aid only (the goal is getting in at the
driver door); seats must be real places (driver, front passenger, back seats) with occupancy by devices
and by other players, not "host = driver, client = mirror"; the test setup (both start a new game with
the same seed) has to become "the guest keeps its own save and travels into the host's zone".
## Guest joins with its own save (2026-10-20)

Code: `mod/CoopSync/Scripts/runsync.lua`; probes `cmds/route-probe.lua`, `cmds/route-override.lua`;
`sync-test.ps1 -GuestJoin`, `start-zone.ps1 -StopInGarage`; test `mod/tools/guest-test.ps1`.

Observed:
- Route model: `BP_ProgressionManager_C.WorldState_M1` (`BaseRouteState`, 67 `BaseLegState`s). In the garage
  its current leg is the garage node (`RP_NODE_00_Garage`, no map); the next leg (`RouteShapeLeg_1`, route
  `RP_CP_Q01_ScannerParts` + junction modifiers) has **no MapLocation yet** — chosen at departure. In the zone a
  new `BP_RouteState_C` holds the visited leg with `MapLocation` (`UMapLocation.LevelAsset` = the map) and the
  route/modifiers. 161 `MapLocation` assets are loaded in the garage (DLC `/PDFeature_Fig/` ones included).
- **`BaseLegState:OverrideMapLocation(ml)` on the guest's next leg in its garage, then `TravelToNextLeg`,
  loads that map** (seed 777 profile → `Rural_Forest_Farm_Rooster_11` on request; host's
  `MLoc_Narrative_Forest_02_Q01` in the test). Spawn replication does not need the seed, only the same map.
- Saving: the game writes the slot when leaving the garage (departure) and on a garage arrival through the
  "rinse" (`TravelToGarage(state, DirectLoad=false, ...)`). `DirectLoad=true` saves nothing: a reload then
  resumed in the zone at the departure save, without what was picked up. `UserLoadGame(1, 1, 0)` loads slot 1.
  Save API seen: `UBaseSaveGameManager.SaveGame(slot, level, ESaveType RINSE/MANUAL/AUTOSAVE)`, `Rinse`,
  `SaveCheckpoint`, `LoadGame`.

Design: host `Run.publish(path)` writes `RUN <MapLocation> <route> <modifiers>` (tmp + rename) into the relay
outbox; the guest, in its own garage, `Run.join(inbox file)` points every next leg at that MapLocation and
calls `TravelToNextLeg`; then the usual sync (spawn list, state, players). Going home: `Run.goHome(false, 0)`
= the game's own rinse return, which saves the guest's profile with what it carries.

Result (`guest-test.ps1`, run 2): **11/11 PASS** — guest (own new game, seed 777) arrived with its seed on the
host's map (`Rural_Forest_Radio_Scylla_02`); spawn 99.1% / 0 extra, loot PASS; picked 2 items (host removed
them: req_PICK_done=2) → in the guest's inventory; went home: garage, own seed, save rewritten; host still in
its zone; guest restarted + loaded its save: own garage, seed 777, both items still carried. (Run 1: 8/11 with
DirectLoad=true, see above.)
Full suite with the guest test (run-all-tests.ps1, ~20:20–21:05): sync, interact x3, players, anim 29/29, drive 23/23,
drive-lag 23/23, guest 11/11 — all PASS.
Not done: the guest still brings its own car into the zone (it becomes the host car's copy) — guest mode wants
it to stay home and the guest to walk; the success/failure outcome (return state values `EN_GarageState` are
unnamed; failure = loss of carried items is the game's own death flow, untested); the host's route/modifiers
are sent but only the map is applied; real exits (gateway) instead of a direct `TravelToGarage`.
## Real seats and getting in at the doors (2026-10-20)

Code: `playersync.lua` (seats section); probes `cmds/car-seats-probe.lua`, `cmds/seat-device-probe.lua`;
test `mod/tools/seats-test.ps1`; `drive-test.ps1` / `anim-test.ps1` now change seats via the doors.

Observed:
- Seat devices are item slots of the car's `UNamedItemContainer` (`BP_InventoryManager_C:GetCarEquippedContainer`).
  `UItemSlot:TransferSingleIntoContainer(trunk)` did nothing. **`equipped:RemoveItemFromSlot(slot.SlotName, inst)`
  + `Inventory_Trunk:AddItem(inst, true)`** takes the device off (the frame actor becomes `BP_Attach_Util_Empty_C`,
  the same item instance lands in the trunk); `trunk:RemoveItem` + `equipped:AddItem(slotName, inst, false)`
  puts it back (frame actor back). Slot name e.g. `Car.Equip.Attachments.BackSeatRight`.
- The game seats its player through `TempSocket_Seat` with a fixed offset (character − socket = 19.6,0,3.3);
  moving the socket to `seat − offset` puts the character on any seat (back seats included).

Design: seats 1 driver, 2 front passenger, 3 back left, 4 back right (back X = −60, an estimate). Taken by a
player (host's table) or a device: seat 2 = the ARC device (fixed until the ARC stage), seats 3/4 = whatever
the back-seat frame holds (new game: base fuel tank / base battery). Getting in is the game's own entry;
the side remembers where its character stood just before (car-local) and asks for a seat: the host gives the
free seat nearest to that door (doors FL/FR/RL/RR at X 131 / 8, Y ±150), or none -> the character is put out.
Messages: `S` request, `A` answer, `X remove <seat>` (device off the frame into the host's trunk), `C` carries
the seat table; `P` seat −1 = in the car waiting. Driving = sitting on seat 1 (`I` input only then); the F7 key
and `W` are gone.

Result (`seats-test.ps1`, run 1): 26/27 — the one FAIL was the test's own pattern (`4:nil` vs printed `4:-`),
the state it checked was right. Start: host seat 1, client found no seat (`1:host,2:ARC,3:IA_Attach_Fuel_Basic,
4:IA_Attach_Battery_Basic`) and was put out; client asked to take the battery off seat 4 -> frame empty,
battery in the host trunk; rear right door -> seat 4 (own character −60,45.8; puppets on both sides there);
rear left door (fuel tank) -> nearest free seat 4; both out, client at the driver door -> seat 1, host at the
front right -> seat 4; driver = client on both sides, client drove 2519 units; back: host seat 1, client seat 4.
Full suite (run-all-tests.ps1, ~21:45–22:37): seats 27/27, anim 29/29, drive-lag 23/23, guest 11/11, players, sync,
interact-net/-lag PASS. Two FAILs: interact (file channel) — 1 extra actor after the interactions (the old rare
flake, seen before these stages); drive — phase 5 (host out of the car, client on seat 1) the host applied the
client's input (in_applied rising) but the car moved 27.9 units. Rerun of drive-test alone: 23/23, phase 5
1041 units (mid-phase: host input 1.00, vehicle controller throttle 1.0, parking brake off, speed 149).
Intermittent, cause unknown (guess: something holding the car, e.g. the host's character next to it); the
mid-phase line stays in the test to show it next time.
Not done: the client's car copy still shows its own devices (device state is not mirrored between the cars);
putting a device back; back-seat geometry checked by numbers only (headless); the doors are teleport +
`CommandEnterCar` (no door-specific interaction in the game was found: it seats its player as the driver).
## The two intermittent FAILs (2026-10-20)

drive-test phase 5 ("client drives with the host out of the car"): reproduced with `mod/tools/drive-flake.ps1`
(phases 4+5 repeated 6 times in one session): 3/6 and 2/6 rounds "stuck". In every stuck round the host side
was right — vehicle controller throttle 1.00, raw `UserThrottleInput` 1.00, engine on, parking brake off,
car upright (up 0.95–1.0) — but speed 2–6: the car, driving straight without steering for 2–3.5k units per
round, ends up nose-first against terrain (rounds 5 and 6 stuck at the same spot; drive-test's phase 5 starts
where the phase-3 curve left the car). Holding brake from standstill does not reverse (vehicle controller
brake 1.00, speed 0): reversing needs the gearbox, which the client does not send yet. **Not a sync bug.**
Test change: phase 5 now asserts that the client's throttle reaches the host's car physics (controller
throttle >= 0.9 mid-drive, engine on, parking brake off), steers back (-0.3), and reports the distance —
`[WARN]` (not counted) when the car is held by terrain. Phase 3 still requires >= 500 units of real driving.
Three runs after the change: phase 5 drove 2395 / 2494 / 2566 units, PASS each time; one run then failed phase 4
("client input while the host drives does not move the car < 50": 57.6) — again not a leak: the client sent
nothing (in_sent unchanged), host input 0, but the unattended car was already creeping downhill (speed 7 at the
phase start). Phase 4 now checks the input too (host raw throttle 0 and vehicle controller throttle < 0.05 while
the client holds its throttle); the distance is printed as [INFO].
Full suite afterwards (run-all-tests.ps1, 2026-10-20 23:35 – 2026-10-21 00:28): all 10 tests PASS, no [FAIL] / [WARN].

interact-test (file channel), 1 "extra" traffic cone: not an extra actor — 16 host / 16 client cones, one
client cone more than 25 units from every host cone, from the first score (4 s after the state sync start)
to the last one ~1 min later, although `snap_back` (> 20 units) re-places mapped copies within seconds.
Hypothesis: that copy had no host key (e.g. the game replaced the actor; a dead path drops the key in
`detectOne`), so neither `M` events nor snap-back touched it. 4 more runs: not reproduced. Diagnostics kept:
`sync-score.ps1 -ShowMisses` (unmatched host/client positions) and, on a FAIL, `cmds/cone-diag.lua` on both
sides (position, speed, simulating components, the client's host key / held host transform via
`CoopSyncState.debugActor`).
## Guest mode in full: own car untouched, outcomes, leaving (2026-10-21)

Code: `runsync.lua` (car insurance, watcher), `main.lua` of CoopSync (starts the watcher every session),
`statesync.lua` / `playersync.lua` (stop when the map changes), `playersync.lua` (puppet hidden + seat freed
when the other player sends nothing for 5 s); `mod/tools/deploy.ps1` (copies the mod into the test copy;
run-all-tests and guest-test call it); test `guest-test.ps1 -Outcome success|death`.

Observed:
- Death: `PDP_MainCharacter:BPI_HandleDeath()` does nothing; **`BP_MainCharacterManager_C:KillPlayer()`**
  sends the player to its garage within 5 s with the game's death penalty: random retention of what it
  carries (12 → 9 items, 32 → 1), `LastRemovedItemsForPenalty` stays 0.
- The penalty also takes **car parts**: 2 random ones per death (battery off a seat frame, wheels, doors,
  panels, bumpers seen). Right after the death the car at home can still look complete; a load of that
  save takes the same 2 slots again — every load, even after the parts were put back and saved. Parts put
  back without a death persist. Instances made with `CreateItemInstance(ctx, arch, 0)` (Unknown context) were
  not written to the save at all; with context 1 (what the car's parts carry) they are; `BP_InventoryManager
  :CreateItemInPlayerInventory(arch, false, CarTrunkInstead=true, 1, false)` works too.
- `UItemInstance:GetDataBlockDump()` = JSON with type tags; a fresh item lists only overrides, a loaded one
  everything, so dumps cannot be compared before/after (tried, also field by field: false differences).
- A guest's sync loops kept running after it travelled home: its puppet walked around the host's zone at
  the garage's coordinates, and its state sync would have seen every mapped actor "gone" (-> PICK requests
  that make the host delete them). Both loops now stop when the map changes.
- `UKismetSystemLibrary:GetProjectSavedDirectory()` = the profile's Saved dir (respects `-userdir`).

Design (guest mode):
- Join (`Run.join`): before driving out the guest records its car (`insureCar`: slot property, slot name,
  archetype path per car item slot, trunk archetype counts) in `<Saved>/CoopSyncGuestCar.tsv`.
- The CoopSync mod (`runsync.watch`, every session, own Lua state) completes the car from that record ~6 s
  after every garage entry (new instances, create context 1) and saves (`SaveGame(slot, "", AUTOSAVE)`);
  log in `<Saved>/CoopSyncGuestCar.tsv.log`. The record stays armed until the player drives out again: a new
  join rewrites it, a solo departure (record older than 2 min) removes it.
- Outcomes are the game's own: success = `TravelToGarage` rinse (keeps what it carries); failure = death
  (the game's random loss of carried items, home in 5 s). The guest's car parts lost to the penalty come
  back from the insurance (as new parts: full durability, an advantage noted as known).
- The host hides the guest's puppet and frees its seat 5 s after the guest's last `P`.
Result (guest-test, 2026-10-21): success 16/16, death 17/17 (guest dies carrying 32 -> 1 left; the watcher put
back the 2 parts the penalty took after the run and again after the load; a second reload: car complete); full
suite 02:35–03:46 all PASS except players (see "Slow client frames" below) and one interact-net import score.

## Shared loot and handing items over (2026-10-21)

Code: `statesync.lua` (NACK handling, DROP, drop detection), `lootsync.lua` (templatePartCount); test
`mod/tools/loot-share-test.ps1` + `cmds/loot-share.lua`.

Rules: one unit of loot goes to one player. The host decides; its own pick-ups/takes are immediate, the
client's are requests (`PICK`, `TAKE`). A request for a unit that is already gone gets `NACK` (`TAKE` NACK now
carries the archetype); the client then gives its local copy back (`RemoveItemsOfType` on the backpack/hand
container). The archetype of a picked world item is remembered when the PICK is sent (a `D` event can arrive
before the NACK and clear the applied state).
Dropping: the client's inventory lost items of an archetype and an unmapped world item of that archetype lies
within 8 m of the player -> `DROP <loot> <transform>`; the host spawns it (`Loot.spawnWorldItem`), the next pass
sends `S`, the client adopts its own copy (`adoptPredicted`). Requiring the inventory loss keeps items the
client's own game spawned (broken crates...) from being duplicated on the host. Host drops were already `S`.
Handing over = drop + the other player picks it up.

Result (`loot-share-test.ps1`, run 2): **7/7 PASS** — same world item picked on both sides at once: host 0->1,
client 0->0 (nack_PICK=1, nack_reverted_items=1), gone from both worlds; the only roll of tape in a backpack
taken on both sides: host 0->1, client 0->0 (nack_TAKE=1); client drops a chemical: the host has it where it
was dropped (req_DROP_done=1), the client adopted it (ap_S_adopted=1, rq_DROP=1); the host picks it up: host
1->2, client 1->0, gone on the client too. (Run 1 failed in the test itself: a helper named `LS` is
PowerShell's alias of Get-ChildItem — like `Sv` = Set-Variable earlier: never name helpers like aliases.)
Not covered headless: the game's own drop/throw paths (the test removes the item and spawns it the way the
mod sees a drop: inventory loss + new world item nearby).

## Slow client frames (2026-10-21, night)

players-test failed 3 times (marionettes off their path, lag 300–490 ms). Measured (`cmds/fps.lua`, two games
in the zone): the client game alone ran 32–90 fps (host 150–190) and varied 3x between runs with no sync at
all; frames of 240–480 ms on both sides; file appends in the project tree occasionally 240–870 ms. Kaspersky
(`avp.exe`) is resident (Defender is off), and the slow period was ~02:00–04:30 — likely its activity (not
changed: security settings stay the owner's). A/B runs: without the CoopSync mod, without the new drop/world
checks, with the client seated — same picture, so not caused by this session's code.
Own cost found on the way: the client's detection serialized every car-wreck template each pass (3–10 ms per
template). Now it compares the part count first (`Loot.templatePartCount`, paths only) and serializes only
when a part is gone; client detection budget 2 ms/frame (host 3). Profiling added: `CoopPlayers.profile()`
(send/apply/wheel + apply sections), `slow_detect_<kind>` counters in `CoopSyncState.report()`.
Loot race fixed afterwards (2026-10-21): in one run the client's take out of a container was never requested —
the host's `U` (container changed) arrived before the client's detection pass noticed its own take, applying it
made the local container equal to the host's, and the client kept a duplicate. Now `U` first compares the
local container with the last applied state: what the player took and the host still has is requested at
once (`TAKE`), what the host no longer has is given back (`contested_take_reverted`). Same for a world item:
a host `D` for an item that is already gone locally with no `PICK` sent -> give the copy back
(`contested_pick_reverted`; not when this side sent a PICK, accepted or refused). The contest checks of
loot-share-test accept either winner (the host decides whichever request comes first). loot-share x3:
1st run "failed" only on the fixed host-must-win check, then 7/7, 7/7; interact + interact-net PASS.

## Leaving the zone (2026-10-21)

Code: `playersync.lua` (leaving section); probes `cmds/exits-probe.lua`; test `mod/tools/exit-test.ps1
-Scenario seated|behind`.

Observed:
- Exits: junction gates `BP_LevelTransition_EnterExit_C` (to the next leg; `ExitActive`, `EntranceActive`,
  `CarEnteredExitVol`, `DoLevelTransition`, `SetExit(EN_ForceDeadEnd)`) and exit portals
  `BP_LevelTransition_ExitPortal_C` (home; opened with the ARC: `StartPress` / `PressComplete` — the latter is a
  multicast delegate). In the first story zone no gate is an exit, both portals inactive, and the run route has
  **no active unvisited leg** — this zone only ends by going home. `SetExit(0)` + `DoLevelTransition`,
  `SetExitPortalActive(true)` + `Activate`, `TravelToNextLeg` and `BaseRouteState:TravelTo` from the zone did
  not travel (they need the game's conditions: car in the exit volume, a chosen next leg, ARC energy).
- So the mod reacts to the travel itself, whatever triggered it: pre-hooks on
  `BP_ProgressionManager_C:TravelToGarage` ("garage") and `/Script/PenDriverPro.BaseRouteState:TravelTo` ("leg").

Design (guest mode; owner's rule for a guest left behind): the host's hook sends `L <time> garage|leg` on the
fast channel before its game starts loading. The guest: in the host's car -> `garage`: the game's own
successful return home (`TravelToGarage` rinse), `leg`: wait for the host's next descriptor (follow; not
testable yet); not in the car -> left behind = failed run: the game's death (`KillPlayer`), random loss, home.

Result: `exit-test -Scenario seated` 5/5 (guest on seat 4 went home with the host, kept its 2 items, own garage,
own seed); `-Scenario behind` 5/5 (guest outside -> left behind, carried 32 -> 26, home).
Full suite (run-all-tests.ps1, 2026-10-21 11:2x–12:50, 15 tests): all PASS except the import score in two tests
(interact file channel, players: 98.3% / 98.1% matched but 1 extra, loot 98.9% with 1 client-only). Evidence
from interact: the host has BP_Lootable_Dumpster_03_C at 80334,-17377 with contents X, the client has
BP_Lootable_Dumpster_C at the same spot with the same contents X and no Dumpster_03. Import keys are full
object paths, so the client's own Dumpster_C should have been destroyed and the host's Dumpster_03 spawned;
likely the spawned variant actor replaced itself with another variant (a variant randomizer) and cleanup did not
catch it. Rare (the old "1 extra" cases), import code unchanged by these stages; to fix separately.
Not done: following the host to the next leg (needs a save further into the story: the first zone has no next
leg; the host side also has to publish the new zone's descriptor + spawn list on arrival — session automation).

## Following the host to the next leg (2026-10-21)

Test `mod/tools/leg-test.ps1 -Scenario seated|behind`; host = copy of the owner's odsave9 (`local/advsave/`,
original untouched, hash checked), guest = own new game (seed 777). The host travels with the game's
`BaseRouteState:TravelTo` (what a gate ends in) to a revealed leg (Rooster_11 -> Alyssa_77), its TravelTo
pre-hook sends `L leg`; on arrival the host publishes spawn list + descriptor; the guest in the car follows
by itself (`Run.follow`: an unvisited leg of its own run route + `OverrideMapLocation` + `TravelTo`) and imports.

Found on the way:
- **Two route states** with a mapped current leg exist after a leg travel (the previous zone's lingers). A probe
  that called `TravelTo` on each travelled twice; the second load restarted the zone generation, so the host's
  export / snapshot caught ~250 replicated actors still at 0,0,0 (and 3000+ markers / splines). Now one route:
  `Run.zoneRoute()` = the one whose current leg's map is `MLoc_<world>` (follow and exits-probe use it).
  A single TravelTo: state 2 -> 5 in ~28 s, zone complete then (replicated roots at the origin: 1, an anchor).
- **Prefab children of road obstructions**: cones / signs are attached under `BP_RoadObstruct_Rock_*`
  (a replicated actor), so they were not roots and not exported, and a rock spawned on the client comes bare.
  `spawnsync` CONTAINERS (`^BP_RoadObstruct_`): replicated actors under them count as roots. This also removed
  the client's own leftover children (the "extra" stop signs).
- The game loads the newest of `odsave<N>.sav` and its `-backup-<date>` copies (written at every travel), so a
  profile kept advancing between runs; `start-save.ps1` now deletes the slot's backups before copying.
- `cmds/snapshot.lua` scores only the current world's level (old map actors linger until GC).

Result: seated 8/8 (spawn 97.6% matched, 0 extra; loot 99.1%; players see each other again), behind 5/5
(guest outside when the host leaves -> failed run, home in its own garage). Both added to run-all-tests.

## Chasing the last percent (2026-10-21)

Tool: `mod/tools/miss-report.ps1` classifies every unmatched actor (at-origin / not-in-list / lost-at-import /
not-spawned / moved / extra-kept / extra-cleaned). leg-test keeps its scoring files in `local/instances/leg-last`.
Found and fixed, in order of size:
- **Export taken while the zone was still generating.** The replicated root count is stable ~30 s after a
  travel, but the generator's helpers (`BP_ClumpedSpawnMarker_*`, ~1000) and its candidates at 0,0,0 come and go
  in bursts after that. `CoopSync.zoneReady()` (no marker, no replicated actor at the origin except the one
  `BP_HazardAnchorPull_C`); `cmds/count.lua` reports it; WaitStable needs it; leg-test re-checks after the
  snapshot and redoes the export when the zone changed (seen once per run or so).
- **Hazards were not synced at all.** `inPool` treated every item manifestation without an item Instance as an
  idle pool actor; landmines (~300 per zone, host 303 vs client 147 at other spots), physics grabbers, electric
  clouds, saw blades, leeches, supercharger mines are exactly that, and all live. Idle = parked at the origin or
  hidden now (spawnsync and snapshot.lua); Loot.serialize writes `W|` only with an Instance.
- **Derived actors of kept creators**: a level gas pump kept on the client does not re-create its handles, so
  derived actors matching a host D row (50 units) are kept; cleanup drops a kept one when the replaced creator
  made its own copy on the same spot (radiation cascades doubled otherwise).
- **Static level actors ignore the move** at import (a pneumatic mailbox stayed 5 km off): replaced when still
  > 100 units away after the move.
- **Repair**: cleanup re-spawns host actors whose client copy died since the import; statesync (client) re-spawns
  a mapped hazard that died locally (3 times at most); the host statesync can start from its export
  (`start(..., hostListPath)`) so the first pass sends what changed after the export (S/D/U).
Scores after: join (sync-test) 100% spawn / 100% loot; leg 99.9% / 100%, 20 s later with live sync 99.8%.

**Update 2026-10-22 — buildings fixed through their site spawners** (see "World tails" below).
**Was: buildings differ per seed.** `BP_BuildingFrame_*` (train cars along railroads, silos,
some houses) are not replicated: of 53 host frames 31 matched, 3 another variant, 19 nothing on the client
(train cars mostly). Loot / mines that the host has on a train car stand in the air on the client (mines fall
and go off; the repair puts them back 3 times). Replicating the frames as containers (destroy the client's,
spawn the host's) **crashed the client** on the next travel; reverted. Next: find how the generator picks
these (seed, prefab settings) and drive the client's choice instead of replacing actors.
## World tails: buildings and hazards (2026-10-22)

New host (Hyper-V on a Ryzen 9 5950X; the quick suite takes the same ~34 min: tests wait, they don't compute).
Tests: `run-all-tests.ps1 -Quick` (6 core tests) / `-Only a,b`; `send.ps1` throws "GAME DEAD" when the
instance's game (pid from its start.log) is gone, so the runner reports ABORTED instead of sitting out timeouts.

Buildings (probes `cmds/site-spawners.lua`, `cmds/frames.lua`):
- Every building frame stands exactly on a site spawner (`BaseSiteSpawnerActor`: `BP_Spawner_Building_*`, e.g.
  `..._Open_TrainFlatbed_C`, one per train car / cabin / trailer). Only ~5 are level-placed (houses, farms);
  the rest are **placed by the generator at random spots with GUID names** - so the guest has other sites, not
  just other variants. `BP_Spawner_Building_Base` has `BuildingsDTR` and `SpecificVariantOverride`.
- A host spawner spawned on the guest builds its building on its own within seconds (frame + prefab cargo).
  Removing the guest's spawners **together with** what stands on their spot (frame, PrefabSettingsActor,
  BP_Container_*, all attached) and travelling after: no crash (removing only frames earlier crashed).
- Now: site spawners are replicated roots (`SITE_SPAWNER`; car spawners not, their wrecks are templates);
  the export writes the built frame class in a 14th column and the guest spawns with
  `SpecificVariantOverride` set; the guest's own spawners go with their products. Level farms pick their silo
  variant per run: the export lists every frame as kind `F`, `alignFrames` replaces a frame of another class
  on a host frame's spot (frame + attached) or adds a missing one (swap + travel checked). sync-score scores
  `BP_BuildingFrame_*` too (ExtraClasses).
- Still different: the prefab cargo on a car (pipes or nothing) is the spawner's own pick; cosmetic.
Derived actors the host has and no creator made on the guest (a zone's radiation cascades) are spawned by cleanup.

Hazards through the host (`hazard-test.ps1`): landmines have a `StartExplode` event (the electric mine
overrides it). statesync pre-hooks it on every hazard class that has it: host -> `X <key>` (the guest's copy
goes off too), guest -> `BOOM <key>` (the host sets off its own; its X comes back and is skipped). A mine that
went off for real is not put back by the hazard respawn. Chain reactions differ (a blast takes neighbours on
the guest the host still has): those are put back, end state compared - host 195 mines, guest 195, all matched.
First full run: a guest blast set off neighbours, each sent BOOM, the host's X set off more on the guest -
ping-pong over whole fields (97 X). Now the guest sends BOOM only for the first mine of a burst (2 s quiet
window after any blast it saw); the host runs its own chain and sends X for it. Two runs after: 194/194, 192/192.
Full suite 2026-10-22 (92 min): all 17 PASS except that hazard run (fixed as above).

## The whole wheel: ignition, drive/park lever, reverse, handbrake (2026-10-22)

Test `mod/tools/wheel-test.ps1` (in -Quick): 10/10.
Observed:
- The state lives in `BP_CarManager_C`: `CarIgnitionState` (0 off / 1 starting / 2 running) and `MyCarGearBox`
  (the lever: **0 drive / 1 park** - parked, gas does not move the car). Change events OnCarIgnitionChanged /
  OnCarGearboxChanged. `PlayerInReverseMode` is true all the time (not the reverse gear).
- `car:ToggleIgnitionState(v)` sets v (key animation). `car:ToggleGearBoxState(s, false)` (lever animation) flips
  the lever only when it stands on s; `(s, true)` (no animation) sets s; same for `ManualActivate_Gearbox`.
- Reverse is no gear: the car's pedal handling (raw input -> ThrottleTarget/Current -> `User*` fields; it does not
  run headless - RawThrottle -1 left the targets at 0) turns S at a stop into a **negative UserThrottleInput**;
  physics backs up on it (-1 for 6 s = 8.5 m). The client's I stream carries the sign, so reverse already worked.
  The handbrake is the `UserHandBrakeInput` axis, also in the I stream. (Headless frame-counted loops run at
  hundreds of fps - time-based loops for measurements.)
- Sync (playersync): the host appends ign + gear to every C line; the client copy follows (not the transient 1,
  not while its own K is pending, no re-follow while the lever is still animating). The client driver's own
  changes of the manager's state (any path: key, lever, script) go to the host as `K <ms> ign|gear <v>`; "starting"
  is sent as 2 (where it is heading). The first version ping-ponged (following -> lever still animating ->
  "changed" -> K with the old value): local changes within 2 s of a follow are not the player's.

## Own-car mode, step 1: both cars in the zone (2026-10-22)

Owner's rules (2026-10-22): a player who dies -> its car goes home by the game's rules and leaves the host's
zone; leaving the zone in somebody else's car is not allowed (each leaves in its own).
Test `mod/tools/owncar-test.ps1 -Scenario guestLeaves|hostLeaves` (11/11, 12/12; since the loop fix with real
driving again, brakes held at the end so the cars stand for the comparison). Quick suite + exit/leg/hazard PASS.
Tools: `$env:COOPTEST_GRAPHICS=1` runs the test games rendered (game-args.ps1); crash report windows are closed
by the launchers / runner; cdb: `"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe" -z <dump> -c ".ecxr; kn 40; q"`
(UE4SS frames carry names; the game has no pdb).
Found on the way:
- **A second BP_PlayerCarNew_C** (spawned copy) makes itself `BP_CarManager_C.NewCarActor` (the player car), brings
  ~124 attached actors incl. ~70 part items, and travels with or after it crashed now and then (restoring the
  manager, removing it in the travel pre-hook, CollectGarbage, removing its items with Remove() - none reliable).
- **Headless, any drive followed by a travel crashes the game - also with CoopSync disabled** (drive 4 s with the
  User* fields, stop, TravelToGarage rinse or DirectLoad -> dead; teleporting the car 20 m then travelling is
  fine). The bisects above were partly this.
  **Solved 2026-10-22 with cdb** (Debugging Tools from Windows SDK 10.0.26100, installed with the owner's OK): the
  dump's stack is UE4SS's game-thread hook -> Lua call -> `UStruct::FindProperty` on a dead object. **UE4SS's
  LoopInGameThreadWithDelay ignores the callback's return value in this build** ("return true" after 10 calls ->
  210 calls in 3 s): the test's drive loop never ended and kept writing `c.UserThrottleInput` after the map (and
  its car) was gone. With the loop cancelled through its handle (`CancelDelayedAction(h)`), drive + travel home is
  fine. Everything below about it being the game / headless was wrong. All mod loops now go through a `loop()`
  helper (playersync, statesync, runsync) that cancels on true; before, every "stopped" sync loop kept being
  called forever, and the follow-the-host loop would have travelled again after it had followed.
  (Before that, checked with graphics - `$env:COOPTEST_GRAPHICS=1`, window 960x540 - it was not a headless artefact:)
  Crashes (access violation, the crash report window stays): throttle via `UserThrottleInput` 4 s, wait, travel
  home (rinse or DirectLoad); the same then `KillPlayer` (the game's own way home); with sound on too. Fine: car
  pushed by physics (SetPhysicsLinearVelocity, 83 m, still rolling at the travel); teleport; the input axis
  `AccelerateBrake(1)` (the pedal pipeline does not run here: RawThrottle 1, ThrottleTarget 0, car stays; also
  after a proper `CommandEnterCar`). So **writing the User* fields directly** leaves something that breaks the next
  travel - wrong, see "Solved" above: the never-ending test loop, not the fields.
- So the other player's car is a **ghost** (`carghost.lua`): the owner's visible meshes (~100: 97 static, 3
  skeletal; `K2_GetComponentsByClass` elements need `:get()`) as StaticMeshActors / SkeletalMeshActors attached
  to an empty root at the car's transform, no collision, no game logic. The owner sends the layout on Y lines
  every 10 s (new seq only when the mesh set changes, not when wheels move); the receiver builds / rebuilds.
  Ghosts are removed in the travel pre-hooks (now registered on both sides) and this map's player sync stops
  there (C lines kept coming and respawned the copy mid-travel).
- Protocol: `G <time> xform ign gear` (client's own car), `Y <time> <seq> <i> <n> <mesh line>`. The host
  removes its ghost of the client's car 5 s after the last G (client went home / died). The host leaving does
  not fail the run of an own-car guest: split (`split=true`), the host's ghost goes.
- A character counts as in a car only when attached to that car (a guest in its own car is not a passenger
  of the host's).
## Own-car mode, step 2: getting into and driving the other's car (2026-10-22)

Test `mod/tools/ghostseat-test.ps1` (in -Quick).
- Getting in / out: pre-hook on the character's `Command Interact` (the game's interact key): outside, next to a
  door of the other's ghost (250 units) -> attached to the ghost root at the door's seat, movement + collision
  off; in a ghost -> out at the seat's door, walking again. No extra key.
- Seats: the car's owner hands them out - the host's car with S/A as before, the guest's car with `SG`/`AG`
  and the guest's table `seatOfG` (its own seat: driver when its character sits in its car). P lines carry a
  car tag (H / G / -) and the puppet sits in that car on the receiving side (real car or ghost).
- Driving a ghost: the game's car input does not reach a ghost, but the character's input events still fire
  every frame: pre-hooks on `Command Move Forward/Backward`, `Command Move Left/Right`, `Command Jump` ->
  throttle, brake (S while moving) or reverse (S below 150 u/s: negative throttle), steer, handbrake (space).
  The game also reports these axes as 0 every frame: an axis = its newest non-zero value for 60 ms. The
  client in the host's ghost sends I as before; the host in the guest's ghost sends `IG`, the guest writes it
  into its real car every frame while the host has seat 1 (released when the host leaves the seat).
- `Ghost.destroy` removes only the ghost's own parts (a character attached to it is detached and kept); a
  player in a ghost is put out before the ghost goes (owner left / went home / died): **no leaving in another's
  car** - the passenger stays in the zone (split).
Results: guest drove the host's car 61 m, host drove the guest's car 62 m; boarding, seats, puppets, getting out,
host leaving with the guest in its car -> guest put out, stays (split), all pass.
Suite after step 2: quick set all PASS except leg-seated, twice in a row on spawn: new zones Golem_09 / Swamp_14
(the leg the host takes varies), 98% / 97% matched but 2 / 1 extra - two cones flung 150 km away on the guest
(host had a StrippedCar_PileUp still at 0,0,0), and one doubled radiation cascade (likely the cleanup's derived
fill racing a creator that made its own later). Spawn side, not the seats.
**Fixed (cleanup, spawnsync):** (a) derived actors on no host spot are removed (a creator the client spawned on
its own after the import was removed by cleanup, its cascade stayed); (b) imported actors pushed more than 1 m
from the host's spot are put back with velocity 0 (a host building spawner builds its building after the import
placed what stands around it - crates, pallets, cones shoved, seen 9 km away / under the ground); (c) the
repair re-spawns every truly destroyed imported actor (not world items), with its loot. The cleanup's report
no longer mixes the derived fill count into "loot sub-containers filled" (shadowed local). leg-seated twice
after: 9/9, 9/9 (Alyssa_77, Swamp_09; put_back=2, derived_filled=8).
More runs (leg-test keeps failed runs in `local/instances/leg-fail-<time>`):
- the import spawns site spawners first; the **frame alignment moved to the cleanup** (aligning right after the
  spawners added a trailer the spawner then built again: 2 trailers); actors are mapped by the path taken at
  spawn, so one gone again within the frame (fell before its building stood) is seen gone and repaired (10-14
  per run in zones with buildings); the cleanup's spawn retry only for real spawn failures with nothing of the
  class on the spot (retrying every unmapped entry made duplicates).
- Residual in zones with buildings: 1-2 extra single objects of ~1500-1800 (a trailer frame, a gas barrel, a
  barrel - likely broken pieces next to their repaired whole), 97.8-99.5% matched. leg-test allows <= 2 extra
  (`sync-score -ExtraTol`), the 95% bar stays. Open, low impact.
Next: devices / paint on the ghost (layout has meshes only), seats 2-4 when devices sit there (chooseSeat on the
ghost side = owner's real car, works), ignition / lever of the other's car (K lines for the guest's car).

## Log

- 2026-10-20: triage done, identity recorded, initial search for prior mods.
- 2026-10-20: workspace. Git for Windows 2.55.0.5 via winget (installer hash checked by winget).
  Test copy of the install made with robocopy (87 files, 20.13 GB, shipping exe hash matches).
  UE4SS `UE4SS_v3.0.1-1181-g83330635.zip` from
  https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest,
  SHA-256 `b9a166a756605b21058a64cde93bcaab1a855dba3553e5c7e6ce0fa8fdfad7b9` (matches GitHub digest).
  Installed into the test copy's `PenDriverPro\Binaries\Win64` (dwmapi.dll proxy + `ue4ss\`).
  Enabled in UE4SS-settings.ini: ConsoleEnabled, GuiConsoleEnabled, GuiConsoleVisible,
  EnableHotReloadSystem (original kept as `.bak`).
- 2026-10-20: first launch of the test copy. Saves + Config backed up first (36 save files,
  hashes verified). `steam_appid.txt` (1458140) put next to the shipping exe so it runs
  outside the Steam folder.
  - Launch without args → game picked DX12, failed ("Failed to choose a D3D12 Adapter",
    only Microsoft Basic Render Driver listed) and exited. **Launch with `-dx11`** — works.
  - UE4SS: engine 4.27 detected, all AOBs found except `ConsoleManagerSingleton` (2 candidates;
    can be fixed with `UE4SS_Signatures/ConsoleManager.lua`, not needed yet).
  - Own Lua mod `CoopDump` (delay 45 s, then on game thread: GenerateSDK, GenerateLuaTypes,
    DumpAllObjects, DumpUSMAP) — all four OK at the main menu. 1798 headers, 58 MB object dump,
    1.7 MB .usmap. Kept privately in `local/dumps/`. Dump taken at the main menu, so
    Blueprints loaded only in-run may be missing.

## Dump findings (observed, main-menu dump)

- Game C++ modules: PenDriverPro, PenDriverInventory, PenDriverDataBlocks, PenDriverUI,
  PenDriverUtils, plus custom car physics plugin `IWCarPhysics` (`ANewVehiclePawn : APawn`,
  not UE's PhysX vehicle).
- Architecture is manager-based: `UBaseCarManager`, `UBaseCharacterManager`,
  `UBaseInventoryManager`, `UBaseSaveGameManager`, `UBaseSpawningManager` (all `: UBaseManager`).
- Key actors: `ABaseCharacter : ACharacter`, `ABaseNewCar : ANewVehiclePawn` (BP `BP_PlayerCarNew`),
  `ABasePlayerController`, `ABaseDrivingGameMode : AGameModeBase`, `ALootableTemplate`,
  `ABaseItemSpawner`.
- Procedural spawning is seeded: `MasterSeed`, `SetMasterSeed`, `RollMasterSeed`,
  `WorldShapeRandSeed`, `StreamSeeds`.
- No `Server_`/`Client_`/`Multicast`/`OnRep_` names in PenDriverPro.hpp → no game-level
  replication to reuse (expected for single player).

Derived / guesses:
- ~~Sharing the master seed host→client may give both players the same zone layout~~ —
  tested 2026-10-20, **does not hold** (see "Seed test" below).
- Car: host simulates, client receives transform/velocity stream; custom physics plugin
  means UE4 replication won't help anyway.

## Session, co-op pause, in-game menu, CoopNet, alpha package (2026-10-23)

- `session.lua`: the mod runs the session from `<chan>/control.txt` (role host|client, mode foot|car, go, stop,
  menu ...) and writes `<chan>/status.txt`. Host: zone settled -> export + publish + sync ("hosting"); leaving
  the zone writes `host-session.txt` with `world=-` (closed). Guest: "go" is one-shot (a guest back home after a
  failed run re-joined the old zone before). Host "resync" publishes a new seq; a playing guest re-imports.
  `session-test.ps1`: 10/10 (incl. pause checks).
- Co-op pause (owner's rule): post-hook on `BP_UIManager_C:PauseGame` + per-tick fallback unpause while
  hosting/playing; single-player pause untouched. Status field `unpaused=`.
- Menu (`menu.lua`): "Кооператив" item added to the live `PDP_PauseMenu_C.MenuItemBox` (UMG_PauseMenuButton_C
  via WidgetBlueprintLibrary.Create, text via SetDisplayText(FText)); pages collapse the game's items.
  Pitfalls: FindFirstOf("PDP_PauseMenu_C") = the WidgetTree template, take the `/Engine/Transient` one; compare
  widgets by GetAddress(); register the K2_OnPressed hook only once the UI exists (class not loaded at mod start).
  Open: `BP_UIManager_C["Set Pause Menu Opened"](true)`; close: `PDP_Game_Hud_C:SetPauseMenuWidgetVisible(false)`.
  Mouse click verified with graphics (`shot.ps1` screenshots the UnrealWindow, can click). `menu-test.ps1` 8/8.
- CoopNet (`mod/net/CoopNet`, C# .NET 8 + Steamworks.NET): hidden exe the mod starts (`session.startNet`),
  Steam friends-only lobby (2 members for now), invites, P2P via SteamNetworkingMessages (relay.ps1's protocol,
  files in 256 KB chunks), lobby -> session roles, start -> guests "go". `--tcp <port>` = local test link.
  `coopnet-selftest.ps1` 10/10 (debug build and the published one). Real Steam path: untested (needs 2 accounts).
- Alpha package: `tools/build-alpha.ps1` -> `local/release/PacificDriveCoop-0.1.0-alpha1.zip` (37 MB;
  pristine UE4SS settings, only CoopSync enabled). `install-test.ps1` 10/10 on a stand-in game folder.

### After the reboot (2026-10-23)
- Quick suite 11/11 (incl. session, menu); `session-test -CoopNet` 11/11: menu commands -> CoopNet (--tcp) ->
  session, no relays.
- Graphic demo `demo-owncar.ps1`: both boardings + driving the other car work. Screenshots (`shot.ps1`,
  `cmds/look-at-car.lua`) showed the ghost lost the paint: a MID went as its parent only. Now the layout
  carries a material table (`mat|<id>|<parent>|<params>`, 127 looks for ~230 MIDs, ~75 KB), parts reference
  `@<id>`, the ghost makes one MID per slot via `comp:CreateDynamicMaterialInstance` (KismetMaterialLibrary's
  version silently failed). Ghost now matches the real car. Layout lines are sent when changed + every 20 s.
  owncar-guest/host, ghostseat, session-net PASS after it.
- A Lua probe walking all StaticMeshActors + MID params from CoopDev crashed the guest (UE4SS FindProperty):
  read material params only in the mod code paths that are tested.
- Alpha rebuilt: `local/release/PacificDriveCoop-0.1.0-alpha1.zip`, install-test 10/10.

## Ghost fidelity, weather + time of day, alpha2 (2026-10-23)

Owner saw in the graphic demo: ghost cars like stubs (no collision, black windshield, stub gauges), weather and
time of day not synced. Compared from the driver's seat (`vis-compare.ps1` after `demo-owncar.ps1`):
- Black windshield = a spare windshield layer whose slots are an MID of `/Engine/EngineMaterials/DefaultMaterial`
  (the game never draws it). Layout now drops parts drawn only with engine default materials.
- Paint: the panels' paint / decal are **material-layer parameters** (`ParameterInfo.Association` 0 = layer,
  1 = blend, 2 = global, + `Index`); set by name only the hood kept its default orange/blue-stripe look. Params
  are sent as `name@assoc,index` and set with `Set*ParameterValueByInfo`.
- Screens = render targets in `/Engine/Transient` (owner's game only): sent as `-`, the ghost gets
  `/Engine/EngineResources/Black` (screen off) instead of the material's white noise. Needles stay still.
- Layout signature maps `@id` to the parent material (ids shifted in the rain and rebuilt the ghost every 20 s).
- Collision: ghost parts `BlockAllDynamic`; a seated player has collision off already (setWalking). One-sided.
- UE4SS pitfall: reading a property the class lacks (e.g. `StaticMesh` on a non-SMC component) crashes natively,
  pcall does not catch it; `GetAttachedActors` out-param gives no array from Lua.
- `weathersync.lua`: host sends W (tod, ToD preset, 7 override values, precipitation, wetness, wind) every 2 s on
  the fast channel (`playersync.send` / `onWeather`), WE/WC on `BP_ToDDirector_C:StartTODEvent` /
  `ClearCurrentTODEvent` / `OnTODEventEnded`. Guest: own events paused, the values held as a priority-1000
  override "CoopSync" via `QuickSetWeatherOverrideAndCurrent`, time set when it drifts > 0.001 day; released
  home. Verified: rain 0.855 / 0.858, same time. WE/WC not yet seen in a run (no event happened).
- Quick suite 12/12 (drive failed once: car-copy error 59 / not stopped, rerun 23/23 - flaky).
  `PacificDriveCoop-0.1.0-alpha2.zip` built, install-test 10/10.
- Next stage (owner): two real cars again in own-car mode, keeping travel working.
- Later (owner): radio sync incl. custom tracks / playlists (the game plays the player's own audio files).

## Owner's demo findings: sky, arms, paint, contact; a real second car probed (2026-10-23, new chat)

Owner ran `demo-owncar.ps1` and listed: light differs between the two games, the seated puppet's arms stick out
through the door, the two cars are painted differently; asked for: skipping the intro in tests, players
colliding, kicking the other player, no "get in" where the other player sits, and the other's car as a real car.
- **Startup movies** (logos, ~15 s with graphics; the game thread blocks, CoopDev cannot poll): the test
  instances' `<userdir>\Saved\Config\WindowsNoEditor\Game.ini` gets `[/Script/MoviePlayer.MoviePlayerSettings]
  bWaitForMoviesToComplete=False` + `!StartupMovies=ClearArray` (`game-args.ps1 -UserDir`, all launchers).
  Main menu with graphics after ~20 s instead of ~35 s. The narrative intro level was already skipped.
- **Sky**: ToD manager north, wind, light / sky multipliers, sun rotation, intensities and fog were equal on both
  (`cmds/sky-probe.lua`, `sky-probe2.lua`); the difference was the **cloud layers**: `ToD_Simulation_C`
  `UVBaseLayerPosition` / `UVSecondLayerPosition` pile up from the map's load, so clouds and cloud shadows differed.
  W lines carry both (fields 15-16, `R,G,B,A`), the guest writes them (-0.561/-0.564 after, drift = transport).
- **Paint**: the ghost drew `CarHighlightMesh` of `BP_Manifestation_Internal_Soul_C` - the whole chassis with
  the default orange / blue-stripe MIC, a highlight shell with `bRenderInMainPass=false` - over the real chassis.
  Layout skips every component with `bRenderInMainPass == false` (also door / interior highlight meshes): one
  chassis. (Panels' layer params were right all along: a green test value showed on the ghost's hood.)
- **Arms**: `M.sitPose(pose, arms)` - two-bone IK in component space on the PoseableMesh (bones turned by the
  rotation between current and wanted child direction, `RotatorFromAxisAndAngle` + `ComposeRotators(cur, delta)`;
  elbow pole down/out): "wheel" in the driver seat (hands 42 in front of the shoulder, 8 from the middle),
  "lap" elsewhere (hand 18 from the knee). Looked at with graphics: hands at the wheel, nothing through the door.
- **Doors**: UE4SS hooks can **override a return value**: a post-hook on
  `BP_CarPart_Door_Base_C:K2_ShouldHighlight` returning false hides the door's prompt AND stops E from getting in
  (Deactivate / UnregisterHighlightComponent / the car's `UICollision_EnterDriverDoor` off did nothing). A door
  whose seat (car-local door position -> seat) the other player sits on (its P line: tag + seat) is blocked; the
  ghost's interact skips such a door too. Pitfall: `GetAttachParentActor()` returns an invalid object, not nil -
  test `a and a:IsValid()` (two probes and look-at-car.lua got this wrong).
- **Collision**: the puppet has a capsule (the character's size) that is a Pawn blocking only Pawns (meshes no
  collision). With the Pawn profile it also blocked vehicles: following its player into a car (seat -1, waiting
  for a seat) it flipped the host's car - now off whenever the other player is in a car (seat ~= 0) or gone.
- **Kick**: pre-hook on `BP_MainCharacterManager_C:PlayerKick` (the game's kick); the other player's puppet within
  170 units, 55 deg in front, |dz| < 120 -> `KK <time> dx dy`; the kicked side `LaunchCharacter(550 xy, 250 z)`
  unless it sits in a car. Test bot: the controller's `InpActEvt_Kick_K2Node_InputActionEvent_31`.
- `contact-test.ps1` (in -Quick): 10/10 (wheel / lap arms, hidden door, ghost door taken, walking into the other
  stops at ~60, kick moves the other, kick from 600 reaches nobody). `M.stop()`: leaving the session removes the
  puppet and the ghosts (they stood frozen).
- **A real second car (owner's ask), probed on the host** (`cmds/second-car-probe.lua`): spawning a second
  `BP_PlayerCarNew_C` works, it takes `BP_CarManager_C.NewCarActor`, builds its own 124 attached actors / 79 parts
  **from the local player's own car inventory** (a copy of your own car, not the other's), with manager -> it one
  can get in with `CommandEnterCar` and drive it with the game's logic (dash, screens, gauges all live; 8.5 m).
  But it **takes over the item -> manifestation links**: after removing it, 43 of the first car's 71 part items
  pointed to destroyed actors (a car that never saw a second one: 70/71 fine). The first car still drove; saving,
  part damage / swaps, travel would use dead links (likely the old travel crashes). Making the second car the
  *other player's* car would need a second car inventory the game does not have -> owner's decision pending.
- Quick suite after these changes 13/13 (drive failed 2 checks once - the known flake, its log was overwritten by
  the rerun - rerun 23/23).

## Twin cars: the other player's car as a real car (2026-10-23, owner's choice)

Owner chose "a real second car built as a copy of the own one, item links restored, look swapped". Code:
`mod/CoopSync/Scripts/twincar.lua` (+ `carghost.lua` `eachPart` / `applyMaterials` / `spawnPart`), playersync uses a
twin by default in own-car mode (`opts.ghost = true`: the old ghost). Probes: `cmds/twin-spawn.lua`, `twin-links.lua`,
`twin-door.lua`. Found on the way:
- `GetActorManifestation()` of an item is NOT `InventorySystem.ItemWorldStates` (that TMap is readable / editable
  from Lua with `ForEach`, `v:get().ActiveManifestations`, `arr:Empty()` + `arr[i] = x`, but emptying the twin's
  entries changed nothing): it is internal to the item and points at the newest manifestation. **Re-binding the own
  car's slot component** (`SetItemSlot(nil)` + `SetItemSlot(slot)`) spawns the own part again and the item points
  back (44 slots after a twin; `HandleSlotItemRemoved/Added` did nothing). 70/70 links after, also after removing
  the twin; travel home and out to a new zone after it: fine.
- The twin's slot components are unbound with `SpawnedActor = nil` first, then `SetItemSlot(nil)`: its parts stay (it
  shows empty-slot placeholders, +53 actors, hidden by the restyle), and later changes of the own inventory (a seat
  device into the trunk) do not touch the twin or the links.
- The game's highlights never offer the twin's doors (no K2_ShouldHighlight / interact calls at all). Getting in =
  `NewCarActor = twin` + `CommandEnterCar(true, nil, false)` (the game's seat, camera, dash, screens); out = "Exit
  Car" + manager back to the own car (Twin.leave). The owner's seat answer moves the twin's `TempSocket_Seat`.
- Driving: the game sends the driver's axes through the car interface (`AccelerateBrake`, `SteerLeftRight`,
  `HANDBRAKE`) **to the own car** whatever the manager says (EnableInput / DisableInput did not move it;
  `BP_CarManager_C:InitializePipelines()` with the manager on the twin sent the guest home - never call it). Hooks on
  those three take the axes as the twin driver's input (`ghostInput` -> I / IG to the owner, as for the ghost). The own
  car gets RawThrottle but stays (nobody in it).
- The twin is a puppet: vehicle controller tick off and **the chassis kinematic** (`SetSimulatePhysics(false)`): a
  simulated one was flung hundreds of km between stream teleports, fell out of the world, and was spawned again and
  again.
- Restyle: the twin's visible parts that match the owner's layout (same mesh within 80 units) get the owner's
  materials (screens - slots with a run-time render target - keep the twin's live ones), the rest is hidden without
  collision, owner-only parts are added as mesh actors under the twin (~84 matched, ~65 hidden, 0-1 added for two
  new-game cars). Layout and restyle skip characters / plain mesh actors under a car (a seated puppet was laid out
  as a car part before).
- Test keys in graphics runs: `mod/tools/keys.ps1` (click into the window, hold a key; the game ignores keys
  without the click). `look-at-car.lua` and several probes treated `GetAttachParentActor()` as nil when none - it is
  an invalid object.
- `ghostseat-test.ps1` now tests twins (17/17: both twins, guest drives the host's car 24 m from its twin, host the
  guest's 79 m, manager and links back after getting out, guest put out when the host leaves, both home, a new run);
  `-Ghost` (suite name ghostseat-old) keeps the ghost path tested. owncar-test accepts `copy_kind=twin`.
Open: the twin's own gauges / fuel show the LOCAL car's items (owner accepted); its steering wheel does not turn for
the other's input; ignition / lever of the other's car still not synced.

## Same zone on both sides instead of sync? Second look (2026-10-23)

Owner asked whether host and guest could generate the same zone (better than replicating it). Probe
`mod/tools/cmds/det-gen.lua` with `run-seed-test.ps1 -PreTravelLua` (same profile seed 12345, two fresh runs):
- pinned StreamSeeds ch0/ch1, MyCurrentStream, every BaseRouteState.WorldShapeRandSeed; Kismet random nodes -> a
  Lua LCG; **the spawn strategy in one frame**: a pre-hook on `/Script/PenDriverPro.SpawnStrategy:
  ExecuteSpawnStrategyAmortized` sets its `AllottedTimePerFrame` param 0.1 -> 1000 (`param:set` works; the whole
  strategy then finishes within ~2 s of one call). Result 64% of actors matched (baseline same seed ~55%).
  The LCG had seen 817 vs 828 calls before the strategy (level load interleaves with ticks), 1152 vs 964 after.
- Same, with the LCG reset when the strategy starts: 45%; inside the one-frame strategy 215 vs 242 random calls -
  the strategy's own native part already branches differently (its inputs / native RNG differ).
- Native side, read with cdb (no pdb; UFunction::Func at +0xD8 of the UFunction, address from UE4SS GetAddress()):
  exec thunk of ExecuteSpawnStrategy -> implementation (~400 lines, 32 calls, no direct CRT rand / time calls).
  A breakpoint on `ucrtbase!srand` through a whole travel to the zone: **never hit** - the game does not reseed per
  zone; the native randomness comes from state that lives since process start (FMath::Rand / streams consumed by
  everything - particles, BP nodes, ticks), so two PCs can not be brought to the same state from Lua.
Conclusion (derived): identical generation would need a native (C++) UE4SS mod - a compiler toolchain (VS Build
Tools, not installed, needs the owner's OK) to hook the executor's random stream / FMath::Rand during generation
and run the level load without interleaving - days of reverse engineering with an uncertain end; and the runtime
state (physics, hazards, loot taken, buildings) would still need syncing. The replication (97-99% matched, repaired
by the cleanup) stays the way.

## Whole-zone match: prefab dressing (2026-10-23)

Owner: improve the sync's match. The scores so far (97-99.8%) covered only the replicated classes. A full snapshot
comparison (every class, host vs client after cleanup) gave **59%**: StaticMeshActor 1081 vs 575, 32% matched, plus
lights, doors, posters, containers. Census (`cmds/sma-census.lua`): the meshes hang under PrefabSettingsActor -
level-placed building variants (one site: host variant 291 meshes, client another variant 79) and whole buildings
on one side only (placed or built at run time by site spawners). BP_LeafSpawner_C culls nothing here (probe
`cmds/leaf-probe.lua`: 4 evaluations, no DestroyActor); PrefabSettingsActor / ManageChildrenActor carry a native
SpawnPlacementHeuristicComponent - the choice is native, so the result is aligned instead:
- Host list rows of kind **P** (`spawnsync.lua` dressing): visual classes (StaticMeshActor, lights, DecalActor,
  BP_Prop_ / Door_ / Poster_ / Decal_ / Billboard_ / IF_) under a PrefabSettingsActor / ManageChildrenActor /
  BP_LeafSpawner_C, or static meshes under a replicated BP_Template_ (wrecks add random meshes at run time); look =
  mesh + slot materials (MID -> parent) + collision profile + visibility, or light intensity / colour.
- Client cleanup `alignDressing` after the frames: matched by class + mesh within 10 units; unmatched client ones
  destroyed, missing host ones spawned (StaticMeshActor with mesh / materials / collision; light with its values;
  other classes by class). Spawned ones are remembered (`CoopSyncDress`) and matched next time (else every cleanup
  spawned them again: duplicates).
- Quest items and other gameplay actors under the same containers are not dressing (allow-list of visual classes).
Result (Scylla_02, sync-test "WHOLE ZONE" line): **59% -> 94%** of all actors, StaticMeshActor 32% -> 99%,
replicated classes 99.1%; cleanup 2 spawns ~0. The rest is mostly invisible (ManageChildrenActor / Actor / prefab
roots / spawn points / pre-hazard helpers) and random graffiti decals. Wreck meshes spawned on the client are not
attached to the client's template (a pushed wreck would leave them; wrecks are heavy, left for now).
`sync-score.ps1` ignores P rows (scored by the whole-zone line instead).
Quick suite after the dressing: 13/13 PASS (drive first try). Whole zone in that sync run 91%; dressing aligned on
the next-leg map too (leg-seated: 696 spawned, 371 removed).

## Twin polish: pose, look, key and lever (2026-10-23)

- **Pose** (twincar `pose` / `applyPose`, line `V <time> <name=x,y,z,p,y,r;...>` from the owner of a car every send
  tick, applied to its twin every apply tick): the car's FrontLeft/Right/RearLeft/RightWheel_Mesh (spin, steer,
  suspension; wheel parts hang under them), *Fixture_Mesh, KeyCylinder_Temp, the steering wheel part's MainMesh, the
  shifter part's MainMesh, the speedometer's SpeedArm / FuelArm. The vehicle code moves these by their **world**
  transform (Relative* stay 0): car-relative transforms are sent, set with K2_SetWorldLocationAndRotation. The
  twin's speedometer actor tick is off (it set the needles from the twin: 0 km/h, the local fuel). Probed in one
  game (own car driving, pose copied every frame): twin wheels / steering wheel / needles equal the car's.
- **Inside a twin** the game's in-car input goes to the own car (its input graph; `InputGraph Begin Play` on the
  twin, EnableInput, SetControlRotation changed nothing): look = hooks on the own car's LookLeftRight / LookUpDown
  (~1 degree per axis unit, measured in the own car: +20 axis -> +20.4 deg) turn the twin's FirstPersonCamera
  (relative rotation; works, within CameraYaw/PitchMinMaxAngles), reset when getting out. The game's own highlight
  inside the twin works (prompt "E Включить" at the key) but its action does nothing to the owner; E (the own car's
  Interact or the character's Command Interact, debounced) looks at what the camera faces: the key (14 deg) ->
  owner's ignition 0 <-> 2, the lever -> drive <-> park (K to the host, new **KG** to the client, from the owner's
  state on C / G lines), anything else -> getting out. Checked with real keys and mouse in graphics: guest started the
  host's car and moved its lever, looked around, got out; host started the guest's car (KG).
- Cosmetic, open: the game's prompt at the key shows the LOCAL car's state (the manager's CarIgnitionState is shared).
- Test helpers: `CoopPlayers.botTwinLookAt(name)`, `twinCtlInfo()`; `tools/keys.ps1 -MouseDX/-MouseDY`.

## Twin: screens, mirror, the key's prompt (2026-10-24)

Owner: the twin's screens were off and its mirror dead; also fix the key prompt. Probed in graphics (guest in the
host's twin, own car vs twin):
- **Screens**: the screen parts (BP_PlayerCar_Computer_C, StatusBox, LimBox battery bar) draw UMG widgets into their
  WidgetComponents' render targets; the screen mesh's MID takes one as a texture param (`Texture`). On the twin the
  MIDs held `Black` (no power: unbound items) and the parts put Black back now and then by themselves. twincar
  `fixScreens(own, twin)`: per part class on both cars, an own MID texture that is one of the own part's widget RTs
  -> the twin's MID gets the twin part's same-named widget RT (5 slots); `light()` (from applyPose) re-asserts them
  every 0.5 s (no flicker seen: no reset within 3 s of probing). Result: computer, health bar, battery readouts lit.
  They show the twin's own widgets = the LOCAL car's data (owner accepted for the gauges).
- **Mirror**: the twin's ScenecaptureMirror drew into the asset RT_Rearview, and its Interior used the very same
  MID as the own car (RearviewMirrorRT = the own car's capture): the twin's mirror showed the view behind the OWN car.
  `fixMirror`: a render target of the own one's size / format (KismetRenderingLibrary.CreateRenderTarget2D) for the
  twin's capture, a new MID in the twin's Interior slot (8) copying the own one's params with RearviewMirrorRT ->
  the new target. `Setup Rearview Mirror Material` on the twin did nothing.
- **Key prompt / lever**: while sitting in a twin the car manager holds the OWNER's ignition / lever (C / G lines;
  the own values are put back on getting out): the game's prompt reads right ("Включить" for a stopped owner car).
  The game's own lever action works in the twin and changes the manager -> forwarded as K / KG (before, that action
  had put the guest's own car in park: the host could not drive it - ghostseat FAIL). The game's own key does
  nothing in a twin (held 2 s: start check without battery / fuel of its own) -> E at the key toggles the owner's
  ignition from the mod (manager updated at once, else the next frame took the old value for a change).
- Note: inside a twin the camera follows the mod's accumulated look (the game sends look axes every frame, zeros
  too), so setting the twin camera by hand is overwritten - tests use `botTwinLookAt`.

## The start of the game: menu, F7 panel, network, lobby flow (2026-10-24)

The owner's real test (two Steam accounts) could not connect. Found and changed:
- **Pause menu**: our buttons copy the game button's font / wrap and slot padding / size (they were smaller);
  "Кооператив" is added the moment the pause menu shows (100 ms poll, was up to 1 s); the friends list is paged
  (7 a page, online only, those in Pacific Drive first, "▶ … (в Pacific Drive)"); the pause menu closed while a
  co-op page showed now clears our rows and brings the game's items back (before: duplicated buttons, nothing opened).
  Debug actions left the pause menu.
- **F7 panel** (panel.lua; owner chose an own panel over imgui, which needs a C++ mod): a UserWidget built from Lua
  (UserWidget + WidgetTree + CanvasPanel + Border + VerticalBox + UButton / TextBlock), the lobby rows plus debug and
  state rows (menu.lua `panelRows`). Probed: the game's UI input only lives while its pause menu is open -> F7 opens
  the pause menu and makes it transparent and hit-test invisible (opacity 0, visibility 3; Hidden killed the input);
  UButton clicks polled with IsPressed (no Lua binding); the panel is collapsed, never removed (a removed one was
  garbage collected -> crash). Test control: `panel open|close|info|press <label>` -> `<chan>/panel-status.txt`.
- **CoopNet**: "access to the path is denied" = the game holding a file CoopNet wrote / read -> retries, a pending
  list for incoming files, every loop turn in try/catch (one error no longer kills the helper). "LimitExceeded" =
  SteamNetworkingMessages' send buffer (512 KB) full with a zone list -> 16 MB (SetConfigValue SendBufferSize,
  global) and an outgoing queue that waits for the next turn instead of dropping.
- **Lobby flow** (owner, see memory pacific-drive-start-flow):
  - the main menu leaves the lobby; loading a save / a new game too (hooks on BP_SaveGameManager UserLoadGame /
    UserNewGame);
  - in the garage, the lobby with a peer runs playersync in **garage mode** (`opts.garage`: only P lines, no cars,
    seats, layouts or leaving logic; each player in its own garage sees the other's puppet). playersync.start has a
    generation counter: the loops of an earlier start end without stopping the new one;
  - the host's departure (BaseRouteState:TravelTo in the garage) -> `start` to CoopNet -> 'S' to the members ->
    "mode" + "go" -> the guest's Run.join (own car by default, or on foot); "Начать вылазку" is gone;
  - CoopNet remembers the run's members; a member that comes back to the lobby while the run is on gets 'R' (same
    go); a guest in a zone other than the host's is moved to the host's map;
  - the guest's map: route nodes take no clicks (post-hook on UMG_PlannerInteraction_Base IsCursorOverInteraction,
    IsOver -> false); the lobby rows say where the host is (host-session world).
  - the lobby holds 2 (owner: for now).
- Tests: `menu-test.ps1` (pause menu, submenu-close, F7 panel), `startflow-test.ps1` (garage lobby puppets, the
  host's departure brings the guest, late join).
- **Crash found by startflow (late join)**: a guest coming back into the same zone in the same game crashed in
  `Sync.import` (access violation reading 0xffff..., inside a Lua call): spawnsync's `classCache` and lootsync's
  asset cache kept UObjects from the earlier visit; going home unloads the zone's blueprints. Both caches (and the
  root cache) are now emptied at every import. Also: the guest's `importedSeq` is reset in the garage (before, a
  second trip to the same zone skipped the import and the sync start: "playing" without a puppet).
- F7 panel bug found by menu-test: the panel's tick closed it before the pause menu under it had opened (the panel
  stayed on screen, dead) -> the visibility check starts once the pause menu is set up (`armed`).

## The garage map: the host's junctions and conditions at the guests (2026-10-24)

Owner: the host's map, junctions and conditions at the lobby's members. Code `mapsync.lua` (+ session.lua mapTick),
test `mapsync-test.ps1`, probes `cmds/route-props.lua`, `route-legs.lua`, `route-funcs.lua`, `func-params.lua`,
`map-diff.lua`.

Probed (advanced save copy, graphics):
- The map table (`BP_RunPlanner_MapTable_2_C`) renders the player menu's map tab: `UMG_RouteDisplay_Main_C` ->
  native `RouteShapeWidget` painting `RouteState` = the progression manager's **WorldState** (`BP_RouteState_C`).
  After a run an older route state of the manager lingers: searching by outer found that one (writes did nothing
  on the map) - use `pm.WorldState`.
- Every profile has the same `WorldShape` (legs `RouteShapeLeg_<n>`, 67, keys equal); per leg: Active, Discovered,
  Revealable, Visited, `RevealState` (0 unscanned, 2 scanned), Instability, AnchorRequirement, DestinationRoute
  (`RP_NODE_<n>`, story `RP_CP_Q01_...`), MapLocation, `AppliedModifiers` = the junction's conditions
  (`RM_ViciousStorm`, `RM_PitchBlack`, ... and `RM_JunctionState_NotRevealed/ExitPoint/Highway/HasQuest`), and the
  leg's **Whiteboard** (tags + floats: biome, `WB.MapLocations.MLoc_*`/level, spawn densities, storm timing - what
  the zone is generated from). RevealFlags / NavigateFlags are derived (UpdateConditions).
- Whiteboard API: GetAllTags(false), GetTagFloat, ClearAllTags, AddTag, SetTagFloat. Leg API: RevealLeg(2, false)
  scans (neighbours get implicit reveals), ApplyModifier(m, true) / RemoveModifier(m).
- No stored "selected destination": hovering draws the path and picks map locations; the departure is the
  host's TravelTo (session hook). The guest's click block (IsCursorOverInteraction) leaves hovering and the
  junction panel working.
- The map widget caches the junction icons: changes show on the next opening of the player menu (the instability
  glow and the hover panel update live) -> after an apply an open player menu (`UMG_PlayerMenu_Main_C` in the
  viewport) is closed and opened again (CloseMapUI / "Open Map UI").
- The trip home rerolls the conditions (two games from one save got 40 different rows once, none another time).

Design: host in its garage with a peer exports rows (R header, L per leg, W per whiteboard tag; ~1750 rows,
~35 ms) when a cheap leg signature (~2 ms) changed or every 30 s, forced on a new garage visit or peer;
outbox/host-map.tsv. Guest in its garage in the lobby applies it (fields, modifiers, whiteboards, the shape seed,
UpdateConditions) after saving its own map to `<chan>/map-backup.tsv` (once); out of the lobby in the garage the
backup is put back; the backup is dropped at the guest's own departure (that departure's save has its own map).
So the guest's zone conditions (the leg it drives to with the host is the host's) come from the host's leg too.
Not copied: hazard / boon / event pools (soft class arrays). Expeditions (DLC planner) not touched.
- Checked in graphics (both from the advanced save; the guest after a run of its own, then in the lobby again):
  junction icons, scanned labels, the junction panel (features, conditions) equal to the host's. The red
  instability glow still differs a little: the route / leg data are equal, the global whiteboard differs only
  in the player's own stats and `WB.WorldState.TimeOfDay` (each garage's clock) - left alone (the guest's own
  progress). `mapsync-test.ps1` 7/7 (also: a guest's own run, home, joins again -> the host's map again).

## Garage sky, alpha 6, changelog (2026-10-24)
- Owner: sync the garage's time of day, weather, light too. weathersync (W / WE / WC: time of day, ToD preset, the
  7 override values, rain, wetness, wind, cloud layers) now also runs over the garage channel: playersync's garage
  filter lets W / WE / WC through, session starts Weather with the garage sync and releases it when the guest
  leaves the lobby (clientTick no longer releases on coming home while in the lobby). Checked in graphics: the
  guest's garage at night (its clock moved by 0.45 day) -> host's daylight and fog after joining; ToD 0.5953 both.
  mapsync-test: + clocks differ before / equal after (9/9).
- Found by startflow: the host's departure marks its first leg visited while it is still in the garage; that map,
  sent and applied, left the new-game guest no leg to drive out to ("no next leg") -> no map exports after the
  host's TravelTo in the garage, no applies while the guest has "go" / is joining.
- Quick suite all PASS (leg-seated failed once on loot 97.6% / client-only, rerun PASS - the known loot flake).
- `PacificDriveCoop-0.1.0-alpha6.zip`, install-test 10/10. New: `mod/release/CHANGELOG.txt` (Russian, testers,
  newest first) shipped in the zip; README updated to the alpha 5/6 flow (alpha 5 had shipped the old one).

## Owner's real test of alpha 6: cars only, the garage exit, stalls, flips (2026-10-24)

Owner: two-car mode only (on-foot frozen: no role switch in the menu, foot tests only in the full suite); garage
puppets jerky, sinking / jumping, legs under the car when seated; the guest could pick a junction; the host's
departure did nothing at the guest (it drove out and picked the same place itself); stalls up to a minute in the
zone; different exits / arrival places; after a while both cars flipped and the car's interactions died; the pause
menu sometimes stuck (Esc dead), the button box jumped in width. Report zip (host side only) analysed:
- **Flip** = twin spawn: Twin.relink re-binds the own car's slots (SetItemSlot nil + slot), which spawns the parts
  (wheels too) again under the car. Probe `cmds/relink-flip-probe.lua`: a standing car dropped 13 cm, 92 cm/s,
  pitch +-2 deg; in the owner's channel tail the guest's car, standing, went roll -87 -> 165 -> 177 in 2 s right at
  the twin's spawn time. Fix: the car put back right after the re-bind (transform, its velocities) and, standing,
  every 100 ms for 0.6 s (`relink-settle-probe.lua`: no movement). A first fix held the chassis kinematic
  (`relink-calm-probe.lua`) - it crashed the game in the twin's frame (with the re-bind also holding slot objects
  across re-binds: now by path, each slot read again right before its re-bind).
- **Garage exit** (probes `embark-watch.lua`, `class-dump.lua`): the garage's `BP_LevelTransition_EnterExit_C`
  (IsGarageExit, ~230 m down the road; the front door `BP_GarageDoorFront` is a separate thing). `SetExit(false)`
  opens its barrier (green lights), `SetClosed()` shuts it; driving into `Collision_Exit` calls `DoLevelTransition`,
  which opens the map to pick a junction (left click = "Отправиться" -> NotifyPlayerMapSelection + TravelTo). A new
  game's first garage never calls DoLevelTransition for an open exit (an advanced save does).
  Guest now (session gateTick / onGuestExit): exit shut until "go" (the host's departure / a run member back), then
  open; driving through (the DoLevelTransition post-hook, or the car inside the exit box - new games) closes the map
  and runs Run.join as soon as the host's zone is published; a guest's own TravelTo (a pick at the map) gets the
  host's MapLocation. No instant travel on "go" any more.
- **Arrival place / exits**: entrance and exits of a zone depend on the junction one came from (the guest's route
  differs). Host publishes `host-gates.txt` (T name entrance exit, C host car) with its zone and when they change
  (every 3 s check); guest applies them (SetEntrance / SetExit / SetClosed by name) before its import, again when it
  starts playing and every 3 s (its game shuts an exit its own route lacks), and puts its car 5 m beside the host's
  when > 40 m away (kinematic for 300 ms). `gates-test.ps1` (host advanced save, 4 transitions).
- **Stalls**: `hitch.lua` writes `<chan>/hitches.log` (frame gaps > 250 ms with the mod's work in them, mod work
  > 30 ms; the report zip takes it; status `hitch=gaps/worst/ops`). Found (headless, big zone 1734 actors):
  guest import 16.5 s and cleanup 16.6 s in one frame (loot: a FindAllOf("ItemContainer") per item with contents
  and per pending sub-container; templateParts rebuilt per template), twin restyle 3-6 s, host "players send"
  ~0.5 s every 10 s (the full car layout), a guest stall > 5 s made the host drop and respawn its twin.
  Fixes: loot sub-containers filled in one search per pass (`Loot.beginBatch/endBatch/fillDeferred`), cleanup's
  and import's forced CollectGarbage removed, car parts via the attachment tree (`attachedUnder` / Ghost.descendants:
  same 131 actors, 3x faster than the world walk), the layout made only when the slots' contents changed or every
  60 s, the twin restyle a job 8 ms per frame, import and cleanup run as jobs of steps (`Sync.runJob`,
  `importJob` / `cleanupJob`: 10 ms per frame, cursors in the job, kept actors by path, ended by a travel; a direct
  call runs every step at once), PLAYER_GONE_MS 5 -> 15 s. **UE4SS pitfall: inside a Lua coroutine every UE4SS
  call fails** ("lua state has no instance inside lua_instances": globals, methods, properties, even FName) - the
  first sliced version used coroutines and broke the import and the twin restyle. Result: cleanup 16.6 -> 3 s,
  loot flush 15.4 -> 1.8 s, twin 4-7 s -> 0.8 s, import spread over frames.
- **Puppets**: drawn 120 ms in the past between two real samples (clock offset = min receive-minus-send), every
  frame, no Z extrapolation (was: 33 ms steps, extrapolated along the velocity, Z too -> sinking / jumping with the
  real network's uneven arrival). Garage P lines carry "seated in its car" -> the puppet sits (pose, hands on the
  wheel) where the seat is.
- **Menu**: our pause-menu buttons sit in SizeBoxes as wide as the game's items (the box no longer jumps with the
  longest label), lobby rows shortened. Esc test with real keys: `esc-test.ps1` (graphics).
- Tests: startflow now drives the guest out through its exit (shut before the host leaves, open after, taken on
  driving in); gates-test; esc-test; the hitch log in every channel.
- **Esc** (esc-test reproduced the owner's stuck pause menu, 4/4): with the world running under the co-op pause the
  game takes Esc for "open the pause menu" again and never closes it (single player: fine). menu.lua: an Esc while
  the co-op pause menu has been open > 0.3 s closes it (HUD SetPauseMenuWidgetVisible(false)); with the F7 panel
  open Esc closes the panel and the menu. esc-test 6/6.
- **The guest's own car held in the garage** (startflow's late join: the drive-out never counted): playersync's
  garage start kept the zone's `target.car` (the host's last car pose): in the garage the guest's `localCar()` is its
  own car, so applyTick moved the own car to the host's zone coordinates every tick and switched its vehicle
  controller off. Garage starts now forget the cars, skip the car part of applyTick, and the own car's controller is
  switched on at every start. (Probe `home-car-probe.ps1`: single player after a trip home the car is in the garage
  and teleports stick.)
- The car-part walk through AttachChildren crashed UE4SS (null read) the frame after a twin's spawn (the car's parts
  just spawned again): carghost.descendants is the world walk again, by address now; the AttachChildren walk stays
  only in the import's destroyTrees (level actors).
- Later crash hunt (quick suite runs): every crash came in or right after a twin's spawn frame: (1) the
  AttachChildren walk (stale entries), (2) the kinematic hold, (3) slot objects kept across re-binds, (4) pose /
  screens on a twin whose restyle job had not run yet (applyPose now waits for the job). The import's destroyTrees
  is a world walk by address again (the AttachChildren version crashed a guest's sliced import once).
  Twin restyle steps measured (host, advanced car vs new car): parts 111 ms, match / materials 347 ms, the missing
  parts added 1577 ms (37 extras) - all spread over frames now.
- The settle itself crashed while it ran in the twin's spawn frame: a 10 ms ExecuteWithDelay still ran inside that
  frame (the spawn frame took 0.4 s), and even reading the chassis' physics velocities there was suspect. Bisect
  (owncar-guest x5 each): original relink alone 5/5; + settle in the frame or 10 ms later: crash in 1-2 runs; the
  settle from the 3rd FRAME after the re-bind (a LoopInGameThreadWithDelay(1) counting calls), car actor reads only:
  5/5, and the probe still shows <= 1 cm / 30 cm/s settling to 0 by 0.6 s. Rule: in the frame a car's parts are
  spawned again, touch nothing of that car; ms delays are not frames.

## C++ probe: UE4SS from source + a native half of the mod (2026-10-25)

Owner asked whether UE4SS limits the mod and what else could serve; chose a C++ probe (and linked his GitHub to
Epic Games for UEPseudo access).
- Paths checked: `UE4SS.dll` exports no Lua C API (a Lua C module cannot be loaded; a second Lua copy on UE4SS's
  states would break tables), but it exports its C++ API (4375 symbols). C++ mods need the UE4SS sources of the
  same build: our UE4SS is "v3.0.1 Beta, Git SHA 83330635" (2026-10-17, 1181 commits after the v3.0.1 tag) -> that
  commit is built. Submodules: patternsleuth (public), `deps/first/Unreal` = Re-UE4SS/UEPseudo (private, a fork of
  Epic's Unreal source: GitHub account linked to Epic + member of the EpicGames org). SSH submodule URLs: cloned
  over HTTPS with `GIT_CONFIG_COUNT/KEY/VALUE` env (url.insteadOf for that command only; GCM did the login).
- Toolchain: VS 2022 Build Tools 17.14 (MSVC 14.44, Windows SDK, CMake 3.31 + Ninja inside), Rust (rustup,
  cargo 1.99). Build tree `local/cppbuild` (CMakeLists adds `../ue4ss-src` and `mod/CoopNative`), `build.bat`
  (vcvars64 + cmake Ninja Game__Shipping__Win64): 515 steps, UE4SS.dll / dwmapi.dll / our main.dll.
- `mod/CoopNative/dllmain.cpp`: a CppUserModBase in `Mods/CoopSync/dlls/main.dll`; `on_lua_start(mod_name, ...)`
  registers functions into every Lua mod's states (main, async, hook = game thread) via LuaMadeSimple
  `register_function` (exported API; Lua globals like UE4SS's own). Probe functions: CoopNative_Version,
  _ScanActors(substr), _AttachedUnder(address), _WeakNew(address) / _WeakValid(handle).
- Test copy: our UE4SS.dll + dwmapi.dll installed (the downloaded ones in `local/ue4ss-prebuilt-backup`); CoopSync's
  Lua loads as before.
- Results (`cmds/native-probe.lua`, zone, headless): actors by class Lua 18-24 ms / C++ 2.7-3.7 ms (x6-7); what
  hangs under the car Lua 65-69 ms / C++ 3.0-3.4 ms (x19-23); a weak reference to an actor destroyed + garbage
  collected reports dead, no crash (the Lua wrapper of such an object crashes the game). A first naive C++ version
  was not faster: ForEachUObject walks every object, a class name string per object, a property lookup by name per
  actor - C++ wins with UE4SS's FindAllOf, classes cached by pointer and property offsets found once.

## The network in the game: Steam P2P in C++ instead of CoopNet.exe (2026-10-25)

Owner: "start with the network inside the game: Steam P2P in C++ instead of CoopNet.exe and the file channel".
- `mod/CoopNative/net.cpp` (+ net.hpp): CoopNet's Program.cs/Link.cs ported to one worker thread in the game
  process. Steam through the game's own `steam_api64.dll` (SDK 1.5x: Matchmaking v009, Friends v017, User v022,
  Utils v010, NetworkingMessages v002, NetworkingUtils v004), flat C exports by GetProcAddress, no SDK headers;
  struct offsets as the SDK packs them (8): LobbyCreated_t {result 0, lobby 8}, LobbyEnter_t {lobby 0, response
  16}, FriendGameInfo_t {gameid 0, lobby 16}, SteamNetworkingMessage_t {data 0, size 8, identity 16 (type 16,
  steamid 24)}. The game initializes Steam and pumps its callbacks; we only use the interfaces:
  CreateLobby/JoinLobby by polling ISteamUtils::IsAPICallCompleted + GetAPICallResult (no CCallResult), the
  broadcast callbacks (LobbyInvite 503, GameLobbyJoinRequested 333, SessionRequest 1251) by SteamAPI_RegisterCallback
  with a class declared like the SDK's CCallbackBase (same MSVC vtable); they only queue for the worker. A session
  is also accepted implicitly: both sides ping every 2 s. Lobby tag `coopsync-net/2` (a CoopNet.exe lobby refused).
- The local test link (`COOPSYNC_NET=tcp:<port>:<name>`): TCP on 127.0.0.1 in the game, same frames as TcpLink; in
  that mode the worker also reads the tests' `<chan>/net-control.txt` (shared open: an ifstream polled every 5 ms
  locked the test's Add-Content out).
- Lua side `link.lua`: menu commands, lobby status and session commands through memory (CoopNative_NetCmd /
  NetStatus / NetSession); the line streams (host.events, client.requests, host.fast, client.fast) through
  CoopNative_NetSend / NetRecv / NetDrain once the network gave the session its role (`Link.carries`); a role from
  `control.txt` (the relay tests) keeps the files. [Later, alpha 10: documents in memory too, see "Owner's real test of
  alpha 9".] Files (outbox -> peer's inbox) stay files, moved by the worker
  (their readers take paths). Lines are packed into one message per turn (up to 200 KB). `net-status.txt` and
  `net.log` are still written (tests, report). COOPSYNC_NET=exe: the old CoopNet.exe.
- deploy.ps1 copies main.dll + our UE4SS.dll/dwmapi.dll when they changed; build-alpha builds them and packs them
  (no CoopNet.exe any more). Tests: `netlink.ps1` (NetSpec / -NetExe); startflow's late join = leave + join.
- `steam-net-probe.ps1`: one game on real Steam (id, friends, a lobby created and left). P2P between two Steam
  accounts: only in the owner's real test.

## Native fast helpers, alpha 8 feedback (2026-10-25)

Owner: "before the test move the fast helpers to C++ (actor search, import/cleanup, weak references)"; then the
alpha 8 report: pause-menu buttons narrow with tiny long labels, "Steam not initialized" shown although the lobby works.
- `mod/CoopNative/world.cpp` (Lua names CoopNative_*): NewClasses / TagClass / ForgetClasses (Lua decides a class's
  tag bits from its name patterns, C++ keeps them per class FName comparison index), Find(want, opts) (LEVEL = outer
  named PersistentLevel, ROOT = spawnsync isRoot, PREFAB = underPrefab, PATHS = strings instead of objects), Under
  (carghost descendants), TreePaths (destroyTrees list), ZoneCounts (zoneReady: markers, unattached replicated at
  0,0,0), OuterMap / ParentMap (lootsync: containers by owner, template parts by parent, as "key\tpath" lines), RefPath
  / Get (weak handles; spawnsync.deref keeps one per path). Objects go to Lua through UE4SS's exported
  `LuaType::auto_construct_object`; tables only through exported LuaMadeSimple calls (prepare_new_table, set_*,
  Table::fuse_pair) - no lua_* in our DLL. Every pointer followed (root component, attach parent, outer) is checked
  against GUObjectArray first (index in range, slot holds that object, not unreachable / pending kill).
- Lua keeps its walks as the fallback (no main.dll). `cmds/native-helpers-probe.lua` (both paths in one zone): same
  results everywhere (collect 426, dressing 927, tree under the car 126, export 674006 bytes identical); collect x4,
  zoneReady x3, destroyTrees list x11-30, deref x10, export x1.5 and dressing x2 (their per-actor Lua work stays:
  loot serialize, dressLook). First ZoneCounts used RelativeLocation of attached actors too (2 false "at origin").
- Cleanup as job steps (it was one frame of up to 2.8 s at the guest): frames, dressing, loot flush, extra roots
  destroyed a slice per frame, derived, put back, repairs. Found on the way: alignFrames called destroyTrees without
  its cursor (failed whenever a frame had to be replaced, hidden by pcall).
- Steam: the mod starts before the game has Steam up (real game launched by Steam): the first start failed and the
  error stayed in the status after a later start worked. Now the error is cleared on success and link.lua retries
  every 2 s while offline; the menu says "ждём Steam" meanwhile.
- Pause menu: our rows were as wide as the game's items (~140 px at 976 px), long labels wrapped into each other; the
  game re-shows some of its collapsed items (empty "TEXT BLOCK" rows among ours); a label failing in SetDisplayText
  left an empty button each second. Now: our own VerticalBox over the menu's ContentOverlay, the game's row (items +
  route panel) collapsed while our page shows, rows 1500 units wide without wrap, text set before the button is added.
  `menu-shot.ps1` (graphics instance, Esc, screenshots in local/shots).
- Loot fill sliced too (native only): Loot.fillStep (the import's sub-containers) and Loot.flushStep (the cleanup's
  pending template parts) - container maps as paths per round, entries a slice per frame. gates-test guest: import
  496 frames / cleanup 80 frames, no gap > 0.9 s inside them (before: 1.2 s and 1.4 s single frames). Left: a 1.7 s
  gap right after the cleanup (no op of ours: engine GC of the destroyed actors?) and 1.1 s at the player sync start
  (apply_parse of the backlog ~0.9 s, twin spawn ~0.5 s).

## The guest's last freezes: stale path lookups, the twin's frame, the car move (2026-10-26)

Owner: remove the guest's 1.7 s after the cleanup and 1.1 s at the player sync start. Timing every start (session
timedStart, sub-ops in statesync / alignDressing / Twin.spawn) and startflow's late join found worse ones:
- UE4SS StaticFindObject (Lua and C++ alike) answers a path that is not there by walking every object: 45-52 ms per
  miss (cmds/deref-miss-probe.lua; a hit is ~0). Stale lists of an earlier visit to the same zone were looked up path
  by path: the late join's dressing step (CoopSyncDress, ~940) 31-43 s in one frame, statesync.start's hookHazards
  (Sync.roots(): the last scan's paths) 11-16 s; the "1.7 s after the cleanup" was the same start (1.1 s) on a first
  visit. Fix: world.cpp find_path uses FUObjectHashTables::StaticFindObjectByPath only (exported; a miss 0.05 ms);
  checked against StaticFindObject on every actor / item container / instance / car component of a zone: all live
  ones found, the only differences objects already pending kill. New CoopNative_FindPath [later replaced by CoopNative_HasPath, see "The esc-test crash"]; every Lua lookup of a path
  in a variable goes through `SFO` (native or StaticFindObject). Stale lists dropped at each import (CoopSyncDress,
  rootPaths, scan); hookHazards takes a fresh roots(true). (find_path cut "Class /path" at the first space: names hold
  spaces - "Timeline Camera Zoom"; now only a prefix before " /".)
- The player sync start (1.1-1.4 s): twin spawn 0.4 s (actor 0.11, relink 0.25) + restyle matching 0.32 s in the
  spawn frame. Restyle step 2 now from the 3rd restyleStep call on (31-41 ms: every lookup native and checked);
  relink re-binds 4 slots per frame, the settler after the last one (owncar-guest, gates "on its wheels", contact,
  ghostseat, wheel, startflow PASS); puppet() takes the twin's own VehicleControllerComponents. Frame 0.3-0.38 s.
- alignDressing as a job step (the dressing spawns, 0.4-0.6 s, a slice per frame).
- A 4-6 s frame right before the import (also in older logs): Run.applyGates moving the guest's car km to the host's
  (the engine streams that area in). Now applied on arrival too (the load's own frame); the later call finds the car
  near and leaves it.
Result (gates / startflow guest): no frame over 0.8 s in the zone after the arrival load except the game's own
generation in the first seconds; import 400 frames, cleanup 59-85 frames, sync start 0.3-0.38 s.

## Owner's real test of alpha 9 (2026-10-26) and why the tests missed it

Reports of both players (local/reports/r-a9-*). Found:
- The co-op pause item gone: one non-object value in menu.lua's FindAllOf loop raised an error inside the
  LoopInGameThreadWithDelay callback; UE4SS then drops the loop for good ("Ref was not function"). Every module's
  loop helper now pcalls its body (and notes the error in hitches.log); menu / panel check `type(m) == "userdata"`.
- The pause stuck after F7: panel.close hid the HUD's pause widget (SetPauseMenuWidgetVisible false), the game stayed
  paused with a cursor. Now the UI manager's "Set Pause Menu Opened"(false), and 0.3 s later, when still paused with
  no menu shown: SetGamePaused false + SetInputMode_GameOnly + no cursor. f7-test.ps1 (graphics, real F7 / Esc keys).
- The guest on another map: its <chan>/inbox kept a day-old host-session / host-run. The documents now never touch
  the disk: net.cpp doc_put / doc_get (CoopNative_DocPut / DocGet), Lua "doc:<name>" paths (link.lua Link.docPath /
  read / write; files only without the in-game network: relay tests, CoopNet.exe). The host's latest document of each
  name goes to the peer when put and again to every new peer; a guest entering a lobby forgets the documents it got.
- Host frozen 32 s, guest 11 s (align_dressing), client_events 3 s, 15-22 fps: StaticFindObject misses (50 ms each)
  on stale paths of the first visit to the same zone (fixed in this round, see above). The guest's car in the air
  without control, the host unable to get into its car: CoopSyncTwins keyed by ADDRESS - on a second visit the own
  car can come at an earlier twin's address and be taken for a twin (puppet: no physics, no controller). Now address
  -> weak handle (a live check: that object at that address), registry pruned at every player sync start; playersync
  drops its paths at every start in a new world; the own car is set simulating at start.
- New: the guest applies the host's event backlog EVENTS_MS per frame (5.2 s frame at the second visit's sync start);
  detection waits while events wait.
- hitches.log F lines every 10 s: fps, frame ms avg / worst, the mod's own ms per frame (loop helpers report through
  CoopSyncHitch.spent). (Not in status.txt: see the esc-test crash below.)
Why the automated tests missed all of it:
1. Every test starts fresh games with fresh channel folders: no files of an earlier game (stale inbox), no second
   visit to a zone within one game process (object names / addresses coming again). -> revisit-test.ps1: lobby,
   trip, both home, the same zone again; own cars simulate and drive, the host gets into its car, the mod's ms per
   frame, no frame over 2 s after the guest's import. Run on alpha 9's files it fails (host 11 s); now 11/11.
2. Only gaps over 250 ms were measured, never the frame rate: 15-22 fps passed unseen. -> F lines (fps= in status was dropped again, see the esc-test crash),
   revisit-test checks the mod's ms per frame.
3. The UI was driven by test commands (menu open / panel open through control.txt) instead of keys, and nothing
   checked that the mod's loops were still alive after an error. -> f7-test with real keys; loops survive errors.
4. Headless instances on one PC over a TCP link: no real Steam latency (ping 495 ms on the owner's test), no GPU
   load. Still open: a Steam test needs a second account (the owner's tests).

### The esc-test crash of this round (2026-10-26)
After the fixes above esc-test killed the game in 30-40 % of runs (alpha 9's files: 0 of 16). Dumps (cdb from the
Windows SDK + local/cppbuild UE4SS.pdb: `cdb -z UE4Minidump.dmp -y <bin> -c ".ecxr; kn"`) always inside Lua's own
structures while UE4SS built a property's Lua object (getgeneric, luaH_getint, lua_setiuservalue...): a broken Lua
state, broken earlier. Bisecting by single runs misled (a 30 % crash rate needs 8-run batches; "fixed" variants were
luck). A temporary global pcall wrapper logging every caught error (main.lua) showed the source: RegisterHook on
"<hazard class>:StartExplode" for classes without such a function - 14 per hosting start, each a C++ error thrown
through Lua inside UE4SS. The new hash-table lookup (SFO) found SOME object at those paths, so the hooks were tried;
before, statesync.hookHazards went over the cached roots (fewer classes). Fixes: hooks only on a real Function
(isFunction: found, valid, class "Function") in statesync / playersync / session; CoopNative_FindPath no longer used
from Lua (SFO = CoopNative_HasPath, a bool, then UE4SS's StaticFindObject on a hit); menu.lua's ShiftChild call (never
worked) removed; widgets kept across frames as weak handles. Then 0 of 16. Also found by that log: the "Кооператив"
item went into our own collapsed column (alpha 9) - gone from the pause menu; menu.info now reports shown=, menu-test
checks it.
Lesson: an error raised inside a UE4SS C++ function (RegisterHook, property access on a bad object) is not free even
when pcall catches it; never repeat one, check before calling.

## Robustness round (2026-10-26, after alpha 10)
Owner: "work on robustness" (HANDOFF next-work item 5).
- `hooks.lua` (CoopSyncHook): every RegisterHook of the mod goes through it (menu, playersync, session, statesync,
  weathersync). A hook is registered only when a Function object is at exactly that path; one not there yet waits
  and is tried every 2 s; a registration that still fails is not repeated (hitches.log "hook failed"). Side effect: the
  PauseGame / UserNewGame / UserLoadGame hooks (session) never got registered before - the mod starts before those
  blueprints load, the call failed once at every start (3 C++ errors per game). Now they hook when the classes load:
  the co-op pause is lifted at once (not on the next tick), loading a save / new game leaves the lobby as designed.
- Per-module cost: every loop helper reports its time with a label (CoopSyncHitch.spent(dt, label)); F lines end with
  the costliest modules' ms per frame ("state=1.31,p.send=0.51,..."; playersync split p.send / p.apply / p.frame,
  import / cleanup "job"). Headless baseline (gates / revisit, ~40 fps): host state 4.3-4.5 ms per frame, menu 0.35,
  guest import 18-23 ms.
- Host pass (statesync): every root's place read in C++ (world.cpp TrackSet / TrackMoved: one call per pass, M events
  for what moved more than MOVE_EPS), the loot serialized each pass only near the players (TrackNear: 30 m of the host,
  its car, the guest and the guest's car - playersync.otherPoints / CoopSyncOtherPoints), all of it every 10 s (the
  others keep their last state in the snapshot meanwhile). Host state 4.4 -> 0.55 ms per frame (revisit), 1.2-1.3 ms
  in the advanced-save zone (1742 actors).
- Pause menu lookup: a weak handle, searched again every 2 s (0.3 s while not found): menu 0.35 -> 0.05 ms.
- Import / cleanup slice 10 -> 6 ms (one spawn or one container fill can still take 5-10 ms on its own: the guest's
  import frames 16 ms at worst, ~4 ms after).
- Crash dumps readable: build-alpha.ps1 keeps each build's native binaries + pdbs in local/release/symbols/<version>
  (hashes.txt); collect-report writes the sha256 of UE4SS.dll and main.dll into info.txt; `tools/crash-stack.ps1
  -Report <zip>` finds the matching symbols and prints each dump's error and stack (cdb). Alpha 10 and earlier have
  no saved symbols (the tree was rebuilt since).
- Not done: hooks inside C++ (UE4SS's C++ cannot call our Lua back - Lua C API not exported; the C++ side could only
  queue events for Lua to poll, the same thing with more parts; the failures were the risk, now gone).
- Quick suite after this round: all PASS except ghostseat (the lever flake) and interact once (LOOT FAIL: one extra
  dropped wheel item, BP_WorldItem_Health_C, on the client 24 m from the host's after the bot's DETACH; containers /
  templates 100 %); interact passed the two reruns. To watch: whether the client's own dropped item is adopted when the
  host's S event arrives late (near-only passes send S within a second - the item falls / rolls meanwhile).

## Point 3: the other player's twin - doors, entry, mirrors (2026-10-26, after alpha 11; in alpha 12)

Owner (alpha 9 test): at the friend's car's wheel "sat for a second, then thrown out" -> never let the other player
sit there; get in through the door with the game's entry animation like the own car (E tap = open + entry, E held =
door only; a taken seat - a player, a device frame, the driver's - = door only); the friend's car's mirrors were dark.

Probed (own car, `cmds/door-trace.lua`, `local/run-doortap.ps1`): a tap at the driver door = door `AttemptOpen`,
`StartEntry(true)`, 0.2 s later `PDP_MainCharacter_C:CommandEnterCar(false, door, false)`, door `EnterCar`,
`GiveUpTryingToEnter`, `AttemptShut` at ~1.45 s; E held >= ~0.4 s = `AttemptOpen` / `AttemptShut` only (toggle). The
game's passenger doors only open. Calling that sequence on ANY door (own car or twin, manager.NewCarActor = twin)
animates the character from that door to the car's `TempSocket_Seat`. An open door = its MainMesh simulates physics
(yaw +-50..55, trunk pitch -80); on the kinematic twin AttemptOpen moves nothing. Hooking BP_CarManager_C
OnPlayerStartEnterCar / OnPlayerFinishEnterCar / SetDoorState crashed the game (do not).

Done (code):
- twincar: door parts in the pose as `D<n>.MainMesh` (n 1 FL, 2 FR, 3 RL, 4 RR, 5 trunk), sent only while open + 3 s;
  the twin applies doors only when changed. `Twin.door / startEntry / finishEntry / doorOpen / setDoor`.
- **Bug found + fixed**: the pose cache (`poseComps`) checked only a wheel component; the own car's PART actors are
  spawned again when a twin's relink re-binds the own slots, so the cached steering wheel / speedometer / shifter /
  door paths died -> the owner's steering wheel etc. stopped reaching the other's twin. Now every `@actor` entry is
  checked once a second.
- playersync (`TD` table - the main chunk is at Lua's 200-locals limit, put new state there): E press at a twin door
  -> `TD.doorPress`; release < 400 ms = tap (`TD.twinDoorTap`), held = `DR <t> <n> toggle`. Tap on a free seat:
  `aimSeatSocket` (twin socket at that seat; sockDelta from the twin socket's home), `startEntry`, `DR n open`,
  `finishEntry` 200 ms later (`TD.doorTick` in the apply loop), `DR n shut` at 1.45 s. Seat 1 never; taken = other
  player (P line) or device (`busyH` / `busyG`: new last field of C and G lines, `TD.devicesBusy`). S / SG carry a 5th
  field "x" = exact seat behind that door, never the driver's (`chooseSeat(..., exact)`); the owner applies `DR` on its
  real door (`Twin.setDoor`). `M.removeSeatDevice(n, own)` (client's own car), `M.doorInfo(n)` for tests.
- ghostseat-test rewritten for twins (old driving steps only with -Ghost): driver door tap only opens the host's real
  door + twin shows it (yaw 51), hold shuts, back seat entry 3 (host frees it), host into guest's seat 4 (device ->
  door only, then freed -> seated), going home split. **22/22 PASS.**
- **UE4SS ExecuteWithDelay is unsafe** (source LuaMod::process_delayed_actions): its callback runs on the async thread
  against the same Lua registry with no lock -> crash `luaH_getint` under `lua_rawgeti` (seen: ghostseat guest crash).
  The mod used it in menu (4), panel (3), runsync, session (2) -> all replaced by `CoopSyncAfter(ms, fn)` (hooks.lua,
  a game-thread loop; modules load it as `After`). Tests / CoopDev: `Dev.after(ms, fn)` (mod/CoopDev main.lua);
  revisit / startflow / home-car-probe / ghostseat and cmds probes switched. Never use ExecuteWithDelay / LoopAsync.
  Possibly behind some earlier real-game crashes (menu clicks, F7, the arrival car move in runsync).
- Mirrors (`cmds/captures.lua`, `door-mats.lua`, `local/run-captures.ps1`, CAPS=<probe> env): capture flags of the
  twin = own car's. SLOT_Mirror items are cosmetic hangers (IA_Cosmetic_Mirror_*), not mirrors. **The side mirrors**
  are slot 6 of the front doors' MainMesh (parent MI_Mirror_Rearview, param RearviewMirrorRT): own = the car's capture
  RT, twin = **Black** -> dark mirrors. Also the own car's capture HiddenActors held 124 twin actors (the friend's car
  never showed in the own mirrors) and the twin's 79 own-car actors. Written, NOT TESTED yet: `M._mirrorDoors(twin)`
  (sets RearviewMirrorRT of twin door materials to the twin's RT, every 2 s from `_light`) and `M._mirrorHidden(own,
  twin)` (drops the other car's entries from both lists: `arr:Empty()` + `arr[i] = v`, every 10 s); both in the timing
  wrapper list. Next: run run-captures with door-mats.lua / captures.lua to check RT=twin RT and other car's=0.

Left of point 3: verify the mirror fix (then a graphics look if possible), owner's headlights / engine state on the
twin (BP_CarManager_C holds CarLightsOn / CarIgnitionState for the LOCAL car: the twin shows local lights), screens
show local data, collisions between the cars (twin kinematic), exit from the twin is still a teleport ("Exit Car"
(false, true)), quick suite (not run since these changes: menu / F7 / session touched by the After change), CHANGELOG.

Finished for alpha 12 (2026-10-26, same day):
- Mirrors verified headless (`cmds/mirror-check.lua`, `mirror-watch.lua` + `-read`): the twin's door mirror slots
  hold the twin's capture RT; both HiddenActors lists hold 0 of the other car (`captures.lua`). Found: the doors put
  a NEW material (RearviewMirrorRT = Black) on the mirror slot ~6 s after getting into the twin (and maybe at other
  door events) - with the 2 s refresh the mirror was black up to 2 s. Now `_mirrorDoors` returns the slots it set
  (component path, slot, material address) and `_light` checks them every 0.25 s (one GetMaterial each): a changed
  one -> mirrorDoors at once (black <= 0.25 s, seen once in a 9 s watch). `CoopPlayers.twinModule()` for probes.
- Seated puppet's legs (owner: the feet stuck out under the car). Measured (`cmds/look-at-puppet.lua`,
  `car-heights.lua`; line traces from Lua returned no hits - LineTraceMulti's out array is not filled by UE4SS): car
  space pelvis -8, Interior mesh bottom -35, Chassis bottom -51, ground ~-77; the old pose (calves straight down)
  put foot -48 / ball -59 - below the floor and the underside. The game's own character in the car stands (feet
  -101, hidden in first person): no reference pose. `M.legPose` (kneeUp 20, calfFwd 45, toeDrop 4) via the arm IK's
  `aim`: knee +6, foot -23, ball -28 at both seats (front toes at X 133, back toes at X 8..27 under the front seat).
  A graphics look from outside showed nothing useful (dark scene, camera above the sill): the owner checks it.
- Tests: contact-test rewritten for the twin rules (driver seat never; tap at a door; hands on the wheel = the host
  at its own wheel seen by the guest) 8/8. anim-test: walks went into the car (the puppet's capsule / the car block
  since the solid puppet) -> the walker faces away from the car first; 28/29, the run phase's foot_motion was 0 once
  (state=run, uphill; sample reset) - watch.
- Quick suite after the mirror / door changes: all PASS except contact (old rules, now rewritten and passing).
- **Alpha 12 built** (`local/release/PacificDriveCoop-0.1.0-alpha12.zip`, install-test 10/10, symbols kept).
- Left open on purpose: lights / engine / screens of the owner on the twin, collisions, exit animation - all go into
  the twin rework below (owner: no more mod-made substitutes).

## Twin rework: the other's car as a real car (owner 2026-10-26, NEXT STAGE after alpha 12)

Owner: "the second car must not differ from the own one in function and interactions; everything native, without
workarounds or crutches" - take parts off / put parts on / repair / interact like the own car, lights, engine, etc.

Today's twin: a copy of the LOCAL car (one car manager, one car inventory), slots unbound (`SpawnedActor = nil`,
`SetItemSlot(nil)`), restyled to look like the owner's; the game's highlights ignore it. Direction found in the
header dump (`local/dumps/2026-10-20/CXXHeaderDump`):
- `UInventoryBlueprintLibrary::CreateNamedContainer(Outer, Title, SlotRules, Cap, MaxForce)` - a named container
  like the car's `UBaseInventoryManager.Inventory_CarEquipped` (UNamedItemContainer: FindOrCreateSlot(name),
  GetSlotNames, RemoveItemFromSlot...).
- `UInventoryBlueprintLibrary::CreateItemInstance(World, Archetype, CreateContext)` / `UItemArchetype::CreateInstance`.
- `USlotSceneComponent::BindNamedSlotsFromActor(NamedContainer, Actor)`: binds an actor's slot components to a named
  container -> the game spawns the parts (manifestations) from the items, as for the own car.
- Part interaction actor: `BP_CarPart_Interactive_C` (Highlight component, GetSlot / GetInstance, AllowsPlayerSwap,
  OpenPartContext, SetMechanicMode, OnSlotItemAdded / Removed); wrecks use another path (ALootableTemplate /
  TemplatePart).
Plan: the twin gets its own container with instances of the owner's items (archetypes + properties: health etc.),
bound with BindNamedSlotsFromActor -> the game's own highlight / detach / attach / repair work on it; the mod watches
that container (slot item added / removed, property changes) and applies the same to the owner's real car, and the
owner's changes back. Open questions: what in the game assumes ONE car (car manager NewCarActor, quest manager
OnCarEquippedItemAdded, saves of world items, car health over parts), item properties (health) read / write
(UInventoryBlueprintLibrary SetItemProperty / GetItemProperties), lights / engine / screens per car.
First probe written, not run: `mod/tools/cmds/twin-container-probe.lua` (needs a twin: run in run-captures with
CAPS=twin-container-probe.lua; TWIN_CONT_READ = true reads the state later).

## Owner's real test of alpha 12 (2026-10-26 evening; reports local/reports/a12-*)
Owner host, friend guest (friend's report taken after a restart, but its hitches / net logs cover the session).
Owner's account: the friend's map pick hung, no automatic travel - it picked the same place by hand; at first the
zone differed, after ~1 min it synced and the friend appeared next to the host; the cars broke, interactions worked
"now and then"; getting into the host's car teleported the friend into its own car, then its car flew off, the friend
died, went to the garage with a frozen white screen. Also: loot the same but individual (both could take the same
item), the gas station's fuel level not synced. Owner: focus on the two cars now, the rest later.
Timeline from the logs:
- 20:20:52 host "start"; guest "go" 20:20:54 -> its exit opened. The host's zone documents (route, gates, spawn list)
  went out only at 20:21:37 (host's zone load + readiness ~45 s): the guest drove out before any route -> the game's
  map pick (no override possible), the friend picked by hand, arrived 20:21:10, waited for the spawn list (20:21:43),
  import 20:21:52-22:12. **Fix later: the guest's exit stays shut until the host's run descriptor arrived** (not just
  "go"); count the wait on the guest's screen.
- Guest fps in the zone ~20 (F lines 45-57 ms frames; mod 2.5-4 ms: p.apply ~1.5, state ~1.2) - the game itself is
  the bulk; watch.
- Twin: spawned on both 20:22:11-13; restyle matched only 42-46 parts (tests: 84) hidden ~100, added 30-55 - their
  cars differ much more than test cars. 20:25:59 guest "Death:OnFoot:Fall"; 20:26:10 guest in the garage 6.5 s, back
  in the zone 20:26:14 (second import 20:26:54-27:00, 207 host events at once, state 34 ms per frame); host: second
  twin spawn 20:27:14, **host crash 20:27:16** (access violation in the game exe called from UE4SS Lua, 2 s after the
  twin spawn + restyle: "MaterialInstanceDynamic ... BP_Manifestation_CarEquipment_C ... is not a valid parent" just
  before) -> guest sent home 20:27:28 (ReturnFail dialogue: the white screen).
- The teleport into the own car / flying car / broken interactions match the twin design's weak points: the twin
  steals the items' manifestations and the own car's slots are re-bound (relink: the own car's parts spawned again,
  flips seen before), one car manager switched between cars on entry. The rework (below) removes relink and restyle.
For later (not cars): loot pickups must be shared (PICK of the same item by both), gas station fuel level sync,
the guest's exit gate vs the host's documents, the second-arrival flow after a death.

### Twin rework, stage A: native parts (2026-10-26 night)
Probes (headless, guest in the zone with the host; scripts: `cmds/twin-container-probe.lua`, `twin-parts-look.lua`
(LOOK_SLOT / LOOK_OWN / LOOK_EMPTY / LOOK_AT_SLOT / LOOK_DZ), `highlight-now.lua` (BP_HighlightManager_C
CurrentHighlight: owner class, own / twin, slot via GetSlotComponent(out)), `slot-state.lua`, `twin-clean-spawn.lua`,
`item-data-probe.lua`, `to-hand.lua`, `twin-put-on.lua`):
- A named container of our own (CreateNamedContainer(IM, FText, real.NewSlotRules, cap -1, max 1)) + new instances
  (CreateItemInstance(world, archetype, it.CreateContext)) bound with SlotSceneComponent CDO
  BindNamedSlotsFromActor(cont, twin): all 83 slot components bound, the game spawns the parts from the items.
- The game's highlight hits the twin's parts (`BP_CarPart_Interactive_C` of the twin). Taking a part off / putting
  one on is NOT E: it is `Command SwapEquipment` (its own key; BP_CarManager_C Swap Equipment / CanSwapEquipment /
  PopOffPartFromCar), held ~3 s: the twin's wheel went into the player's inventory, the slot shows
  BP_CarPart_Wheel_Empty_C; the own car untouched. Same result on the own car.
- **Clean spawn**: with IM.Inventory_CarEquipped pointed at our filled container while the car spawns (deferred spawn
  + FinishSpawningActor), the car's BeginPlay binds to it: own car 0 parts respawned, 44/44 item links whole, the
  new car 81 slots on our container, a slot left out of it empty. No relink (the flips / flying cars), no unbind, no
  restyle (the crash of alpha 12's host 2 s after a twin spawn + restyle).
- Item data: `UItemInstance:GetDataBlockDump()` = the save-format JSON (IP_CarEquipment slot meshes, IP_WorldItem,
  ...); health via the part's BP_HealthComponent_C HC_GetHealth / HC_GetMaxHealth (wheel 175, engine 400, fuel tank
  200, battery 150, door 40). Writes: properties are UserDefinedStructs (IP_Health, IP_Fuelable, IP_Battery,
  IP_Fatigue) - SetItemProperty / GetItemProperties are generic thunks (risky from Lua); damage / heal go through
  messages (MSG_Base_Damage / MSG_Base_Heal -> BP_HealthComponent Process Damage / Heal Message) - stage B.
- Putting a part on in tests: an empty wheel slot was never highlighted from where the probe stands (the panel above
  wins), on the own car too; moving an item into the hand slot with TransferSwapIntoSlot did nothing. Tests put a
  part on by moving the inventory item into the twin's container slot (`twin-put-on.lua`, what the game's attach
  does). How a person puts a part on (hand, aim) - to look at in graphics.
Code (twincar "Equipment", playersync TD.sendEquip / TD.equipTick / EQ / EX):
- Owner: EQ <time> <slot>=<archetype path>@<context>;... of its real container (checked every 2 s, sent when changed
  and every 10 s). Other side: the twin is spawned only after an EQ (Twin.spawn(loc, rot, equip): container + clean
  spawn + puppet), later EQ lines go onto its container (Twin.applyEquip: a slot the local player changed waits 4 s
  for the owner's line), the local player's changes (Twin.watchEquip every 250 ms) go to the owner as
  EX <time> <slot> <path@ctx | -> -> Twin.ownerEquip on the real container (a part taken off leaves the owner's game:
  the other player has it; a part put on is a new instance there). Twin.destroy empties the container first.
- Verified over the test network (`eq5` scenario): guest takes the host car's wheel off its twin -> host's real slot
  empty; puts it on -> host's real slot has it; host takes a seat device off -> guest's twin slot empty. equip_errors
  0, broken_links 0. ghostInfo has equip_* / eq_* / ex_* fields.
Next: test script + quick-suite entry; health / fuel / charge (stage B); entering the twin through its own doors
natively (the alpha-12 "teleported into my own car"); lights / engine / dash per car; clean out relink / unbind /
restyle / ghost-only code; a graphics look (paint: the tint is item data - the twin's panels show the default color).
- **Hang found + fixed**: ghostseat step 6 (host goes home with twins) hung BOTH games right after the travel save
  ("Writing save slot backup ... FlushAsyncLoading: 1 QueuedPackages", nothing after, no dump). Twin.destroy had
  emptied the twin's container first (fillSlot "-"): every emptied slot spawns a placeholder part (Empty meshes to
  load) - inside the travel pre-hook, during the save's flush. Single-instance probe `cmds/home-after-twin.lua`
  (none / cont / spawn / destroy 3 s before TravelToGarage) all went home fine - the timing was the point. Now
  destroy leaves the container alone (outer = /Engine/Transient, item instances created with the PlayerController as
  world context; the GC takes them). ghostseat 22/22 again.
- `mod/tools/twin-equip-test.ps1` (quick suite "twin-equip"): twins from EQ on both sides, guest takes the host car's
  wheel off with the game's SwapEquipment (aims until the highlight says that twin slot), host's real slot empties,
  guest puts it back (`twin-put-on.lua`), host takes the guest car's wheel off, host's seat device change reaches the
  guest's twin, no errors / broken links: 10/10.
- Quick suite after stage A (2026-10-27 night): all PASS (sync, interact, drive, wheel, owncar-guest, ghostseat 22,
  twin-equip 10, session-net, menu, startflow, mapsync, gates, esc, contact 8, f7, revisit).

### Twin rework, stage B: part state - health / fuel / battery (2026-10-27)
Found (`cmds/part-state.lua`: STATE_CAR own|twin, STATE_SLOTS, STATE_SET): the part actors' own components have the
game's own setters - BP_HealthComponent_C `SetHealth` / HC_GetHealth, BP_FuelableComponent_C `Set Fuel` /
GetFuelStatus (out params: one table each, keyed by the param name), BP_BatteryComponent_C `Set Battery` /
GetBatteryStatus (classes under /Game/Gameplay/Inventory/GenericItemProperties/Components/). Reading per item also via
BFL_ItemPropertyUtilityFns GetHealth / GetFuelableInfo / GetBattery. SetHealth on a twin part changes that part only
(own car untouched). Fuel lives in Internal.FuelReserve (25), Internal.BatteryReserve (50), Attachments.FuelCan (10).
Code (twincar "Part state", playersync TD.sendState / ES / EY):
- Owner: `ES <t> <slot>=<h>,<f>,<b>;...` (empty where no such component), checked every 1 s, sent on change and every
  10 s. Other side: `Twin.applyState` sets the twin's parts (eps h 0.5, f/b 0.05; a slot the local player just changed
  waits PENDING_S). `Twin.watchState` (250 ms) sends `EY <t> <slot> <h|f|b> <delta>` -> `Twin.ownerState` adds it on
  the owner's real part.
- Only UPWARDS changes go back (repair, refuel, charge) and none while the local player sits in that twin: with the
  manager on the twin the game simulates it (seen: battery / fuel drained there, sent as 37 changes to the owner = a
  double drain). Damage to the twin is the owner's business (the twin hit here is that car hit there); the owner's
  next ES puts the twin back.
- `mod/tools/twin-state-test.ps1` (quick suite "twin-state"): host damages its wheel / half-empties its can -> twin
  shows it; guest repairs the twin's wheel (SetHealth, where the game's repair ends) -> host's real wheel repaired;
  guest fills the twin's can -> host's can full; guest damages the twin's wheel -> host untouched, twin back to 175;
  own car untouched, no errors: 9/9. (The repair tool / refuel action of a person: to check in graphics.)

### Twin rework: entering through the twin's doors natively (2026-10-27) - the alpha 12 "teleported into my car"
Probed (`cmds/twin-door-native.lua`, `door-trace.lua` now tags [TWIN] / [OWN] and traces HighlightPress /
SetHighlight, `twin-door-unbind.lua`; runs aimed with `twin-parts-look.lua` LOOK_SLOT = 'DoorsFL' until the game's
highlight is on that twin slot):
- The twin's doors are real parts now: the game highlights them. Its own E at the twin's DRIVER door: door
  AttemptOpen + StartEntry (on the TWIN door), 0.2 s later the character's CommandEnterCar into the car the manager
  holds = the OWN car, 8 m away (exactly the owner's alpha 12 report). The old mod path never saw it (it picked doors
  by distance; the probe stood 2.4 m off). At a back door the game does nothing visible.
- Worse: GiveUpTryingToEnter 30 ms after did not stop it, and the door opened its physics on the kinematic twin -> it
  broke off (world item SM_CarPart_Door_Steel_01_World), the twin's slot emptied -> the guest's watchEquip sent EX "-"
  -> the HOST LOST ITS REAL DOOR. Manager pointed at the twin before E: the game did nothing at all (no use).
- **UE4SS runs a BP function's "pre" hook after its body** (traced: HighlightPress true logged after the door's
  AttemptOpen / StartEntry; the character's Command Interact hook even later): no Lua hook can get in before the game's
  E. Dropping the highlight (SetHighlight(nil)) works only BEFORE the call (probe), not from a hook.
- **The native lever**: the door actor's Highlight component has the game's handlers on its multicast delegates
  (OnInteract -> BndEvt_0, OnInteractShort -> BndEvt_1, OnInteractLong -> BndEvt_2; the interactive part's
  Highlight: OnInteractStart / End for taking it off). Our UE4SS build has delegate properties in Lua
  (`comp.OnInteractShort:GetBindings()` -> {Object, FunctionName}, `:Remove(obj, fname)`, `:Add`, `:Clear`,
  LuaXDelegateProperty.cpp). Removing the door's three: the prompt stays, the game's E does nothing, the mod's hook
  still sees the press with the highlight on.
Code:
- `Twin.muteDoors(twin)` (from TD.equipTick every 250 ms; works only when a door actor is new: address per door n)
  removes those three bindings of the twin's door actors (`doors_muted` in Twin.info: 15 = 5 doors x 3).
- `Twin.highlightedDoor()`: the twin + door n (slot Car.Equip.Body.DoorsFL/FR/RL/RR/Trunk -> 1..5) the game highlights.
- `TD.hookHighlight` (hook on BP_HighlightManager_C:HighlightPress, registered with hookDoors) -> `TD.onHighlightPress`
  sets TD.doorPress from the highlighted twin door; tap / hold as before (TD.twinDoorTap, TD.doorTick). The old
  distance pick (TD.nearGhostDoor) stays for the old ghost only.
- A part that leaves a twin slot is sent to its owner as taken off only when it is with the local player
  (`heldByPlayer`: its GetOuterSlot's container is Inventory_Player / PlayerHand / Trunk / LargeTrunk / Overflow),
  checked for STRAY_S = 1.5 s; else (broke off, fell, destroyed here) the loose one is removed and the slot filled
  again from the owner's line (`equip_strays`).
- Tests: ghostseat / contact `Tap` now aim at the twin's door until `highlightedDoor()` says it (as a player looks),
  then press; ghostseat has a new check "nor put into its own car by the game's E, the host's door still on".
  ghostseat **23/23**.

### Twin rework stage C: the car body, levers, lights (2026-10-27)
Probed (`cmds/twin-lights.lua`, `twin-body-hl.lua`, `twin-body-press.lua`, `car-funcs.lua`, `ctl-probe.lua`,
`headlight-power.lua`, `consumer-battery.lua`, `car-tick-count.lua`):
- **One state for the game**: the car manager holds the headlights (SetCarLightsOn / GetCarLightsOn), the top light
  (Set/GetCarTopLightVariable), wipers (Set/GetWipersOnOffVariable), ignition, lever, radio, horn, door states. Every
  car shows it: the twin's ManualSetIgnition_NoAnim(0) put out the rear lights of BOTH cars. The car's
  ToggleHeadlights / ToggleInteriorLight / ToggleWiperBlades flip the manager's state with the lever animation (~1 s).
- **The twin's car body highlights** (Highlight_Key / TopLight / LeftHandle / RightHandle / EnterDoor / ExitDoor /
  Gearbox) are bound to the twin's own BndEvt handlers (params: Component, InteractData), and they act on the manager:
  the game's E (SetHighlight + the character's Command Interact - HighlightPress takes 2 params) at the twin's
  LeftHandle switched the OWN car's headlights on; at the twin's EnterDoor it got the guest into the OWN car (the
  alpha 12 teleport again, through the body). Key / TopLight from outside: nothing.
- **Headlights**: only the headlight parts' battery consumers (BP_BatteryConsumerComponent_C, 2 per car) - the twin's
  never found a battery (found=0; FindBattery did not help: it goes through the manager). Given the twin's own
  battery (SetBattery) they lit, but with the LOCAL manager state. The headlight part's tick (BaseLightTick) sets its
  light every frame.
- **Body lights** (Light_Top, rear, interior fill, dash...): ReceiveTick -> ElectronicUpdate_All -> _TopLight / _Dash /
  _RearLights run every frame on BOTH cars (178 each in 2 s) and set them from the manager.
- So a per-car lights state does not exist in the game: the twin shows what the owner's game computed.
Code:
- `Twin.muteBody(twin, inside)` (TD.equipTick, 250 ms): the key and EnterDoor lose the game's handlers always (the key
  in a twin is the mod's twinInteract; EnterDoor = the driver's door: TD.onHighlightPress -> door 1), the levers and
  the top light only while the local player is not in this twin (given back with the delegate's `:Add(obj, fname)`
  when it gets in). `body_muted` / `body_restored` in Twin.info. `Twin.highlightedBody()`.
- In the twin: `twinInteract` leaves a press at TopLight / LeftHandle / RightHandle to the game (not "get out").
- **Lights / top / wipers like the ignition**: the owner's state rides on C / G lines as "ltw" (3 digits, TD.ownLtw:
  the manager's, or savedCtl while that player sits in the other's twin). twinControls: in the twin the manager holds
  the owner's (TD.setLtw: the manager's setters), the player's change (the game's lever on the manager) goes as
  K / KG lights|top|wipers <0|1>, the owner flips its real car with the game's own toggle (TD.toggleLtw); the owner's
  own changes are followed (LTW_HOLD_MS 2.5 s after ours); getting out restores the own state.
- **Lights display** (`Twin.lightLine` / `applyLights` / `applyBodyLights`): the owner sends LI lines - each light
  component's intensity (+ "h" hidden), body ones keyed "body|<name>", part ones "<slot>|<name>" - 5 a second when
  changed, else every 5 s. The twin applies them every 250 ms (TD.equipTick; headlight parts' actor tick off on the
  twin), and its body lights again right after its own per-frame update (`TD.hookCarLights`: hook on
  ElectronicUpdate_All, which UE4SS runs after the body). `li_sent` / `li_recv` / `lights_set`.
- Cleanup: the old relink / settler / unbind / restyle code (pre-clean-spawn twin) removed from twincar (~300 lines),
  `restyle=` / `relinked=` gone from Twin.info, playersync's restyleStep call gone.
- `mod/tools/twin-ctl-test.ps1` (quick suite "twin-ctl"): outside the host's twin the guest's E at its levers / top
  light leaves its own car alone, EnterDoor opens the host's real driver's door (not into the own car); inside (back
  seat freed) the handlers are back, the manager holds the host's state, the guest's headlight lever / top light switch
  the host's real car (the guest stays in), the host's own wipers are followed; out again: the guest's own state back,
  its car dark while its twin of the host's car shows the host's headlights + top light, and the host's twin of the
  guest's car stays dark; the host's headlights off -> the twin's off: **18/18**.
Open: the radio, horn, gearbox highlight, wipers' motion on the twin (the wiper blades follow the local state - their
timeline is not a light); screens of the twin (`screens=0`: fixScreens did not match since the clean spawn - check).

- Quick suite after stage C (2026-10-27): all 18 PASS, no reruns (sync, interact, drive 23, wheel 10, owncar-guest 11,
  ghostseat 23, twin-equip 10, twin-state 9, twin-ctl 18, session-net 12, menu 15, startflow 13, mapsync 9, gates 5,
  esc 6, contact 8, f7 4, revisit 11).

### Twin rework stage D: screens, radio, horn, wipers (2026-10-27)
Probed (`cmds/twin-screens.lua`, `widget-comps.lua`, `screen-mats.lua`, `dash-look.lua` + graphics run screenshots,
`radio-probe.lua`, `horn-probe.lua`, `wiper-probe.lua`):
- **Screens**: since the clean spawn the twin's computer / status box / battery bar are the game's own parts with
  render targets of their own (the LimBox's screen material samples its own RT; the other two are world-space
  widgets) - seen lit in a graphics run, like the own car's. `fixScreens` never matched any more (`screens=0`) and was
  retried every 30 s (150-250 ms each): removed with its keep-alive list; `screens=` gone from Twin.info, the
  ghostseat line prints the mirror only. (The status box's lights may show the local state - not checked further.)
- **Radio**: on / off is the manager's (Get/SetCarRadioOnOffState); BOTH radio parts are bound to its
  OnCarRadioStateChanged; the music manager plays from GetRadioSource = the radio part of the manager's car (the twin
  while the player sits in it). The radio part's ToggleRadio flips it natively (no UI). The twin's radio button
  (Highlight1.OnInteract) switched the OWN radio from outside.
- **Horn**: the manager's StartHornHonk / EndHornHonk (instigator name) -> UpdateHornState -> ToggleCarHorn(Active,
  Pitch) on the manager's car - the twin while the player sits in it (it honked there already, the owner's car not).
- **Wipers**: every car plays Timeline_wiperblade from the manager's one wipers state; the car's SetWiperTimeline(pos)
  moves the blades to a position (UpdateWiperRotations).
- Wwise runs no events in the test instances even without -nosound (HasActiveEvents false everywhere): sound itself
  is not checkable here, only the game objects' state.
Code:
- Radio = a 4th TD.LTW entry (getter / setter with SkipQuirks / the radio part's ToggleRadio; entries may be
  functions): "ltw" is now 4 digits (TD.fmtLtw / parseLtw, a 3-digit line = radio unknown), K / KG radio <0|1>.
  `Twin.radioOf(car)` (cached 2 s), the twin's radio button muted outside in Twin.muteBody (bodyOf "Radio", with the
  part's name - a swapped part is muted again), `Twin.highlightedRadio()` keeps twinInteract from getting out there.
- Horn: hook on the car's ToggleCarHorn (TD.hookHorn, with hookCarLights): on the twin the local player sits in ->
  "HR <0|1>" to the owner (TD.askedHorn: its manager Start/EndHornHonk "CoopSync"); on the own car -> "HN <0|1>
  <pitch>", the other side's twin honks with the game's ToggleCarHorn (TD.setTwinHorn, guarded). Getting out with
  the horn down sends HR 0. `horn_sent / horn_recv / horn_asked / last_horn_done / twin_horn` in ghostInfo.
- Wipers: the pose line ends with "WT=<timeline position>"; Twin.applyPose sets it on the twin with SetWiperTimeline
  unless the local player sits in it (the manager holds the owner's wipers then). 10 Hz steps (pose rate).
- `mod/tools/twin-ctl-test.ps1` now **24/24**: + the twin's radio from outside leaves the own radio, inside it
  switches the host's real radio; the guest's horn in the twin honks the host's car and stops; the host's horn ->
  the guest's twin (its own car silent); the host's wipers -> the twin's blades sweep while the guest's are off.
Open: the radio channel / track (custom tracks per player), the twin's radio lights and wiper sounds follow the local
state outside, the gearbox highlight; the radio / horn heard by ear only in a real game.
- Quick suite after stage D (2026-10-27): all 18 PASS (twin-ctl 24/24, ghostseat 23/23, contact 8/8, revisit 11/11).

### Twin rework stage E: radio music, gear lever (2026-10-27)
Probed (`cmds/music-probe.lua`, `shifter-probe.lua`; the music manager plays only with sound: `game-args.ps1` keeps it
with `$env:COOPTEST_SOUND=1`):
- **No stations**: the radio is one playlist on the music manager (BaseMusicManager.RadioPlaylist, 61 built-in
  MusicTrack assets /Game/Music/MT_* + the player's own files from Custom/Radio with ExternalUrl). The channel
  buttons = the radio part's BP_RadioComponent:ChangeChannel(dir) -> the manager's SkipTrack. CurrentRadioTrack().
- The playlist is a queue: the track picked is removed (every entry of it) and added at the end; SkipTrack picks
  ~50 ms later (async). No call plays a given track and no seek (Wwise events; only external files have a
  MediaPlayer). A given track: every entry set to it, SkipTrack(1) (the playlist is that one track then), the playlist
  written back once it plays (TArray:Empty, then written past its end - a UE4SS TArray grows), the track at the end.
- **Gear lever**: the car's GetGearboxActor answers the NEWEST shifter of the world, not its own: with a twin both
  cars answered the twin's. So the own car's lever animation (SetGearboxRotationFromAnimPosition) moved the twin's
  lever (overwritten by its pose) and the own lever stood still - and so did the other side's twin of it (it follows
  the owner's lever pose). The highlight on the car (Highlight_Gearbox) has no handlers; the shifter part's own
  Highlight does the lever.
Code:
- twincar: `trackId` (asset path, "x:<file>" for own files), `currentTrack`, `playTrack(id)` (the trick above,
  `musicBusy`, `tracksPlayed`), `changeChannel(car, dir)`; `partOf(car, cls)` cache (radioOf / `shifterOf`).
- playersync: `RT <track>` (TD.sendTrack with the other car lines: checked 1 s, sent when changed / every 10 s, only
  while the manager's car is the own car); TD.musicTick (equipTick): in the other's twin with the radio on, a
  different local track -> playTrack(owner's); the twin's ChangeChannel hooked (TD.hookRadio) -> `RK <dir>`, held 2 s,
  the owner's real radio changes channel (not while the owner sits in a twin), its new track comes back on RT.
  `rt_sent rt_recv rt_played last_track rk_sent last_rk_done` in ghostInfo.
- TD.hookGearbox: hook on GetGearboxActor (after the body) sets the out param to `Twin.shifterOf(self)` - the game's
  own calls see it (~30 per lever move); `gear_fixed`. The hooks' `.on` are renewed after a module reload now
  (hookCarLights runs again when CoopSyncGearHook.on is stale).
- Tests: `mod/tools/twin-radio-test.ps1` (new, quick suite "twin-radio", sound on): host radio on -> RT; guest in the
  twin plays the host's track; the twin's channel -> host skips, guest follows; the host's own channel -> guest
  follows; the guest's playlist whole again (61); out: guest radio off: **9/9**. twin-ctl + the host's lever moves
  (own_asks=own), the guest's twin shows it: **26/26**.
Open: no seek (a track joined in the twin starts from its beginning: the two players hear different positions);
custom tracks only when both have the same file name (else the guest keeps its own music; untested: no files here);
the owner's radio is heard only by the player in that car (the music manager has one source: outside, the twin's
radio is silent).
- Quick suite after stage E (2026-10-27): 18 of 19 PASS at once (twin-ctl 26/26, twin-radio 9/9); drive 21/23 (the known coasting flake: the car still rolled at speed 278, so the copy lagged 137 units), PASS 23/23 on rerun.

### Radio in step, live loot, the cars colliding (2026-10-27, after alpha 13)
Owner: "item 2" (cars: collisions, seek, own tracks), live loot (take / put shows at once), the radio's random picks
must not split the two radios, seek; also the garage (the stereo plays the radio there), and part damage in crashes.
- **Wwise from C++** (`mod/CoopNative/audio.cpp`): the game's exe EXPORTS AK::SoundEngine (decorated names in its
  export table: GetProcAddress on the exe). `CoopNative_AkPlaying(go)` (Query::GetPlayingIDsFromGameObject +
  GetEventIDFromPlayingID), `CoopNative_AkSeek(event, go, ms, pid)` (SeekOnEvent), `CoopNative_AkPos` (GetSourcePlayPosition:
  answers 94 for the radio tracks - posted without its flag, so no position). Game object = the UAkComponent's address
  (MusicTrackPlayer.PlaybackSource = the radio part's AK_RadioSource); event id = AudioEvent:GetWwiseShortID() (signed:
  +2^32). Seek verified: to 4 s before the end -> the next track 4-5 s later (`cmds/ak-probe.lua`). Radio off does not
  stop the track (same playing id, only silent).
- Position = a clock per side (twincar `trackPos` / `seekTrack`): a new playing id = the track began; a seek here moves
  it. RT lines carry the ms; the follower seeks when > 700 ms off (at most every 3 s). The game's own random seek
  (BP_MusicManager RandomSeekMusic, when a radio turns on; the radio component has RandomizeStartTime) is hooked and
  replaced by a known one (following: the owner's place).
- **Next track**: ~4 s before the end the owner picks the next one (random, like the game) and queues it (playlist =
  that one track; given back once it plays); "RN <track>" -> the follower queues it too: both change at the natural
  end together (measured 45 ms apart). A follower already on the announced next track waits for the owner (it ended
  first; it used to switch back and forth: rt_played 1 -> 3, the first garage run).
- **Garage**: the stereo (BP_Garage_Stereo_01_C, its own BP_RadioComponent) plays the music manager's radio (the car
  radio's AkComponent); in the lobby the guest always follows the host (RT / RN / RK pass the garage filter), the
  guest's channel button (stereo or car) -> RK -> the host's radio skips. Each player's stereo on/off is its own.
- **Own files** (Custom/Radio next to Saved: `<userdir>/Custom/Radio`; settings RadioSource 0 built-in, 1 both, 2 own
  only): NOT in RadioPlaylist - the library (DirectoryMusicLibrarySource) picks them and makes their MusicTrack. The
  other's file this side has under the same name: that track object, or one made here (StaticConstructObject, ExternalUrl
  file://...), queued like a playlist track (`cmds/custom-play-probe.lua`: plays, playlist untouched). Their time is a
  UMediaPlayer FTimespan (Lua gets an empty table): `CoopNative_MediaTime / MediaSeek` call GetTime / GetDuration / Seek
  through ProcessEvent. UNVERIFIED: in the test copy the media player reports not playing (time 0, seek false). The
  owner's pre-pick of the next track only works for built-in tracks (own files are picked by the library).
- **Live loot** (statesync "Live"): hooks on ItemContainer HandleSlotItemAdded / Removed (they run through UE4SS hooks:
  `cmds/loot-hook-probe.lua`; outer = the lootable actor, or BP_InventoryManager_C for the player's own) mark the actor
  dirty: the host serializes it the next frame and sends U (and puts it into the pass under way, else the pass sent
  the older state after it); the client runs detectOne on it the next frame. A player-inventory change starts a pass at
  once (pick-ups / drops). The host handles requests every frame (was once per pass) and sends D at once for a PICK.
  New request `PUT <key> <item spec> <n>` (the client put items in; before, the host never knew and its next U wiped
  them): counted by archetype like TAKE (whole specs of rebuilt items need not match: duplicates), the spec says what
  to make (`Loot.newItem`); reconcileTake asks PUTs too; a refused PUT (host's container full) gives the item back to
  the player. The client's own applies are quiet (`LH.quiet`).
- **Collisions**: the car chassis is of the game's car channel (22) and ignores that channel (one car in the game):
  the cars drove through each other (`cmds/collide-probe.lua`). The twin's chassis now WorldDynamic (the own car
  blocks it) blocking channel 22; the twin is moved without teleport except when it snaps (a kinematic target with
  velocity pushes; a teleport only pushed out of overlaps). Damage needs nothing more: each car's own physics damages
  it on its owner's side, the twin shows it (ES lines). A kinematic twin is infinitely heavy to the physics: the car it
  drives into takes the striker's whole speed (the guest's parked car thrown 42 m at 15 m/s).
- Tests: `garage-radio-test.ps1` (new, sound on) **10/10**; `loot-live-test.ps1` (new) **7/7** (0.36-0.7 s per change
  incl. the test's polling); `collide-test.ps1` (new) **6/6** (host's car stops at the guest's twin, the guest's car
  pushed 42 m, both damaged: host -44, guest -37, the twin shows the host's). All three in the quick suite.
Open: own-file position unverified; the striker-takes-all collision feel; the other's car storage (trunk contents)
not looked at yet; DJ interstitials are each side's own.
- Quick suite after this round (2026-10-27): 22/22 tests passed, 0 failures (garage-radio 10/10, collide 6/6,
  loot-live 7/7, the rest unchanged).

### Alpha 14; the DJ in step, the cars' storages, the hit between the cars (2026-10-27)
- Alpha 14 built (local/release/PacificDriveCoop-0.1.0-alpha14.zip, install-test 10/10) with the radio seek, live
  loot and collisions of the section above.
- DJ breaks: the music manager's RequestInterstitial has the dialogue manager play a DialogueSequence of the event
  "Ambient" (DJ Garlic, Flash Wednesday ...; ~18 s). Natural ones only past QD_Q01_RepairAndPrepare and off the
  critical path (ConditionsToAllowNatural/ManualInterstitials: WC_Exists tags) - the test save has none, so tests call
  RequestInterstitial. Never in the garage. IsAnyoneTalking + GetCurrentlyPlayingSequence show one playing (a second
  PlaySequence of one still playing left "talking" stuck). The owner sends "RI <sequence>"; the follower plays it
  (PlaySequence, priority Default), keeps both interstitial counters at 99 while following (back after) and stops
  any break of its own. twin-radio 13/13 (step 2b).
- Car storages (carstore.lua, new): the twin's trunk part pointed its ExternalInventory component at the LOCAL
  player's Inventory_Trunk - the friend's trunk showed and changed the own one. Now it points at a container of its
  own (StaticConstructObject of the trunk container's class, outer the trunk part, layout + slot parameters copied:
  the part does not point it back). Storage attachments (IA_Attach_Util_Storage_Small/Large: window slots, e.g.
  LeftRearWindowBack; not BackSeat / Roof without racks) keep items in a container owned by their item instance.
  CS (owner, 1 s / 10 s) -> filled into the twin; the visitor's changes (diff by archetype every 500 ms, before the
  next CS is filled) -> CX -> owner's real storage; CN (put did not fit: back to the player), CT (take the owner no
  longer had: the player's copy removed). lootsync: serContainer (owner map of its items only), fillContainer,
  containersByOuter exported. car-store-test 12/12 (trunk both ways, owner's own take, attachment both ways).
- Found on the way: one dead entry in a car slot (a fillSlot whose AddItem the slot rules refused, after the old item
  was removed) made equipLine throw - the whole EQ line stopped. contents() skips dead entries; fillSlot reports the
  refused add.
- The hit: the twin is kinematic (infinite mass); the parked car got either the striker's whole speed (42 m) or
  nearly nothing (the striker stopped at the twin on its own side: 0.5 m). bumpTick (every frame with a twin): the
  own car's velocity jumping >= 3 m/s away from the twin within 9 m. Own car closing faster -> "BI nx ny vc" with the
  shared speed from the velocities before (masses: both 2786); the other side sets it on its car and its twin of the
  striker lets cars through 0.4 s. Twin closing faster (its prediction ahead) -> the jump cut by mt/(mo+mt) locally.
  collide-test 8/8: striker 14.4 m/s, the parked car's top 6.9 m/s (the test spot is a slope: it rolls on).
Open: own-file radio position unverified; the striker still stops dead (the game's bounce off the twin); a take the
owner no longer had is undone on the visitor (CT) but a put racing an owner's change can reorder items.
- Quick suite after this round (2026-10-27): 23 tests; 21 PASS at once, interact (the known loot flake: 1 client-only
  wheel) PASS on rerun, collide 8/8 after its damage compare got a 5-point tolerance (STATE_EPS 0.5 per part: small
  scratches on 21 parts are not applied to the twin, ~3 in all) and a few seconds to settle.

### Alpha 15; the striker keeps going, storage changes in order (2026-10-27/28)
- Alpha 15 built (local/release/PacificDriveCoop-0.1.0-alpha15.zip, install-test 10/10): DJ in step, car storages,
  the hit's shared speed.
- The striker: in its hit frame its own car takes the shared speed along the line between the cars too (it had
  stopped dead: the twin a wall), and its twin of the car hit moves on at that speed at once (playersync TD.kick,
  500 ms, the twin placed without lag) until the stream shows that car pushed (a round trip later).
- Found on the way, in that order:
  * a pass-through of the twin for 0.4 s after a hit let the striker, still driven, through the twin (cars inside
    each other: ending in a throw at 26 m/s); the twin coming back from its kick read as a push. No pass-through any
    more; no "cut" right after the own car struck.
  * **the car channel unknown after a player sync restart**: puppet() took it from the twin, but a twin set up by an
    earlier module load is world-dynamic already - bumpTick never ran its checks on that side (a session started
    again in a real game would have it). carChannelOf() takes it from the own car.
  * a guard: for 1 s after a hit (BI, or a cut push) the car hit moves away no faster than the shared speed +30 %.
  * the guest's car thrown at 33-58 m/s in collide-test was one frame's speed right after the physics pushed it out
    of the twin (prediction ahead), overwritten in that frame (BI / the guard): it moved ~10 m. The test now takes the
    top speed held over 2 samples (30 ms) and checks that the cars never went through each other (closest centres
    on both sides, every 30 ms) - the old "behind the twin along its axis" failed when the hit turned the car.
  collide-test: 9/9 in 4 of the last 6 runs before the held-speed change, the 2 others only the one-frame peak.
- Storages: each CX has a number; the owner's CS says per storage the last number done (key~n); an older CS is not
  filled in (5 s at most: an owner started again counts from 0) - the taken item came back / the put one vanished
  for a moment and the storage was refilled in the owner's old order. Changes are per item and per tile (X_Y_R): a
  put lands on the visitor's tile, a take comes from it, a move inside goes tile to tile (ItemTileLayout
  CanInsertItem / EmplaceSlot; anywhere else when the tile is taken). car-store-test 16/16 (new: a move and a put on
  a tile land on the same tile on the host; the guest takes while the host puts: the taken item never comes back,
  both trunks alike tile by tile).
- Then, still failing in the quick suite (collide 7/9): the guest's car rolling down the slope toward the host's twin
  took itself for the striker - "striker sends / car hit takes" breaks when both move. Rebuilt symmetric: either side
  (or both) that sees the hit frame computes the shared speed from both velocities (the other car's from the STREAM:
  the twin's own steps are smoothed - a 14 m/s hit read as 1 m/s), sets it on its own car, sends BI and kicks its
  twin of the other car; the side getting BI does the same (setting a speed twice is harmless). For 1 s no new hit
  is read and the own car is held to the shared speed: no faster (+30 %), and not thrown back by a jump >= 3 m/s
  against it (a striker still driven bounced off the kicked twin and stopped). The kick now puts the twin exactly on
  the shared-speed line both ways (the striker's twin, ahead by its prediction, had driven into the car hit again:
  28 m/s). ghostInfo strike_max = the hardest closing speed seen. collide-test 4/4 runs 9/9: striker 12.3-15 m/s
  keeps 6.8-7.8 m/s 0.25 s on, the car hit tops at 6.7-7.7 m/s.
- Quick suite after the symmetric hit (2026-10-28): all 23 PASS at once (collide 9/9, car-store 16/16).

## Tests closer to a real game: the long bot session, the state comparison, a lossy link (2026-10-28)
Owner (2026-10-28): work on the tests, make ones closer to reality, find and fix what they show.
- **soak-test.ps1** (full suite: 20 min; alone: -Minutes 40 -Seed n): two instances over the test relays, both in
  own-car mode, a bot per side picking at random (seeded) what a player does by where it is - in its own car: drive,
  ram the other's car, horn, lights, radio, get out; on foot: walk, get in, get into the other's car (look at a door,
  E), loot (bot-actions), take / put / move in the other's trunk, repair / fill a part of the other's car; in the
  other's car: get out; anywhere: its own trunk and parts change (the owner's own play). Cars more than 60 m apart:
  the guest's put beside the host's. Every -CheckEvery rounds both stop and the comparison runs until both sides
  agree or -SettleSec; the loot every other check (loot-score). Health per check: errors, FPS, the mod's ms per
  frame, frame gaps (hitch log started by the test), the Lua heap, the processes' memory. Log and the digests of
  failed checks: local\instances\soak\<time>\. The setup frees seat 3 of both cars (the test save has a device on
  every passenger seat: the driver's door and the device seats only open the door, by design).
- **cmds/digest.lua + compare-state.ps1**: each side writes its own car and its twin of the other's in one form
  (twincar equipLine / stateLine / lightLine take another container now; carstore twinLine), the characters and the
  puppets; compared: equipment, parts (within 1), lights (5 %), storages (tiles sorted), positions (still cars within
  1 m, characters within 1.5 m on foot). Usable by any test (dot-source compare-state.ps1).
- **Lossy link**: relay.ps1 -LossPct (and -ResendMs): Steam's messages are reliable, so a lost line is a stall of
  ResendMs..2x with every later line waiting behind it, then a burst - what the game sees. COOPTEST_NET="d,j,l" puts
  every relay of every test on such a link: run-all-tests.ps1 -Lag 60,40,1; the soak uses 60,40,1 by default.
- Harness notes: `R` is PowerShell's alias of Invoke-History (the first trial's random helpers silently did nothing:
  Rnd / Fmt now); a `tail -F` of the log locked it for Add-Content (the log is written with a shared handle now).
- **Found and fixed**:
  * the charge port's "battery" (BP_BatteryComponent_ChargePort_C overrides GetBatteryStatus / ModifyBattery) is the
    local car's batteries added up: on the twin it showed the OWN car's charge, and the owner's value set there did
    nothing (the comparison: 35 against a falling 32.8 .. 23.4 with the guest's headlights on). It is left out of the
    part state now; the batteries themselves are synced. Not fixed: charging through the twin's port (a cable at a
    zone's power source) would charge the local player's own car.
  * a part knocked off the guest's car by a crash (a door) lay on the guest's side only: the host never got it
    (loot check: one client-only world item). The drop detection counts the car's equipment too and looks near the
    cars as well as the player: such a part goes to the host as a DROP and comes back as the shared world item.
  * the mod's own cost: the hitch log showed 15-17 ms a frame (FPS 19-25 in the session, falling over 40 min);
    M.profile per part (car_*, eq_*, st_*, s_*; M.profileReset): the twin's pose was applied 30 times a second also
    when unchanged (4 ms each), the twin's part state checked 4 times a second (6 ms), the storages' changes looked
    for twice a second anywhere (9 ms), FindFirstOf (0.3 ms each) for the managers many times a frame. Now: the same
    pose once a second, part state every 1 s, equipment every 0.5 s, the storages only near / in the twin and every
    1 s, the managers / controller kept by weak handles (CoopSyncFirst), the parts' components cached 5 s. Per call:
    apply 12 -> 4.3 ms (2.2 of it the test relays' file reads; the game's link reads cheaper), send 9 -> 4.4 ms; the
    idle stand 30 -> 40-42 FPS, the mod 8-10 -> 4 ms a frame.
  * the storage digest listed the same tiles in another order on the twin (slots made in the fill's order): a false
    difference, the comparison sorts the tiles.
- The 40-minute run (seed 3, 60/40/1): 156 rounds, 53 checks, 47 alike at once (settled in 1-4 s), the rest the
  storage-order false difference; 21 rides in the other's car; no errors; then the host travelled home at 41 min
  (a save, then RB_Garage; the cause not found - the game log was overwritten by the next runs; the soak now logs
  the world every round and stops on a travel, and keeps both games' logs) - the copies went with it, as they should.
- **Second round of fixes (runs seed 4, 5):**
  * the parts' component cache held Lua objects across a travel: freed memory, IsValid passed, a property read
    crashed the host (revisit test: EXCEPTION_ACCESS_VIOLATION in auto_construct_object). The cache keeps native
    weak handles now (CoopNative_RefPath / Get) plus the manifestation's address (a new item at an old address).
    Rule: never keep a UE4SS Lua object across frames where a travel can happen - a weak handle or a path.
  * the storage changes only near the twin (the perf fix) let a change made from farther wait for the next approach:
    5 min out of step in the run (a bot reaching the trunk from 50 m; an inventory screen kept open would do the
    same). Farther the check runs every 5 s now.
  * an item taken out of the own trunk with a full backpack (or dropped from the trunk screen) lay on the guest's
    side only (two scrap steel, loot check): the drop detection counts the car's storages too (carstore ownLine).
  * both "travels home" (seed 3 host at 41 min, seed 4 guest at 11 min, seed 5 host at 29 min) were the bot's own
    doing: twin-parts-look put the character beside the door in the car's full transform - a car on its side or
    roof after a ram put it under the ground, it fell, died (the garage's save then holds an
    IA_Storage_Trunk_Tombstone) and the game took it home. The look stands by the car's yaw only now and does not
    go to a tilted car (up.Z < 0.7). Seen in the soak log as a visit with "highlighted nil" right before.
    The character's health: no component with Health in its class name on the pawn (hp stays "-").
  * esc / f7 failed once in a quick suite and passed alone (window focus during the run): flaky, not the mod.
- **Owner's graphics look (2026-10-28):**
  * getting into the other's car showed its door opening (the game's StartEntry here, DR open to the owner), getting
    out did not: ghostLeave is "Exit Car"(DipToBlack=false, Teleport=true), a teleport outside, no door. Now the
    way out sends DR open and DR shut after TD.EXIT_SHUT_MS (1.2 s; not when the car / its owner went). The owner's
    real door moves, the twin follows it by the pose: both sides see it. The character itself still appears outside
    at once (the game's animated exit, "Exit Car"(false, false), not tried on a twin). contact-test checks door 3:
    shut before, open 0.7 s after E, shut 3.7 s after.
  * after a kick the kicked player's puppet kept its walk clip ~0.8 s standing still (an average of the instantaneous
    sample speed + a 400 ms idle hold). Now the speed is the way the samples went over the last 300 ms (TD.histSpeed,
    0 when no sample for 0.5 s), idle hold 150 ms: idle 0.2 s after the player stands. contact-test samples both
    sides every 100 ms through the kick (the host's speed, the guest's puppet clip): idle within 0.6 s.
    (During the knock-back flight the puppet runs: no falling clip.)
- **Seed 6 run (35 min) found:**
  * the twin moved as a kinematic body (no teleport) on any step under SNAP_DIST (500) - a jump (the bot's regroup
    putting its car elsewhere; on a real link a stall's catch-up) was a step of hundreds of units in a frame: physics
    took it for ~10000 u/s and threw what it touched (world items out of PlayBounds at Z 30000 a second after the
    regroup; the host died 1.5 min later, cause not proven). A step faster than TD.KIN_MAX_SPEED (4000 u/s by the
    frame's time, ~145 km/h) is a teleport now (kin_jumps in the C line info).
  * the twin's computer danger light shows the LOCAL car's state (the computer part sets it every frame, like its
    screens - accepted for the gauges): left out of the comparison, a known limit.
  * items dropped from a driving car (taken out of the trunk with a full backpack) lay behind the car by the time
    the drop detection looked, or came a pass later: the lost kinds and the places of the player / cars are kept
    10 s now (a trail per 200 units), so such items still go to the host.
- Seed 5 (29 min until the bot's fall): 44 checks, all 44 alike (avg 1.8 s, max 14 s), no errors, FPS avg 34 / 37
  (min 27), the mod 5-6 ms a frame, memory +60 MB over the run.
- Once a minute both games logged ~60 frames of "FlushAsyncLoading: 1 QueuedPackages" (a synchronous load) over ~5 s;
  not tied to the mod's ops in the hitch log - to look at.
- **Seed 7 run (40 min, the whole run, no travel / death)**: 178 rounds, 60 checks, all 60 alike (avg 1.2 s, max
  7 s), no errors, FPS avg 35 / 34 (min 23), kin_jumps not seen. One loot fail from check 8 to the end: one
  client-only `BP_WorldItem_Health_C` steel door. The guest's car had lost three doors (FL, FR, RR) by the end, only
  one lay on its side alone - the others went to the host as drops. A damaged door hangs on the car before it falls:
  the slot is empty while the item reaches the world later than the 10 s memory. Car-equipment kinds are kept
  CAR_KEEP_S (30 s) now (only those: a resource the game spawns near the player would pass as an old drop), and a
  lost kind that expired unmatched counts `drop_unmatched`.
- Quick suite on the same build (it holds most tests now, ~2.5 h): all PASS except drive (speed / copy error, known
  flaky), interact (a wheel item client-only after the bot's DETACH, the known flake), contact 5/10 (the guest did
  not board the host's car; the later steps followed from it). Rerun: interact LOOT PASS, contact 9/10 - the exit
  door check read the door at fixed times (0.7 s, 3.7 s) and missed it: the door opens ~1.2 s after E (the exit
  itself) and stays ~1.3 s. The check samples the host's door every 100 ms for 4 s now: contact 10/10.
- **Alpha 16 built** (2026-10-28) with all of this stage.

## Anomaly sync: the nearer player's side runs a moving hazard (2026-10-28, after alpha 16)
Owner (2026-10-28): how do anomalies behave with two players, whom do they target? Before: positions host -> guest
(M lines, ~1 Hz pass), mines go off through the host (X / BOOM); no targeting at all.
- Census (cmds/hazard-census.lua, the owner's save zone Rural_Forest_Farm_Rooster_11): landmines (electric) x100,
  gopher mines, supercharger malfunction mines x19, electric clouds, conductive links, movement hazards (prongs),
  radiation zones (~110). The game's hazards know ONE player: BP_Base_Hazard GetDistanceToPlayer /
  IsPlayerOrCarInRange / IsPlayerLookingAtAnomaly / IsCarInLineOfSight, BP_HazardProperty_PlayerRange (one
  PlayerInRange), the malfunction mine's MoveToCar / CreepTowardCar / LeapTowardCar / IsCurrentTargetCar, the cloud's
  OverlapCarOrPawn, the conductive link's HookedToCar. Each game's copy acts on its own local player only.
- Probe (the guest's car by a supercharger far from the host): the guest's copy woke (PlayerInRange, MovingTowardCar)
  but the guest's statesync pulled it back to the host's spot every pass (snap_back) - a hazard could never reach the
  guest; the host's copy never woke (its player 60 km away). Hazards near the guest were harmless, by accident.
- Now (statesync "Moving hazards", HZ): the side whose player is nearer runs a hazard - the game's own AI picks its
  target among its own player, which is the nearer one; the other side's copy is a puppet eased (0.1 s) onto the
  owner's pose.
  * guest: a mapped BP_Hazard_ copy left the host's spot (the snap-back check) and the guest is nearer (own pawn / car
    vs CoopSyncOtherPoints) -> HCLAIM, the copy keeps running meanwhile (3 s at most); HDENY: snapped back, no new
    claim for 2 s
  * host: HCLAIM granted when the guest is nearer by its view too (HGRANT): the host's copy puppeted (physics off), no
    M for it; HM from the guest (its pose 10 times a second while it moves > 3 units) eases it
  * host, every 1 s: once its player is nearer by HZ.MARGIN (500) -> HREVOKE, its copy gets its physics back and
    streams (hot)
  * host hazards that moved in a pass stream HM 10 times a second for HZ.HOT_S (3 s) after (the pass's M is 1 Hz)
  * one the guest ran gone there (went off, ...) -> HDEAD: the host's copy is parked in its pool (K2_DestroyActor on a
    pooled actor), no respawn on the guest
  * physics turned off by the puppeting is given back to the side that runs it (HZ.physOff by address)
- Found on the way: the guest's D for a non-item actor called Sync.destroyTrees with a map (a job over a list): it
  raised, the D was never applied (a hazard the host lost stayed on the guest). K2_DestroyActor now.
- Native crash on the guest right after the player sync's start (CoopNative_Under -> parent_actor -> IsA read
  0xffffffffffffffff): a live object with a dead class pointer. usable_actor checks the class is live first.
- The supercharger mines of that save stand locked (bLockMovement true, MovingTowardCar true, in range) even in a
  single game with the car 400 units away (cmds/mine-chase.lua): their real chase was not seen. The test scripts the
  chase (moves the hazard toward a car, as its AI would). One mine reaching the guest's car went off for real during
  a run: HDEAD -> gone on both.
- anomaly-test.ps1 (quick suite): 1. guest's car by a hazard far from the host, scripted chase -> granted, the host's
  copy moved 1513, gap 0 after (~150 units behind while moving: send 0.1 s + link + ease); 2. the host's car nearer
  -> revoked, the host moves it, the guest's copy follows (1200, gap 0); 3. guest runs it, it dies there -> gone on
  both. 9/9.
- Not done / limits: damage stays the owner game's own (a hazard running on the guest hurts only the guest - as it
  only goes after the guest); the other player standing next to a puppet copy is not hit by it (a hazard between two
  players goes for the nearer one only); static hazards (clouds, radiation, mines) act on each side's own player as
  before; hazards with a real chase still to be watched in a zone where they move (leeches, grabbers, abductors).
- **Real chasers (2026-10-28 night).** Zones visited from the garage (zone-census.ps1: TravelToGarage, route-override
  to a MapLocation, TravelToNextLeg; LevelTravel from a zone fails - no BP_LevelManager_C there; the list from
  cmds/maplocs-all.lua, 161 locations): Wilderness_Swamp_10 (13 superchargers, 4 grabbers, saw blades, Teslas,
  bollards), Rural_Swamp_Town_Kraken_02 (8 grabbers, 109 landmines, malfunction volumes, clouds), Wilderness_Rocky_10
  (grabbers, bollards, a BombRock mimic), Rural_Rocky_GhostTown_Leviathan_15, Highway_Swamp_02, Wilderness_Forest_15
  (4 grabbers, 12 clouds, 20 malfunction volumes). Physics grabbers in every one; no leeches in these six.
  A grabber by a parked car (single game, cmds/mine-chase.lua MINE_CLASS) flies to and past it, ~550 u/s, back again.
- Save in Wilderness_Forest_15 kept as local\advsave\forest15.sav; `anomaly-test.ps1 -Real` (full suite:
  anomaly-real): the guest's car by a grabber far from the host, its own AI: granted at once, the host's copy flew the
  same ~11-13 km path in 12 s. Gap 210 median at first (0.1 s sends + link + 0.1 s ease); the puppet now leads along
  the last two poses' velocity by the pose's age + HZ.LEAD_S (0.15 s, at most 0.4 s), no lead once no pose came for
  2.5 sends (stopped: the owner sends only moves). Runs: median 117 / max 358, 192 / 265 (the two sides are read one
  after the other: part of it is the probe). The scripted anomaly-test still 9/9.

## The owner's alpha 16 test with the friend (2026-10-29): findings, fixes, why the tests missed them

Reports: `CoopSync-report-2026-10-28_23-07-45.zip` (host), `..._23-06-45.zip` (guest; crash 23:05 in Wilderness_Forest_09).
The friend's PC ran the zone at ~12 fps (hitches.log F lines: 80 ms frames).

Fixed (code / probe):
- **Lua heap crash (the guest's)**: stack `luaH_getshortstr <- add_pair <- push_enumproperty` in a delayed action =
  a fresh Lua table broken = heap corrupted earlier. UE4SS source: `process_delayed_actions` and the hook callbacks
  call Lua WITHOUT `m_thread_actions_mutex`; `RegisterKeyBind` callbacks run on UE4SS's event-loop thread. Our F7
  (panel) and Esc (menu) keybinds ran Lua concurrently with our loops. Now `CoopSyncOnKey` (hooks.lua) polls
  `CoopNative_KeyDown` (GetAsyncKeyState + own window in front) on the game thread; no RegisterKeyBind left.
  Note: every UE4SS enum property read builds a Lua table of all enum names plus a global.
- **Zone start waits**: the host exported 25-38 s after arrival (MIN_ZONE_S 25 + zoneReady), the guest travelled only
  after that, then waited its own 25 s. The host now publishes host-run / gates / `host-session` with `list=-` on
  arrival (seq reserved, reused by the export); startflow-test checks the guest is in the zone before the host's list.
- **Exit from the own car with a twin around**: the car's ExitDoor handler calls AttemptOpen / AttemptDoorExit on the
  TWIN's door (traced; the game's own door lookup, like GetGearboxActor). Hooks on BP_CarPart_Door_Base_C
  AttemptDoorExit / AttemptShut (after body) redo it on the own door; the following shut redirected only >= 0.8 s after.
- **The car manager's OnDoorChanged** had the twin's car, doors, panels and slot spots bound: the player's own door
  opened the twin's. Twin.muteDoors removes those bindings (actors / components only).
- **Twin slot spots (BP_CarPart_Interactive_C)** of doors / trunk / hood ran OnInteractStart/End on the manager =
  the LOCAL car (the guest's taps at the host's car opened its own doors and trunk far away). Muted on the twin; their
  K2_ShouldHighlight hooked (shown while the owner's door is shut by the pose). An open twin door / lid is not hit by
  the highlight trace (kinematic): `TD.lookedAtOpenDoor`. Door actors have no GetSlotComponent (the old call raised).
- **Trunk lid tap** tried to seat the player at "seat 5": trunk = door only.
- **Driver seat in the other's car** allowed while its owner is not at the wheel (target design). With the owner out
  of its car the remote input reached nothing (User*Input reaches the vehicle controller only with the game's driver
  inside; parking brake set at the owner's exit): `TD.releaseBrake` writes the vehicle controller's inputs and
  releases the parking brake. Gear 1 = drive, 0 = park.
- **The host entering its own car** took the seat by the door it came in (guest-mode rule): own-car mode -> driver.
- **Animated exit from a twin**: "Exit Car"(false, false) works on a twin; the manager stays on the twin until the
  character lets go (+0.4 s) - switched at once, the game ended the exit at the OWN car (7 m away).
- **Own car's lights while in a twin**: held (`Twin.holdOwnLights`; LI sends the held line).
- **Twin motion for a passenger**: was moved at 30 Hz toward an extrapolation; now per frame, inside (not driving) a
  Hermite interpolation 160 ms back (cars-test jerk 0.06 vs the real car's 0.3).
- **Paint**: BP_TintableComponent per part (GetTintableProperties / SetPaint / SetDecal); EP lines.
- **Wreck trunks**: the trunk's container belongs to the trunk part's item; detection compared part counts only.
  Live marks of a part's item -> the wreck's key (subOwner); TAKE/PUT "<socket>#<n>". Open / pried trunks:
  `#S<socket>=<0 locked|1 shut|2 open>` on the T loot (AnimStateOpened + the lock's IsLocked; TrunkState is the zone's
  roll), opened the game's way (lock ModifyStrength(-100) + the trunk's BndEvt...OnLockOpened(nil)); TRUNK requests.
- **World doors** (BP_Door_Single_C, BP_Door_Sliding_Single_C; CurrentState 0 shut, 2 open, 3 locked; the zone
  opens some at random - 9 differed at a test start): DS / DSR by place, "Set Door from State".
- **Radio**: twincar is dofile'd per Players.start -> the track clock restarted at each sync start. Clock global, a
  0.1 s session poller from the game's start; 2.5 s into a new built-in track a self-seek to its clock (the channel
  change's static); RI "-" when the owner's DJ break ends. Unverified by ear.
- F7 not in the main menu. TcpLink lists the other local copy as a friend ("local-copy"); "Две копии игры.bat".

Open: the twin trunk storage showing the player's own trunk was not reproduced (repointed now the moment the player
looks at a twin storage); the manager's door flags of the guest's own car may stay wrong after riding in the host's
car (restored for 3 s after the exit, not proven); radio by ear.

### Why the tests missed them (and what changed)
1. **Bots bypassed the game's input paths** (exits by teleport, entries by CommandEnterCar, doors by mod functions).
   New cars-test (quick suite): every E through the highlight manager + Command Interact, both sides.
2. **Checks read the mod's own state, not what the player sees** (radio clocks, the owner's door only, never the own
   car's lights / door flags / the other car's paint). cars-test samples doors / positions on both sides.
3. **One direction, one scenario**: loot-live had lootables only; now wreck trunks, pried trunks, world doors, both ways.
4. **No timing or smoothness budgets**: startflow now checks the guest travels before the host's list; cars-test
   measures frame-to-frame jerk.
5. **Fast test PC, no key presses during the sync**: the keybind thread race needed real presses while loops run
   (esc-test's old 30-40 % crashes were probably this too).
6. **Clean starts only**: the radio bug needed a track playing before the sync started.
7. **The test scene**: the guest car placed 8 m aside hit an obstacle (its door opened 20 deg); now placed on the free
   side. Probes: cmds/car-e.lua, exit-trace.lua, openable-probe.lua.

### After alpha 17: the leftovers (2026-10-29)
- **The twin's trunk box showed the player's own trunk** (owner's item 14): found. BP_Storage_Trunk_Base_C's
  `RefreshTrunkInventory` (the game calls it on trunk changes) points the storage's container component at the
  inventory manager's Inventory_Trunk - the LOCAL player's own trunk - on the twin's storage too (cmds/store-point.lua:
  own_box before, own_trunk right after a call). The mod only pointed it back at its next check. Now a hook on it
  (playersync TD.trunkRefreshed, after the body) points a twin's storage back at once. car-store-test step 1b calls the
  game's refresh and reads the twin's box in the same call.
  Note: an E on a storage through SetHighlight + Command Interact opened no player menu in the test instances (the
  highlight manager's trace clears the highlight; the storage's handler called directly did not open it either) - the
  menu itself is not tested; cmds/menu-params-probe.lua hooks "Apply Menu Parameters" for a look on a real screen.
- **The own car's door flags after riding in the other's car** (cars-test: RL "open" for good): the snapshot was taken
  in the twin after the twin's door had opened and written its flag. Restored now from the own car's real doors (open =
  the door mesh simulates; the hood from the snapshot). cars-test step 6 checks them (was info).
- **The twin's door during the player's exit from its own car**: not a short twitch - the twin's door swings open to
  ~57 deg for ~1.2 s with the own door (both sides; the old cars-test samples showed it). exit-trace (EXIT_DOORS): the
  car's ExitDoor handler calls AttemptOpen on the twin's door first, the character's exit stays bound to that door
  (ExitValid on both, the twin's "Player Left Car" shuts it at the end). Shutting it, or switching its physics off,
  during the exit aborts the exit (the player stays in the car, the own door shuts too). The handler's door lookup is
  inside its graph: not the manager's DoorSlotMap (tag -> index), not the car's SLOT_*Door components (own), not the
  door highlight meshes (own), not the item manifestation. Left as is (visual only); next: a native hook on what the
  handler calls (GetAllActorsOfClass?) to find the lookup.
- Probes that crashed the game: walking ForEachFunction over several managers' class chains, and reading delegate
  bindings with an actor's function called on a widget object (cmds/mgr-bindings.lua does it the muteDoors way).

### Low fps and lag tests (2026-10-29)
- **Frame cap for tests**: `$env:COOPTEST_FPS` (run-all-tests `-Fps 15`); session.lua reads it and runs `t.MaxFPS` in
  every world (KismetSystemLibrary ExecuteConsoleCommand). `-ExecCmds="t.MaxFPS 15"` on the command line did not hold
  (headless ran at 37-40). Checked in hitches.log F lines: 15 fps.
- run-all-tests `-Lag 150,60,1` called from PowerShell arrives as "150 60 1" (an array to [string]): every relay broke,
  nothing synced. The suite now turns spaces into commas.
- **At 15 fps** (8 key tests): three real issues.
  - The host's pried wreck trunk did not show on the guest's side within 8 s: on the host only the state pass saw it,
    a far wreck in the full pass (every 10 s), and the pass is slower at 15 fps (3 ms budget a frame). Now hooks on
    BP_TemplatePart_Trunk_C UpdateTrunkState / SetHighlightOpened mark the wreck (LH.dirty: hostLive / the client's
    live detection): 357 ms at 15 fps.
  - A world item the guest picked up left the host's world after 4.4 s: the guest noticed it in its detection pass
    (~2.5 s at 15 fps). Now a change of the player's inventory (LH.inv) looks at the mapped world items at once (only
    whether the actor is gone: cheap) and sends PICK: 371 ms.
  - startflow's late join (guest home, back to the lobby, drives out): 2 of 3 runs at 15 fps stayed "joining" in the
    garage for 8 min after Run.join; those runs pointed 67 legs, the passing ones 1 (WorldState_M1=1). Likely the
    previous zone's route states still alive (GC) at low fps. Not understood; now the note shows legs per route, and a
    guest still in its garage 30 s after joining joins again (3 times at most). Passed at 15 fps since (1 leg).
- **At 150 ms delay, 60 ms jitter, 1 % loss** (transport median ~280 ms, p95 ~450): 8 key tests pass; interact once
  had a duplicate wheel: the host bot took a wreck's wheel, the guest's bot took the same one before the host's update
  came; the host counted DETACH_missing and the guest's dropped wheel stayed (client-only). Now the host answers
  NACK DETACH and the guest removes its copy (hands / inventory, else the unknown item of that kind near the wreck).
  The race did not come again in the rerun: the NACK path is untested.
- **Two copies on the owner's PC** (alpha 17): the game started straight from the Steam library restarted through
  Steam ("launch with custom parameters"), only one copy came up, though steam_appid.txt was there; here the test copy
  (outside any library) never did. two-games.ps1 now starts the copies through a junction (Documents\PacificDriveCoop\
  two-games\game -> the game folder) and sets SteamAppId / SteamGameId; the junction start checked here (the mod
  loaded), the Steam side only on the owner's PC. Deleting the junction in Explorer removes only the link.

### The owner's alpha 17 test (2026-10-30), verbatim summary
1. When the friend searches loot containers, the container UI opens on the owner's side too.
2. Building / abandoned house positions differed on the friend's side: their interiors stood outside, nearby.
3. Don't show the friend the junction map at departure: a loading screen "Ожидание хоста" instead.
4. The friend's zone load now starts at once with the host's, but in the zone the wait for the map sync / connection
   is still long: find where the time goes; hold the loading screen until the friend is connected.
5. On the zone load the friend got a second copy of their own car hanging in the air; once connected, three cars on
   the friend's side (the owner had two).
6. Entering the own car: no door-open animation (owner).
7. Driving the friend's car from its wheel: jerky, and the owner's own car drove along at the same time.
8. Many other car problems: controls broke, the wheel repeat stopped, the car drove as if braking.
9. The friend started the car with one press of the key, not a hold.
10. Exiting from the passenger seat of the friend's car: the door could not shut, its animation looped.
11. Once the friend left the owner's car from the passenger seat but the camera stayed in the car.
12. A passenger exit must need aiming at the door + E; now E anywhere works and the exit is a teleport.
Owner: cars rest on workarounds; rebuild them as natively as possible (the game's own interactions, the cars only
shared). Plan + order: HANDOFF "The owner's plan after the alpha 17 test".
13. (added) When the friend's camera stuck on the passenger seat, they still got out - and at once their health
    dropped and they died.
Reports: local/reports/alpha17/ (host 23-18-21: D:\SteamLibrary; guest 23-18-53: F:\SteamLibrary). Their crash
folders are old (2026-10-26/28, one from February); no crash during the alpha 17 session. dumps\crash_2026_10_29_22_12
(UE4SS) = the first two-copies try (the game quitting to restart through Steam).

### The game's own zone save vs our sync (2026-10-30)
Tools: `tools/save-dump.ps1` (SAVC chunks, LZ4, `-Tree` via `tools/SaveTree.cs`), `tools/save-diff.ps1` (two trees'
/Map: objects by class + place, property differences), `cmds/save-probe.lua` (hooks, info, `SaveGame(slot)` in a zone).
- **Format**: odsave<N>.sav = "SAVC" + chunk table (OPTS, META, GAME, CHKP; flags 6 = LZ4 block). GAME = u32 6, u32 3,
  then a typed tree: key = u32 len + chars; types 01 bool(4) 02 i32 03 f32 04/05/0e/11/19/1a strings 07 vec 08 rot
  0a transform(10 f) 0c color 0d guid 0f i64 10 struct 12 ref (kind 0/1 class+guid/2 class+name/3 class+path)
  13 array(elem type, n) 14 map(kt, vt, n, n, keys, values) 15/16 map(n, key+type+value). Root: current_master_seed,
  global_states, managers, hashes (class layouts), Garage, **Map** (the zone: _data = SaveGameScene with Level,
  player / car / camera transforms, clock, SubLevels = SaveGameLevelState with DestroyedIntrinsicActors; _objects =
  every actor: _class, _name, _outer (the level), _data: _intrinsic, _transform, _components, saved properties).
- **SaveGame(slot, "", MANUAL) works in a zone** (CanUserSaveGame is false there - the menu's rule only); 500 KB,
  ~2900 /Map objects (Scylla_02). UserLoadGame(slot, 1, 0) from the zone loads it back in ~13 s.
- **Load restores the zone from the save, not by generating it again**: load slot 5 -> save slot 6 on the same
  instance: same objects, same building frames and their deleted parts, posters, radiation sizes, bollards, paint;
  differing only: lamps' LocalSeed (rolled on every load: flicker), Tesla / grabber runtime state, door
  RandomizeOnBeginPlay flags, AttachedParts ref order, 3-5 bushes / trees.
- **Host vs guest with our sync** (cars-test -SetupOnly pair, both saved in the zone): 1875 objects matched by class +
  place, host only 79, guest only 55. What our sync misses:
  - **buildings (owner's alpha 17 item 2)**: at a trailer site the guest kept its own frame variant
    (BP_BuildingFrame_Open_Trailer_I1_03 at 80946,-19541) next to the host's Trailer_I1 - two buildings in one place,
    an interior outside; and each frame's ManageChildren.DeletedComponents (foundations, dirt piles it removed) is
    rolled per side (host: 010,07,DirtPile,DirtPile1 / guest: 08,010). The frames' content managers
    (ManageChildrenActor_Food_Med, _Electronics_Low, ...) then differ too (73 host only / 47 guest only).
  - per-actor rolls our sync never sends: posters' Selected Mesh, graffiti decals (RolledInvisible,
    ChosenDecalMatParent), bollards' Scale / sizeSwitch, landmines' relative rotation / scale, radiation zones'
    Radius / BoxShapeSize (gameplay), physics grabbers' patrol points (gameplay), stripped cars'
    SelectedPaintPalette, T-pole meshes, a converter's SelectedConversionName, chemical cabinets' grabbable highlights,
    lamps' power state.
  - a few spawner products: one civ car spawner / street light / bushes on one side only.
- **Idea (owner: "make the zone reproducible the right way")**: send the host's /Map (its zone save) and let the
  guest's game load it - splice the host's Map subtree into the guest's own save (its profile, garage, inventory
  kept), write it as a slot, UserLoadGame. The game then restores the host's exact zone natively (buildings, rolls,
  loot, destroyed actors), and the scene's car / player transforms place the guest. Needs: a tree writer or a
  byte-range splice of the Map value, LZ4 or stored chunks, the run / leg state on the guest's side, and the sync's
  keys (the saved _name may come back as the actor names: then host and guest paths match).

### Prototype: the host's zone through the game's save (2026-10-30) - works
Tool `tools/save-splice.ps1 -Guest <guest save> -HostSave <host zone save> -Out <file> [-Keys Map]`: the guest's own
save with the host's root "Map" value (byte ranges from `SaveTree.RootRanges`, nothing re-encoded; a key the guest
lacks is appended and the root count raised); GAME written as an LZ4 block of literals only; chunk slots rebuilt.
- Guest's zone save + host's Map -> UserLoadGame from the main menu: in the zone in 11 s; its zone vs the host's (both
  saved again): as close as the host to itself after a reload.
- **Guest's departure save + host's Map** (the save the game writes when the guest leaves its garage: no Map key at
  all, the zone's level only in META; loading it normally generates the zone): UserLoadGame -> in the zone in 11 s,
  the game set OutOnRun = On itself; vs the host: **1945 of 1954 objects matched, host only 9, guest only 6** (bushes,
  grabbers, 2 decals) - with today's sync the same pair had 79 / 55 and two buildings on one site.
- Going home after it: Run.goHome(false, 0) -> own garage, own seed (777) in 10 s. The rinse writes into the slot
  loaded last (SaveGame / UserLoadGame make it current): the spliced save must go into the guest's own slot.
- Actor names do not come back (spawned actors get new names; no runtime GUID - ISaveGameInterface has only
  K2_PostLoaded): the sync keeps matching by class + place, which then finds every actor in place.
- Seen on the way: when the host reloaded its zone (it re-published), the guest's re-import ran FlushAsyncLoading
  every frame for 12 min and the process vanished (no crash report). Re-publish while a guest is in: to look at.

Integration plan (the owner's step 2, zone / start):
1. Host, its zone ready: SaveGame into a scratch slot, read its Map (C++: CoopNative unpacks / extracts; Lua strings of
   4 MB are slow), DeleteGame the scratch slot, SetCurrentSlot back (SaveGame makes its slot current); send the Map
   (~2.6 MB raw, ~0.5 MB LZ4) over the link. Measure the save's hitch on the host.
2. Guest: leaving its garage (the departure save in its own slot) - no TravelToNextLeg of our own: a loading screen
   "Ожидание хоста" until the host's Map is in, then splice it into the departure save in its own slot (backup kept),
   patch the scene's PlayerTransform / CarTransform (fixed 40-byte transforms: in place) to a spot beside the host's
   car, UserLoadGame. Then the usual sync (its import maps everything by place; expect ~0 spawned / removed).
3. Late join / next leg: the same with the host's current save (it carries the current loot state too).
4. Watch: the host's narrative actors in Map (BP_QuestDirector, Fig NUX director) on the guest's side; the guest's
   own car (managers) vs the scene's CarTransform; the twin cars; DLC; saves left behind (backup files).

### Native cars: probes (2026-10-30) - the owner's step 3 ("cars rebuilt natively")
Setup: `cars-test.ps1 -SetupOnly -NoMute` (new: `CoopSyncNoMute` keeps the twins' own handlers: twincar muteDoors /
muteBody return at once), the guest's player sync frozen (`cmds/native-car.lua` NC_OP=freeze; also state / mgr / phys
/ drive). New native tool: `CoopNative_TraceStart(callee substr[, caller substr])` / `TraceGet` / `TraceStop`
(trace.cpp: ProcessLocalScriptFunction + ProcessInternal pre-callbacks, caller chain 3 deep, game thread only - an
unfiltered trace stalled / crashed the game: anim blueprints run on worker threads).
Findings:
- **The game's own entry works on the other's car** once the car manager points at it BEFORE the E: guest on foot,
  aimed at the host car twin's driver door (its slot spot highlighted), `NewCarActor = twin`, E -> the twin's door
  opened, the character walked in, the door shut, PlayerCarState 2 -> 1, the character attached to the twin. The game's
  own exit (Highlight_ExitDoor of the twin) got it out again. No mod entry / exit code needed.
- **The twin drives on local physics**: physics on + its vehicle controller ticking + the manager on it: User*Input
  -> its vehicle controller -> 0 to 500 in 2.5 s, like the own car (gear: 0 = drive, 1 = park; ToggleGearBoxState(s)
  flips only from s).
- **Why "the own car drove along" (owner's alpha 17 item 7)**: the player's in-car input does not come from the
  character or the manager: `BP_Controller_PlayerCar_C` (one actor; InpAxisEvt / InpActEvt for throttle, steer,
  look, interact, horn, wipers, lights, radio, abilities) calls them on its `PlayerCarReference` - set once, the own
  car. Traced: "Input Car Throttle Brake -> BP_PlayerCarNew_C:AccelerateBrake" on the own car while the guest sat in
  the twin with the manager on it (280 calls / 1.5 s). `PlayerCarReference = twin` -> traced on the twin.
- The cars have no InputComponent of their own (AutoReceiveInput 0); AccelerateBrake writes RawThrottle, the car's
  pipelines turn it into User*Input.
- The own car's exit: the character's "Exit Car" calls AttemptDoorExit on the TWIN's driver door (traced once after
  an entry through the door; after a CommandEnterCar teleport entry no door call at all) - the lookup not found yet.
Design (to build):
1. **Car context = the car the local player is in or works on**: manager.NewCarActor + the car controller's
   PlayerCarReference + the manager's state (ignition, gear, lights / top / wipers / radio, door flags) swapped per
   car; the manager's delegates bound to the context car only (the cars bind themselves at BeginPlay: today both are
   bound and the mod removes some of the twin's). On foot the context follows what the player aims at (a highlight
   on the other's car switches it before the E), else the own car.
2. **The driver's side simulates the car** (authority): the car the local player drives simulates here with the
   game's own input; the other side's copy of it (even the owner's real car) is kinematic and follows the pose stream.
   Nobody at the wheel: its owner. Handoff with the last velocity.
3. Seats: the game's one seat socket moved per seat (as now); a passenger's exit through the game's ExitDoor moved to
   the passenger's door (aim at that door + E).
4. Then the old paths go: remote pedals (TD.releaseBrake, ghost axes), the key / lever / horn relays inside the
   other's car, the door taps (TD.doorPress), twinExit / twinEnter.
- **The context switch works** (`mod/CoopSync/Scripts/nativecar.lua`, probed on the frozen guest): `use(car)` = manager
  NewCarActor + the input controller's PlayerCarReference + the manager's 48 delegates: every binding of the other car
  removed and kept by path ("parked": 229 for the twin, 22 ms the first time, 12 ms a switch after), the context
  car's put back (229/229, none lost), the manager's door flags kept per car. Aim at the host car's door -> use(twin)
  -> E: in with only the twin's door animating (OnDoorChanged: own 0 / twin 61 bound), the game's exit from the twin:
  the twin's door opens / shuts (traced AttemptDoorExit / AttemptOpen / AttemptShut on the twin's door 1 only).
- **Which door "Exit Car" uses**: the character's `CarEntryTransitionPoint` = the EntranceLogicPoint component of the
  door it last got in by (CommandEnterCar's OptionalTriggeringDoorRef). After a teleport entry it stays the old one:
  that is the alpha 16/17 "own exit opens the twin's door" (the last door was the twin's). The native fix: point it at
  the door of the seat the player sits on, in the car it sits in - for a passenger that door's exit is the game's own.
- **Built (2026-10-30, behind `CoopSyncNative = true`; cars-test sets it, every other test runs the old mode)**:
  - nativecar.lua: use / park / unpark / sweep (every 10 s and 1 s after an EQ line: parts spawned again bind
    themselves; ~9 ms), per-car door flags + `realDoors` (the own car: its doors simulate; the twin: its posed angle),
    `stayParked` (the twin's door actors stay off OnDoorChanged: the owner's pose moves them).
  - playersync TD.nativeTick (apply loop): the context = the car the player sits in, on foot the car it aims at (the
    highlight's owner), the own car again when it aims at it or is 15 m from the other's; TD.aimNative (door n from the
    highlight -> the twin's seat socket moved to seat n before the E); entry detected in sendTick (attached to the twin
    -> inGhost native, the seat asked for as before), exit = detached once it was in (TD.nativeLeft); a back door of the
    twin: the game only opens it, so a tap there starts the game's entry by that door (TD.twinEnter, as before); the
    E / key / levers / horn otherwise the game's own (onPawnInput and onHighlightPress return); the twin's door flags
    follow its pose, a flag the game changed here goes to the owner as DR (held 1.5 s).
  - TD.placeExit: the ExitDoor collisions / ExitPoint / ExitCheckPoints moved to the seat's door (mirrored for the
    right side) - a passenger looks at its door + E, the game's exit through it (cars-test: walked out, ends at the
    back-left door, -172,-168).
  - Driving: DV / VD lines - the side at the wheel of the other's car simulates it (Twin.setDriven), the owner's real
    car kinematic meanwhile, following VD with the passenger interpolation (TD.carInterp "drv"); given back with its
    velocity. Remote pedals (I / IG lines, TD.releaseBrake) off in native mode. Not proven yet (see below).
  - "V" is the pose line: the drive pose is "VD" (a first "V" broke every twin pose: poses=0).
- cars-test (native) 12/17: PASS exits both sides, back-seat entry by the game's entry, smooth ride (jerk 0.08 vs the
  real car's 0.4), the passenger's exit with the game's animation at its own door, trunk open, paint, own car drives.
  FAIL / open:
  1. the host's door 3 does not open for the guest's exit: the guest's twin door opens by its own physics (the game's
     exit), but the DR is not seen at the host (to check: the flag change while the player leaves);
  2. the twin's doors opened by the game here keep simulating (door 3 after the exit, the trunk after the tap): the
     pose cannot move them back; plan: while a twin door simulates here, applyPose leaves it; when the owner's pose
     says shut for > 2.5 s, the game's own AttemptShut here;
  3. the E at the open lid does not shut it (follows from 2);
  4. the driver's seat of the other's car: nothing highlighted at its driver door (no CAT spot, no EnterDoor) after the
     earlier steps - not found yet (not the parts-disabled queue; refreshing the spot's OnDoorStateChanged did not
     help; the guest's aim / position to check again);
  5. so driving the other's car (DV / VD) is untested.
- Later the same day: TD.twinDoorReconcile (a twin door the game opened here simulates: the pose leaves it via
  Twin.doorLocal; the owner's door shut for 2.5 s -> the game's AttemptShut, which does NOT close a door on the
  kinematic twin (128 tries) -> then the door mesh stops simulating and the pose has it again). Doors no longer stay
  open. TD.NATIVE_NEAR: with nothing highlighted the nearer car within 5 m is the context. lua-lint caught `parse`
  used before its local declaration in TD.onDrive (fixed: inline). Old-mode tests after all this: ghostseat 23/23,
  twin-equip 10/10, twin-ctl 26/26, car-store 17/17, contact 10/10.
  cars-test (native) now 12-13/17, the door checks timing-dependent between runs. Still open:
  1. the guest's exit does not open the host's door 3: the exit opens the twin's door 3 here without a flag change
     (the flag stays "open" from the back-door entry, whose door the game never shuts here); sending DR on a door that
     starts / stops simulating here was tried and dropped (it broke the lid's shut - the shut came as "open");
  2. the guest's own door flags show the twin's tapped doors (2 = RL, 5 = trunk) after riding: likely the twin's spot
     handlers acting while the context was the own car (a switch race) - check with the switch logged per press;
  3. the twin's driver door: nothing highlighted even with the twin as the context and its FL slot spot active, at the
     same place as the own car's spot (which highlights). A probe with KismetSystemLibrary LineTraceSingle on channels
     0-8 crashed the guest - find what blocks the UI trace there another way (the twin chassis' object type is
     WorldDynamic since puppet(); the own car's is the car channel);
  4. driving the other's car (DV / VD) untested until 3 is fixed.
- **Found the game's part lookup (2026-10-30 evening)**: "Exit Car" takes the door to open through
  BP_CarManager_C:GetItemManifestationEquippedInSlot -> GetItemSlotFromSlotTag, which answers the slot of the car
  spawned LAST (the other's twin) - not CarEntryTransitionPoint, not GameplayStatics lookups (hooked: none during the
  exit), not GetCarActor (answers the own car). With the twin's door handlers live (native) the host's exit opened the
  guest twin's driver door, the manager's flag reached the own door and it broke off (EmptyDoor). Fix: a hook after
  GetItemSlotFromSlotTag answers the context car's slot of that tag (TD.hookSlotLookup, like GetGearboxActor). The game
  asks it constantly (13-21 thousand answers corrected in two minutes: dash / UI read the twin's parts all along) -
  its cost to measure / cache.
- Also: the sweep at a twin's spawn parked the OWN car's bindings (the spawn points the manager at the new car for a
  moment; 8 never came back) - the sweep keeps the context, else the own car. The guest's DR for doors it never touched
  (flags following the pose woke the car's door logic): sent only within 2.5 s of the player's E. The twin's doors
  stopped and put back: the mesh re-attached to its door (it hung in the air). The twin's vehicle controller class is
  /Script/IWCarPhysics.VehicleControllerComponent (twincar VCC was nil: setDriven / the puppet fell back to FindAllOf).
  cars-test step 8 walks the guest up to the driver's door; a new check: the host's car keeps all its doors.
- **cars-test (native) 15/18**: the guest gets in at the host car's wheel the game's way and DRIVES it (its side
  simulates, the host's car follows). Open: the host's door 3 on the guest's exit, the lid's shut (flaky), the own
  car's door flags 5,4 after riding.
- **Passengers (2026-10-30, owner: "the back-seat passenger reached the lever and the front door; the controls are
  the driver's, the passenger has its own door")**: a hook after BP_HighlightManager_C "Should Allow Highlight" says no,
  for a player on a seat other than the driver's, to anything of the car it sits in but Highlight_ExitDoor (moved to
  its door) and its own door (TD.passengerMayReach). Denied in a probe: the shifter, Highlight_Key, the dash's car
  friend. cars-test step 3b checks the lever and the key from the back seat.
- The passenger's exit: the game's exit animation only works by the driver's door (by a back door it is a jump, one
  33 ms sample) - so the exit keeps the driver's door here, its points stand at the passenger's door (TD.placeExit),
  and the DR to the owner carries the passenger's door (open, then a sure shut 1.2 s later: TD.exitShut).
- The own car's door flags follow its doors too (TD.ownDoorFlags, not within 2.5 s of an E). cars-test reads the own
  car's flags through CoopPlayers.ownDoorFlags() after 3 s.
- **cars-test (native) 19/19 PASS.** Old-mode car tests after the day's changes: ghostseat 23, twin-equip 10,
  twin-ctl 26, car-store 17, contact 10 - all PASS.
  Open: the host's trunk lid stood open after the guest had driven its car (no DR for it: likely the handback -
  kinematic to physics with the velocity - popped it); the cost of the slot / reach hooks (not in the F lines);
  the native mode is still behind CoopSyncNative (only cars-test) - the other tests (ghostseat, twin-ctl, contact,
  twin-equip, car-store, loot, soak) to be moved to it before it becomes the default.
- **The host's trunk lid open after the guest drove (2026-10-30 night)**: two things. (1) A car left in drive with
  the engine on creeps away (~2.7 m/s) when its driver gets out - the game's own behaviour, the own car alike (probed);
  the host's car crept into something. Not changed (a parking brake set on the handback did not stop it either and is
  not the game's); cars-test step 8 now shifts to park before getting out, then checks the host's car stands with its
  doors and lid shut. (2) The guest's door lines (CoopPlayers.doorLog(): "s/d<ms>:<door>:<op>", 40 kept): taking the
  host car's wheel sent "3 open" and "5 open" along with "1 open" - other doors' flags changed by the context switch
  inside the E window. Now only the door the player works goes out (aimed at / sat behind / got out by), plus a sure
  shut of the entry door (TD.entryShut) and of the exit door (TD.exitShut). cars-test: 19/20, 19/20, 19/20 - the lid
  passes in all three; single flakes left: the own car not driving in step 9 once, the own FL flag open once (both
  likely a context switch race while the guest stands between the two cars).

### Native cars are the default (2026-10-31)
`TD.native = CoopSyncNative ~= false and (role == "host" or ownCar)` (the old guest mode, no own cars, as it was:
remote pedals there). Every quick test runs native now. Changes made while moving the tests:
- **A car's controls are its driver's only**: key, levers, top light, gearbox, shifter, radio part, the dash's car
  friend denied ("Should Allow Highlight" hook) to anyone not at that car's wheel - on foot outside too: the test had
  pressed the other's light lever through the window, and the manager's one lights state lit the own car.
- **No way in by a door whose seat the other player sits on** (the twin's doors too: doorBlocked / catShow /
  TD.doorOfHighlight) - the game's own entry started and the mod threw the player out (contact-test).
- **The twin's doors open here when the owner's are open** (the game's AttemptOpen while the twin is the context, its
  flag cleared first): a posed open door was no door for the game (no highlight, no shut; ghostseat). Shut here when
  the owner's is shut for 2.5 s (AttemptShut, else the mesh stops simulating and is re-attached). Found on the way: the
  owner's door state was always read "shut" (`s and s:match(...)` returns one value: the yaw was lost) - the source of
  the flaky lid.
- The context goes back to the own car 2 s after the other's car was last aimed at (TD.NATIVE_LET_GO_MS; the "nearer
  car" rule was for a missing door, dropped) and stays the other's through the game's exit animation (it jumped to the
  own car's exit point otherwise).
- Tests moved: twin-ctl (controls not offered outside; levers worked at the wheel; the game's exit), twin-radio,
  contact, ghostseat (step 2: a hold opens the door, the host shuts it, the twin follows; the game's exit), twin-equip
  (the slot's point tried as a second aim; the guest's doors shut first), cars (door log, park before getting out).
- Quick suite native (2026-10-31): sync, interact, wheel, owncar-guest, twin-state, twin-ctl 27, twin-radio 13,
  garage-radio, collide, loot-live 14, car-store 17, session-net, menu, startflow, mapsync, gates, esc, contact 10,
  cars 20, revisit - PASS; then ghostseat 23/23, drive 23/23, f7 4/4, twin-equip 10/10 x2 on reruns. anomaly: the
  guest died once ("Unknown token ... ReferenceTokenStreamIndex" = the GC walking a bad reference,
  Rural_Forest_Farm_Rooster_11 ...None_2147353948), 9/9 twice after - to watch (crash rates need 8-run batches).
- Open: the cost of the slot / reach hooks; that GC crash; the old-mode code (muteDoors / muteBody, the mod's own
  entry / exit / pedals) to remove once native has a real test with the owner.

## The owner's alpha 18 test, two copies on one PC (2026-11-01) - findings (summary of the owner's list)
Reports: `C:\Users\super\Downloads\two-games_alpha18_test1.zip`, `..._test2.zip` (the two-games folders zipped:
Report.bat does not pick two-games up). Owner: zone sync first (the new save mechanism), interactions, and the
guest's own car exists TWICE (as in the alpha 17 test) - likely behind several bugs.
Pass 1 (garage lobby):
1. Pause in the lobby: the other's puppet moves in the background without animation -> no pause in the lobby.
2. The host's car does not start: no highlight on the key, nor the gear lever, light / wiper handles, radio, top light
   (keys on the keyboard work). The guest fine. (In the zone later the host was fine.)
3. Both see a stuck "Ошибка сети: Recv: the other side closed".
4. After quitting to the menu the host copy crashed.
Pass 2 (host started its car before the lobby):
5. Both can pick the junction on the map; the guest's pick opens the host's gates -> on the guest's map only look.
6. The map's orange blots (instability) differ; a junction's info (objects, anomalies) differs between the two.
7. The guest arriving in the zone loses all control (not even the camera); the mirror shows a second car being
   driven at that moment.
8. Joined: the guest has THREE cars (two own + the host's); its two collided at the teleport and flew apart.
9. The host: two cars fine, but a hood floats in the air in front of its car, moving with it, physical; dropping it
   (a hitch) removed it - together with the real hood of the host's car.
10. Allow the host the passenger seat of its own car.
11. The host getting into the guest's car: the car twitched, the camera flew under the map for a second, a part
    fell off; the gear lever switches every other time / visually only.
12. The host got out of the guest's car after driving it a bit: it and the car were put back at the start; on the
    guest one of its cars drove on, the host was put into the second car that had stayed.
13. Host as passenger in the guest's car: the exit highlights the driver's door, not the passenger's.
14. Part wear by health not synced (an almost broken part on the host's car looks new on the guest).
15. The guest got anomalous wind clouds the host did not have.
16. The car's map: North at the top for both, but on the guest it is South (map flipped).
17. The guest getting into the host's car as passenger: the door cannot shut for a while on the guest (tries again
    and again); on the host it shut at once.
18. Different light levels: the sun's position differs (maybe with the map).
19. Getting out of the host's car the guest's driver door highlighted too; on the exit both opened and shut late.
20. Abandoned cars' parts differ in colour (the guest's always orange / blue); a street lamp lit on the guest only;
    an abandoned car's door ajar on the host, shut on the guest.
21. Car parts lying on the ground on the guest only: they fall off the host's car when the host takes the wheel
    (stuck sounds); the parts stay on the car on both, copies spawn on the ground.
22. A car drives through the other player: must collide, damage and push (as with the own car in the game).
23. Anomalies: the saw lags on the guest; the geyser fires later on the guest; the mannequin in other poses, no sway
    on a kick.
24. The guest cannot close the host car's trunk (closes on the host, the guest's tries and fails); it does no damage
    hitting the own head.
25. The host driving: on the guest the physical car bits glitch (the mirror trinket shakes, the antenna stretches
    into the sky).
26. The host's wipers do not run on the guest.
27. The car's monitor: different health / damage on the two (the guest's glass not broken, the host's is); the guest's
    monitor lacks doors that are on the car (follows 21).
28. Dash icons, fuel, battery, radiation gauge differ.
29. The guest hears the trunk closing again and again while driving.
30. The host opening / shutting doors: jerky and late; the hood did not open at all.
31. A tree / barrel / physical object knocked by the host's car stays standing on the guest.
32. The guest searching a resource container: the loot menu still opens on the host -> only for the one searching.
33. The guest putting new loot into a chosen slot: it lands in the first slot (the host fine).
34. The host's own mirrors show a frozen picture from the start (the guest's update).
35. The host's own steering wheel does not turn.
36. A trial zone (gates, wires on the road, checkpoints on time, a prize) on the host's map - none on the guest.
37. A fuel barrel's level differs.
38. Destruction / pushing objects by a kick not synced.
39. The guest took an anchor - not taken on the host (duplicated); put into the ARC of the host's car by the guest:
    the exit's charge only on the guest.
40. The host opened the exit: not opened on the guest, the instability did not start closing.
Wishes:
- A "Кооператив" checklist like the game's "Список водителя" (the car status screen in the garage): "Лобби: 2 из 2
  (Пинг 10 мс)", the players ("PLAYER1 (Вы)", "PLAYER2 (Хост)" or "PLAYER1 (Вы, Хост)"), the action (host: "Выберите
  развилку" -> "Выезжайте в зону"; guest: "Ожидание хоста" -> "Выезжайте в зону"); shown once a lobby exists.
- The menu's info-only buttons as text on the right (like the pause menu's current objective), the same list.
- Every in-game text of the mod in a localization file (Russian + English now), picked by the game's language.
- Report.bat misses two-games: a ReportTwoGames.bat; "Две копии игры.bat" -> "TwoGamesTest.bat".
- The bat files' texts in English; CHANGELOG and README in English too.
- Better tests so these are caught.

### Alpha 18 findings: causes and fixes so far (2026-11-01)
- Item 2 (host's key / levers / radio dead in the garage lobby): TD.passengerMayReach denied every control to a player
  not at the wheel per TD.seatNow - and the seat block never runs in garage mode, so seatNow was nil. Now the hook
  answers "allow" in the garage and in a stopped session (single player after a lobby: same trap).
- Item 1 (pause in the lobby): coopActive() now also covers the garage lobby (S.garageWorld): the pause menu does not
  stop the world there. (The debug "restart" keeps its own hosting / playing check.)
- Item 3 (stuck "Ошибка сети: Recv: the other side closed"): the native net keeps the last error after a leave; the menu
  hides "other side closed" when not in a lobby.
- Zone through save: session.lua's UserLoadGame / UserNewGame hook left the lobby on any load - the guest's own
  UserLoadGame of the host's zone too. ZoneSave.selfLoad marks it. startflow now checks it (CoopSyncZoneSave.info()).
  First run: host saved into slot 8, guest spliced (map 2.6 MB, player / car moved), loaded, then imported and played.
- Duplicate car: startflow's new census (cmds/car-census.lua: every BP_PlayerCarNew_C of the level, own / twin, and
  car parts with no parent within 15 m of a car) after the LATE JOIN found the host with THREE cars: own, the new twin,
  and one at 0,0,0 with its 28 parts loose at the same spot - the extra car of the owner's report. Being traced
  (twin spawn / remove now logged).
- Tests could not see it before: no test counted cars or loose parts; UE4SS.log is one file for every game started
  from one folder (the two-games copies and the test instances overwrite each other's), so the mod now writes its own
  <chan>/coopsync.log (print wrapped in main.lua); ReportTwoGames.bat collects both copies' folders in one zip.
- Test-side pitfalls: in the command env rawget(_G, ...) misses the mod's globals (the env falls back by __index) and
  require() does not find the mod's modules -> globals (_G.CoopSyncTwins, CoopSyncZoneSave). CoopPlayers is set
  only by tests that start playersync themselves.
- The "third car at 0,0,0" was a DESTROYED twin waiting for the GC (minutes in this game: removed 07:13:55, still
  there at 07:15:40, gone by 07:22): UE4SS's IsValid() AND KismetSystemLibrary:IsValid(a) are both still true for it
  (probed: cmds/shell-probe.lua; destroying it again changes nothing). What tells: it has no root component (location
  0,0,0, no parts; its parts likewise). car-census.lua and the mod's car watch (session.lua carWatch) count only actors
  with a valid RootComponent.
- The same startflow late join showed the real item 8 ("the cars collided at the teleport and flew apart"): the guest
  was put by the host car's place from host-gates.txt (C line, written only when the gates changed - stale), the host's
  car had moved 1.6 m, the new twin spawned inside it and threw the host's car 65 m up (EXTRA CAR log: Z 14754).
  Now gateSig includes the car's place to 10 m (gates re-sent when it moved) and applyGates also moves the guest's car
  when it is closer than 4.5 m to the host's (CLASH_CM), not only further than 40 m.
- Item 32 / alpha 17 item 1 (the loot window opened on the host when the guest searched): statesync's host OPEN replayed
  the guest's search with HighlightInteract() = the player's E. Now the quiet way (DataBlock_WasOpened,
  SwitchToOpenedVisuals, UpdateInteractionOpened, then OnRollForOpenItems).
- Item 33 (the guest's item landed in the first slot): PUT carried only the item and count; the host added it to the
  first free tile and its layout came back. PUT now carries the tile (x_y_r, field 6) of the guest's new slot
  (statesync tileOf); the host sets the slot's Location / bRotated (req_PUT_placed).
- Quick suite after the first batch: 23/24 PASS, startflow FAIL only on the new car checks (above).
- The garage co-op checklist (owner's wish; checklist.lua): the game's "Список водителя" is the mission
  QD_Generic_Mission_DriversChecklist shown by UMG_Missions_Main.UMG_DriversChecklist_Objective_List (in
  ShoppingListWidgetSwitcher in RecipeSizeBox in ObjectiveSetsBox: the HUD's left under the health bars). It opens from
  the status screen by the map table (BP_Garage_StatusDisplay_C; its "DbgActEvt_Start Drivers Checklist_Execute" opens
  it - used for screenshots). Do NOT: put UMG_Mission_Task_C / UMG_Objective_Info_C widgets without a mission into the
  game's lists (the game crashed rebuilding the list), call BaseMissionManager:StartMission from Lua (an assert killed
  the game), FindFirstOf("UMG_Objective_Info_C") + GetClass (a dead template: UE4SS crash). What works: a VerticalBox
  of ours wrapping the RecipeSizeBox's content (the switcher first, our list under it; put back when ours goes), text
  blocks and images with the fonts / check box brushes read from a UMG_Objective_Info_C and a UMG_Mission_Task_C made
  only for reading (classes by FindObject("WidgetBlueprintGeneratedClass", name, 0, 0)). Screenshots:
  local/checklist-10.png (under the driver's list), checklist-9.png (alone). status.txt chk= = its rows (startflow).
  $COOPSYNC_CHECKLIST_DEMO=1 shows it with a made-up lobby (graphics checks).
- The pause menu's info rows (no action: lobby state, players, the last result) are text in a column beside the buttons
  (menu.lua infoText; our column and it in a HorizontalBox over the menu's content: the frame widens like for the game's
  route panel). Screenshot local/menu-info-3.png. A probe with graphics created a REAL Steam lobby of the test copy
  (Steam runs on this PC) - left by closing the game.
- Item 29 (the trunk shut over and over at the guest): the twin door mirror-open now waits until the owner's pose has
  been open for TD.OWNER_OPEN_MS (600 ms) - a lid swinging on the road read as open for a frame.

### Alpha 18 items: cars and world, live checks (2026-11-01)
Live pair through the real start flow (startflow-test -Keep: lobby, the host's departure, the guest loads the host's
zone save) + probes:
- **World (items 6, 15, 16, 18, 20, 36)**: `cmds/world-digest.lua` (time of day, sun, weather event, every actor of the
  world by class with places, looks of abandoned cars / lamps) on both sides, `world-compare.ps1` diffs them. With
  the zone through the save: time / weather the same, every class count and place the same except the per-load
  prefab rolls the save does not keep (known from the prototype): BP_PrefabSelfDeletor 6/3, ManageChildrenActor
  149/122, a street lamp guest only (item 20's lamp), a road-work sign, a shrub, graffiti decals, StaticMeshActor
  1221/1227, one light pole / billboard elsewhere. Whole sites (the trial zone, item 36) and the abandoned cars match:
  the owner's alpha 18 run used the old sync. Not done: aligning those last rolls (the old sync's dressing rows).
- **Item 34 (the host's own mirrors frozen)**: FOUND. The game hands every car ONE mirror MID (outer
  /Engine/Transient; `cmds/mirror-shared.lua`: interior slot 8 and both front doors of BOTH cars = one object).
  twincar `_mirrorDoors` set the twin's capture target on that MID when it was already a MID - so the own car's
  mirrors sampled the parked twin's capture (`cmds/mirror-rt.lua`: own car interior / doors = OTHER, on both sides).
  Now every twin mirror slot gets a MID of its own mesh (made from the shared one's parent + parameters) and the own
  car's slots are put back on its own capture target (stats mirrorMids / mirrorOwnFixed). startflow checks "each
  car's mirrors show its own camera" after the join and the late join.
- **Item 35 (the host's own steering wheel)**: not reproduced: `cmds/steer-probe.lua` (SteerLeftRight or the input
  controller's axis event every frame) moves SteeringWheelRotationCurrent to 0.1 only and the wheel mesh not at all,
  on BOTH sides (headless input does not steer here). The wheel mesh is moved by its world transform (car-relative
  read: pitch -25 = its tilt). Needs a live look.
- **Items 13 / 19 (a passenger's exit outlined the driver's door)**: Highlight_ExitDoor draws its HighlightVisuals
  (DoorInteriorHighlightMesh by the driver's door, `cmds/exit-highlight.lua`) wherever its collision is moved;
  TD.placeExit now also puts the seat's door mesh there (the car's own list back for the driver). cars-test step 10.
- **Item 10 (the host on the passenger seat of its own car)**: a tap at a back door (3 / 4) of the own car whose seat is
  free: the seat socket moved there, the door's StartEntry, CommandEnterCar 0.2 s later, the door shut at 1.45 s
  (TD.ownEnter, as for the other's car); TD.ownSeat makes the seat logic seat it there (host: chooseSeat by that door;
  guest: that seat number) and wheelFrame zeroes the car's input fields every frame meanwhile (the controller still
  feeds the car the player sits in); the socket goes back to the wheel on the way out. The front passenger seat stays
  the ARC's. cars-test step 10 (host: in by door 3, seat 3, the exit outline on door 3, throttle moves nothing, out).
  First try failed: StartEntry alone opens the door and walks nowhere - CommandEnterCar is the game's second step.
- **Items 21 / 25 / 26 / 27 / 28 (parts on the ground, antenna, wipers, monitor, dash)**: the live pair showed two cars
  per side, no loose parts before / after the host took its wheel (car-census), 125 parts / 5 doors on each car on
  both sides (`cmds/cars-live.lua`). ToggleWiperBlades from Lua did not start the wipers (timeline 1.5 on all cars)
  - not a valid check yet. These look like consequences of the guest's extra car in the owner's run (the old zone
  sync); the car watch logs any extra car now.
- cars-test step 6 "the guest's E at the open lid shut it": flaky (2 of 3 runs, 1 of 3 repeats by hand) - the
  game's E on the open lid sometimes changes no door flag at all (flags 5=true before and after, the highlight on
  the lid's slot spot both times); not the sync (the shut goes out when the flag changes). Pre-existing.

### Quick suite after the cars / world round, test fixes (2026-11-01)
- Quick suite: 19/24 PASS at once. Rerun alone: anomaly 9/9, contact 10/10 (both failures single flakes); the
  guest's crash in anomaly was inside the engine's world tick (cdb: UEngine::Tick through UE4SS's engine-tick detour,
  a virtual call on a freed object; new stack hash C11D81F1E410; not in Lua). collide 8/9 twice, a different check each
  time: the test spot (Rural_Forest_Radio_Scylla_02) is a slope, the guest's car rolls on 60 m after the hit (held speed
  914 before the striker reached it) / the twin's damage 5.0 off at a 5 tolerance. Not the mod's change; left.
- cars-test step 10 (back seat, no driving): the test bot's input loop and wheelFrame are both 1 ms game-thread loops
  whose order in a frame is not fixed - the bot's throttle won one run in two. The bot keeps the same back-seat gate
  (M.botInput's act loop writes ZERO while TD.ownSeat.seated); the check reads the car's input fields while the bot
  holds the throttle (all 0) instead of the distance (the test spot is a slope: the car rolls 0.5-3.6 m in 5 s parked
  in drive). Real keys from the back seat not checked (no key injection in the tests).
- cars-test step 8 checks items 11 / 12 the other way round (the guest at the wheel of the host's car): after driving,
  park and the exit, the host's car stays where it was driven to, the guest stands by it, the lever's park reached the
  host. Step 8b (the host at the wheel of the guest's car, three lever shifts, drive, exit) runs only when the guest's
  car has a driver's door: the test save's guest car has EmptyDoor in FL, RL and the trunk slots. Its first runs failed
  on a test bug: step 10's twin-parts-look call left the global LOOK_OWN = true in the host's Lua state, so Tap aimed
  at the host's OWN car's door (Tap sets LOOK_OWN = false now); the host's own car, left in drive with the engine on,
  then rammed the guest's.
- OPEN (found on the way): a car without its driver's door (EmptyDoor in DoorsFL) shows no highlight to get in -
  neither the guest at its own car nor the host at the twin (looking straight at Highlight_EnterDoor's
  UICollision_EnterDriverDoor, car-relative 58,-92,31; the game's E on that highlight did nothing either). Not known
  whether the game itself allows it (single-player check needed) - if it does, the mod's body-highlight handling
  (twincar BODY_HL EnterDoor "always", TD.aimNative) is the suspect.

### The other's car's doors broke the own car's doors (2026-11-01, found by cars-test step 8b)
- Owner (2026-11-01): in the plain game a car without its driver's door can be got into (E at the empty slot's spot;
  checked here too: the guest got into its own door-less car that way). The "test save's guest car without doors" was
  no save: cars-test's new per-step line of the guest's own car's doors showed them gone DURING step 8 (the guest at
  the wheel of the host's car), no door item or actor left anywhere.
- Traced (a 100 ms poll of the own car's door classes + hooks on the door's BreakEvent and the manifestation's
  ReceiveDestroyed): as the guest drove the twin, the twin's doors 3 and 5 broke (BreakEvent on the twin's door) and in
  the same frame the guest's OWN doors 3 and 5 were destroyed; door 1 6 s later. The door's PhysicsConstraint
  (Chassis - MainMesh; OnConstraintBroken -> the door's OnConstraintBroken_Event_0 -> BreakEvent) ends in destroying
  "the car's" door of that number - the own car's.
- Why the twin's constraints break at all: the twin is built kinematic, so its doors are not welded into the chassis
  body as the own car's are; once this side simulates it (driving it), the constraints take the strain. With the doors
  made unbreakable (DoorBreakAmount 1e30) the car could not move at all (cars-test step 8: 2 units) - before, they had
  snapped at once and the drive looked fine (4-6 km).
- Fix (twincar M.muteDoorBreak / M.rejoinDoors): the twin's doors lose the OnConstraintBroken binding (each second with
  the pose refresh and when this side starts driving it); when this side stops driving it, a broken constraint is made
  again (SetConstrainedComponents(Chassis, MainMesh)) so an open door does not fall off. The owner's car breaks its own
  doors; the equipment line takes them off the twin. Status: break_muted=, rejoined= in the twin line.
- cars-test after it: 29/30 (only the known own-FL-flag flake after step 6). Step 8 drove 4700, the guest's own car kept
  all its doors (new check), step 8b ran for the first time: the host at the wheel of the guest's car, every lever shift
  reached the guest's car (item 11), it drove 2312 and the host got out where it stopped (item 12).
- Likely the same cause in the owner's alpha 18 test: doors missing on the car monitor (item 27), car parts lying on
  the ground / falling off when a player took the other's wheel (item 21).
- Probe pitfall: a probe calling GetFName on a null object (GetAttachParent() of a door mesh, a constraint's
  ConstraintActor1) killed the game (UE4SS construct_fname, read at 0x18; stack hash 61EBDE396A55) - nm() with IsValid.

### Items 24 / 17: the other's car's doors shut from this side (2026-11-01)
- Item 24 ("the guest can't shut the host's trunk, it tries and can't"): cars-test step 6 had failed in 4 of 6 runs
  ("flaky"). Four open / shut rounds in one session (scratchpad lid5.ps1): only the first shut. The guest's E at the
  open lid lands on the trunk slot's spot (BP_CarPart_Interactive_C), the game's shut runs on the twin's lid - and the
  game's shut does not close a door of the kinematic twin (known: TD.twinDoorReconcile); the manager's flag stayed
  open, nothing went to the host. Now (TD.onHighlightPress, native): E while aiming at a twin's door / lid that is open
  (here or by its owner's pose) arms TD.shutPress; 400 ms later, if the game sent no door line meanwhile and the owner's
  door is still open, "DR n shut" goes to the owner (status shut_press=). 4 / 4 rounds shut.
- Item 17 ("the host's door the guest got in by tries to slam several times"): a door the game opened on the twin
  (entry, exit, a tap) waited TD.DOOR_LOCAL_MS 2.5 s after its owner's had shut, then the game's AttemptShut (no effect on
  the kinematic twin), then another 2.5 s before the pose took it. Now 1.5 s and straight to the pose; the game's shut
  only while this side drives the twin (it simulates then). Not checked by eye.
- Not done for item 24: the lid's hit on the head doing damage on the guest's side.
- cars-test after both: 30 / 30 PASS (the first clean run of it).


### Item 39: anchors and the ARC (2026-11-01)
Probed on the owner's save copy (Rooster_11; the test save's first zone has no anchors at all):
- An anchor is a `BP_Spawn_Anchor_Unstable_M_C` (< `BP_Spawn_Anchor_Base_01_C` < `BP_Spawn_Resource_GrabBase_C`), a
  long-grab resource, not an item manifestation: the W| pick-up sync never saw it, so a taken anchor stayed on the
  other side (doubled). The spawners themselves are in the spawn list (same keys both sides). Taken = 
  `SuccessfullyGrabbed` (+ `AnchorRemoved`, the grab mesh hidden). `"Long Grab Complete"` called with nobody grabbing
  marks it taken and hands no item to anyone (anchor item instances stay 2); `AnchorTaken` alone sets only
  AnchorRemoved.
- Fix: lootsync serializes every GrabBase actor as `R|0` / `R|1`; the guest's grab -> `GRAB <key>` -> the host marks
  it taken ("Long Grab Complete"); the host's grab -> its next pass sends `U R|1` -> the guest marks it.
- The ARC is the car's Gobbler: `BP_Carpart_Internal_Gobbler_C` (item IA_Internal_DoctorGobbler) at
  SLOT_Internal_Gobbler, the screen `BP_Carpart_Internal_GobblerScreen_C` (`GetAnchorCharge(cur, max)`). Each side
  has exactly one, its own car's: a twin carries none, so a guest "putting it into the host's car" charged its own.
  The charge is the Gobbler item's item property (getter `InventoryBlueprintLibrary:GetItemProperties(<class>, ...)`
  with the class from IP_Gobbler / IP_Anchor's `PropertyComponent` - a ClassProperty UE4SS cannot read, so the exact
  value is out of reach). A deposit ends in `AddingAnchorCompleteLogic(anchor)`; called with a new anchor instance of
  the same archetype (lootsync newItem) it adds that anchor's rolled charge (medium: 1.1 / 1.2 / 1.3).
- Fix: a hook on AddingAnchorCompleteLogic (hooks.lua) sends `GOB <archetype>` (guest -> host request, host -> guest
  event); the other side repeats it on its own Gobbler (quiet: no echo). Both charges rise together, about equally.
- Test: `mod/tools/anchor-test.ps1` (host = owner's save copy, guest joins): guest grabs A -> host's taken, no item;
  host grabs B -> guest's taken; no revert; deposits both ways charge both ARCs, once. 7/7. Quick suite member.
- Not checked: a real deposit by hand goes through AddingAnchorCompleteLogic (inferred from the function names and
  parameters; the test calls it directly).
- Item 40 found on the way: the exit portals (`BP_LevelTransition_ExitPortal_C`) are not in the spawn list - the
  host had 3, the guest 4 at other spots. Opening one and the instability that follows are not synced either.

### Item 40: the exit home (2026-11-02)
Owner: "the host opened the exit: not opened on the guest, the instability did not start closing".
- Probes (owner's save copy, Rooster_11): the host had 3 portals (GUID names, restored from the save), the guest 2
  others (runtime names, elsewhere) - the portals were not in the spawn list.
- Picking an exit on the ARC (UMG_GobblerScreen UseSelectedWidget / ActivateExit) ends in
  `BP_StormManager_C:"Select Exit Portal Actor"(portal)`: the portal becomes `EvolvedGatewayExit` (`IsPickedExit`), and
  ~10 s later the closing storm `BP_ZoneStormRoyale_C` spawns at the portal (`SpawnedStormIfValid`,
  `CurrentStormState` 0 -> 3). The portal's `Active` stays false. (Calling UseSelectedWidget + ActivateExit on the host
  fired the hook too.)
- Fix: `^BP_LevelTransition_ExitPortal_` in spawnsync PATTERNS (same portals on both); statesync EXIT: a hook on
  "Select Exit Portal Actor" sends the pick (host -> events, guest -> requests with the host key) and the other side
  calls its own storm manager with its copy (quiet flag: no echo; a portal already picked is skipped).
- Test: `portal-test.ps1` (owner's save copy): same portals; guest picks A -> host picks A (req_EXIT_done), the storm at
  A on both; host picks B -> guest follows, no echo. 4/4. Quick suite member.
- Not checked: the ARC pick by hand (the test calls the storm manager; the UI path fired the hook in a probe).
- Guest crashes on this save in the sync-test setup (the guest imports ~1760 host actors, removes ~1200 of its own):
  idle after ~6 min (F008609C, a TaskGraph thread; before the portals were in the list), C11D81F1E410 twice (engine
  tick; both right after two FlushAsyncLoading in consecutive frames, same address 0x1e31506c8), and on picking a third
  different exit in a row (5C5B4A5C, TaskGraph; the host survives the same three picks; no state sync running). A 12 min
  idle run did not crash. Real play loads the zone from the host's save instead of this import; a pick happens once.
  Left (time-boxed); watch the owner's reports for these hashes.

### Items 31 / 38: knocked and kicked objects (2026-11-02)
Owner: "a tree / barrel / physical object knocked by the host's car stays standing on the guest", "destruction /
pushing objects by a kick not synced". Owner's choice: smooth, in real time.
- The breakables are `BP_Crash_Base_C` (/Game/Gameplay/Destruction/Base/): Simple (`BP_Crash_Simple_Base_C`: barrels,
  cones, signs, boxes; `SimpleBreak(Impulse)`) and Complex (`BP_Crash_Complex_Base_C`, foliage
  `BP_Crash_Complex_Foliage_Base_C`: `BP_IF_*` shrubs / young pines / oaks, benches, barricades;
  `ComplexBreak(BreakImpulse, BreakingPrimitive)`); kicks `ObjectKicked(component, location, vector)`. Placed ones
  (`BP_Destruct_*`) are in the spawn list; the foliage / road-spline ones are swapped in by `BP_FoliageManager_C`
  (`ConvertInstanceToSwappable`, `SetupSwappable`) near each side's own player - both sides at the same places.
- Probe (collide-test setup, Scylla_02): the host's car broke three shrubs (gone in ~1 s), the guest's copies stayed:
  the other's car is a kinematic twin (objtype 1, not Vehicle), its game does not count it. `ComplexBreak` called on
  the guest's copy broke it the same way. A medium oak stops a car unbroken.
- Every breakable is removed 3-12 s after its break (`UseObjectRemovalOnBreak` true, `ObjectLifetime` 3, 12 for
  Barrel_03 / WheelBarrow), so the same impulse on both sides gives each a smooth flight of its own and the pieces go
  on both; no pose stream needed (the rest spots may differ for those seconds).
- Fix (statesync KNOCK): hooks on SimpleBreak / ComplexBreak (both) / ObjectKicked / SetupSwappable; each side sends
  its own break / kick (KB / KK: class, place in 10 units, impulse / kick), the other finds its copy by class and place
  (60 units) and calls the same (quiet: no echo; one already broken is left; 3 per tick). A break of one not swapped
  in there waits for its SetupSwappable; a kick of one not there is let go.
- Test `knock-test.ps1` (collide-test -SetupOnly): host's car through a shrub -> gone on both; host kicks an oak ->
  the guest's copy kicked (KK); the guest's own car through another shrub -> gone on the host too. 3/3. Quick suite.
- Found on the way: releasing a car's parking brake from Lua (VehicleControllerComponent SetParkingBrakeActive(false)
  + Wake) crashed the game - on the host's car with its player at the wheel and on the guest's empty car alike
  (collide-probe's "ram" does it; not used by the suite). The test drives the guest's car with its player inside.
- Not covered: kicked objects that do not break and loose physics props outside BP_Crash (pushes stay per side).

### Item 37: fuel barrels (2026-11-02)
Owner: "a fuel barrel's level differs".
- `BP_Spawn_GasBarrel_C` (PlacedOnly kind; in the spawn list): `RandomizeFuel()` at BeginPlay - each side's copy rolls
  its own - and the fuel lives in its `BP_FuelableComponent` (`GetFuelStatus` out params Fuel / Fuel Capacity /
  Percent ..., one table per out param; `"Set Fuel"(v)` takes one parameter). The actor's `IP_Fuelable_Fuel` stays the
  first roll (Set Fuel 1.5 -> status 1.5, the field 3.0). Siphoning goes through the component (TransferFuel /
  ModifyFuel) - not hooked: the same component class is every fuel tank's, the car's own included.
- Fix (statesync FUEL): each side reads its barrels every second (list every 10 s); one changed here goes over (FUEL
  <key> <fuel>, host key), the other side sets its copy; the host sends all of them every 30 s (the guest's own roll).
- Test: anchor-test step 5 (owner's save copy, 2 barrels): equal at the start, host 1.25 -> guest, guest 0.5 -> host.
  10/10. Not covered: the wrecks' gas caps / gas tankers (their level is the item's archetype, in the loot strings).


### Item 23: saw blades, geysers, tourists (2026-11-02)
Owner: "the saw lags on the guest", "the geyser fires later on the guest", "the mannequin is in other poses, it does
not sway on a kick".
- Where: the hazard set is rolled per visit and grows with progression - a new game's zones had no saws; from the
  owner's save copy, Wilderness_Swamp_14 had 6-7 saws on 2 of 4 visits, ~100 tourists. Kept as
  `local\advsave\swamp14.sav` (zone-census.ps1 + cmds/save-probe.lua SP_OP='save'). No geyser seen in 7 swamp visits;
  `BP_Hazard_SmallGeyser_C` spawned by hand (LoadAsset '<path>.<name>') to read its layout.
- Saw (`BP_Hazard_SawBlade_C`): the actor stays put; its blade runs a ground spline by timelines (PreMoveTimeline:
  rise ~3 s, MovingTimeline: run 1/DataBlock_TimelinePlayRate = 3.5 s, hold, Direction flips, back). Random `Phase`
  (RandomPhase). It runs while its `BP_HazardProperty_PlayerRange` says the LOCAL player is within DistanceToActivate
  (12000, out past + RangeBuffer 500; a 1 s timer, CheckIfPlayerIsInRange) - the component calls the actor's
  `BndEvt__..._OnPlayerInRange__DelegateSignature` / `OnPlayerOutOfRange`. So each side's copy started when its own
  player came near, at its own moment: never in step. Calling the InRange event by hand on a far saw starts it.
- Geyser (`BP_Hazard_SmallGeyser_C`): the same PlayerRange component and InRange / OutOfRange events (StartWave,
  acid lobs): fired by each side's own player, so later on the guest.
- Fix (statesync RANGE, classes SawBlade / SmallGeyser / LargeGeyser names): both sides `StopCheck()` the range
  component (one this side had started is stopped); the host starts / stops its copy by the nearer of the two
  players (HZ.dists, the component's own distances) and sends `RG <key> 1 <phase> <dir>` / `RG <key> 0` (all started
  ones again every 15 s); the guest sets Phase and Direction and calls the same event.
- Tourist (`BP_Hazard_Landmine_C`): the body (`Body`, simulated on `ConstraintJoint` to `Base`) rolls one of 4 meshes
  (SM_Landmine_Top_F_01/02, M_01/02), a yaw / small tilt and a mirrored scale at BeginPlay: each side its own. A push
  at the body's tip (TipScene) sways it ~1 s (300 cm/s: 87 deg); an angular velocity set on it died out in 0.2 s.
- Fix (statesync TOUR): the host sends each pose (`TP <key> <mesh> <p y r> <scale>`, all again every 30 s, the guest
  skips one it has); the guest sets the mesh, scale, world rotation, SetupConstraints - its tilt fuse
  (PreventExplodeOnAngle) off for 4 s. Each side watches the tourists within 3000 of its player / car 10 times a
  second: a body turning > 30 deg/s sends `TS <key> <tip velocity>` (2 s quiet per tourist), the other side pushes
  its copy at the tip by that velocity x mass (fuse off 4 s; skipped when its own copy sways already).
- Test: `range-test.ps1` (swamp14.sav; quick suite): poses 117/117; a saw 30000+ from both, the guest's car 8000 (its track ~3000 each way) from
  it: the host's copy runs (the host far) and both run in step (same timeline and direction within 0.5 s, 14/14
  samples); the guest away: both stop; a push on one side sways the other's copy (both ways, ~100 deg).
- Not covered: a geyser in a live pair (none found on visits); the guest's own kick on a tourist by hand (the test
  pushes the body). A tourist's creep toward the camera stays each side's own (the actor's moves are the host's M
  lines as before).

### Item 14: part wear (2026-11-02)
Owner: "part wear by health not synced (an almost broken part on the host's car looks new on the guest)".
- The health was synced already (ES h, SetHealth on the twin's part). What the player sees as wear is not the health:
  it is the health component's visual damage (`GetVisualDamageValues` / `SetVisualDamageValues`, struct
  ST_VisualDamage: Impact / Radiation / Burn 0..1, field names with GUID suffixes, kept in the item's properties; hits
  add to it - IncrementVisualDamageValues), put on the part's materials as Impact_Amount / Burn_Amount /
  Radiation_Amount by `UpdateDamageVisuals()` (no parameters). Probed on a door: SetHealth(2) changed no material;
  Set + Update with Impact 0.9 -> Impact_Amount 0.9.
- Fix (twincar part state): kinds i / r / u (the health component's) after h, f, b in the ES line (2 decimals);
  owner -> twin only (not in the twin's EY changes: the owner's hits make them). partState prints them too.
- Test: twin-state-test step 1b: the host's wheel Impact 0.7 -> the guest's twin wheel 0.70, its material
  Impact_Amount 0.70. 10/10. (A repair restores the health only: the dents stay, on both - the game's own.)

### Item 22: a car runs over the other player (2026-11-02)
Owner: "a car drives through the other player: must collide, damage and push (as with the own car in the game)".
- Why it passed through: on the driver's side the other player is a puppet whose capsule blocks pawns only (a profile
  that blocked vehicles flipped the host's car when the puppet followed its player into it); on the walker's side the
  driver's car is the twin, kinematic, moved by its owner's poses - neither game sees a hit. A kinematic twin moving
  into the character carries it along (the host was dragged 96 m in a probe) and once over the capsule the character
  is stuck in it: LaunchCharacter then moves it 0.
- The player's damage: the game's message system. `MessageSystem:DispatchMessage(payload, recipient)` with a
  `MSG_Damage_Physical_Impact_C` (StaticConstructObject, Damage / Normalized Intensity / Impulse / HitLocation,
  Initialize()) reaches the player's AC_PlayerHealthReceiverHelper (CalculateFinalDamageAmount ran with it);
  `MSG_Damage_Physical_C` itself it ignores; MSG_Damage_FallDamage_C works too. (Where the player's health itself is
  kept was not found - not on the pawn's components.)
- Fix (playersync TD.RUN, every frame): each side watches its own player on foot against the other player's car (its
  twin here): speed from its positions over >= 0.15 s (frame to frame it read twice the car's speed - the twin follows
  in steps), the player in the car's frame inside its box (250 x 105 + 40, 250 high) or LEAD_S 0.12 s of its way ahead,
  the car closing, > 300 cm/s -> the capsule ignores that car 0.8 s (IgnoreActorWhenMoving), LaunchCharacter along the
  car (0.8 x speed, at most 1500), 350 off its line, 400 up, and an impact message of 0.012 x speed (at most 40).
  1.5 s cool-down. The other side sees it through the player's own moves. `CoopPlayers.runOverInfo()` (tests).
- Test: `runover-test.ps1` (collide-test setup; quick suite): the guest on foot 900 in front of the host's car, the
  host's car sent at 1300 -> the guest hit (24 dmg) and knocked 1189; the other way round: the host hit, knocked 1286.
  5/5. Not checked by eye: how the knock looks; the speed estimate still reads ~1.5x the car's.

### Item 30: the host's doors jerky and late, the hood (2026-11-02)
Owner: "the host opening / shutting doors: jerky and late; the hood did not open at all".
- The doors' poses come with the car's pose line (V, 10 a second) and each was set as its line came: on a 30-60 fps
  frame the twin's door stood still in 2 of 3 frames and jumped. Now applyPose keeps the newest pose per door and
  `M.doorEase(twin, dt)` (TD.twinFrame, every frame) moves it 0.35 of the way per 33 ms (RLerp / linear, car-relative).
- The hood is a `BP_Panel_Base_C` (/Game/Gameplay/Inventory/Items/Car/Panels/) whose `IsHood()` (returns the bool
  directly); it opens like a door (AttemptOpen: MainMesh simulates, pitch ~50; AttemptShut) but only the door class
  was posed. Now it is door 6 in the pose ("D6.MainMesh"), muteDoorBreak / rejoinDoors cover it (1..6).
- Test: cars-test step 1b: the host's hood open -> the guest's twin hood max 52 deg, moving in 30 of 50 frames of
  its way (0.6; stepped: ~0.33); shut -> 0. cars-test 33/33.
- Not done: the hood opened from the other side (the guest at the host's hood) - the interactive spot of PanelHood
  is muted on the twin (its handlers act on the own car); trunk-lid damage below.
- "Late": a door the guest's game opened natively because its owner's was open (the twin as the context car) waited
  TD.DOOR_LOCAL_MS 1.5 s after the owner's shut, then snapped shut. Now TD.OWNER_SHUT_MS 0.25 s for those (the 1.5 s
  stays for a door this side opened itself, whose owner's pose comes later) and it eases shut (Twin.shutEase), no
  snap. (A "2.4 s late" trunk lid I measured first was the probe: each send.ps1 call starts a PowerShell, the host's
  shut went out ~2 s after the guest's watch began. Measured with the pose's send time - CoopPlayers.poseDoor(n):
  the lines arrive 100-250 ms after sending, the posed lid shuts ~0.3 s after the host's.)

### Item 24 (rest): the trunk lid on the guest's head (2026-11-02)
Owner: "it does no damage hitting the own head". The game hurts a player under a lid through the lid mesh's hit
(BP_CarPart_Door_Base_C BndEvt__MainMesh_..._ComponentHit); the twin's lid is posed (kinematic, teleported) and hits
nothing. Fix (playersync TD.LID, every frame): the other's car's lid on its way shut (Twin.doorClosing: its newest
pose nearer shut than where it stands) and this side's player's head (+60) inside its bounds (KismetSystemLibrary
GetComponentBounds, +10) -> the impact message, 8 damage (TD.RUN.damage), a 250 push away from the car; 3 s cool-down.
Test: runover-test step 3 (the guest under the host's open lid - its bounds' middle -, the host shuts it): 6/6. (40
back from the middle the head was outside the bounds all the way: a head behind the bumper is not hit.)

### The tests on the zone save (2026-11-02)
Owner: "let's move the tests to the new mechanism". The real start flow gets the guest the host's zone through the
game's save (zonesave.lua, session.lua); only startflow-test went that way - the ~20 tests on sync-test.ps1 had the
guest's own generated zone with the host's list imported over it (~1200 actors removed, ~1700 spawned: where the
guest's engine crashes C11D81F1E410 / 5C5B4A5C / others were seen).
- sync-test.ps1 -GuestJoin now does what session.lua does: the host's ZoneSave.hostSave (scratch slot, the file into
  its relay outbox; ~0.5 MB in ~5 s, the call ~0.4-0.5 s), the guest's ZoneSave.guestLoad (spliced into its departure
  save, UserLoadGame), then the usual import over it. The load keeps the game in state 5 all along: the test waits
  for a new World object (the level reloaded: ~21 s), then for the zone to settle. -OldZone: the old way.
  -NoImport: stop before the import (to compare the loaded zone: world-digest.lua + world-compare.ps1).
- Read the "BEFORE import" score with care now: sync-score matches the host's spawn-list keys (actor names), and a
  loaded save gives every actor a new name - it reads ~30 % though the places match (world-compare: only small rolls
  and the hazards the helpers spawn again on load differ). After the import: 99.4 %, as before.
- The first quick suite on it (2026-11-02) found a real bug: the swamp zone's save (range-test, swamp14.sav, ~4.7 MB)
  did not splice - "ERR host tree": CoopNative's save walker knew none of value types 0x06 (an FText: u32 flags, a
  history byte - 0xff none, 0 base, 1-3 format + its arguments, 4-6 as number / percent / currency, 0x0b string
  table), 0x17 (u32 length + bytes: a photo's JPEG) and 0x18 (int64: a currency table's counts). A new player's save
  has none of them (runs' stats, photos, scrap); a player further in the game would have had no shared zone at all.
  save.cpp and SaveTree.cs know them now; all saves in local\advsave parse to the end. sync-test no longer waits 4
  minutes for a reload when guestLoad returned an error.
- The trunk lid's hit on a head (TD.LID): a lid bouncing back at its stop when opened read "closing" - a hit on
  whoever stood under it, then the real shut fell in the cooldown. Closing now also means 15 degrees under the lid's
  widest open (Twin.doorClosing). runover-test's lid misses had another cause too: after steps 1-2 the host's car
  stood in drive, on a slope it rolled 500-2000 away with its lid while the guest stood where the lid had been - the
  test parks it first (ToggleGearBoxState(0, false): called with the current state). Then two more: the lid's
  "openness" was |pitch| + |yaw| of its car-relative rotator, and the same open lid read (50, 180, 180) or (130, 0,
  0) - 208 -> 80, "closing"; now the quaternion's turn angle from the car's frame (shut reads ~0). And PAD 10 -> 30
  (a head 20 outside the lid's box missed). runover 2 of 3 before the PAD change, the third would have hit.
- range-test: 3 of 4 runs found the headless host's world paused by its own pause menu (PDP_PauseMenu_Main_C /
  UMG_PlayerMenu_Main_C in the viewport, WorldSettings' pauser its own player state) from about the sync's start;
  the saw and the sway stood still there. Not from keys (CoopNative_KeyDown reads only with the game's window in
  front; this host has none) nor the zone save (a probe with the same steps kept running 36 s after the starts).
  Cause still open; the test closes the menu and says so. The sway check waits 6 s now (the guest's line came after
  the 3 s it watched).

### The full suite on the zone save (2026-11-03)
First full run (61 tests) after the move: 13 not passed, 2 of them the guest's game dead. Reruns sorted them:
- session (file channel): the test was stale - the guest no longer travels on "go", it drives out of its garage
  (only the CoopNet branch did). Both branches drive out now. 11/11.
- twin-equip step 4 (the host takes the guest car's wheel off its twin) failed every run on the zone save, passed
  with -OldZone: the tests put the guest's car 800 aside at the host's height + 60, and a car loaded from a save
  sleeps in the physics - teleported, it stayed asleep 60 in the air (WakeAllRigidBodies did not wake it; a
  velocity did). The host's twin hung as high: the camera 14 above the wheel, the spot under it out of the
  highlight's 160 (SelectionDistance_Outside_LookingForward). Not the mod's: runsync's own move turns physics off
  and on (a new, awake body). The 12 tests with that move give the car a -50 velocity after it. 10/10.
- session-net: a test write to net-control.txt met the game's read ("file in use") - session-test writes with
  retries now (AddRetry).
- ghostseat-old (-Ghost: the other's car as a ghost, the old way): 6 fails, the same with -OldZone - not the zone.
  Only the tests use opts.ghost; the game never does. Left (time-boxed); not blocking.
- portal: 2 of 5 runs the guest had 2 more portals at 0,0 (the pick syncs anyway). The test prints their names
  and the list at the end when it differs. Cause open.
- anomaly: one check of 9 failed in 2 of 4 runs (a different one each time). Open.
- The guest's game died going home from the zone 3 times (session-net step 4 twice, ghostseat-old step 7), all in
  a Lua call on a freed UObject from a game-thread loop (UE4SS prepare_to_handle / HasAllCastFlags on garbage). The
  dumps hold no Lua heap, so no Lua stack. New: `CoopSync/Scripts/trace.lua` (loaded first by CoopSync and CoopDev
  main.lua) wraps the loops; `tools/trace-on.ps1 -Dir <coopdev> -Sec N` makes both Lua states write every mod
  function entered and every UObject call site to <coopdev>/trace-sync.txt / trace-dev.txt (flushed per line; off
  without COOPDEV_DIR, so never in players' games). session-test step 4 and ghostseat-test step 7 switch it on.
  Not reproduced in 3 traced runs (the trace slows the loops - it may hide a race). Known issue in alpha 19.
- Follow-up (2026-11-03, afternoon): trace.lua got a light mode (the default): one line per loop callback run and per
  CoopSyncAfter / Dev.after call ("@ src:line clock"), no debug hook - cheap enough to keep on in the tests that
  go home (trace-on.ps1; -Full for the old hook mode). The going-home crash did not come back in 13 runs since the
  test fixes (session-net x9, ghostseat-old x3, in the old order after session / anomaly-real too). All 3 crashes
  were before those fixes; 2 of the 3 came right after a session run that had failed (the guest left in its garage
  with a pending "go" - its userdir save carried into the next test). Not proven; left with the light trace on.
- anomaly: the "same place after" checks read the positions 2 s after the watch (a still-moving hazard read a
  200 gap); step 3 prints the hazard's run state on the guest before it is destroyed (CoopSyncState.hzInfo: mine,
  asked, respawns...) - the failed run had the guest's hz_died=0 and the hazard put back, as if the guest no longer
  ran it. 9/9 since.
- ghostseat-old is out of run-all-tests (the owner, 2026-11-03): the ghost path stays in the code, run
  ghostseat-test.ps1 -Ghost by hand if it is ever needed again.

## The owner's alpha 19 test (2026-11-03, two copies on one PC)
Report: local\reports\a19-owner-1 (player1 = guest, player2 = host; TwoGamesTest.bat, local tcp link). The crash
dump in it is the host's of 2026-10-31 (D3D device lost: not the mod). The owner's list:
1. The Co-op checklist sits right under the driver's checklist: more space between them.
2. The ping updates make the driver's checklist fold and unfold: drop the ping.
3. Pause menu: back to buttons instead of the side text, but as text headers, not buttons.
4. The map's route details (the bottom list of objects / anomalies at a junction) differ between host and guest
   for the same route (screenshots: different icons in the list).
5. The guest stood about a minute in its own generated zone before the load and sync: as fast as possible, the
   guest should never see a random zone. Log: guest LoadMap Wilderness_Forest_03 18:12:01 (own generation), the
   host's save loaded 18:12:25 (24 s on its own zone, then the import).
6. The guest still has two copies of its car, the controls mix: getting out moves it into the other one. Log:
   "EXTRA CAR: 2 cars, 0 twins" from 18:12:21 (before the save load) to the end, 125 / 124 parts each (both full).
7. Wipers at the wheel still not synced.
8. While driving, the guest's hood fell off and hung in the air (as before).
9. The ARC map's orientation still differs (the compass points do not match).
10. Anomaly clouds at different places on the map.
11. The guest sees a pillar anomaly from under the ground that the host has not (or has under the ground).
12. The dashboard readings (durability, battery charge, ...) differ.
13. Getting out at the back opens the back AND the front door.
14. A taken seat: the door must still highlight and be openable / removable, only sitting is blocked.
15. The guest got a high-radiation anomaly around it, the host not (likely the random event when standing long).
16. All abandoned cars on the guest have the same orange-blue paint.
17. A player's kick should do 1 % damage.
18. A car still drives through the player.
- Item 5 (the guest's minute in its own zone): its own travel cannot be skipped - the departure save is written in
  the travel's frame and the game refuses a load "on top of LOADING LEVEL"; a garage save with the host's Map spliced
  in loads the garage again (garage-load-probe.ps1: the level comes from the route state - LastVisitedLeg,
  MapLocation, WB.Routes.*.Attempted -, not from the Map key). Found instead: after the zone save's load the
  arrival step (S.zoneWorld ~= world) took the state back to "zone: generating" at once, so the guest waited the
  generator's MIN_ZONE_S 25 s again in a zone that comes whole from the save (owner's log: loaded 18:12:28, import
  18:13:04). Now the load step comes first, waits for the new World object (not a fixed 4 s) and the zone from the
  save settles in SAVED_ZONE_S 3 s. And the guest's screen is dark (the camera's manual fade, set every frame,
  at most 240 s) from leaving the garage until it plays (status cover=<ticks>/<shown>). startflow: playing 52 s
  after the drive-out (71 before), dark meanwhile.
- Item 6 (two own cars): the owner's guest log has two "Traveling to level" in one frame - the game's own garage
  exit (an advanced save's exit travels by itself to the planned junction: the host's, mapsync copies the plan)
  and the mod's Run.join, called because the drive-through volume check saw the car in the exit at the same time;
  "Tried to perform concurrent save/load operation on top of LOADING LEVEL". Now the exit's DoLevelTransition
  hook marks the game's own travel; the volume check waits 1.2 s for it; after it the mod does not join (still in
  the garage 3 s later - a new game's exit only opens the map - it joins as before). Not reproduced in a test: the
  test guests are new games (their exits never travel).
- The going-home crash (open since alpha 19): caught. startflow's late join (the guest goes home) crashed 2 of 3 runs
  that day; the light trace's last line was statesync's frame loop (statesync.lua:53) right after the guest's arrival
  in its garage, nothing after it in either Lua state. That loop looked at the world name every 30th frame only, and
  playersync's frame / apply loops not at all (only its send loop did): for some frames they ran in the new world on
  the old zone's freed objects (twins, puppet, hazards, doors). Now Sync.worldAddr() (the game instance's world's
  address: cheap, and a zone reloaded from a save keeps its name but not its address) every call of every sync loop
  (statesync frame, playersync send / apply / frame, the import / cleanup jobs). startflow 4/4 since, no crash.
- Items 1-3 (UI): the Co-op checklist 36 under the driver's (12); no ping in it nor in the pause menu (each ping
  change rebuilt the list, and the rebuild took the driver's checklist out of our wrap and back - it folded and
  unfolded; now a rebuild replaces only our box). Pause menu: the rows that do nothing are text headers in our
  column again, in their place among the buttons (dimmed, centred), not the side text of alpha 19. menu-test,
  startflow checks.
- Item 7 (wipers): twin-ctl only checked host -> guest; it checks guest -> host now too. Likely the extra car of
  item 6 (the guest's poses from its other car), to be seen in the owner's next test.
- Item 13 (back exit opens both doors): on the exiting side the game's exit opens the twin's driver door (its walk-out
  animation's door) while the owner's pose opens the back one. TD.twinDoorReconcile now poses door 1 shut
  TD.EXIT_DOOR_MS (400) after it starts simulating while the player sits / just got out on a back seat and the owner's
  door 1 is shut. Tried: shut at once - no walk-out (the player jumped out); shut once the game let go
  (TD.passengerExit) - the door stood wide open ~1 s. cars-test step 5 samples the guest's twin door 1 (at most 6
  samples over 20 degrees): 34/34. Quick suite before it: cars / contact / collide single flakes (cars 33/33 alone).
- Item 17 (kick damage): the player's health is the game instance's BP_ResourceManager_C.PlayerHealth (UGameResource:
  Current / Maximum = 100; not on the pawn). A MSG_Damage_Physical_Impact did nothing while the pawn's
  AC_PlayerHealthReceiverHelper.playerProtected was true (10+ min in one probe, cause unknown; later false and the
  message took 10). `PlayerHealth:Adjust(instigator, -amount)` takes it always: kicked() adjusts by TD.KICK_DMG (1 %)
  of Maximum (status kick_health). contact-test step 5 checks 100 -> 99.
- Item 16 (wreck paint): reproduced - host 39 abandoned cars in 13 palettes, the guest 26 of 33 in
  BP_Palette_Paint_Crafted_01 and no dynamic materials (the mesh's MI_CivCar_Metal_Painted_Rust): the guest's
  BP_Template_BaseVehicle_C never ran SetupMaterials. Setting SelectedPaintPalette (+ decal) and calling
  SetupMaterials + SetupTintOnVehicleAndParts gives the host's colours (Color1 equal). statesync CoopSyncPaint: VP
  lines (place / paint / decal class) host -> guest 3 s after the start, then every 20 s; the guest matches by place
  (150). New paint-test.ps1 (quick suite): 39/39 same.
- Item 14 (taken seat's door): three filters hid every door of a taken seat (doorBlocked on K2_ShouldHighlight, the
  reach filter, catShow). The game itself gets in by the driver's door only - back / passenger doors it just opens,
  the mod's entry there (TD.ownEnter / TD.twinEnter) already refuses a taken seat - so the filters keep only door 1.
  Tried for door 1: GiveUpTryingToEnter after the E (20-600 ms) - the player got in anyway. contact-test step 3b: the
  guest on the host's seat 3, the host's door 3 highlighted (its slot spot), E opens it, the host stays out
  (own_enter=3:player).
- Item 4 (junction details differ) / 15 (the guest's own radiation event): mapsync never copied the legs' soft
  class pools (BP_LegStateBase_C CurrentHazardPoolClasses / CurrentBoonPoolClasses / CurrentGameplayEventPool) - the
  junction panel's logbook entries; in the lobby the guest's L5 had 0 boons (host 2) and GEV_WindSquall (host
  GEV_MachineMalfunction). Read: KismetSystemLibrary Conv_SoftClassReferenceToString(e:get()); written:
  arr:Empty(), arr[i] = Conv_SoftClassPathToSoftClassRef(MakeSoftClassPath(path)) (probed). Now P rows (leg, field,
  paths) in the export, applied after the modifiers. mapsync-test compares all rows: 10/10 (one run before failed step
  2 on L rows only - timing, rerun PASS). Item 15 is likely this (the event pool of the guest's leg) - not proven.
- Note: the Bash tool collapses a doubled backslash inside heredocs - Python edit scripts use chr(92).
- Quick suite after items 13 / 14 / 16 / 17 / 4 (2026-11-04): reruns alone - anchor, mapsync, gates, cars pass.
  gates' first run: the guest's game died in the zone cleanup (a Lua UFunction call in a game-thread loop; state
  "zone: cleaning", statesync stopped then - not the new paint lines); not seen again. portal (2 extra portals at
  0,0 on the guest) and runover's lid check fail as at alpha 19 (open). anchor-test's barrel probe skips a barrel
  with no fuel component (the guest's broken copy gave "nullptr" for all three checks; reported as no-fuel-component).
- collide-test: step 1 failed 3 runs in a row (host stopped "as by a wall", the guest's car barely pushed). Not the
  mod: the test's second `aim` teleported the host's car near the guest's - its twin glided there on the guest's side,
  the guest read that as a hit (BI) and the host was then held to that shared speed (~3 m/s) for a second, so it came
  in at 3 m/s instead of 15. Now the gas is pressed again before the launch and the launch is a new probe op `launch`
  (velocity only, no teleport); peakget times after= from this side's own hit first. 9/9. (Waking the car's
  VehicleControllerComponent in `aim` - SetParkingBrakeActive / Wake - crashed the host's game once: dropped.)
- Item 9 (the ARC map's compass): the ARC is BP_Gobbler; its map views (BP_GobblerMapview MapView, fixed 90) were the
  same on both sides. The difference is the north: Wilderness zones pick a random one (BP_ToDManager_C
  RandomizeNorth(bAlsoSetTOD): DataBlock_IsUsingRandomNorth / DataBlock_PickedRandomNorth -> CurrentTrueNorth,
  "Current North As Rotator", the ToD actor's yaw). In Wilderness_Swamp_14 the host had picked 180, the guest's
  manager nothing (the zone save does not carry the manager's data block); Rural zones pick none. RandomizeNorth with
  a pick already in the data block uses it (probed: 90 -> 90). weathersync's W line carries the north now
  ("<random>,<pick yaw>,<yaw in use>"); the guest copies the data block and runs RandomizeNorth(true) (else
  SetTrueNorth + the ToD actor's yaw) when its yaw is off by > 0.5 (status north=<n>). range-test checks it (the
  test save's load leaves the host's pick unapplied: the test applies it first).
- Items 10 / 15 (anomaly clouds at different places on the map; the guest's own radiation event): the cloud on the
  map is a BP_LocationalEvent_C - the cloud of a gameplay event (GEV_BaseGameplayEvent_C, a status effect on the
  BP_GameplayEventDirector_C's event item; the director's CurrentEvent stays empty) that drifts from a random start
  (StartLoc, MoveDirecton, MoveSpeed, SizeOfEvent; its MapIcon). Each game's director rolled its own events, the class
  is in no spawn list: in Wilderness_Swamp_14 the host was in a GEV_WindSquall, the guest in none (or its own
  GEV_RadSpotSpawn - likely item 15's "high radiation"). Now statesync CoopSyncEvent: the host sends its live events
  every 2 s (GE: id, class, the cloud's place / start / way / speed / size); the guest's director rolls none
  (ForceNoEvents, back to false in weathersync.release), the guest starts the host's main event (the one with a cloud)
  once per host event (Internal_StartNewEvent with the class - LoadAsset of "<path>.<name>" first), finds its copy by
  class, gives its cloud the host's values and place (moved when > 300 off) and ends its other events. Probed: an
  ended event stays a while (its cloud InWindDown; IsRemoved false) - live() skips those; ClearCurrentEvent ends
  nothing; RemoveFrom sometimes nothing; UStatusEffectLibrary.Remove(event) at once; a new Internal_StartNewEvent ends
  the director's last event (so one copy: a GEV_HeavyFog alongside the squall has no cloud, its fog comes with the
  weather lines). range-test checks it (no guest event the host lacks, the cloud within 15 m).

- Item 11 (a pillar anomaly on the guest the host has not, 2026-11-04). The pillar is BP_Hazard_Bollard_C (mesh
  SM_bollardPillar). Hazard lists of a swamp pair (scratchpad hzlist.lua) right after the join: 160 guest hazards at
  0,0,0 (the import cleanup's destroyed ones, parked by their pools and gone a little later); after that the two lists
  were the same (230 = 230, position within 3 m). The import cleanup removes the guest's own roots only once. Any
  hazard the guest's game spawns later stays, for example from an event's copy (GE), a spawner or a helper waking up.
  New: statesync CoopSyncStray (guest). Every 3 s, FindAllOf("BP_Base_Hazard_C") (~2 ms; a full root collect is
  ~16 ms, and the guest keeps no root scan of its own). A hazard is destroyed when it has been unmapped for 6 s:
  in the persistent level, a root, not pooled, a replicated class, and not a value of CoopSyncMap (every writer:
  the import, the repair after the cleanup, S, a respawn), reverse or CoopSyncKeep. Counter stray_hazard. A first
  version that checked only reverse left the tourist step of range-test broken, with one hazard fewer on the guest.
  range-test plants a bollard on the guest and requires it gone and the BP_Hazard* counts per class the same (11/11).
  Seen alongside: the host had a BP_Boon_LootCreature_C the guest had not (not a replicated class) - open.
- Item 12 (the dashboard readings differ), probed 2026-11-04 on a twin-ctl -Keep pair (scratchpad dashtext.lua,
  dashprops.lua):
  - The dash widgets are UMG_CarBatteryBar_C (on the LimBox part, BatteryWidget), UMG_CarComputer_C and
    UMG_CarHealthBar_C (on BP_PlayerCar_Computer_C: ReceiveTick -> UpdateHealthBar / UpdateMaterialWithWidgetData)
    and UMG_StatusBox_C. Each car, the twin included, has its own.
  - The texts never changed in the test instances: the battery bar's CurrentText stayed 8.8 on both cars and both
    sides, and so did the computer's OverallText. The host's battery and health were changed through the parts'
    components (ownerState), and the guest's own batteries were set to 0.2. So the source of the readings (the
    twin's own parts or the manager's car) is not measurable without a graphics run - open.
- Quick suite after item 11 (2026-11-04). Failed: range (saw step), anomaly, mapsync and cars.
  - Rerun alone, range and anomaly pass.
  - anomaly's host had an error "statesync.lua:722 CoopSyncMap nil". HZ.frame took `role == "host" and
    Sync.deref(key) or resolve(key)`: with a host hazard gone, deref gives nil and the host fell through to
    resolve (the guest's map, nil there). Now hzActor(key). anomaly 9/9.
  - mapsync step 2 failed twice in a row. The second map applied may be one the host sent before its scans were
    in. The test now compares the rows until they match, 30 s at most. 10/10.
  - cars: the seating steps are flaky; 34/34 alone.
- Item 8 (the guest's hood fell off and hung in the air while driving; alpha 18 item 9 the same on the host),
  2026-11-04. On a cars-test -SetupOnly pair (scratchpad hood.lua / doorsim.lua), the TWIN's hood on both sides
  simulated physics with nobody at it: its MainMesh was detached from its door root and lay 340 in front of the car
  (guest) or 380 behind it (host), pitch 18. It is held near the car by its constraint, so it moves along with it.
  The own cars' hoods and all twin doors 1-5 were fine. AttemptShut on the twin hood changed nothing. What turns it
  on was not found (it was already so right after the setup). TD.twinDoorReconcile, which puts back a twin door that
  simulates while its owner's is shut, went over doors 1-5 only. It covers the hood (6) now. The mirror-open for the
  owner (AttemptOpen here) stays doors 1-5: the owner's open hood comes by its pose (cars-test 1b). Put back by hand,
  it stayed in place 20 s. cars-test 0b checks the hood on both twins, and step 9 checks the host's twin again
  after the guest drove: 37/37.
- Item 18 (a car still drives through the player), 2026-11-04. On the walker's side the twin follows its owner's
  poses, so it sees the car late. Its knock then reaches the driver in the walker's own moves, after the puppet's
  INTERP_MS. On the driver's screen the car had passed through the puppet before it flew: about 0.3-0.4 s, or 4-5 m
  at 13 m/s. The tests only ever checked the walker's side.
  - New TD.RUN.drive (every frame). The side whose player sits in a car that simulates here watches the other's
    puppet on foot: Twin.ownCar(), localCar() or the other's car (the guest's localCar() is the host's car in
    own-car mode, so a first version missed the guest's own car). The box and lead are the walker's, with the car's
    real velocity.
  - On a hit:
    - The puppet is thrown at once: RUN.knock, a ballistic throw along the push in puppetFrame for KNOCK_S 0.8 s,
      then eased back to the stream over 0.4 s.
    - The car keeps CAR_KEEP 0.9 of its speed.
    - RO <push x,y,z> <dmg> <speed> goes to the walker, and TD.RUN.hit takes it as its hit (launch, ignore the
      cars FREE_MS, damage).
  - One cool-down covers both the walker's own watch and RO. The counters are drove_over, by_driver and late.
  - In the tests (one PC, ~80 ms transport) the walker's own watch still fired first: its speed reads ~1.6x, so the
    lead is longer. The RO then came late. The driver's puppet moved 320-330 within 0.3 s of its hit.
  - runover-test checks the driver's side both ways: 8/8.
- Quick suite after items 8 / 18 (2026-11-04), 32 tests. Failed:
  - portal: extra 0,0 portals on the guest, known and open.
  - range: the saw-step sway, known flake.
  - runover: the lid check, known and open since alpha 19. The guest stood 780 off the lid and the lid opened only
    32 degrees. The new driver checks passed, both in the suite and in the rerun.
  - collide, twice: the striker came in at 46-195 cm/s, the test spot's flake. collide-test -Keep then passed 9/9
    with drove_over=0 on both sides, so TD.RUN.drive does not fire between two cars.
  - contact: 12/12 alone.
  - cars: the host's car lost door 1 between steps 1 and 7, and the seating steps after it failed. Alone it passed
    37/37, so not reproduced. Watch for it in the full suite.
- Item 12 (the dashboard readings differ), 2026-11-04 with graphics (COOPTEST_GRAPHICS=1, cars-test -SetupOnly).
  - What the dash reads:
    - With graphics the dash widgets update. In headless runs they never draw, so the widget-ticked digits stay at
      their 8.8 default.
    - Both cars' dashes read THIS side's car. The guest's own charge 0.4 showed on its twin of the host's car (35
      there), even while the guest sat in it.
    - The battery bar (BP_CarPart_Internal_LimBox_C ReceiveTick -> TargetBattery) and its digit widgets
      (UMG_BatteryCurrentDisplay_C / MaxDisplay, own script Tick -> TargetBattery / CurrentText) read
      BP_ResourceManager_C.CarLim.
    - The computer's health bar (BP_PlayerCar_Computer_C ReceiveTick -> UpdateHealthBar) and its overall status
      text (UMG_CarComputer_C Tick -> CheckOverallHealthStatus) read BP_ResourceManager_C.CarHealth.
    - The part icons (UMG_CarComputer_Part_C in the computer widget's ChildrenArray) hold the manager's car's
      items (ItemInstance via Native_GetItemInstanceEquippedInSlot). The twin's 22 icons showed the own car's parts.
  - Fix (twincar):
    - The owner's pose line carries "DB=<LimBox CurrentBattery>/<CurrentMaxBattery>/<CarHealth>", before WT.
    - The twin side's applyDash (from applyPose; values at most once a second unless they change):
      - turns off the twin's LimBox and computer actor ticks and the digit widgets' script Tick
        (bHasScriptImplementedTick = false: it holds; setting TargetBattery alone was undone every frame);
      - sets the LimBox's values, SetupBatteryBar (on a max change), ChangeCurrentBattery and the digits' text
        (FText, the game's decimal separator taken from the own car's digits);
      - sets the health bar with UpdateCurrentHealth and calls UpdateMaterialWithWidgetData;
      - points each part icon at the twin's item of its slot (Gameplay Tag -> the twin container's slot) and calls
        ItemHealthChanged(0), once a second (an own-car part change can put the own item back meanwhile).
    - The screens stay lit with the ticks off (screenshot local/dash-guest-twin.png: the guest at the host car's
      wheel).
  - Not done: the computer's overall status text and its clock still come from this side. The game times differ
    between the two (the dash clocks read 08:42 vs 08:35).
  - cars-test step 0c (cmds/dash-read.lua):
    - The guest's batteries go to 0.2 and its back seat loses 60 health.
    - On the host's twin the digits must read the guest's charge (0.4, the host's own 35) and the back seat's icon
      the twin's own part at the guest's 0.70.
    - 39/39.
- Quick suite after item 12 (2026-11-04 evening), 31 tests.
  - Passed: portal, range and runover this time (4/4, 11/11, 8/8).
  - interact: LOOT FAIL on a client-only wheel after the bot's DETACH, the known flake.
  - collide: the spot flake again.
  - contact 10/12, then 12/12 in a contact + cars rerun.
  - cars 30/39:
    - The host's car lost door 1 between steps 1 and 7 again: the second time in the suite, never alone.
    - Suspect the test: step 4 teleports the host's car home after its drive, maybe with door 1 still simulating
      open from the step-1 exit. Not proven.
  - The contact + cars rerun: cars 35/39, with different failures, steps 9 (the guest's car moved 148) and 10
    (the host ended on the driver's seat and drove from it). errors=0 on both sides.
  - Alone, cars passed 39/39 with step 0c.
  - cars in a sequence is the weak spot to watch in the full suite.
- cars-test in a sequence (2026-11-05): 8 contact + cars runs. 5 passed 39/39; the 3 failures were the test's.
  - Step 10: the host's aim at its own back door missed ("aimed back door: nil"). The guest had driven the host's
    car off in step 8 onto uneven ground. The car now goes back to the step-4 home spot first; the step's other two
    failures followed from the miss (the host never got in, so "no driving" read the bot's raw throttle).
  - Step 8: the guest got out 560 from the host's car, against a limit of 500. The game's exit takes the first free
    of its exit points. The limit is 700 now.
  - Step 4: the host's doors are shut before it drives. The bot's way in leaves the driver's door as the step-1 exit
    left it, and an open door breaks off while driving (the game's own). This is the likely cause of the lost door 1
    in the two suite runs, not proven: it did not happen in these 8 runs ("none were open" each time). The host's
    doors are printed after every step now, and before the step-4 teleport.
  - Step 9 (the guest's car moved 5): not seen again. The step prints the car's state now (physics, the
    controller's tick, ignition, lever, charge, context car). It was normal in every run.

## Alpha 20 built (2026-11-05)
`local\release\PacificDriveCoop-0.1.0-alpha20.zip` (8.7 MB, install-test 10/10, symbols in local\release\symbols).
The full suite (63 tests) the night before:
- Reruns passed: range, runover, gates, cars 39/39.
- cars 8b: the host's aim at the guest car's driver's door missed ("highlighted: nil") - the same kind as step 10.
  The step now tries a second spot.
- portal (extra 0,0 portals) and collide (the test spot): known.
- guest and leg-seated: "extra on client" right after the test's own import + cleanup.
  - The guest holds a second copy of most host classes (signs, cones, rocks, wrecks: 160-1535 actors). In
    leg-seated the live check 20 s after the sync starts reads 0 extra.
  - Not an alpha 20 regression: guest-test with alpha 19's Scripts deployed fails the same way (extra 160).
  - Open, test side: the cleanup the test calls leaves them; the live sync removes them.
  - cmds/snapshot.lua now skips actors with no root component (destroyed ones waiting for the GC passed both
    IsValid checks). That changed nothing here.
- Two guest crashes, neither reproduced in the reruns:
  - leg-seated, the guest following the host to the next leg: a Fatal error in the engine's async loading thread,
    "Could not find SuperStruct BP_Hazard_Movement_Prong_C to create BP_Hazard_Movement_Prong_AnchorSpawn_C".
    Not in the mod's Lua; first seen.
  - gates, state "zone: cleaning": an AV at 0x8 in a UFunction call from a Lua delayed action (UE4SS
    process_delayed_actions -> call_ufunction_from_lua), the known freed-object family seen in gates once before.
  - Dumps: local/reports/suite-a20-crashes.
- CHANGELOG lists both under "Known issues", with the dash's overall status text / clock.

## The texts: one file per language (2026-11-07, owner)
The owner asked for a proper localization layout instead of Russian texts as keys in loc.lua. Now:
`mod/CoopSync/Scripts/lang/<code>.lua` returns `{ [key] = text }` (68 keys: common.*, cl.* checklist, menu.*,
dbg.*, panel.*, sess.*, tp.*); `en.lua` is the reference, `ru.lua` is kept complete (the tests run with
COOPSYNC_LANG=ru and press rows by their Russian labels, unchanged). `loc.lua`: `L(key, ...)` = the current
language's text, else English, else the key; with arguments `string.format` (a translation with broken %-codes
falls back to the English format). Language = the game's language/culture lower-cased: `lang/<full>.lua`
("pt-br"), else `lang/<language>.lua`, else en; COOPSYNC_LANG / CoopSyncLang force any code. Joined texts became
format strings ("Приглашение от %s — принять", "в зоне %s", "нечего синхронизировать (%s)"). menu.press accepts a key
or a label prefix. `loc-check.ps1` (via lua-lint): every L("key") in en.lua, other files only known keys with the
same %-codes in order, missing keys listed (an error only for ru.lua), unused en keys listed, no Cyrillic in code
outside lang/ (it is ASCII-only now: Ѐ-ӿ; the CI runner's ANSI code page broke the old literal range).
build-alpha and deploy copy `Scripts\lang\`; lua-lint covers it. Checked offline (lua54: ru, ru-RU, en-US, de-DE ->
en, pt_BR -> en, "../x" -> en) and in game: menu, f7, esc, startflow, session-net.

## The owner's alpha 20 test (2026-11-07, host = owner, guest = friend, real Steam link)
Reports: local/reports/a20-owner (r1 = guest, r2 = host; ping 13 ms, guest ~50 fps steady, mod 2-4 ms a frame; the
crash dumps in them are old ones). The owner's list, and what was found / done:
1. Map instability spots around the junctions differ. mapsync copied each leg's Instability, but the map's
   UMG_RouteShape_Static_Instability draws only on the route's OnInstabilityUpdated (and its Construct): applyRows now
   calls route:OnInstabilityUpdated() and UpdateInstabilityMaterial on the live widgets. Not seen with graphics yet.
2. At the start the guest's junction map stayed open through the load and was open again in the zone; at the zone's
   exit it got the map again, picked a junction of its own, and the two split (host leg 92 = Wilderness_Forest_22,
   the guest's leg 92 = Scylla_02). Causes, from the game logs:
   - Run.join pointed EVERY next leg of every route state at the host's map and called TravelToNextLeg: it travelled
     once per route state, five "Traveling to level" in one frame (legs 1, 10, 13, 26, 60; "concurrent save/load on
     top of LOADING LEVEL"), the route's current leg left at the last one; the guest's later junctions all led back to
     the host's first zone.
   - The map opens a moment AFTER DoLevelTransition (the post-hook's CloseMapUI came too early); at a zone exit gate
     the guest's DoLevelTransition hook did not fire at all (nextzone-test), only "Open Map UI".
   - In own-car mode the guest never followed the host (playersync: the host's L line = split).
   Now: the descriptor's 5th field is the host's leg (its RouteShapeLeg name); Run.travelTo finds the same leg in the
   guest's routes (WorldState first; the maps are the host's: mapsync), sets the host's MapLocation on that one leg
   only if it differs, and does ONE BaseRouteState:TravelTo (join and follow). session: "Open Map UI" post-hook +
   tick close the map while the guest drives out / arrives (mapGuard); the map opening with the guest's car in an
   open zone exit gate (or the gate's DoLevelTransition) = the guest at the exit: state "zone: at the exit", screen
   dark, followPending; when the host's descriptor changes and the host is in another world: Run.follow (one travel).
   Out of the gate for 4 s or 300 s: back to playing. Status: exitmap=<maps closed>/<zone exits>/<follows>,
   travels=<mod's travels>. Probed: CloseMapUI closes it, the game does not open it again while the car stays.
   Exit PORTALS are the exits home (Select Exit Portal Actor + the car in it -> the garage), not next junctions.
   Tests: startflow TravelCheck (one "Traveling to level" per drive-out in the guest's game log, no "concurrent", no
   map open); new nextzone-test.ps1 (advanced save pair, lobby, drive-out, the guest first into the zone exit gate,
   then the host picks: the same zone, the same leg, one travel more, no map, both cars).
3. The other's car jerks. The twin seen from outside was moved by the apply loop (30 Hz) toward a sample extrapolated
   along its velocity, pulled back at each new sample (10 Hz): now every frame in TD.twinFrame with the time-scaled
   smoothing the driver's view had (TD.OUTSIDE_EVERY_FRAME). Collisions to check (collide / contact / runover).
4. A door the guest took off and threw down stood in the air on the host and jumped on the guest: the host's DROP
   world item (SpawnItemActor) did not simulate; now SetSimulatePhysics + WakeAllRigidBodies.
5. No getting onto a back seat without its door: TD.twinEnter / TD.ownEnter refused without a door actor; now in
   through the doorway (seat socket aimed, the context car, CommandEnterCar without a door, teleport as fallback).
6. Wreck paint all orange-blue on the guest again: VP was applied once per place; now again whenever that wreck has
   no DynamicMaterialInstances (ap_VP_again / ap_VP_no_mid counters). Not verified with graphics.
7/9. Door chaos: a twin door's OnConstraintBroken handler destroys the OWN car's door of that number; it was muted
   only with a full pose once a second - a door just put on the twin (by the owner's line or by hand) had it. Now
   muted every 0.5 s in TD.equipTick and right after applyEquip. Item 7 (the host's door followed the guest's car in
   the air) is likely the extra car below (a second real copy) - not reproduced yet.
8. No putting on / taking off the driver's door while the other sat at that wheel: doorBlocked / catShow hid the door
   and its slot spot (K2_ShouldHighlight false). Now only their Highlight E handlers (open / get in) are parked while
   the seat is taken (twincar parkEntry, TD.entryPark at most once a second), the highlight and the taking off stay.
10. The light differed: nextzone-test compares cmds/light-read.lua (tod, north, suns, sky, fog) on both sides.
11. A tourist mine (BP_Hazard_Landmine_C) went off on the host only when the guest drove past: a guest claims a hazard
   only once its copy moved. HZ.handOver (host, every second): hazards within 4000 of the guest and nearer to it by
   HZ.MARGIN are granted to the guest at once (puppet here, HGRANT).
12. See 2.
Found on the way (open): "EXTRA CAR" on the guest right after the zone save's load (owner's log 00:11:01-00:11:11,
then "twin spawned ... cars now 2": gone by itself). Neither save carries a BP_PlayerCarNew_C (save-dump of
coop-host-zone.sav and the guest's departure save: none) - the game spawns the cars. In one nextzone run a second
guest car (not moving, at the guest's arrival place) stayed in the first zone the whole stay; in the next zone it
was clean. A first fix (remove any car that is not the manager's / a twin after the load) aimed at the wrong car (the
manager pointed at the other one right then) - taken out. nextzone-test checks cars=2/1 on both within a minute.
Light (item 10): the same on both sides in nextzone-test (tod equal, sun pitch/yaw equal, sun 2.02/2.01, sky
2.37/2.36, fog 0.2602/0.2614) - the sync holds; the owner's brighter / darker look is likely each PC's own graphics
(exposure, quality). nextzone-test: 13 of 16 at that run (the car check, the light check's strict compare - since
5 % -, the extra counter), the transitions all pass: one travel each, same leg RouteShapeLeg_1 / RouteShapeLeg_39.

## The owner's alpha 21 test (2026-11-08): findings

Host with an advanced save, guest (friend) with a new game; reports `local/reports/a21` (host side only; the crash
dumps in them are old, from October).
- **Garage map, fewer junctions at a new-game guest**: the leg rows were equal (mapsync-test diff 0 even with the
  owner's 2024 early save `local/advsave/early-garage.sav` as the guest), yet the map drew 20 junctions against the
  host's 42 and few roads. The drawing asks the player's own story: `BP_LegStateBase_C:ShouldBeVisibleOnMap` (through
  "Is Visible Via Adjacency", LegPassesWhitelist_* on the global whiteboard's progress) per junction, and each road
  widget `UMG_RouteShape_Edge_C` caches `CachedShouldRender` / `CachedIsOnMap` / `Render Mode` (its "Should Render
  Line" is not called again while the map is open). Tried and useless: copying RevealFlags / NavigateFlags (recomputed
  natively at every map opening), Max Reveal Depth / bAllowHighwayNavigation, ActiveElementCache, SetRouteState. Fix:
  the host's export adds `V <leg> <0|1>` (its ShouldBeVisibleOnMap) and `E <from>><to> <render> <onmap> <mode>` (its
  road widgets, once its map menu exists; the quick signature notices that); the guest returns the host's answer from a
  hook on ShouldBeVisibleOnMap and writes the road widgets' cached fields once a second while its map is open.
- **UE4SS: the first callback of RegisterHook is the one whose return value / out-param counts** (it runs after the
  body - "pre-hook = after body"); logic put in the second one never changed anything (counters stayed 0).
- **Guest departing from the map**: hovering a junction and holding the button ran TravelTo on the guest (traced,
  the loading screen came) - the click unbinding misses the hold. `UMG_PlayerMenu_RunMap_C:CanTravelHovered` ->
  false for a guest in the garage; `UMG_RouteShape_Leg_C:CanReveal` / `CanRevealAndHasCharge` -> false (no scan marks).
- **Pause menu stuck after leaving the lobby**: reproduced (esc-test step 5): the co-op pause had lifted the pause;
  once the session ends the game's Esc / Continue do nothing in an unpaused world under an open menu. Fix: on the
  session's end with the pause menu open, `SetGamePaused(true)` (session keepRunning).
- **Own back seat in the garage** (items 1-3): the garage start is native for the host only; the host's back-door tap
  seated it, but the seat bookkeeping (TD.seatNow, the exit spot, the seat socket back) ran in the zone send tick only
  - so all controls, the driver's exit, and the next entry on that back seat; the guest (not native) got no entry at
  all. Fix: TD.garageSeat from the garage send tick, the reach rules and the back-door press in the garage for both.
  garage-seat-test 10/10 (both roles; the advanced car's back right fuel tank taken off for it).
- **Anchor in both hands**: a stable anchor (`BP_Spawn_Anchor_Stable_S/M/L_C`, Wilderness_Forest_15 =
  `advsave/forest15.sav`) - "Long Grab Complete" on the other side hands nobody an item (near or far). A real hold-E
  grab was not reached in a test (aiming at the pedestal's anchor failed: the bounds are the whole pole); the player's
  carried item is `PDP_MainCharacter_C.CurrentPickedUpItem`; `p["Exit Car"](p, false, true)` gets a test player out.
  Open.
- **ARC map north**: the Gobbler map (`BP_GobblerMapview_C`, its camera `MinimapInternal_Camera_C`) had equal values
  on both sides in range-test (actor yaw 90 both, north 180 synced). The owner's two ARC maps were turned 90 degrees
  against each other. Open.
- Quick suite after the alpha 22 fixes (2026-11-08): new mapsync 13/13, garage-seat 10/10, esc 7/7. startflow /
  nextzone: the guest travelled twice - Run.travelTo's rs:TravelTo failed with "StrProperty can only be set to a
  string ... TravelTo:ReturnValue" (the Lua stack holding booleans): the new guest-map hooks (ShouldBeVisibleOnMap
  returns a value) ran inside that call and broke its return; the join's pcall failed, JOIN_RETRY_S joined again.
  Now CoopSyncTravelling is set around the mod's TravelTo and guestInGarage() is false then. Alone: startflow 30/30,
  range 10/10 (saw in step, flaky in the suite), cars 38/39 (step 9 moved 290 of 300, the known flake), nextzone
  14/16 (only the known extra guest car after the zone load).
- **ARC map north (alpha 21 item 6), 2026-11-08**: the ARC view `BP_GobblerMapview_C` (its `MapView` a
  MapViewComponent, relative rotation 0) gets its yaw from the north once, at spawn (Rocky_07: north 180 -> yaw -90;
  a north set later, as range-test does, leaves it at 90). The guest's spawned with its own north before the W lines
  set the host's: the earlier checks compared the ToD north only. W now carries the host's view yaw and its world
  (fields 18 / 19); the guest turns its views (this world's only - the last world's stay IsValid till the GC) to that
  yaw, and skips north / view for a line of another world (seen: the guest still in the old zone took the host's
  next zone's north 180). Status weather=sent/applied/<north>:<sets>; north and view sets go to hitches.log.
  light-read.lua read CurrentTrueNorth (a vector) as a number: north / todyaw were never read - fixed, + arcyaw.
  nextzone-test: north + view equal in both zones, the guest's view turned 90 comes back (17/19: the known extra
  car, sun intensity 5.5 %). range 11/11, mapsync 13/13, session 11/11.
- **The report's channel tails were stale**: the in-game network does not write host.fast & co; the owner's alpha 21
  report carried a host.fast from 2026-10-24 (no north field) - a false lead. collect-report now leaves out a tail
  older than 12 h (noted in info.txt).
- Found on the way (open): a guest left in the old zone (the test sent the host through another gate; the guest's
  "left the zone's exit: playing on") applied the host's next zone's events there (528 at once, a twin at the new
  zone's spot) and crashed ~10 s later (ProcessEvent from a Lua loop). The guest should not apply another world's
  lines.
- **Fixed (2026-11-08)**: the guest's sync loops stopped only on the guest's own world change, never on the host's.
  Now clientTick: playing / at the exit and host-session's world not this one for 2 ticks (1 s; the host writes
  world=- the moment it leaves, long before its next zone's lines) -> State.stopped + Players.stop (the guest stops
  sending too, so the host's new zone gets no old-zone lines either), S.hostAway, note "sync stopped". The host's
  world here again with the same import -> the sync starts again. A guest left behind drives into an exit later: its
  followFrom is empty, so the host's current descriptor is followed (before, followFrom = the host's already-new
  descriptor: it would never follow). `staybehind-test.ps1`: 7/7 on the rerun; the first run's guest crashed in the
  engine's async loading thread on the late follow ("Missing Dependency ... BP_Spawn_GasBarrel_C ... hasn't been
  created yet", "Could not find SuperStruct") - the same family as the leg-seated crash above; no Lua ran in that
  frame (the whole LoadMap was frame 998). 0 "Missing Dependency" in the other 20 logs of the day. Open, engine side.
- **The other's car jerked, seen from outside (owner's alpha 21 test, "a few updates a second")**: predicted() took
  the sample's age as nowMs() - time, the time being the SENDER's wall clock. Two PCs' clocks differ by up to
  seconds: the age was 0 (no prediction: the twin stood and jumped to each 10 Hz sample) or the 0.3 s cap. One PC's
  tests share the clock, never saw it. Now M.withVelocity keeps the smallest receive-minus-send of the last 2 s
  (as TD.carSample) and the age is taken against that. `twin-outside-test.ps1` (CoopPlayers.testClockSkew on the
  guest; the host drives, the guest on foot): the old age jerk 0.63 / 0.76 at +1500 / -1500 ms, the fix 0.11-0.14.
  (The first try of the fix added a main-chunk local: playersync went over Lua's 200 locals - deploy's lua-lint
  refused to copy; such state goes into TD.)
- **The other's puppet outside by the driver's door (owner's alpha 21 test)**: measureDriverSeat (the seat geometry
  for the other's puppet, from the own player at the wheel, once) took the first frame the pawn is attached to the
  car. The game's own entry (native cars) attaches it at the door: `seat-measure-test.ps1` - the first attached
  frame at rel 113,-131, seated 46,-46. Now taken only inside the cabin (|Y| < 80, |X| < 250) and still for 1 s.
- **Quick suite after these (2026-11-08)**: all pass but nextzone (sun 5 %, known), contact (passed 12/12 alone),
  cars: 'the guest's own car drives after all that' moved 8 / 14 - and 5 with this round's Lua reverted (control
  run, also back-seat checks failing there): an older flake, not from these changes; open.
- **The instability storm on the host only (owner's alpha 21 test: "at an unstable junction my siren started and the
  instability came, my friend's not")**: BP_StormManager_C runs the instability timer on each side
  (TimeBeforeInstabilityStarts, ShouldTickInstability; 720 s in Wilderness_Forest_13/14 from the advanced save, false
  near the garage / on the story's Rural_Forest_Radio map) and at its end calls SpawnRoyaleStorm(location, fromTimer,
  gateway) -> BP_ZoneStormRoyale_C (walls, its WeakStormOverrideValue timeline darkens the sky) and
  ChangeStormTimerState (the ARC's state, 0 none ... 3). Not reproduced by the natural timer in the tests (it did not
  tick even with DbgActEvt_EnableNewInstabilityTimer); SpawnRoyaleStorm by hand on the host: storm there, none on
  the guest. A second SpawnRoyaleStorm while one is up does nothing. A pre-hook (= after the body) on both functions
  sees the arguments. Fix: statesync CoopSyncStorm - host sends `STORM x,y,z fromTimer gatewayKey` / `STST n` at the
  call and every 10 s; the guest spawns the storm with its manager when it has none, sets the state (quiet: no echo).
  Status field `storm=sent/done/have`. `instability-test.ps1` (the staybehind lobby + drive-out, then the host's
  state 2 + storm): same spot (75734,-40493 both), state 2 on both, the repeats reach the guest (have=2, done=1), one
  storm on the host. 6/6. (Test commands run in the coopdev mod's Lua state: package.loaded.statesync there is
  another, empty instance - read the session's status line instead.)
- **The guest's own timer first (owner: "the guest's storm must not start earlier")**: `cmds/storm-timer-probe.lua` (each
  call, the fields after it, the calls hooked meanwhile): the game calls InstabilityTimerTick all the time; with the
  timer on (OnPlayerLeaveStartingArea, SetupInstabilityTimer -> CalculateInstabilityTimer(leg)) the instability grows
  (IncrementStormInstability) and "Check Instability" calls SpawnInstabilityStorm once it is past
  FinalInstabilityTollerance (rolled with a variance per side). GetInstabilityTollerance reads that field;
  IncrementStormInstability takes negative steps. (SpawnInstabilityStorm by hand spawned nothing, even 12 s on.)
  Fix: the host sends `STI <instability> <tolerance>` every second; the guest takes the tolerance and holds its own
  instability at the host's, never within 2 % of the tolerance (also every 0.25 s on its own frames): its check never
  fires, the storm only from the host's STORM line; the ARC's instability is the host's. Status `storm=` gets a 4th
  field (holds). instability-test: guest tolerance 1000 -> the host's 60000, instability 3000 = host's; the guest's
  +100000 and a check 1.5 s later -> held back to 3000, no storm on either side; then the host's storm as before. 8/8.
  The exit pick's storm stays each side's own (both pick the same portal, EXIT).
- **The sun's strength 5 % off in nextzone (2026-11-08)**: in-game sampling on both games every 250 ms on the PC's clock
  (`light-sample.ps1`, os.time calibrated on its second change), paired by time: the fog and the sun swing over ~30 s
  (wind) and the guest followed 1-2 s behind - up to 10 % off side by side (W lines every SEND_MS = 2000). Also the
  old check read the two games seconds apart. Fix: SEND_MS 500; the nextzone check compares the paired samples over
  15 s (max <= 5 %): 0.7 % / 1.0 % in two runs. After an arrival the guest keeps its own sky until its sync starts
  (~1 min in a hand run: its own preset, tod 0.663 vs 0.690), then matches at once.
- Two hand-probe pairs crashed / closed: the guest in Rocky_07 70 s after a quick follow (engine tick AV, no Lua in the
  stack's top; after many storm probes on the host), and both games gone at once without a crash report (outside?).
  nextzone once: the guest's car left the exit gate while waiting (> 4 s out: "playing on"), then the host left and
  the stay-behind stop hid that note - now a hitch note says why the guest left the exit. The rerun passed the follow.

### Abandoned cars' parts: the guest's saw, the parts' damage (2026-11-09)
Owner: "on an abandoned car the friend could saw off the whole white bar of a part, the red one never started, so the
part could not be broken"; "the parts' breakage is not synced".
- A part's BP_HealthComponent_C: the health (the white bar), then, once it is zero, the break health (the red one:
  HC_GetBreakHealth / SetBreakHealth; more hits fill it up to the item's IP_Health MaxBreak, then the part breaks off -
  TakeDamage outputs Breaking / BecameBreaking / Broken, CheckDoCut / HandleCut) - only with the component's
  `CanBeBreaking` set. A damage message (MSG_Damage_Physical_Piercing_Scrapper etc.) dispatched to the part actor
  through the MessageSystem works; its effect shows on the next frame (`cmds/wreck-part-probe.lua`,
  `cmds/part-break-probe.lua` for car parts).
- Found: CanBeBreaking on the host's wreck parts 169/169, the guest's 0/169 - the guest's parts are the host's attached
  by lootsync applyTemplate (AttachTemplatePart), which never sets it up. Set by hand before the health ran out, the
  guest's red bar filled as the host's (3, 6, 9); set after the health reached zero it did nothing (the breaking starts
  at the zero). Also each side rolled its own health (a wheel 108 on the host, 10 on the guest) and saw only its own
  hits; a part broken off went already (the loot's part list).
- Fix (statesync CoopSyncWreck, in a do-block: the main chunk's locals): the guest sets CanBeBreaking on every wreck
  part at the start and every 10 s; a hit on a wreck part (hook on the component's "Process Damage Message": marks the
  part) sends `WPH <wreck key> <socket> <health> <break health>` on the next frames (while hit + 1 s), the other side
  sets its copy (SetHealth / SetBreakHealth; index by wreck address + socket, rebuilt at most every 5 s); the host
  sends every part's 3 s in and every 30 s (189 lines), a part this side hit in the last 3 s keeps its own.
- Test `part-break-test.ps1` (quick suite): guest 189/189 can break, the wreck's healths equal the host's; the guest
  saws a door past its health -> break health 5 on both; saws it off -> gone on both; the host saws a panel -> the
  guest's copy follows; no errors. 8/8.
- Seen on the way, not the owner's report: a part of the other's car (its twin) behaves the same - the white bar goes on
  the twin, the red never starts, the owner's next state line puts the health back (twin damage is the owner's
  business, stage B). Sawing the friend's car's parts would need the hit sent to the owner.

### Abandoned cars' paint: the parts (2026-11-09)

Owner, alpha 21 test: "all the guest's abandoned cars have the same orange-blue paint, for a long time". The VP sync
(alpha 19) gave the guest the host's palettes and the body's dynamic materials (paint-test checked only those), but
the parts kept their material's own orange-blue.

- Probed with `cmds/wreck-look.lua` (materials and colour parameters of a wreck's body and parts; WL_LOOK puts the
  player in front of it for a screenshot): the body was the same on both sides; the host's door material had 7 vector
  parameters (Palette_Paint_Color ...), the guest's none.
- How the game paints a part: `SetupTintOnVehicleAndParts` (locals show it) loops `GetAllTemplateParts` / the wreck's
  `AttachedParts` and sets the tint item property (GetItemProperties / SetItemProperty) of each part's item; the part's
  `BP_TintableComponent_C` (an ItemPropertyComponent) paints its meshes from it. On the guest `AttachedParts` is
  empty (lootsync attached the host's parts again). Filling `AttachedParts` and calling SetupMaterials /
  SetupTintOnVehicleAndParts / ReattachParts / K2_PostAttachItems, or the part's own SetupMaterials, did not paint.
- Fix: `CoopSyncPaint.paintParts` calls each attached part's tintable component `SetPaint(palette, {})` /
  `SetDecal(decal, {})` (2 params: the palette class, a ColorTag struct) once per part; a part attached later is
  painted on the host's next VP line (every 20 s).
- paint-test step 2: every wreck's parts have as many painted materials with the same Palette_Paint_Color on both
  sides (38/38, 30 with painted parts, `ap_VP_part`=223). Seen with graphics (COOPTEST_GRAPHICS=1): the same red
  CivCar and burnt-red stripped car on both screens.

### The guest's departure: a loading screen, the world paused, waits cut (2026-11-09)

Owner, alpha 21 test: the guest saw the junction map open and close, then a black screen under which it could still
walk, saw the items' highlights, heard the zone - anomalies attacked it while the two were joined; the join was slow.
"Only real work, no waits just in case"; "events from the host instead of waiting".

- **Timeline**: session.lua writes every change of state / game state / world into hitches.log
  (`N <time> timeline +<s in the previous one> <state> g=<gstate> <world>`), plus the map closes, the pause, the
  zone's first ready moment, the drive-out's waits. nextzone-test before (guest, gate -> playing, 2 min 3 s): 4 s
  exit wait, 42 s own zone, 38 s the host's zone load, 11 s "generating" after it (3 + 3 s fixed), 14 s import (4.5 s
  of work at 6 ms a frame), 10 s fixed before the cleanup, 4 s cleanup. The host: its zone ready **0.0 s** after
  arriving (both zones), yet published 27 s later (MIN_ZONE_S 25 + 6 ready ticks) - on the guest's path at the
  zone exit (the guest starts its own travel only when the host is in).
- **Cut**: MIN_ZONE_S 25 -> 0, READY_TICKS 6 -> 2 (startflow now checks "zone: generating" <= 10 s on the host);
  a zone loaded from the host's save is ready at the first zoneReady; the 2 s floor after UserLoadGame dropped (the
  new World object is the event); CLEANUP_AFTER_S 10 -> 3; the import / cleanup jobs take 40 ms a frame under the
  loading screen (spawnsync `M.sliceMs`, 6 while playing); the garage exit's fixed 3 s (the game's own travel?) is
  the TravelTo hook now (`S.gameTravelSeen`: the game's own travel shows in the exit's frame; none = our join).
  Second leg after it: host's zone in -> the guest playing 13 s after the host's zone save was loaded (import 3.5 s,
  cleanup 2.6 s).
- **Loading screen**: the game's own `/Game/UI/System/LoadingScreen.LoadingScreen_C` (PenDriverUI
  LoadingScreenUserWidget, "В ПУТИ..." with the car throbber) made by WidgetBlueprintLibrary:Create and
  AddToViewport(10000): over the HUD, the highlights and the junction map (the map opened under it - seen with
  graphics). Added again in each new world (the viewport's widgets go with the world). Raised at once in the exit's
  hooks (DoLevelTransition, Open Map UI) and when the guest's car is in the garage exit; the camera fade stays under
  it. Its CurrentStateText can be set (FText from UTF-8 works) but a long text is cut on the right: left as the
  game's own (localized).
- **Pause**: GameplayStatics:SetGamePaused on the guest while nothing of its world is needed (coverPause): its own
  generated zone while the host's save comes, the host's zone loading and importing, the zone exit waiting for the
  host's pick. Not in the garage, not while a zone the guest keeps generates (no host save), not after the import
  (3 s + cleanup, under the screen, input ignored). Probed: UE4SS loops (LoopInGameThreadWithDelay) run in a paused
  world; UserLoadGame from a paused world works and takes as long (32 s vs 32 s, two each); the new world comes
  unpaused (paused again on the next tick). keepRunning (the co-op pause's unpause) leaves this pause alone.
- **Not the host's zone**: the guest's world not the host's for 10 s under the screen -> the screen and the pause
  lifted (a note in the timeline). Seen in nextzone-test: when the host's junction (RouteShapeLeg_54) is a
  stabilizer zone (Rural_Forest_Stabilizer_Cerberus_05), the guest's travel with the host's MapLocation set
  (OverrideMapLocation) still loads its own roll (Wilderness_Swamp_04, Rural_Swamp_ZoneRepeater_Chimera_09). **Found and
  fixed** (same day): the host's descriptor was wrong, not the guest's travel. The host's leg kept its rolled
  MapLocation (MLoc_Wilderness_Swamp_12) while its game loaded the leg's chart override (CP_MapSettings,
  MapLocationOverride - the story's stabilizer, MLoc_Rural_Forest_Stabilizer_Cerberus_05_SR / _Q03), and Run.describe
  published the rolled one. Run.legMap(leg) = ProcessChartPropertiesForMapSelection's MapOverride when it is used, else
  the MapLocation; describe publishes it, zoneRoute matches MLoc_<world> or MLoc_<world>_*. One instance: a leg with
  no map given the stabilizer's _SR or _Q03 by OverrideMapLocation travels there (no SelectMapLocation at the travel).
  nextzone-test with the host on the stabilizer: 19/19. The timeline logs every travel (	imeline travel:, TravelTo:,
  the game choosing a leg's map); CoopSyncObjName(o) names objects for logs (IsValid first: GetFName on an unset
  MapLocation crashed a nextzone host). (Probing the leg states with FindAllOf("BaseLegState") + ShapeLeg:GetFName crashed the game twice -
  access violation in GetFName, a dead object: not catchable by pcall.)
- **Skipping the guest's own zone** (owner's question): a save made in the garage with the host's Map spliced in
  loads the garage again - the level comes from the run state the departure writes (META Level / MapLocation /
  ShapeLeg, global_states OutOnRun, the route manager's CurrentLeg, AllLegsVisited, TraveledEdges, ...; save-dump
  trees, garage vs departure save). Not done: with the host's 25 s gone, the own zone's load (~25 s at a zone exit)
  is now the biggest part of the guest's path.

### Fuel canisters on the ground (2026-11-10)
Owner: "I dropped a full canister, on the friend's side it was empty".
- A canister on the ground is `BP_WorldItem_Fuelable_C` (its `BP_FuelableComponent`, the same as a barrel's); the
  other side spawns it from its archetype (lootsync W|), which comes empty: the item's fuel is not in the loot string.
- Fix (statesync FUEL): the fuel list also holds the world canisters (refreshed at once after a pick-up / drop, the
  inventory manager's slot hooks); the guest's DROP carries the fuel (last field) and the host sets it on its spawn;
  a canister new in the host's list goes over at once; a FUEL for a guest copy still spawning waits (FUEL.pend, 30 s).
- Test `fuelcan-test.ps1` (sync-test setup): host puts one down with 3.5 -> guest 3.5; guest drops a carried one with
  1.75 -> host 1.75 (one DROP); the host's level to 0.5 -> guest 0.5.

### Fuel canisters inside containers (2026-11-10)
Owner: fuel level synced when a canister goes through a container.
- In a container a canister is only an item instance (no actor): its fuel is the item's IP_Fuelable property, and an
  item made on the other side from the archetype came with the archetype's fuel.
- Read: `BFL_ItemPropertyUtilityFns` CDO (/Game/Systems/ScriptingLibraries/) `GetFuelableInfo(inst, worldCtx, ...)`,
  out params one table each (`Fuel`, `Max Fuel`; Max Fuel 0 = no such property, remembered per archetype). Write: a
  `BP_FuelableComponent_C` constructed by us (outer the PlayerController), `SetItemInstance(inst, false)` +
  `"Set Fuel"(v)`, then pointed at nil - what a world canister's component does with its item. Works on a bare
  instance (fuelcan-test 4/5).
- lootsync: a container's item string carries the fuel - `<archetype>[{subs}]*<fuel>` (serContainer only; wreck
  parts' strings stay without it: their sockets compare by the string, each side's own fuel would rebuild the part);
  makeItem sets it. Archetype parsing strips it (`^([^{*]*)`: lootsync M.archOf, carstore, statesync itemBag /
  putsOf, playersync CT). Covers lootable containers, wreck trunks, the car storage, the guest's PUT (whole spec).
- Test `fuelcan-test.ps1` steps 4-5: the guest puts a canister with 1.37 into a crate -> host 1.37; the host puts
  one with 2.61 into the same crate -> guest 1.37,2.61. 5/5.

### Each car's own handling (2026-11-10)
Owner: "after we swapped cars the cars' characteristics swapped: my upgraded fast car, the friend's slow starting one
behaved the other way round".
- Every car's VehicleControllerComponent.Profile is one object, the asset
  `/Game/Characters/PlayerCar/TuningProfiles/MainTuningGraph` (UIWTuningGraph: FirstNode, 191 nodes shared within
  it, BlendValue / BlendValueMulti on CarHandling_Less/More, EnginePower_Less/More, Slomo).
- AC_CarHandling (each car has one) writes ~38 parameters every tick (IWTuningGraph SetParameter, hooked): engine
  quality / power / damage, CarHandling_*, the tires' Wheel* kinds, FlatTire*, AcellBoost, and the moment's Speed,
  Up/DownSlope, surfaces, Park, Slomo. It writes into the context car's Profile (the car manager's NewCarActor:
  with copies given, both handlings wrote the own car's copy), and reads the parts through the car manager - the
  local player's own (the twin's handling's PartProperty_Wheel on the host took the host's offroad tires).
- Measured: the guest's own car, 4 s full throttle from the same spot: 1800 (twin's handling tick off) vs 2300-3150
  (on); the host on offroad tires, its own car's graph read 0.9 / 0.09 by turns (the two handlings).
- A copy: StaticConstructObject(class, outer, None, 0, 0, false, false, template) copies the properties (FirstNode
  shared: shallow); each node copied once (memo by address - a walk without one made 315 593 nodes), children
  pointed at the copies. A copy's parameters start empty (not properties): seeded with GetParameter (works).
- Fix (tuning.lua): each car its own deep copy; part writes kept per handling function (hooks run after the body:
  ReceiveTick, UpdateProfileOnParking, UpdateBaseCarGameplayOptions, InitializeTuningConstants); the own car's
  handling's are the own parts; every graph written gets its car's values back (own: its handling's; the other's:
  the owner's TU line). The moment's parameters stay in the context car's graph.
- Test `tuning-test.ps1` (collide setup): three graphs per side; the host on offroad tires: steady on both sides for
  each car (5 reads); with the guest at the wheel of the host's car the same. 5/5.
- Not covered: the moment's parameters of the car that is not the context (a car driven by the other player's input
  while this side sits in the other one: its Speed / slopes stay as last written).
### The other's car's gas cap (2026-11-10)
Owner: "the friend's car's fuel tank does nothing - let us siphon from it (as from abandoned cars) and fill it".
- The car's cap is `BP_CarPart_GasCap_C` (SLOT Internal.GasCap) with `BP_FuelableComponent_GasCap_C` (CarActor: its
  car; GetFuelTanks(out FuelTankItems, NumFuelTanks, HasFuelTank): that car's tank items - the twin's own on a twin).
  Its GetFuelStatus / "Give Fuel" / "Take Fuel" (overrides) go to the car manager's tanks - the local player's own:
  the guest's twin cap showed the guest's 6 (the host had 12), "Give Fuel" 3 filled the guest's own tank. Its
  fuelable actions: CanBeRefueled, not CanBeSiphoned.
- UE4SS hooks on a BP function run after the body, and their out params can be set (`p:set(v)`: the caller gets it;
  probed on GetFuelStatus).
- Fix (gascap.lua, for a cap whose CarActor is the twin): GetFuelStatus -> the twin's tanks summed; GetFuelableActions
  (the base class's, the cap's by its class) -> can be siphoned; Give / Take -> the body's amount back to the own car
  (SiphonAllFuelTanks / RefuelAllFuelTanks), the asked one into / out of the twin's tanks' components. A rise there
  goes to the owner as before (twincar EY f); a siphon goes down, which watchState never sends (wear, drain): now told
  (Twin.noteSiphon -> EY with a negative delta).
- Test `gascap-test.ps1` (collide setup): the cap shows the host's 10, not the guest's 4, siphonable; a canister
  (TransferFuel, steps of 0.5) pours 3 -> host +3, siphons 2 -> host -2, the guest's own unchanged; the host pours 2
  into the guest's car -> guest +2. 4/4. Not covered: holding a canister at the cap by hand (the test calls
  TransferFuel, what the hold ends in - assumed from the names).
### The other's trunk box (2026-11-10)
Owner: "I open the friend's trunk and see my own things".
- A trunk box's E (BP_Storage_Trunk_Base_C, its Highlight OnHighlightInteract) opens the inventory manager's trunk
  whatever car it is in: OpenCarInventories -> OpenInventoryContainer(Inventory_Trunk, true, false, true) ->
  OpenPlayerMenu(cat, ST_PlayerMenuParams{TransferContainer}); the box's own component (carstore's repoint) is not
  read there. The menu's UMG_PlayerMenu_Inventory_C (Category_Inventory; a second one is the widget tree's template,
  TransferContainer unset) had TransferContainer = the guest's own Inventory_Trunk. GetInventoryTrunk is not called
  (the variable is read directly).
- Fix (playersync TD.trunkOpened, a hook on the box's interact - after the body): a twin's box -> repoint, and every
  live UMG_PlayerMenu_Inventory_C showing an own trunk gets `Set Transfer Containers(twin's container, true, nil)`.
- Test: car-store-test step 6 (the box's interact called): the menu shows the twin's container with the host's
  fabric (4/4); 18/18. The game windows are not drawn in the tests: what the screen shows is not checked.

### The own car stalled when the friend connected (2026-11-10)
- Probe (collide setup, host's engine on): CoopPlayers.stop (the twin removed with its parts) -> the host's
  CarIgnitionState 2 -> 0 at once; a new twin (spawn + its parts) -> 0 again ~1.5 s after the start. The parts'
  handlers are the car manager's, one for both cars.
- Fix (twincar keepEngine): the manager's ignition and lever read before Twin.destroy / Twin.spawn / applyEquip (when
  it changed parts) and put back right after, and 100 / 500 ms later, if they changed - only while the own car is the
  manager's car.
- Test: gascap-test step 5 (ignition sampled every 30 ms through a stop and a start of the player sync): stays 2.

### The trunk lid that kept slamming (2026-11-10, not reproduced)
- trunk-slam probe: the guest opens and shuts the host car's lid (Tap door 5): one open, one shut on both sides, no
  repeat in 12 s; with the lid open and the host driving 4 s: the guest's twin lid swung (yaw -176 / pitch 44 at a
  moment), the guest's press then opened it again (doors_sent 5:open) - it looked shut there. No repeating shut seen.
### The guest's own car twice after a zone load (2026-11-10, fixed)
- The open "EXTRA CAR: 2 cars, 0 twins" (owner's alpha 17-20: "getting out moves it into the other one"; nextzone's
  car check failed in most quick suites). A NotifyOnNewObject watch on BP_PlayerCarNew_C on the guest: a load builds
  the own car twice now and then - two cars 150 ms apart, the same spot, at the travel into its own generated zone
  and again at the host's zone save's load (passing runs: one per load). The mod spawns no own car: the game's.
- Both manifest the same equipped items (InventorySystem.ItemWorldStates ActiveManifestations: 67 items with a part
  on each car), but an item's own link (GetActorManifestation) points to one car's part only: 69 links on the newer
  car (the manager's NewCarActor then), none on the other - the one the player sat in later.
- First try kept the player's seat's car: its links all pointed to the removed car's parts, and the game crashed
  20 s later (access violation 0x38 in a ufunction call) on an item's link to a freed part.
- twincar dropCopies: the kept car is the one the items' links are on (seat / manager only on a tie); the other is
  removed with M.destroy (manifestations forgotten first) only when it shares >= 10 items with the kept one, and
  nothing is removed while any of the kept car's items links elsewhere. The player sitting in the removed copy is put
  into the kept car (CommandEnterCar). Called when the guest's zone starts playing and from the car watch (every
  10 s while playing / hosting). Status: copies=<removed>.
- Probe runs: copy removed at "playing", links broken=0 at +0 / +40 / +60 s, the player seated, no crash.

### The own car rolled away after a ride in the other's car (2026-11-10, fixed)
- cars-test failed in different checks from run to run (the host could not get to the guest car's wheel, the guest's
  own car "did not drive"): the guest's own car stood 60 m down the slope by step 8b. keepEngine (the stall fix) put
  the lever back too, read from the car manager while the player sat in the other's car - the manager's state is the
  context car's, in drive then - onto the own car the game had just parked as the player got out.
- Now only a running engine that stopped is put back (with its lever), and only when the manager's car was the own
  car when the state was read (M.ctxIsOwn).
- On the way: the graph of the own car read EnginePower / EngineQuality / WheelPower 0 - its own handling's values
  (ownVals 0 too: no engine upgrade), not a fault. A graph made again for a car now starts from that car's graph
  before (not the asset's, which nothing writes once the cars have copies) with its part values put on.
- collide-test: the guest's car on the slope rolled at 3.5 m/s before the hit (weak or missed hits, the top speed the
  slope's). Parked (lever) it stopped the striker like a wall; now it stays in drive, its speed put to 0 every 30 ms
  until the striker came 80 closer, and the check uses the speed the hit gave (dv: the velocity change within 1 s of
  the closest moment), not the top speed.
- nextzone light check: 5 % for 9 pairs in 10 and 10 % at most (one pair of 51 was 5.2 % off while the fog swung).

### Test flakes of the quick suite (2026-11-10)
- contact / cars "the guest getting out opens the host's door 3": the host got only the shut. The exit's open went
  out only from the door-flag watch (the game's flag change seen while the other's car was the context); when the
  switch back to the own car came first, nothing. Fix (playersync TD.nativeLeft): the open is sent there unless one
  went out for that door within 2 s (st.exitOpenSent).
- contact kick moved the host 53-76 instead of ~290: knocked into its car or up a slope (LaunchCharacter in walking
  mode, 550 cm/s, the sweep slid along). The test now picks a flat clear way (cmds/kick-dir.lua: 8 directions, knee /
  chest traces 350 out, the lowest ground) and puts the guest behind the host on it: 320. kicked() keeps kick_at
  (mode, speed limit, direction).
- twin-radio rt_played=0: the guest's own DJ had picked the host's track already - nothing to play; the check is the
  track itself now. instability: one 4 s read missed the host's line under load; polled up to 12 s.
- cars: Tap pressed E with nothing of the twin's lit (another spot: the host got into the car, the next try started
  seated); 8b's tries use -OnlyIfLit, and a miss prints the look, the highlight's owner car / slot, the pawn.
  Still open: 8b / 9 on the slope - the guest's car, parked after the host's drive, slid back ~750 and then did not
  move under the guest's throttle (moved 7, engine on, drive) - where it ends up in the zone.
- range, still open: the guest's mine sway did not reach the host - once the host's copy never moved, once the host's
  mine exploded (ev_X / ev_D) as the guest's car was teleported near it; the stray-hazard check had 3 guest bollards
  more than the host (unmapped list printed now).
- anomaly hz_grant=0 once (the rerun passed); no data.

- range sway, found 2026-11-10: the pushed mine's tilt fuse (PreventExplodeOnAngle) came back on mid-sway (armed for
  1 s of it; not the mod's TOUR.fuse - cleared), so the mine went off instead of swaying and nothing was sent. The
  test holds the fuse off for 7 s now (11/11). Who re-arms it is not known (the game's blueprint, likely).
- cars 8b / 9 were the guest's car driven into a tree or a rock by the start spot (bounced back, then stuck nose-on):
  cmds/car-clear-dir.lua turns the car to a clear, flat way (16 yaws, bumper / roof traces 4000 out) before 8b, and
  the host's twin is waited for. Turning the host's car the same before step 8 made it worse (a slope, it rolled;
  step 10's back door missed) - not done.

### The owner's two-games test on cdc4e8d (2026-11-11)
Report local: scratchpad rep11 (CoopSync-report-two-games-2026-11-11_00-18-18.zip; player1 = guest, player2 = host,
Wilderness_Forest_18). The owner's list:
1. In the garage: in the own car's back seat, out by the same back door - the driver's door opens, the player goes
   through the back door and ends up as if out of the driver's door. The same in the zone in the guest's car.
2. Entry gate: instead of teleporting the guest to the host, the guest takes the same entrance as the host's car
   came in by (the maps show different entrances: a fork marked by an arrow, a dead end by a cross). A check that the
   guest's car does not spawn inside the host's (moved a little). A random event: now and then the two get different
   entrances and have to find each other on the map.
3. The guest's load into the host's zone felt long (all under the loading screen otherwise).
4. Map: both players are blue markers - the other player green. Players' own map markers synced: one's own blue,
   the other's green.
5. While one sits at the wheel the door is not highlighted and nothing can be done with it.
6. No door on the back seat: can't get in there. The guest's back door does not close the first time (tries, stays
   open, then closes - by the forced sync, likely).
7. The trunk slamming, reproduced: the guest opened the host's trunk, came close, E opened the trunk's container
   (inventory up) and the lid shut, hit the guest and kept making the shut sound on the guest. The trunk is unstable
   in general (can shut and not open again, start slamming): test it better, refactor.
8. Pickups are late on the guest - in that lag an item can be picked up again (duplicated): an event system for
   quick point syncs? Dropped items appear late and without the throw animation.
9. Part durability: a bar gone red shows as an empty white bar on the other side.
10. The host's driver's door broken glass is missing on the guest.
11. Driving the other's car: lags and jerks on actions - the lever late and jumping back for a while; the ceiling
    light, headlights, ignition late.
12. Radio on both, each in the other's car: tracks differ; skipping does not sync. Tracks between different cars?
13. The host taking parts off / putting them on its car jerked the guest's car - it even turned over.
Guest's load timeline (hitches.log; the host's TravelTo 23:35:53):
- 36:00 the guest's car in the exit volume, "waiting for the host's zone" until 36:11 (the host: LoadMap 4.6 s,
  generating 9.9 s, published 36:12). 11 s.
- 36:11-36:18 the guest's LoadMap (7 s), 36:18-36:28 its game's own generation (10 s, thrown away after).
- 36:28 the host's zone save loaded: LoadMap 5.1 s, the game to state 5 at 36:46 (18 s).
- import 4.5 s (3656 ms over 78 frames), cleaning 3.1 s + 2.4 s (1365 ms over 29 frames). Playing 36:56.
- 56 s from the exit, 63 s from the host's start. Cuts: the guest's travel at the host's TravelTo (the route is known
  then) overlaps the host's 17 s; the import / cleaning under the cover with a larger frame budget (paused anyway).Work on the list (2026-11-11):
- Item 1 (back-seat exit). Two bugs. (a) The game's exit works the driver's door only (its animation); on the own car
  it really swung open. TD.backSeatExit (the door's AttemptDoorExit hook, also native): the driver's door hidden
  (SetVisibility false) while it swings - shut at once the exit never let go of the player - the seat's door
  AttemptOpen, shut TD.EXIT_SHUT_MS later; twincar's pose sends no hidden door. (b) The place the game puts the player
  is ExitCheckPoints' child TempExitLocation by its own relative place: turning the parent 180 for the right side moved
  it in the world, not for the game - out by the right back door stood left. placeExit moves TempExitLocation /
  _StartTrace themselves (mirrored), the parent stays; the garage put the exit back at the wheel the moment the player
  let go, before the game placed it - 1.5 s later now; the garage also sets the seat's entry point.
  Why the tests missed it: cars step 10 / garage-seat checked only "off the seat". Now: cmds/exit-watch.lua (doors seen
  open - visible - and the end spot), backseat-test (zone, both sides, doors 3 and 4, the other side's twin doors),
  garage-seat side check.
- Item 5: passengerMayReach still hid the driver's door when the other sat behind it (the older contact-test rule),
  after twincar parkEntry had been made for exactly that (alpha 20 item 8): only Highlight_EnterDoor is hidden now; E
  at the door / its slot spot -> TD.takenDoorPress (own: AttemptOpen / Shut in the own context; twin: DR toggle).
  Missed: no test had a player at a door with the other at that wheel. backseat-test step 2.
- Item 6a (doorless back seat): the slot holds BP_CarPart_EmptyDoor_C (a door subclass, with entry points) that no
  highlight trace hits. TD.lookedAtDoorway: the camera's line within 70 of the doorway's middle (car-relative -40, +-94,
  0), 3.3 m at most, E = a tap there; TD.realDoor treats EmptyDoor as no door; the walk in goes by the EmptyDoor.
  Found: CommandEnterCar with no door took the car's driver's door off (the own car's) - twincar.finishEntry never
  does that now. Also found: a stale TD.aimed (the twin's door looked at earlier) took an E at nothing to the host's
  back door; onHighlightPress needs the twin lit / its open door looked at now. Missed: "in through the doorway" was
  done in alpha 21 and never tested.
- Item 6b (the twin's back door shutting twice): the game's own shut of the twin's door (the entry's) swung it into
  its frame on the kinematic car, it bounced to 40 deg, then shut (backseat-test timeline 55 -> 4 -> 40 -> 0). The
  door's AttemptShut hook (native) takes such a door off physics at once and eases it shut, the owner's late open
  poses held off 1.5 s (twincar shutEase hold). Missed: the tests checked the door open / shut, not its way.
- Item 7 (trunk): (a) the owner side's own car's door works by the manager's flag of the CONTEXT car: with the other's
  twin the context (the owner had been at the other's car) the DR shut / open did nothing - the lid stood open for good.
  DR now makes the own car the context and holds it TD.DR_CTX_MS. (b) aimNative kept TD.aimed (the lid) when something
  else of the twin was lit: a flag change from the box's E went to the owner as the player's lid. trunk-test: 4 open /
  shut rounds after the host stood at the guest's car. Open: the twin's trunk box has no collision
  (SM_CarPart_Interior_Storage_Trunk_Basic_01, CollisionEnabled 0) - not lit in the test; what the owner pressed is not
  known (the twin's RearTow attachment spot is lit there). Missed: cars step 6 ran with the host far from the guest's car.
- range: the guest's stray bollards - an unmapped key kept its reverse[] entry, so a pooled copy back out was never a
  stray (4 at one spot). reverse cleared on unmap / D.
- Test lesson: restarting CoopPlayers many times on a reused pair broke its Lua state; ExitDoor pressed by a test on
  foot took the car's driver's door off (the tests exit only when seated now).- Item 12 (radio): one station in the zone (TD.isStation: the host when its radio is on, else the guest); RS lines
  carry each side's radio on / off; the station sends RT / RN / RI, every other radio that is on follows, a
  follower's channel change is RK to the station (applied on the radio playing there). twin-radio step 6.
- Item 11 (the lever jumping back): (a) while the owner sat in the other's twin its C / G lines read the manager -
  the other car's lever - and the driver's twin followed them back; now TD.ownControls (savedCtl) and K into the kept
  state; on the way out a changed lever / key turns with the game's animation (set straight, the lever stood at drive
  in park). (b) on foot, K / KG lights and the key / lever were applied through the context car's manager - the twin
  when the owner had looked at it: TD.ownCtxFor (the own car the context, held 2.5 s). twin-ctl 2b. Open: the own
  car's lights toggled by the other while the owner sits in the other's twin still wait in savedCtl.ltw until it gets
  out (the held light line, twincar holdOwnLights, is not changed meanwhile).