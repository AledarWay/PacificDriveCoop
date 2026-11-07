# CoopSync network: two PCs (legacy relay)

> **Legacy.** This is the first-stage network (a relay process next to the game). Since 0.1.0-alpha8 the network
> runs inside the game (the native half, `mod/CoopNative/net.cpp`, Steam P2P), and the alpha zip no longer ships
> CoopNet or the relay. Kept for the history and the relay self-tests.

Lua in UE4SS cannot use sockets, so a **relay** (`relay.ps1`, plain PowerShell + .NET, nothing to install) runs
next to the game. The game writes and reads local channel files, and the relays carry their lines and files between
the PCs over TCP (default port 27520). The connection is by direct IP: on a local network or through a VPN overlay
(Tailscale / ZeroTier), as the playbook advises for the first stage.

## What both PCs need

1. Pacific Drive from Steam, the same build (the host checked buildid 21896301; the exe's SHA-256 is in
   `games/pacific-drive/NOTES.md`).
2. A **test copy** of the game (not the main install!) with UE4SS and the `CoopDev`, `CoopSync` mods, as in
   `C:\PacificDriveCoop\testgame`, and the same `UE4SS-settings.ini` (important: `bForceGUObjectArrayForIteration = true`).
3. The project folder `C:\PacificDriveCoop\mod` (the scripts use this path).
4. A network between the PCs: one local network **or** Tailscale/ZeroTier on both. The host's IP is its address on
   that network (for Tailscale, `100.x.y.z` from the app).

## Host only: open the port

Windows Firewall blocks incoming connections by default. This changes system settings, so the PC's owner runs the
command themselves, in PowerShell **as administrator**:

```powershell
New-NetFirewallRule -DisplayName "CoopSync relay" -Direction Inbound -Protocol TCP -LocalPort 27520 -Action Allow
```

No port forwarding on the router is needed on one network or in Tailscale/ZeroTier.

## Automatic test on two PCs

Pick a shared secret (any string): it keeps strangers off the relay.

Host:

```powershell
powershell -ExecutionPolicy Bypass -File C:\PacificDriveCoop\mod\net\coop-net-test.ps1 -Role host -Token <secret> -Bind 0.0.0.0
```

Client (start it after the host prints `sync: OK host sync started`):

```powershell
powershell -ExecutionPolicy Bypass -File C:\PacificDriveCoop\mod\net\coop-net-test.ps1 -Role client -Token <secret> -HostAddr <host IP>
```

Each PC runs its game without graphics (`-nullrhi`) in a separate profile (`-userdir`); your saves are not touched.
For three stages (after the sync, after the host bot's actions, after the client bot's actions) the host prints
`PASS`/`FAIL` lines for the positions and `LOOT PASS`/`LOOT FAIL` for the contents. Send the output of both windows.

## What was tested and what was not

- Tested on one PC (two copies of the game talking only through the relays over TCP on 127.0.0.1): all stages PASS,
  also with an emulated 75 ms delay each way + 30 ms jitter.
- **Not tested**: two real PCs, internet/VPN, packet loss, a connection drop mid-game.
- Known limits: on a TCP drop the lines "in flight" can be lost (no acknowledgements or resends); movement goes over
  TCP (one delay holds up the rest); the traffic is not encrypted, the token goes in plain text.
