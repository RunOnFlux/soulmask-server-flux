# soulmask-server-flux

The Soulmask dedicated server for [Flux](https://runonflux.io), as `runonflux/soulmask-server-flux`.
The game's native Linux server (Steam app 3017300, anonymous), installed and updated with SteamCMD
on every start, run as uid 1000 under a supervisor that:

- builds the server's command line from the environment: map (Cloud Mist Forest or Shifting
  Sands), PvE or PvP, name, players, join and GM passwords, Workshop mods, save interval
- writes the hub panel's gameplay settings (flux/gameplay.json) into the game's GameXishu.json
  before every start, keeping any value a GM changed in game; applies the game's own presets; and
  sets values on the running server through the game's console, no restart
- saves on stop: a forced save on the game's console (2-4 s measured; the slow first one of a
  session is done before the server is marked running), then SIGKILL (its own shutdown takes
  ~45 s); Flux allows 10 s
- never starts the game on a missing world it had (a half-synced data volume on Flux's second
  node): the newest backup with that map's world is put back, or the start waits for it
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
| `/mnt/soulmask/data` | `g:` (synced) | `Saved/` (the game's: `Worlds/Dedicated/<map>/world.db`, `GameplaySettings/GameXishu.json`, `BlackAccountList.txt`; the install's `WS/Saved` is a link to it) and `flux/` (state, `gameplay.json`, uploads, backups) |
| `/mnt/soulmask/server` | `ml:server` (local) | the game install, about 2.2 GB, and the game's logs (`flux-logs/`, which `Saved/Logs` links to). Downloaded again on a new node Also `flux-logs/flux.log` (our supervisor log, 5 MB then one `.1`): local, never synced. |

Spec: `g:/mnt/soulmask/data|ml:server:/mnt/soulmask/server`.

## Ports

| Variable | Default | |
|---|---|---|
| `GAME_PORT` | 8777/udp | the game port players connect to |
| `QUERY_PORT` | 27015/udp | the Steam query port (A2S: name, map, players / max) |

The server registers the ports it binds, so the public and the container ports must be the same
numbers (the hub rolls both and passes them here). The game's maintenance console (`-EchoPort`,
18888/tcp) is bound by the game on 127.0.0.1 only and must never be published; RCON is not used
(it has the same commands as the console, no kick).

## Environment

A variable that is **set to a value** is applied on every start; one that is not set, **or set
empty** (the marketplace writes every declared parameter, blank ones as `NAME=`), takes the default.

