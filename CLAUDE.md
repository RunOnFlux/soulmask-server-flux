# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the Soulmask dedicated server for Flux,
`runonflux/soulmask-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's native Linux server
(Steam app 3017300, anonymous), and a supervisor in bash. Same family as
`~/work/corekeeper-server-flux` and `~/work/tf2-server-flux`; read them for the patterns this one
follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`, never the game. The game runs as a child (uid 1000) so a stop becomes a save,
and a server that ends on its own is followed by the next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build -t soulmask-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update, Saved/ linked to the data
  volume, a pending restore / import / new world, a backup, `fluxsm.py apply` (GameXishu.json, and
  the command line on stdout), the server as uid 1000, then the watcher (ready, game updates, daily
  restart), the backupper and the log capper.
- `scripts/fluxsm.py`: every decision about the server's files and the hub's commands
  (`flux-soulmask ...`), including the client for the game's maintenance console. The one place
  those rules live.
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly.
- `tests/image/standin-server.py`: the stand-in server of the image test (console on 18888, a SQLite
  world, the game's answers). Keep its answers in step with the real server's.

## Things that will bite you

- **Not as root.** Unreal refuses it: `setpriv --reuid=1000`, and the volumes are chowned every start.
- **Run the binary, not WSServer.sh.** The wrapper is `sh` and does not pass signals on.
- **"GAME STARTED" is not ready.** The server then builds the world's dungeons with its game thread
  blocked for about a minute: no console, no players. Ready (`running`) = the console answers `qi`.
- **The console (echo port 18888) is bound on 127.0.0.1 by the game itself.** Never publish it.
  It is plain text, one command per line, answers with no terminator (read until quiet), and `help`
  opens a pager that must be left with `q` (`console_many` does it). RCON 19000 listens on 0.0.0.0
  even without a password: it is simply never published.
- **The world lives in memory.** `-saving` / `-backup` (both SM_SAVE_MINUTES) write it; `sav 1`
  forces a write (2.7 s warm, 10.7 s the first time). The stop path is `sav 1` then SIGKILL (SIGTERM shutdown measured 45 s on 2026-10-19): after
  SIGTERM the database closes ~7 s later and the process exits ~12 s later, past Docker's 10 s, so
  the forced save first is what makes a stop lose nothing.
- **There is no kick** in the console (40 commands, none removes a player). Bans are `usp 1 1 <id>`,
  written by the game to `Saved/BlackAccountList.txt` and read at start.
- **GameXishu.json has three blocks**; a PvE server reads `"1"` (measured with `lc`). `apply` writes
  the panel's values into all three and never the PvP switch (`MODE_KEYS`): the mode is SM_MODE's.
  `sc` in game writes the active block at once; `apply` takes such values back into
  flux/gameplay.json (3-way against flux/gameplay.applied.json) before writing.
- **The difficulty templates leave block "1" alone** (Jiandan, Dashi... change only "0" and "2"):
  `preset_values` reads a template's changes from "0" and the mode's block.
- **World backups copy the SQLite database with its online-backup API** after a forced save: a plain
  copy of a database being written can be torn.
- **The stdout of the server repeats its log with every level-streaming line.** It goes to
  /dev/null; Saved/Logs/WS.log (a link to the local log folder) is tailed to docker logs instead.
- **Empty env = unset**: the marketplace writes blank declared parameters as `NAME=`.
- **Flux stops a container with Docker's default 10 seconds.**
