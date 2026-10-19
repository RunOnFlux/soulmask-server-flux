# soulmask-server-flux

The Soulmask dedicated server for [Flux](https://runonflux.io), as `runonflux/soulmask-server-flux`.
The game's native Linux server (Steam app 3017300, anonymous), installed and updated with SteamCMD
on every start, run as uid 1000 under a supervisor that:

- builds the server's command line from the environment: map (Cloud Mist Forest or Shifting
  Sands), PvE or PvP, name, players, join and GM passwords, Workshop mods, save interval
- writes the hub panel's gameplay settings (flux/gameplay.json) into the game's GameXishu.json
  before every start, keeping any value a GM changed in game; applies the game's own presets; and
  sets values on the running server through the game's console, no restart
- saves on stop: a forced save on the game's console (4-5 s measured), then SIGKILL (its own shutdown takes ~45 s); Flux allows 10 s
- restarts the server in place when it ends on its own, with a restart budget
- marks the server ready only when the game's console answers (it builds its dungeons for about a
  minute after the world loads, answering nothing)
- follows game updates: a newer build on Steam means a restart onto it, when nobody is playing or
  after the game's own 5-minute countdown in chat (at most an hour later)
- restarts it daily at `SM_RESTART_TIME` (in `TZ`) the same way
- makes a backup of every map's world, the gameplay settings and the ban lists on start (unless one
  is under an hour old), every 6 hours and on request, keeps them so a crash loop can never rotate
  the good ones away, and restores one, imports an uploaded world.db, or starts a new world when
  the panel asks (each after a safety backup)