| Variable | Default | |
|---|---|---|
| `SM_SERVER_NAME` | Soulmask on Flux | `-SteamServerName`. Quotes and backslashes are taken out (Unreal re-parses the command line) |
| `SM_MAP` | `Level01_Main` | `Level01_Main` (Cloud Mist Forest) or `DLC_Level01_Main` (Shifting Sands; players need the DLC). Friendly names work too (`cloudmist`, `shifting-sands`). Each map keeps its own world |
| `SM_MODE` | `pve` | `pve` or `pvp` |
| `SM_MAX_PLAYERS` | 20 | 1-70 |
| `SM_PASSWORD` | none | join password (`-PSW`); spaces are taken out. Never shown in the logs (`-PSW=<hidden>`) |
| `SM_ADMIN_PASSWORD` | chosen once, kept in `flux/admin-password` | the GM password (`-adminpsw`): `gm key <password>` in the game's console |
| `SM_MODS` | none | Steam Workshop IDs or links, comma separated (`-mod=`). The server downloads them itself at start (verified on Linux, build 26158199: `[MOD]downloaded <id>`, into the install's `WS/Mods/`, so again on a new node) |
| `SM_SAVE_MINUTES` | 5 | `-saving` and `-backup`, 1-60 |
| `SM_RESTART_TIME` | none | `HH:MM`, a daily restart in `TZ` (UTC when unset) |
| `SM_EXTRA_ARGS` | none | other options starting with `-`; the ports, console port and passwords cannot be overridden |

Supervisor knobs: `FLUX_BACKUP_HOURS` (6), `FLUX_BACKUP_KEEP` (10, plus the newest older than a day
and the newest older than a week), `FLUX_BACKUP_MIN_AGE_MINUTES` (60), `FLUX_GAME_LOG_MAX_BYTES`
(50 MB), `FLUX_UPDATE_CHECK_MINUTES` (30, 0 = off), `FLUX_UPDATE_WAIT_MINUTES` (60),
`FLUX_RESTART_WAIT_MINUTES` (30), `FLUX_COUNTDOWN_SECONDS` (300), `FLUX_STOP_SAVE_SECONDS` (8),
`FLUX_RESTART_MAX_ATTEMPTS` (5 in `FLUX_RESTART_WINDOW` 3600 s, then exit 42), `SKIP_UPDATE`,
`FLUX_STEAMCMD_TIMEOUT` (1800 s, a first install), `FLUX_STEAMCMD_UPDATE_TIMEOUT` (600 s, an update
over an install; after `FLUX_STEAMCMD_UPDATE_TRIES` 2 the installed build starts),
`FLUX_STEAMCMD_QUERY_TIMEOUT` (180 s, the watcher's version check). With no install and no Steam,
the download is retried for ever (30 s doubling to 10 min), the state message says so.

## For the hub

Commands, run through appexec. Each prints one JSON document, except `console`.

| Command | |
|---|---|
| `flux-soulmask status` | `state` (`updating`, `starting`, `running`, `restarting`, `crashed`, `stopped`) and its `message`, `generation` and `since` (wait for them to move after a restart), `players` (`id` = SteamID64, `name`; the console's `lp`, cached 15 s), `max_players`, `name`, `map`, `mapName`, `mode`, `inviteCode` (null when stopped), `passwordSet`, `mods`, `gamePort`, `queryPort`, `build`, `nextRestart`, `updateWaiting`, `restartPending`, `restorePending`, `lastAction`, `features` |
| `lastAction` | the last restore / import / new world, as the start that applied or refused it: `{"kind": "restore"\|"import"\|"new-world", "name": <backup or upload, or null>, "generation": <the start that applied it>, "ok": bool, "error": <text or null>, "at": "<ISO UTC>"}`; null before the first |
| `features` | `{"kick": false, "whitelist": true}`: there is no kick (neither the console nor RCON has one, build 26158199) |
| `flux-soulmask connect` | ports, invite code, join password and GM password (owner only: it is an exec) |
| `flux-soulmask console <command>` | one command on the game's console; the answer as text. `close` / `exit` / `shutdown` are refused (use `restart`) |
| `flux-soulmask players` | `online` (lp) and `all` (lap: name, tribe, level, time played) |
| `flux-soulmask gameplay` | `panel` (flux/gameplay.json), `server` (the mode's block of GameXishu.json), `defaults`, `presets`, `mode`, `running` |
| `flux-soulmask preset <name>` | a template of `WS/Config/GameplaySettings` (`Jiandan`, `Dashi`, `PvE_04P_3x`, `Creative`...) becomes the panel's values |
| `flux-soulmask apply-live` | every panel value that differs, set on the running server with `sc` |
| `flux-soulmask bans` / `ban <id>` / `unban <id>` | the blocked-accounts list; live (`usp 1 1|0`) when the server runs, else the file. The list is on by default (no `-serverpm` needed: the game starts with 2+8+16) |
| `flux-soulmask whitelist` | `{"enabled": bool, "ids": [{"id": "7656...", "name": <a known player's name or null>}]}` (`Saved/WhiteAccountList.txt`) |
| `flux-soulmask whitelist add <id>` / `remove <id>` | `{"ok": true}`; live (`usp 0 1|0`) when the server runs, else the file |
| `flux-soulmask whitelist on` / `off` | `{"ok": true, "restart": bool}`: kept in `flux/whitelist.json`, set live (`ssp 0 1|0`) and on every start (`-serverpm=27`/`26`; the game forgets `ssp` at a restart). `restart` is true only when the running server did not take it live. **An enabled whitelist with nobody on it lets nobody in** (players see "Server is still self-testing!") |
| `flux-soulmask restart [seconds]` | a restart in place; with seconds (10-3600) the game's own countdown first (`close <s>`) |
| `flux-soulmask backups` / `backup <why> [force]` / `restore <name>` | the backups (name, size, time, why, maps); a restore on the next start after a safety backup, the server restarted now (`serverQuit`). A restore puts back the **current map's** world (the backup must have it), the gameplay settings and the permission lists; another map's world in the backup is put back only where this server has none, so it is never rolled back |
| `flux-soulmask import <file>` | a file uploaded to `flux/uploads`: a world.db (SQLite's `quick_check` and the game's `actor_table`) becomes the current map's world, one of our backups is restored like a restore; anything else is refused and removed |
| `flux-soulmask new-world` | the current map's world removed on the next start, after a backup |

## The world guard

Flux runs the app on two nodes with the data volume synced (Syncthing). A node can start on a
volume whose `world.db` has not arrived, and the game then makes a new world without a word,
which syncs over the real one. Before every start (`fluxsm.py world-guard`): `*sync-conflict*`
copies under `Saved/` go to `flux/sync-conflicts/` (never a world, never in a backup); when the
current map's world is missing or unusable (kept aside as `world.db.flux-unusable-<time>`) but this
server had one (`flux/worlds.json`, a backup with that map, other files in its folder), a MISSING
world is first waited for, 5 minutes on this node (`FLUX_WORLD_SYNC_GRACE_SECONDS`, counted in
`flux-world-missing.json` on the install volume): the backups are synced too and can arrive before
the world, and a backup put back at once would carry a newer file time, so Syncthing could send that
older world over the real one still on its way. Then the newest backup with that map's world is put
back (flux.log, the start's state message, `worldRestored` in
state.json), or, with none, the start waits (state `updating`, the reason in `message`), checking
every 30 s. The panel's `new-world` marks the map so a new world is let through.

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
- **1.0.2** (2026-10-23): gameplay values set with apply-live, a restore or a GM's `sc` no longer revert at the next start (the 3-way merge compares only the block the server reads; keys missing from gameplay.json are left as they are); the world guard (a missing world is waited for 5 minutes, then comes back from a backup instead of a new one syncing over it); sync-conflict copies kept out of worlds and backups; the passwords hidden in docker logs and flux.log; no NUL bytes from the game log cap (punched out, not emptied); the slow first save done before `running`; SteamCMD deadlines and retries; status `lastAction` and `features`; the whitelist (`whitelist`, `on|off`, `add|remove`, `-serverpm`); a restore puts back only the current map's world; import checks for the game's tables and removes refused uploads; a stop clears the invite code and the next restart.
- **1.0.1** (2026-10-20): `flux.log` moved off the synced data volume to `/mnt/soulmask/server/flux-logs/flux.log` (5 MB, one `.1`; an old one is moved there once); start-up banner; the weekly rebuild only when it has something to apply.
