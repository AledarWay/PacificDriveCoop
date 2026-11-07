CoopSync co-op mod for Pacific Drive - alpha for testing
========================================================

What it is
----------
The mod lets two people play together: the host runs its own trip, the guest joins it through Steam -
each in their own car. The zone, the loot, the hazards and the cars are the same for both.
(The "on foot in the host's car" mode is frozen for now.)
This is an alpha: desyncs and crashes are possible. Please send reports (see below).

What you need
-------------
- Pacific Drive from Steam (both players on the same game version).
- Steam running, the two of you friends on Steam.
- Windows 10/11, 64-bit. Nothing else to install.

Install
-------
1. Close the game.
2. Unpack the zip into any folder and run Install.bat.
   The installer finds the game through Steam, backs up your saves to
   "Documents\PacificDriveCoop\saves-<date>" and puts UE4SS and the mod into the game folder.
   If the game is not found: Install.bat "D:\SteamLibrary\steamapps\common\Pacific Drive"
3. Start the game from Steam as usual.

Playing together
----------------
- The co-op menu: Esc -> Co-op. A spare panel with the same items: the F7 key.
  (The mod's texts follow the game's language: Russian or English.)
- Host: Create lobby -> Invite a friend... -> pick the friend (friends in Pacific Drive come first).
- Guest: the menu shows "Invitation from ... - accept" (or "Join lobby: ..." if the friend is already in one).
- The lobby forms in the garages: each player in their own garage, seeing the other. The guest's map table
  shows the host's map (junctions, conditions) - the guest can look, only the host picks; the time of day and
  the weather in the garage are the host's. The pause menu does not stop the game while in a lobby.
  A "Co-op" checklist under the game's driver's checklist shows the lobby, the players and what to do next.
- The host drives out of the garage as usual. The guest's exit gate stays shut until the host has left; then
  it opens - the guest drives out through it and goes straight to the host's zone (no junction to pick).
  The guest's game loads the host's zone exactly as the host's game has it (through the game's own save),
  with the guest's car next to the host's.
- If the guest went home earlier while the host is still out, the gate opens again after joining the lobby.
- Quitting to the main menu or loading a save leaves the lobby.
- The friend's car works like your own, by the game's own means: E at the driver's door - take the wheel (unless
  the friend is driving), E at a back door - take that seat; the door of the seat the friend sits on cannot be
  used. At the wheel of the friend's car the key (hold, as usual), the lever, pedals and wheel, lights,
  wipers, radio and horn work, and your game drives the car - no delay. A passenger reaches only their own door:
  to get out, look at your door and press E. Levers and the key are the driver's only.
- Put the lever into park before getting out: in drive with the engine on the car creeps away by itself (that
  is how the game works).
- The radio plays the same for both (in the friend's car and in the host's garage). Cars collide and knock
  each other's parts off - careful when parking.
- The friend's trunk and racks are the friend's: what you put there ends up with the friend.
- During co-op the pause does not stop the game - the other player keeps playing.
- Map and story progress count for the host. The loot you bring home is yours.
- The mod is made for two players for now.

Testing without a friend: two copies of the game on one PC
----------------------------------------------------------
After installing, run TwoGamesTest.bat (Steam running, the game closed).
Two game windows open. Each plays on its own COPY of your saves
(Documents\PacificDriveCoop\two-games\player1 and player2); the real saves do not change.
To copy the saves there again: TwoGamesTest.bat -Fresh
- Copy 1: Esc -> Co-op -> Create lobby (it is the host).
- Copy 2: Esc -> Co-op -> Join lobby: the second copy of the game on this PC.
The rest is as with a friend. It needs a strong PC: two games at once are heavy.
The report of both copies: ReportTwoGames.bat (one zip on the desktop).

If something broke
------------------
Press F7 - the co-op panel opens, with a Debug section:
- Resync the zone - if loot or buildings differ between you;
- Restart the sync - if the other player froze or vanished;
- Teleport to the other player - if you are stuck or lost;
- Restore car parts (insurance) - if parts went missing from your car after a co-op trip;
- Leave the session - go on alone;
- Collect a report to the desktop - the zip CoopSync-report-<date>.zip. Send it to the developer
  with a short description: what you did and what went wrong.
If the game crashed and the menu is gone, run Report.bat from this folder: it collects the same zip.
The report holds only logs and the mod's own files; no saves or personal files.
Send the reports of BOTH players: the host and the guest have different logs (e.g. the hitch log hitches.log).

What's new - in CHANGELOG.txt next to this file.

Uninstall
---------
Close the game and run Uninstall.bat. The mod and UE4SS are removed from the game folder; if you had your own
UE4SS before the install, it comes back. Saves are not touched.

Contents and licences
---------------------
- UE4SS (RE-UE4SS, MIT licence) - the mod loader, built from the sources of the same version,
  files\ue4ss\LICENSE.
- CoopSync - the mod itself: Lua scripts and dlls\main.dll (its C++ part with the Steam network inside the game;
  it uses the game's own steam_api64.dll).