- gives the hub a JSON status, the game's own maintenance console, the players, bans and presets

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/soulmask/data` | `g:` (synced) | `Saved/` (the game's: `Worlds/Dedicated/<map>/world.db`, `GameplaySettings/GameXishu.json`, `BlackAccountList.txt`; the install's `WS/Saved` is a link to it) and `flux/` (our log, state, `gameplay.json`, uploads, backups) |
| `/mnt/soulmask/server` | `ml:server` (local) | the game install, about 2.2 GB, and the game's logs (`flux-logs/`, which `Saved/Logs` links to). Downloaded again on a new node |

Spec: `g:/mnt/soulmask/data|ml:server:/mnt/soulmask/server`.

## Ports

| Variable | Default | |
|---|---|---|
| `GAME_PORT` | 8777/udp | the game port players connect to |
| `QUERY_PORT` | 27015/udp | the Steam query port (A2S: name, map, players / max) |

The server registers the ports it binds, so the public and the container ports must be the same
numbers (the hub rolls both and passes them here). The game's maintenance console (`-EchoPort`,
18888/tcp) is bound by the game on 127.0.0.1 only and must never be published; RCON is not used.

## Environment

A variable that is **set to a value** is applied on every start; one that is not set, **or set
empty** (the marketplace writes every declared parameter, blank ones as `NAME=`), takes the default.

| Variable | Default | |
|---|---|---|
| `SM_SERVER_NAME` | Soulmask on Flux | `-SteamServerName`. Quotes and backslashes are taken out (Unreal re-parses the command line) |
| `SM_MAP` | `Level01_Main` | `Level01_Main` (Cloud Mist Forest) or `DLC_Level01_Main` (Shifting Sands; players need the DLC). Friendly names work too (`cloudmist`, `shifting-sands`). Each map keeps its own world |
| `SM_MODE` | `pve` | `pve` or `pvp` |
| `SM_MAX_PLAYERS` | 20 | 1-70 |
| `SM_PASSWORD` | none | join password (`-PSW`) |
| `SM_ADMIN_PASSWORD` | chosen once, kept in `flux/admin-password` | the GM password (`-adminpsw`): `gm key <password>` in the game's console |
| `SM_MODS` | none | Steam Workshop IDs or links, comma separated (`-mod=`) |
| `SM_SAVE_MINUTES` | 5 | `-saving` and `-backup`, 1-60 |
| `SM_RESTART_TIME` | none | `HH:MM`, a daily restart in `TZ` (UTC when unset) |
| `SM_EXTRA_ARGS` | none | other options starting with `-`; the ports, console port and passwords cannot be overridden |

Supervisor knobs: `FLUX_BACKUP_HOURS` (6), `FLUX_BACKUP_KEEP` (10, plus the newest older than a day
and the newest older than a week), `FLUX_BACKUP_MIN_AGE_MINUTES` (60), `FLUX_GAME_LOG_MAX_BYTES`
(50 MB), `FLUX_UPDATE_CHECK_MINUTES` (30, 0 = off), `FLUX_UPDATE_WAIT_MINUTES` (60),
`FLUX_RESTART_WAIT_MINUTES` (30), `FLUX_COUNTDOWN_SECONDS` (300), `FLUX_STOP_SAVE_SECONDS` (8),
`FLUX_RESTART_MAX_ATTEMPTS` (5 in `FLUX_RESTART_WINDOW` 3600 s, then exit 42), `SKIP_UPDATE`.

## For the hub

Commands, run through appexec. Each prints one JSON document, except `console`.

| Command | |
|---|---|
| `flux-soulmask status` | `state` (`updating`, `starting`, `running`, `restarting`, `crashed`, `stopped`) and its `message`, `generation` and `since` (wait for them to move after a restart), `players` (`id` = SteamID64, `name`; the console's `lp`, cached 15 s), `max_players`, `name`, `map`, `mapName`, `mode`, `inviteCode`, `passwordSet`, `mods`, `gamePort`, `queryPort`, `build`, `nextRestart`, `updateWaiting`, `restartPending`, `restorePending` |
| `flux-soulmask connect` | ports, invite code, join password and GM password (owner only: it is an exec) |
| `flux-soulmask console <command>` | one command on the game's console; the answer as text. `close` / `exit` / `shutdown` are refused (use `restart`) |
| `flux-soulmask players` | `online` (lp) and `all` (lap: name, tribe, level, time played) |
| `flux-soulmask gameplay` | `panel` (flux/gameplay.json), `server` (the mode's block of GameXishu.json), `defaults`, `presets`, `mode`, `running` |
| `flux-soulmask preset <name>` | a template of `WS/Config/GameplaySettings` (`Jiandan`, `Dashi`, `PvE_04P_3x`, `Creative`...) becomes the panel's values |
| `flux-soulmask apply-live` | every panel value that differs, set on the running server with `sc` |
| `flux-soulmask bans` / `ban <id>` / `unban <id>` | the blocked-accounts list; live (`usp 1 1|0`) when the server runs, else the file |
| `flux-soulmask restart [seconds]` | a restart in place; with seconds (10-3600) the game's own countdown first (`close <s>`) |
| `flux-soulmask backups` / `backup <why> [force]` / `restore <name>` | the backups (name, size, time, why, maps); a restore on the next start after a safety backup, the server restarted now (`serverQuit`) |
| `flux-soulmask import <file>` | a file uploaded to `flux/uploads`: a world.db (checked with SQLite's `quick_check`) becomes the current map's world, one of our backups is restored whole |
| `flux-soulmask new-world` | the current map's world removed on the next start, after a backup |

## Measured (build 25955350, Soulmask 1.0, 2026-10-18)

- Install 2.2 GB (`SizeOnDisk` 2191425391). A fresh world: `[ GAME STARTED. ]` after ~100 s on a first
  start (~50 s on a restart), then ~50 s of dungeon building with the game thread blocked before the
  console answers. A panel restart: 82 s from the request to `[ GAME STARTED. ]`, plus the dungeons.
- Cloud Mist Forest with nobody on: RSS 8.9 GB, peak (VmHWM) 9.5 GB; ~1 core while loading, 0.6-1
  core idle. world.db 40 MB (SQLite), a backup 8.6 MB compressed.
- A2S on the query port: name, map (`Level01_Main`), players / max, version `1.0.0.0`; the password
  flag stayed 0 with a join password set.
- Forced save `sav 1`: 10.7 s the first time, 2.7 s after. After SIGTERM the database closes in ~7 s
  and the process exits in ~12-45 s (the 45 s one measured on 2026-10-19 under load); the stop path therefore ends it with SIGKILL right after the save.
- The console: 40 commands (`help`, paged). `lp`, `lap`, `lg`, `lc`, `lsp` print `|`-tables; `sc <key>
  <value>` answers `<key>: <value> (updated)` and writes GameXishu.json; `usp 1 1 <id>` writes
  `Saved/BlackAccountList.txt`; `say` answers `send to all online players. Done.`; `qi` prints the
  25-character invite code; no kick command.
- GameXishu.json: blocks "0", "1", "2" of 282 keys; a PvE server reads "1". The install's
  `GameXishuConfig_Template.json` (UTF-16) has every key's default, range and whether it is a switch.

## Versions

- **1.0.0** (2026-10-18): first release.
