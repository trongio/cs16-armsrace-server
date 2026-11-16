# CS 1.6 Arms Race server

Counter-Strike 1.6 dedicated server in Docker for playing with friends and bots, with a web dashboard.

## Install (Ubuntu 24.04)

```bash
git clone https://github.com/trongio/cs16-armsrace-server.git && cd cs16-armsrace-server && ADMINS=YOUR_STEAMID64 ./install.sh
```

`ADMINS` is optional: one or more SteamID64s, comma separated (find yours at steamid.io). The installer sets up Docker, generates passwords in `.env`, builds the images, opens the firewall and adds "CS 1.6 Server" and "CS 1.6 Dashboard" shortcuts. Friends need to own CS 1.6 on Steam.

For players outside your network, forward `27015` (TCP+UDP) and `27080` (TCP, map downloads) on your router.

## What's inside

- ReHLDS + ReGameDLL + Metamod-r + AMX Mod X 1.10
- Modes: **Arms Race** (GunGame), **Deathmatch** (FFA, instant respawn), **Casual**, **Competitive (short)**
- YaPB bots fill empty slots (default 6 players, hard)
- Mode + map vote near the end of every match: type the number in chat. `!vote` starts one any time
- Fun toggles: `!lowgrav` `!headshot` `!speed` `!adaptive` `!announcer` `!colors`
- Host commands (admins): `!bots <n>` `!diff <0-3>` `!map <name>` `!mode <ar|dm|casual|comp> [map]` `!restart`
- Dashboard on http://localhost:8016: live scoreboard, map/mode switching, bots, toggles, all-time stats, invite link, QR code for phones
- FastDL (nginx on :27080) so custom maps download fast

## Files

| Path | What |
| --- | --- |
| `cfg/server.cfg` | hostname, passwords (synced from `.env` by the installer) |
| `cfg/servertools.ini` | modes and their maps |
| `cfg/st/*.cfg` | per-mode settings |
| `overlay/` | everything baked into the server image (plugins, maps, configs) |
| `overlay/addons/amxmodx/scripting/servertools.sma` | the vote/stats/dashboard plugin |
| `panel/` | dashboard (FastAPI + one HTML page) |
| `tools/rcon.py` | `tools/rcon.py <command>` sends an RCON command |

After editing anything in `overlay/`: `docker compose up -d --build`. Start/stop: `./launch.sh` / `./launch.sh stop`.
