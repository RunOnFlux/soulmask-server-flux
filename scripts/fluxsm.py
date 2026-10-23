#!/usr/bin/env python3
"""Every decision about the Soulmask server's files, and the hub's commands.

    fluxsm.py apply                  GameXishu.json from the panel's gameplay settings, then the
                                     server's command line, one argument per line (the entrypoint)
    fluxsm.py state <state> [msg]    record what the supervisor is doing (flux/state.json)
    fluxsm.py note <key> [value]     a field of flux/state.json the supervisor keeps (nextRestart,
                                     updateWaiting, inviteCode); no value removes it

    flux-soulmask status             state, generation, players, name, map, mode, build (JSON)
    flux-soulmask connect            how to join: ports, invite code, join password, GM password
    flux-soulmask console <command>  one command on the game's maintenance console (the "echo
                                     port", 127.0.0.1:18888); prints the game's answer as text
    flux-soulmask players            online players (lp) and every player the world knows (lap)
    flux-soulmask gameplay           the gameplay settings: the panel's, the server's, the presets
    flux-soulmask preset <name>      replace the panel's gameplay settings with a preset's
    flux-soulmask apply-live         set every gameplay value that differs on the RUNNING server
                                     (the console's Set_Coefficient), no restart
    flux-soulmask bans               the blocked-accounts list
    flux-soulmask ban <steamid64>    block an account (live when the server runs, else on file)
    flux-soulmask unban <steamid64>
    flux-soulmask restart [seconds]  save and restart; with seconds, the game's own countdown
                                     (players are told in game) and then the restart
    flux-soulmask backups            the backups in flux/backups (name, size, date, why)
    flux-soulmask backup <why> [force]  a backup now (the supervisor's, and the panel's "back up now")
    flux-soulmask restore <backup>   restore one: the server restarts, a safety backup of what is
                                     there is made, the backup goes back, the server starts again
    flux-soulmask import <file>      a world.db (or one of our backups) uploaded to flux/uploads
                                     becomes the current map's world, the same way as a restore
    flux-soulmask new-world          the current map starts over on the next start (after a backup)
    flux-soulmask whitelist          {"enabled", "ids": [{"id", "name"}]}
    flux-soulmask whitelist add|remove <steamid64>   live when the server runs, else on file
    flux-soulmask whitelist on|off   {"ok", "restart"}: live (`ssp 0`) and on every start (-serverpm)

    fluxsm.py do-restore             apply a pending restore/import/new world (before a start);
                                     its outcome is status.lastAction
    fluxsm.py world-guard            before a start: exit 0 to start, 3 to wait (a world this
                                     server had is missing and no backup has it)
    fluxsm.py world-seen             the watcher, once up: this map's world exists
    fluxsm.py update-target <build>  remember the build a planned update restart is for
    fluxsm.py update-check           after the update step: a target that was not reached is
                                     remembered as failed (the watcher skips it for 6 hours)
    fluxsm.py update-skip <build>    exit 0 when that build failed less than 6 hours ago

GAMEPLAY SETTINGS (GameXishu.json, three blocks "0", "1", "2" of the same ~280 coefficients; a PvE
server reads block "1", measured with the console's `lc`). The panel's values are flux/gameplay.json,
a flat {key: number}; `apply` writes them into all three blocks before every start, so they hold
whatever the mode. A value changed IN GAME (a GM's `sc`, which the server writes into its own file)
is not lost: a key the panel did not change since the last start but the server's file did is
taken back into flux/gameplay.json first (flux/gameplay.applied.json is that last start's values).

Environment: a variable SET to a value is applied on every start; one unset or set EMPTY (the
marketplace writes every declared parameter, blank ones as `NAME=`) takes the image's default.
"""

import calendar
import json
import os
import re
import secrets
import shutil
import socket
import sqlite3
import string
import subprocess
import sys
import tarfile
import tempfile
import time

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/soulmask/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/soulmask/data")
SAVED_DIR = os.environ.get("FLUX_SAVED_DIR", os.path.join(DATA_DIR, "Saved"))
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
GAMEPLAY_FILE = os.path.join(STATE_DIR, "gameplay.json")
GAMEPLAY_APPLIED = os.path.join(STATE_DIR, "gameplay.applied.json")
ADMIN_PW_FILE = os.path.join(STATE_DIR, "admin-password")
UPLOADS_DIR = os.path.join(STATE_DIR, "uploads")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
BACKUP_INDEX = os.path.join(BACKUP_DIR, "index.json")
RESTORE_FILE = os.path.join(STATE_DIR, "restore-pending.json")
UPDATE_TARGET_FILE = os.path.join(STATE_DIR, "update-target.json")
UPDATE_FAILED_FILE = os.path.join(STATE_DIR, "update-failed.json")
UPDATE_FAILED_SKIP = 6 * 3600
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
PLAYERS_CACHE = os.environ.get("FLUX_PLAYERS_CACHE", "/tmp/flux-players.json")
GAME_PROCESS = os.environ.get("FLUX_GAME_PROCESS", "WSServer-Linux-Shipping")
ECHO_HOST = "127.0.0.1"
ECHO_PORT = int(os.environ.get("FLUX_ECHO_PORT", "18888"))
STEAM_APP = os.environ.get("FLUX_STEAM_APP", "3017300")

TEMPLATES_DIR = os.path.join(SERVER_DIR, "WS", "Config", "GameplaySettings")
LIVE_XISHU = os.path.join(SAVED_DIR, "GameplaySettings", "GameXishu.json")
WORLDS_DIR = os.path.join(SAVED_DIR, "Worlds", "Dedicated")
BAN_FILE = os.path.join(SAVED_DIR, "BlackAccountList.txt")
WHITE_FILE = os.path.join(SAVED_DIR, "WhiteAccountList.txt")
WHITELIST_FILE = os.path.join(STATE_DIR, "whitelist.json")
PLAYER_NAMES = os.path.join(STATE_DIR, "player-names.json")
# Which maps this server has had a world for, and a new world the panel asked for (world-guard).
WORLDS_SEEN = os.path.join(STATE_DIR, "worlds.json")
# When the world went missing, on THIS node (kept off the synced volume, so each node counts its
# own wait), and how long the guard waits for Syncthing before it puts a backup back.
WORLD_MISSING = os.path.join(SERVER_DIR, "flux-world-missing.json")
WORLD_SYNC_GRACE = int(os.environ.get("FLUX_WORLD_SYNC_GRACE_SECONDS", "300"))
CONFLICTS_DIR = os.path.join(STATE_DIR, "sync-conflicts")
# What this image can do for the hub (status "features"). There is no kick: neither the console
# nor RCON has one (build 26158199: `KickPlayer`, `gm KickPlayer`, `kick` are "Not Found!" on
# both; `gm KickPlayer` is an in-game GM command of a player's client).
FEATURES = {"kick": False, "whitelist": True}
# -serverpm, the permission lists on at start (bits: 1 account whitelist, 2 account blacklist,
# 4 IP whitelist, 8 IP blacklist, 16 mute). Without it the game starts with 2+8+16 (measured
# with `lsp`, build 26158199), so bans work; the whitelist adds 1.
SERVERPM_DEFAULT = 2 | 8 | 16
BACKUP_NAME_RE = re.compile(r"^\d{8}-\d{6}-soulmask\.tar\.gz$")
# The game's own hourly copies (BackupDatabaseByHour: YYYYmmddHH.db) and ours are not worlds.
GAME_HOURLY_RE = re.compile(r"^\d{10}\.db$")

# The two maps (1.0 + the Shifting Sands DLC of 2026-04-10). Each keeps its own world:
# Saved/Worlds/Dedicated/<map>/world.db.
MAPS = {"Level01_Main": "Cloud Mist Forest", "DLC_Level01_Main": "Shifting Sands"}
MAP_ALIASES = {
    "level01_main": "Level01_Main", "cloudmist": "Level01_Main", "cloudmistforest": "Level01_Main",
    "cloud-mist-forest": "Level01_Main", "forest": "Level01_Main", "base": "Level01_Main",
    "dlc_level01_main": "DLC_Level01_Main", "shiftingsands": "DLC_Level01_Main",
    "shifting-sands": "DLC_Level01_Main", "sands": "DLC_Level01_Main", "egypt": "DLC_Level01_Main",
}
MODES = ("pve", "pvp")
# The game's ceiling (the client's own server browser and the community images: 70).
MAX_PLAYERS_CAP = 70
TEXT_FORBIDDEN = '"\\\n\r\t'
# The block a mode reads (pve: "1", measured with `lc` against the file; pvp: "0", from the
# PVP template, where block "0" is the one with the PvP-only keys).
MODE_BLOCK = {"pve": "1", "pvp": "0"}
BLOCKS = ("0", "1", "2")
# Keys the panel never writes: the PvP switch is the mode's (SM_MODE, -pve / -pvp). A preset or a
# form default of 0 written into every block could otherwise turn PvP off on a PvP server.
MODE_KEYS = {"HuXIangShangHaiKaiGuan"}

# Console commands the hub must not send raw: the game's SaveAndExit would end the server
# behind the supervisor's back (`restart <seconds>` does the same with the supervisor told).
CONSOLE_REFUSED = {"close", "exit", "shutdown", "saveandexit"}
STEAM_ID_RE = re.compile(r"^7656119\d{10}$")
PLAYER_ROW_SPLIT = re.compile(r"\s*\|\s*")


# ------------------------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data, indent=4):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


def env(name):
    """The value of a variable that is SET to something; None when unset or empty."""
    value = os.environ.get(name)
    return value if value not in (None, "") else None


def clean_text(value, limit):
    """Text for the command line: printable, no quotes or backslashes (Unreal re-parses the
    command line, and a quote would end the value)."""
    value = "".join(c for c in str(value) if c.isprintable() and c not in TEXT_FORBIDDEN).strip()
    return value[:limit]


def clean_password(value, limit):
    """A password for the command line: clean_text without whitespace (one word on the game's
    command line, so the log filter can hide it whole)."""
    return "".join(clean_text(value, 200).split())[:limit]


def max_players(value):
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    return n if 1 <= n <= MAX_PLAYERS_CAP else None


def map_name(value):
    """SM_MAP: the game's map name or a friendly one (cloudmist, shifting-sands...). None when
    it is neither."""
    if value is None:
        return "Level01_Main"
    folded = {re.sub(r"[\s_-]+", "", k): v for k, v in MAP_ALIASES.items()}
    return folded.get(re.sub(r"[\s_-]+", "", str(value).strip().lower()))


def mode_name(value):
    value = str(value or "pve").strip().lower()
    return value if value in MODES else None


def mod_ids(value):
    """SM_MODS: Workshop IDs separated by commas, spaces or semicolons; links are accepted."""
    ids = []
    for part in re.split(r"[,;\s]+", str(value or "")):
        m = re.search(r"(?:id=)?(\d{6,12})", part)
        if m and m.group(1) not in ids:
            ids.append(m.group(1))
    return ids


def minutes(value, default, lo, hi):
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return min(max(n, lo), hi)


def admin_password():
    """SM_ADMIN_PASSWORD, or one chosen once and kept on the data volume (the GM password:
    `gm key <password>` in the game's console)."""
    given = env("SM_ADMIN_PASSWORD")
    if given:
        return clean_password(given, 64), "env"
    try:
        with open(ADMIN_PW_FILE, encoding="utf-8") as f:
            kept = f.read().strip()
        if kept:
            return kept, "generated"
    except OSError:
        pass
    alphabet = string.ascii_letters + string.digits
    chosen = "".join(secrets.choice(alphabet) for _ in range(16))
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(ADMIN_PW_FILE, "w", encoding="utf-8") as f:
        f.write(chosen + "\n")
    os.chmod(ADMIN_PW_FILE, 0o600)
    return chosen, "generated"


def current_settings():
    """What the environment asks for, with the image's defaults."""
    return {
        "name": clean_text(env("SM_SERVER_NAME") or "Soulmask on Flux", 64) or "Soulmask on Flux",
        "password": clean_password(env("SM_PASSWORD") or "", 32),
        "maxPlayers": max_players(env("SM_MAX_PLAYERS") or 20) or 20,
        "map": map_name(env("SM_MAP")) or "Level01_Main",
        "mode": mode_name(env("SM_MODE")) or "pve",
        "mods": mod_ids(env("SM_MODS")),
        "gamePort": int(env("GAME_PORT") or 8777),
        "queryPort": int(env("QUERY_PORT") or 27015),
        "saveMinutes": minutes(env("SM_SAVE_MINUTES"), 5, 1, 60),
    }


# ------------------------------------------------------------------------------------------------
# Gameplay settings (GameXishu.json)
# ------------------------------------------------------------------------------------------------

def number(value):
    """A coefficient as the game writes it: an int when it is whole, else a float."""
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return int(f) if f.is_integer() else f


def template(name=None):
    path = os.path.join(TEMPLATES_DIR, f"GameXishu_Template{'_' + name if name else ''}.json")
    data = read_json(path)
    return data if isinstance(data, dict) else None


def known_keys():
    base = template() or {}
    return set((base.get("0") or {}).keys()) - MODE_KEYS


def merge_gameplay(panel, applied, live_blocks, block):
    """The 3-way merge: returns (panel values to keep, keys adopted from the game).

    A key whose value in the server's file differs from what the last start (or apply-live)
    applied, and that the panel did NOT change since, was changed in game (a GM's `sc`): the
    game's value wins. Only `block` is compared, the one the server reads (MODE_BLOCK): `sc`
    writes that block alone, so the other two still hold older values that mean nothing (comparing
    them took a stale block "0" back into the panel and undid every apply-live, 1.0.1).

    A key absent from the panel's file is not the panel's: it is never written, so the server's
    (or the GM's) value stays. The hub writes only the keys it changed."""
    panel = dict(panel)
    adopted = []
    current = live_blocks.get(block) or {}
    for key, was in applied.items():
        if key not in panel or number(panel[key]) != number(was):
            continue
        now = current.get(key)
        if now is not None and number(now) != number(was):
            panel[key] = number(now)
            adopted.append(key)
    return panel, adopted


def write_gameplay(live, panel, keys):
    """Every panel value into every block of the server's file (keys the game knows only)."""
    for block in BLOCKS:
        target = live.setdefault(block, {})
        for key, value in panel.items():
            if key in keys:
                target[key] = number(value)
    return live


def apply_gameplay(notes):
    panel = read_json(GAMEPLAY_FILE, {}) or {}
    if not isinstance(panel, dict):
        notes.append("WARN flux/gameplay.json is not an object; ignored")
        return
    panel = {k: number(v) for k, v in panel.items() if number(v) is not None}
    applied = read_json(GAMEPLAY_APPLIED, {}) or {}
    live = read_json(LIVE_XISHU)
    if not isinstance(live, dict):
        if not panel:
            return
        live = template()
        if live is None:
            notes.append("WARN no GameXishu template in the install; gameplay settings not written")
            return
        notes.append("gameplay: GameXishu.json created from the game's template")
    keys = known_keys() or (set(live.get("0", {}).keys()) - MODE_KEYS)
    panel, adopted = merge_gameplay(panel, applied, live, MODE_BLOCK[current_settings()["mode"]])
    if adopted:
        notes.append(f"gameplay: kept {len(adopted)} value(s) changed in game: {', '.join(sorted(adopted)[:8])}")
        write_json(GAMEPLAY_FILE, panel, indent=2)
    unknown = sorted(k for k in panel if k not in keys)
    if unknown:
        notes.append(f"WARN gameplay: unknown key(s) ignored: {', '.join(unknown[:8])}")
    if panel:
        write_json(LIVE_XISHU, write_gameplay(live, panel, keys), indent="\t")
        notes.append(f"gameplay: {len([k for k in panel if k in keys])} value(s) written to GameXishu.json")
    write_json(GAMEPLAY_APPLIED, {k: v for k, v in panel.items() if k in keys}, indent=None)


def preset_names():
    """Every GameXishu_Template_<name>.json in the install (presets and the hosted-server
    templates the game ships)."""
    try:
        files = os.listdir(TEMPLATES_DIR)
    except OSError:
        return []
    return sorted(f[len("GameXishu_Template_"):-5] for f in files
                  if f.startswith("GameXishu_Template_") and f.endswith(".json"))


def preset_values(name, mode):
    """A preset as full values: the base template's block for the mode, with what the preset
    changes on top. What it changes is read from block "0" AND from the mode's block: the
    difficulty templates (Jiandan, Dashi...) change blocks "0" and "2" and leave the PvE block
    "1" as the base (build 25955350), while the hosted-server ones (PvE_04P_3x) change only "1"."""
    base = template() or {}
    over = template(name)
    if over is None:
        return None
    block = MODE_BLOCK.get(mode, "1")
    values = dict(base.get(block) or base.get("0") or {})
    for b in dict.fromkeys(("0", block)):
        for key, value in (over.get(b) or {}).items():
            if number(value) != number((base.get(b) or {}).get(key)):
                values[key] = value
    return {k: number(v) for k, v in values.items() if number(v) is not None and k not in MODE_KEYS}


def cmd_gameplay():
    s = current_settings()
    live = read_json(LIVE_XISHU) or {}
    block = MODE_BLOCK[s["mode"]]
    out({
        "mode": s["mode"],
        "block": block,
        "panel": read_json(GAMEPLAY_FILE, {}) or {},
        "server": (live.get(block) if isinstance(live, dict) else None) or {},
        "defaults": (template() or {}).get(block) or {},
        "presets": preset_names(),
        "running": bool(game_pids()),
    })


def cmd_preset(name):
    if not re.match(r"^[A-Za-z0-9_~-]{1,80}$", name):
        fail("no such preset", 2)
    mode = current_settings()["mode"]
    values = preset_values(name, mode)
    if not values:
        fail("no such preset", 2)
    write_json(GAMEPLAY_FILE, values, indent=2)
    out({"ok": True, "preset": name, "values": len(values), "appliesOn": "restart or apply-live"})


def cmd_apply_live():
    """The panel's values onto the running server with the console's Set_Coefficient (`sc`),
    which also writes the server's own file. Only what differs is sent."""
    if not game_pids():
        fail("the server is not running", 3)
    s = current_settings()
    panel = {k: number(v) for k, v in (read_json(GAMEPLAY_FILE, {}) or {}).items() if number(v) is not None}
    live = read_json(LIVE_XISHU) or {}
    current = (live.get(MODE_BLOCK[s["mode"]]) or {}) if isinstance(live, dict) else {}
    keys = known_keys() or (set(current) - MODE_KEYS)
    todo = [(k, v) for k, v in sorted(panel.items()) if k in keys and number(current.get(k)) != v]
    changed, failed = [], []
    if todo:
        replies = console_many([f"sc {k} {v}" for k, v in todo], first_timeout=10.0)
        for (k, v), reply in zip(todo, replies):
            (changed if "(updated)" in reply else failed).append({"key": k, "value": v, "reply": reply.strip()[:200]})
    applied = read_json(GAMEPLAY_APPLIED, {}) or {}
    applied.update({c["key"]: c["value"] for c in changed})
    write_json(GAMEPLAY_APPLIED, applied, indent=None)
    out({"ok": not failed, "changed": changed, "failed": failed, "unchanged": len(panel) - len(todo)})


# ------------------------------------------------------------------------------------------------
# The command line
# ------------------------------------------------------------------------------------------------

def command_args(notes):
    s = current_settings()
    pw, source = admin_password()
    if env("SM_MAP") and not map_name(env("SM_MAP")):
        notes.append(f"WARN SM_MAP={env('SM_MAP')!r} is not a map; Cloud Mist Forest")
    if env("SM_MODE") and not mode_name(env("SM_MODE")):
        notes.append(f"WARN SM_MODE={env('SM_MODE')!r} is neither pve nor pvp; pve")
    if env("SM_MAX_PLAYERS") and not max_players(env("SM_MAX_PLAYERS")):
        notes.append(f"WARN SM_MAX_PLAYERS={env('SM_MAX_PLAYERS')!r} is not 1-{MAX_PLAYERS_CAP}; 20")
    save = s["saveMinutes"] * 60
    args = [
        s["map"], "-server", "-log", "-UTF8Output", "-forcepassthrough",
        "-MULTIHOME=0.0.0.0", f"-Port={s['gamePort']}", f"-QueryPort={s['queryPort']}",
        f"-EchoPort={ECHO_PORT}", "-online=Steam",
        f"-SteamServerName={s['name']}", f"-MaxPlayers={s['maxPlayers']}", f"-{s['mode']}",
        # -saving: game objects into the in-memory database; -backup: that database onto disk.
        # Both at the same interval, so a crash loses at most SM_SAVE_MINUTES.
        f"-saving={save}", f"-backup={save}",
        f"-adminpsw={pw}",
    ]
    if s["password"]:
        args.append(f"-PSW={s['password']}")
    if s["mods"]:
        args.append(f"-mod={','.join(s['mods'])}")
    extra_args = []
    extra = env("SM_EXTRA_ARGS")
    if extra:
        for part in extra.split():
            part = clean_text(part, 200)
            if part.startswith("-") and not re.match(r"^-(Port|QueryPort|EchoPort|MULTIHOME|adminpsw|PSW)=", part, re.I):
                extra_args.append(part)
            elif part:
                notes.append(f"WARN SM_EXTRA_ARGS: {part!r} ignored (not an option, or one the image sets)")
    # The permission lists on at start: the game's own default plus the whitelist when the panel
    # turned it on. An -serverpm in SM_EXTRA_ARGS wins.
    if not any(re.match(r"^-serverpm=", a, re.I) for a in extra_args):
        args.append(f"-serverpm={serverpm_mask()}")
    args += extra_args
    notes.append(f"{MAPS[s['map']]} ({s['map']}), {s['mode'].upper()}, {s['maxPlayers']} players, "
                 f"game UDP {s['gamePort']}, query UDP {s['queryPort']}, saves every {s['saveMinutes']} min, "
                 f"{'a join password' if s['password'] else 'no join password'}, GM password from "
                 f"{'SM_ADMIN_PASSWORD' if source == 'env' else 'flux/admin-password'}"
                 + (f", mods {','.join(s['mods'])}" if s["mods"] else ""))
    return args


def cmd_apply():
    notes = []
    try:
        apply_gameplay(notes)
    except (OSError, ValueError) as e:
        notes.append(f"WARN gameplay settings not written: {e}")
    args = command_args(notes)
    for n in notes:
        print(f"# {n}")
    for a in args:
        print(a)


# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

def cmd_state(state, message=None):
    """`generation` counts the server's starts: the panel waits for it to change after asking for
    a restart, rather than comparing its own clock with this machine's."""
    data = read_json(STATE_FILE, {}) or {}
    previous = data.get("state")
    if previous != state:
        data["since"] = int(time.time())
    # One start is one generation, however many steps of it say "starting" (loading the world,
    # then building its dungeons).
    if state == "starting" and previous != "starting":
        data["generation"] = int(data.get("generation") or 0) + 1
        data.pop("inviteCode", None)
    # A stopped server has no invite code to join with and no restart coming.
    if state == "stopped":
        for key in ("inviteCode", "nextRestart", "updateWaiting"):
            data.pop(key, None)
    data.update({"state": state, "message": message or None,
                 "image": os.environ.get("FLUX_IMAGE_VERSION", "dev")})
    write_json(STATE_FILE, data, indent=None)


NOTE_KEYS = ("nextRestart", "updateWaiting", "inviteCode")


def cmd_note(key, value=None):
    if key not in NOTE_KEYS:
        fail(f"unknown note {key}", 64)
    data = read_json(STATE_FILE, {}) or {}
    if value in (None, ""):
        data.pop(key, None)
    else:
        data[key] = int(value) if key == "nextRestart" and str(value).isdigit() else value
    write_json(STATE_FILE, data, indent=None)


def installed_build():
    path = os.path.join(SERVER_DIR, "steamapps", f"appmanifest_{STEAM_APP}.acf")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
        return m.group(1) if m else None
    except OSError:
        return None


def game_pids():
    try:
        res = subprocess.run(["pgrep", "-f", f"/{GAME_PROCESS} "], capture_output=True, text=True, timeout=5)
        return [int(p) for p in res.stdout.split()]
    except (OSError, subprocess.SubprocessError, ValueError):
        return []


# ------------------------------------------------------------------------------------------------
# The maintenance console (echo port)
# ------------------------------------------------------------------------------------------------

def _read_reply(sock, first_timeout, idle):
    """Everything the game sends for one command: waits up to first_timeout for the first byte
    (a forced save answers after 3-11 s), then until it has been quiet for `idle` seconds."""
    chunks = []
    sock.settimeout(first_timeout)
    while True:
        try:
            data = sock.recv(65536)
        except socket.timeout:
            break
        if not data:
            break
        chunks.append(data)
        sock.settimeout(idle)
    return b"".join(chunks).decode("utf-8", errors="replace").replace("\r", "")


def console_many(commands, first_timeout=15.0, idle=0.7):
    """Several commands on one connection; one reply each. The help pager ("QUERY INTERACTIVE
    MODE") is paged through to its end and left with `q`, so the connection is never stuck in it."""
    replies = []
    with socket.create_connection((ECHO_HOST, ECHO_PORT), timeout=5) as sock:
        for command in commands:
            sock.sendall((command + "\r\n").encode("utf-8"))
            text = _read_reply(sock, first_timeout, idle)
            pages = 0
            while "QUERY INTERACTIVE MODE" in text[-400:] and pages < 20:
                pages += 1
                m = re.findall(r"PAGE:\s*(\d+)\s*of\s*(\d+)", text)
                last = m and m[-1][0] == m[-1][1]
                sock.sendall(b"q\r\n" if last else b"n\r\n")
                more = _read_reply(sock, 5.0, idle)
                text += more
                if last:
                    break
            text = re.sub(r"=+QUERY INTERACTIVE MODE=+\n(\|.*\|\n)+=+\n?", "", text)
            text = text.replace("Query exited.", "").rstrip() + "\n"
            replies.append(text)
    return replies


def console(command, first_timeout=15.0):
    return console_many([command], first_timeout=first_timeout)[0]


def console_refused(command):
    words = str(command).strip().split()
    return bool(words) and words[0].lower() in CONSOLE_REFUSED


def cmd_console(*parts):
    command = " ".join(parts).strip()
    if not command or "\n" in command or "\r" in command:
        print("Nothing to send.")
        sys.exit(2)
    if console_refused(command):
        print("Refused: this would stop the server behind the supervisor's back. Use the panel's "
              "Restart (or `flux-soulmask restart <seconds>` for a countdown).")
        sys.exit(2)
    if not game_pids():
        print("The server is not running.")
        sys.exit(3)
    try:
        sys.stdout.write(console(command))
    except OSError as e:
        print(f"The server's console did not answer ({e}). It may still be loading the world.")
        sys.exit(4)


def parse_table(text):
    """The console's tables: `| a | b |` rows under a header row. A list of dicts by header."""
    rows = [r for r in text.splitlines() if r.strip().startswith("|") and r.strip().endswith("|")]
    if not rows:
        return []
    header = [h for h in PLAYER_ROW_SPLIT.split(rows[0].strip().strip("|").strip())]
    out_rows = []
    for row in rows[1:]:
        cells = PLAYER_ROW_SPLIT.split(row.strip().strip("|").strip())
        if len(cells) == len(header):
            out_rows.append(dict(zip(header, cells)))
    return out_rows


def parse_players(text):
    """`lp` (List_OnlinePlayers): | Account | PlayerName | PawnID | Position |."""
    players = []
    for r in parse_table(text):
        account = r.get("Account", "").strip()
        if not account:
            continue
        players.append({"id": account, "name": r.get("PlayerName", "").strip(),
                        "pawn": r.get("PawnID", "").strip() or None,
                        "position": r.get("Position", "").strip() or None})
    return players


def parse_all_players(text):
    """`lap` (List_AllPlayers): | Account | PlayerName | Guild | Level | TotalOnline | Birthday |."""
    rows = []
    for r in parse_table(text):
        if not r.get("Account", "").strip():
            continue
        rows.append({"id": r["Account"].strip(), "name": r.get("PlayerName", "").strip(),
                     "guild": r.get("Guild", "").strip() or None, "level": r.get("Level", "").strip() or None,
                     "online": r.get("TotalOnline", "").strip() or None, "birthday": r.get("Birthday", "").strip() or None})
    return rows


def online_players(max_age=15):
    """`lp`, cached for max_age seconds (the hub polls)."""
    cached = read_json(PLAYERS_CACHE)
    now = time.time()
    if isinstance(cached, dict) and now - cached.get("at", 0) < max_age:
        return cached.get("players")
    try:
        players = parse_players(console("lp", first_timeout=5.0))
    except OSError:
        return None
    try:
        write_json(PLAYERS_CACHE, {"at": now, "players": players}, indent=None)
    except OSError:
        pass
    return players


def cmd_players():
    if not game_pids():
        fail("the server is not running", 3)
    try:
        online, known = console_many(["lp", "lap"], first_timeout=8.0)
    except OSError as e:
        fail(f"the server's console did not answer ({e})", 4)
    out({"online": parse_players(online), "all": parse_all_players(known)})


# ------------------------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------------------------

def cmd_status():
    state = read_json(STATE_FILE, {}) or {}
    s = current_settings()
    running = state.get("state") == "running" and bool(game_pids())
    players = online_players() if running else []
    out({
        "state": state.get("state", "stopped"),
        "message": state.get("message"),
        "since": state.get("since"),
        "generation": state.get("generation", 0),
        "nextRestart": state.get("nextRestart"),
        "updateWaiting": state.get("updateWaiting"),
        "restartPending": os.path.exists(RESTART_MARKER),
        "restorePending": (read_json(RESTORE_FILE, {}) or {}).get("backup"),
        "image": state.get("image"),
        "build": installed_build(),
        "name": s["name"],
        "map": s["map"],
        "mapName": MAPS[s["map"]],
        "mode": s["mode"],
        "players": players,
        "max_players": s["maxPlayers"],
        "inviteCode": state.get("inviteCode") if state.get("state") != "stopped" else None,
        "passwordSet": bool(s["password"]),
        "mods": s["mods"],
        "gamePort": s["gamePort"],
        "queryPort": s["queryPort"],
        "lastAction": state.get("lastAction"),
        "features": dict(FEATURES),
    })


def cmd_connect():
    s = current_settings()
    state = read_json(STATE_FILE, {}) or {}
    pw, source = admin_password()
    out({"gamePort": s["gamePort"], "queryPort": s["queryPort"], "inviteCode": state.get("inviteCode"),
         "password": s["password"] or None, "adminPassword": pw, "adminPasswordFrom": source})


# ------------------------------------------------------------------------------------------------
# Bans: Saved/BlackAccountList.txt, one account per line, written by the game itself when the
# console's Update_ServerPermissionList (`usp 1 1 <id>`) adds one. Live when the server runs
# (the game reads its list only at start, so the file alone would wait for a restart).
# ------------------------------------------------------------------------------------------------

def read_ban_file():
    try:
        with open(BAN_FILE, encoding="utf-8-sig") as f:
            return [line.strip() for line in f if line.strip()]
    except OSError:
        return []


def write_ban_file(ids):
    os.makedirs(os.path.dirname(BAN_FILE), exist_ok=True)
    with open(BAN_FILE + ".tmp", "w", encoding="utf-8") as f:
        f.write("".join(f"{i}\n" for i in ids))
    os.replace(BAN_FILE + ".tmp", BAN_FILE)


def parse_permissions(text):
    """`lsp`: numbered lists, each with `status:` and `values:` then `|   <id>` rows."""
    lists, current = {}, None
    for line in text.splitlines():
        m = re.match(r"^\s*(\d+)\.\s*(\w+)\s*$", line)
        if m:
            current = m.group(2)
            lists[current] = {"index": int(m.group(1)), "enabled": None, "values": []}
            continue
        if current is None:
            continue
        m = re.match(r"^\s*status:\s*(\w+)", line)
        if m:
            lists[current]["enabled"] = m.group(1).lower() == "yes"
            continue
        m = re.match(r"^\s*\|\s*(\S+)\s*$", line)
        if m:
            lists[current]["values"].append(m.group(1))
    return lists


def cmd_bans():
    live = None
    if game_pids():
        try:
            live = parse_permissions(console("lsp", first_timeout=5.0))
        except OSError:
            live = None
    if live and "BlackAccountList" in live:
        out({"bans": live["BlackAccountList"]["values"], "muted": (live.get("BanSpeek") or {}).get("values", []),
             "source": "live", "lists": live})
    else:
        out({"bans": read_ban_file(), "muted": [], "source": "file", "lists": None})


def cmd_ban(steam_id, add=True):
    steam_id = str(steam_id).strip()
    if not STEAM_ID_RE.match(steam_id):
        fail("not a SteamID64 (17 digits, 7656119...)", 2)
    if game_pids():
        try:
            reply = console(f"usp 1 {1 if add else 0} {steam_id}", first_timeout=5.0)
            if "done" in reply.lower():
                out({"ok": True, "id": steam_id, "banned": add, "live": True})
                return
        except OSError:
            pass
    ids = [i for i in read_ban_file() if i != steam_id]
    if add:
        ids.append(steam_id)
    write_ban_file(ids)
    out({"ok": True, "id": steam_id, "banned": add, "live": False})


# ------------------------------------------------------------------------------------------------
# The whitelist: Saved/WhiteAccountList.txt (list 0 of the console's `usp` / `ssp`), written by
# the game when `usp 0 1 <id>` adds one. Whether it is ON is ours (flux/whitelist.json): set live
# with `ssp 0 1|0` and on every start with -serverpm (the game forgets `ssp` at a restart).
# An enabled whitelist with nobody on it lets NOBODY in (the game says "Server is still
# self-testing!"); the hub warns before turning it on.
# ------------------------------------------------------------------------------------------------

def whitelist_enabled():
    data = read_json(WHITELIST_FILE, {}) or {}
    return bool(data.get("enabled")) if isinstance(data, dict) else False


def serverpm_mask():
    return SERVERPM_DEFAULT | (1 if whitelist_enabled() else 0)


def read_id_file(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return [line.strip() for line in f if line.strip()]
    except OSError:
        return []


def write_id_file(path, ids):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write("".join(f"{i}\n" for i in ids))
    os.replace(path + ".tmp", path)


def known_names(rows=None):
    """SteamID64 -> player name, from `lap` rows when given (kept in flux/player-names.json for
    when the server is down)."""
    names = read_json(PLAYER_NAMES, {}) or {}
    if not isinstance(names, dict):
        names = {}
    if rows:
        fresh = {r["id"]: r["name"] for r in rows if r.get("id") and r.get("name")}
        if any(names.get(k) != v for k, v in fresh.items()):
            names.update(fresh)
            try:
                write_json(PLAYER_NAMES, names, indent=None)
            except OSError:
                pass
    return names


def cmd_whitelist(action=None, steam_id=None):
    if action is None:
        live, rows = None, None
        if game_pids():
            try:
                perm, known = console_many(["lsp", "lap"], first_timeout=8.0)
                live = parse_permissions(perm).get("WhiteAccountList")
                rows = parse_all_players(known)
            except OSError:
                live = None
        names = known_names(rows)
        ids = live["values"] if live else read_id_file(WHITE_FILE)
        enabled = live["enabled"] if live and live.get("enabled") is not None else whitelist_enabled()
        out({"enabled": bool(enabled), "ids": [{"id": i, "name": names.get(i)} for i in ids]})
        return
    if action in ("on", "off"):
        if steam_id is not None:
            fail("usage: whitelist on|off", 64)
        on = action == "on"
        write_json(WHITELIST_FILE, {"enabled": on, "at": int(time.time())}, indent=None)
        restart = False
        if game_pids():
            try:
                reply = console(f"ssp 0 {1 if on else 0}", first_timeout=5.0)
                restart = f"status is: {'ON' if on else 'OFF'}" not in reply
            except OSError:
                restart = True
        out({"ok": True, "restart": restart})
        return
    if action in ("add", "remove"):
        steam_id = str(steam_id or "").strip()
        if not STEAM_ID_RE.match(steam_id):
            fail("not a SteamID64 (17 digits, 7656119...)", 2)
        add = action == "add"
        if game_pids():
            try:
                if "done" in console(f"usp 0 {1 if add else 0} {steam_id}", first_timeout=5.0).lower():
                    out({"ok": True})
                    return
            except OSError:
                pass
        ids = [i for i in read_id_file(WHITE_FILE) if i != steam_id]
        if add:
            ids.append(steam_id)
        write_id_file(WHITE_FILE, ids)
        out({"ok": True})
        return
    fail("usage: whitelist [on|off|add <id>|remove <id>]", 64)


# ------------------------------------------------------------------------------------------------
# Restarts
# ------------------------------------------------------------------------------------------------

def request_restart(reason, not_before=0):
    """Asks the supervisor for a restart and returns at once: the marker it reads, with the
    earliest time it may stop the server itself. One restart at a time."""
    if os.path.exists(RESTART_MARKER):
        return False
    tmp = RESTART_MARKER + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"{reason}\nnotbefore={int(not_before)}\n")
    os.replace(tmp, RESTART_MARKER)
    return True


def cmd_restart(seconds=None):
    """Restarts the server in place. With seconds (10-3600): the game's own SaveAndExit countdown
    (`close <seconds>`, which tells the players), then the supervisor starts the next one."""
    if not game_pids():
        fail("the server is not running", 3)
    state = read_json(STATE_FILE, {}) or {}
    delay = 0
    if seconds not in (None, "", "0"):
        try:
            delay = min(max(int(seconds), 10), 3600)
        except ValueError:
            fail("seconds must be a number", 2)
    # The supervisor stops the server itself only if the countdown has not done it by then.
    started = request_restart("requested: from the panel", time.time() + (delay + 60 if delay else 0))
    countdown = False
    if started and delay:
        try:
            countdown = "not found" not in console(f"close {delay}", first_timeout=5.0).lower()
        except OSError:
            countdown = False
        if not countdown:
            os.remove(RESTART_MARKER)
            request_restart("requested: from the panel")
    out({"ok": True, "alreadyPending": not started, "countdown": countdown, "seconds": delay,
         "generation": state.get("generation", 0)})


# ------------------------------------------------------------------------------------------------
# Backups: flux/backups/<UTC>-soulmask.tar.gz, made by the supervisor (on start and every few
# hours), by the panel, and before a restore. index.json says why each was made.
#
# What is in one: Saved/Worlds (each map's world.db, copied with SQLite's online backup, so a
# running server's database is copied consistently), GameplaySettings, the permission lists
# (*.txt) and flux/gameplay.json. Not the game's own hourly copies.
#
# Kept: the FLUX_BACKUP_KEEP newest, AND the newest older than a day and the newest older than a
# week, so a server that crash-loops (each start a backup) can never rotate every good copy away.
# ------------------------------------------------------------------------------------------------

def backup_files():
    try:
        return sorted((n for n in os.listdir(BACKUP_DIR) if BACKUP_NAME_RE.match(n)), reverse=True)
    except OSError:
        return []


def backup_time(name):
    try:
        return calendar.timegm(time.strptime(name[:15], "%Y%m%d-%H%M%S"))
    except ValueError:
        return 0


def backups_to_keep(names, keep, now):
    kept = set(names[:max(keep, 0)])
    for age in (86400, 7 * 86400):
        older = [n for n in names if now - backup_time(n) >= age]
        if older:
            kept.add(older[0])
    return kept


def is_conflict(name):
    """A Syncthing conflict copy (name.sync-conflict-<date>-<time>-<device>.ext): never a world,
    never in a backup."""
    return "sync-conflict" in os.path.basename(name)


def no_conflicts(info):
    return None if is_conflict(info.name) else info


def world_files():
    """(path, arcname) of every world database: Saved/Worlds/Dedicated/<map>/*.db."""
    found = []
    for root, _dirs, files in os.walk(os.path.join(SAVED_DIR, "Worlds")):
        for f in files:
            if f.endswith(".db") and not GAME_HOURLY_RE.match(f) and not is_conflict(f):
                p = os.path.join(root, f)
                found.append((p, os.path.relpath(p, DATA_DIR)))
    return sorted(found)


def sqlite_copy(src, dst):
    """A consistent copy of a database the server may be writing (SQLite's online backup)."""
    s = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=30)
    try:
        d = sqlite3.connect(dst)
        try:
            s.backup(d)
        finally:
            d.close()
    finally:
        s.close()


def cmd_backup(why, force=None):
    names = backup_files()
    now = int(time.time())
    min_age = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60")) * 60
    if force != "force" and names and now - backup_time(names[0]) < min_age:
        print(f"# backup ({why}) skipped: the newest is {(now - backup_time(names[0])) // 60} min old")
        return None
    # A running server keeps the world in memory and writes it every few minutes: a forced save
    # first, so the copy is the world as it is now.
    if game_pids():
        try:
            console("sav 1", first_timeout=20.0)
        except OSError:
            print("# WARN backup: the forced save did not answer; copying the last save")
    worlds = world_files()
    if not worlds:
        print("# backup skipped: no world yet")
        return None
    os.makedirs(BACKUP_DIR, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now)) + "-soulmask.tar.gz"
    # Names are to the second: a forced one (a restore's safety backup) waits for the next.
    while name in names and force == "force":
        time.sleep(1)
        now = int(time.time())
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now)) + "-soulmask.tar.gz"
    if name in names:
        print(f"# backup ({why}) skipped: one was made this second")
        return None
    out_path = os.path.join(BACKUP_DIR, name)
    staging = tempfile.mkdtemp(dir=STATE_DIR, prefix=".flux-backup-")
    try:
        with tarfile.open(out_path + ".part", "w:gz") as t:
            for path, arc in worlds:
                copy = os.path.join(staging, "w.db")
                try:
                    sqlite_copy(path, copy)
                except sqlite3.Error:
                    shutil.copy2(path, copy)
                t.add(copy, arcname=arc)
                os.remove(copy)
            for extra in ("GameplaySettings",):
                p = os.path.join(SAVED_DIR, extra)
                if os.path.isdir(p):
                    t.add(p, arcname=os.path.relpath(p, DATA_DIR), filter=no_conflicts)
            for f in sorted(os.listdir(SAVED_DIR)) if os.path.isdir(SAVED_DIR) else []:
                if f.endswith(".txt") and not is_conflict(f) and os.path.isfile(os.path.join(SAVED_DIR, f)):
                    t.add(os.path.join(SAVED_DIR, f), arcname=os.path.relpath(os.path.join(SAVED_DIR, f), DATA_DIR))
            if os.path.isfile(GAMEPLAY_FILE):
                t.add(GAMEPLAY_FILE, arcname=os.path.relpath(GAMEPLAY_FILE, DATA_DIR))
        os.replace(out_path + ".part", out_path)
    except (OSError, tarfile.TarError) as e:
        try:
            os.remove(out_path + ".part")
        except OSError:
            pass
        print(f"# WARN backup ({why}) failed: {e}")
        return None
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    index = read_json(BACKUP_INDEX, {}) or {}
    index[name] = why
    keep = int(os.environ.get("FLUX_BACKUP_KEEP", "10"))
    names = backup_files()
    kept = backups_to_keep(names, keep, now)
    for old in names:
        if old not in kept:
            try:
                os.remove(os.path.join(BACKUP_DIR, old))
            except OSError:
                pass
            index.pop(old, None)
    write_json(BACKUP_INDEX, {k: v for k, v in index.items() if k in kept}, indent=None)
    print(f"# backup ({why}): flux/backups/{name}, {os.path.getsize(out_path) // 1024} KB")
    return name


def cmd_backup_cli(why, force=None):
    """The panel's "back up now": the JSON the hub reads."""
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        name = cmd_backup(why, force)
    notes = [line[2:] for line in buf.getvalue().splitlines() if line.startswith("# ")]
    if os.environ.get("FLUX_BACKUP_TEXT"):
        print(buf.getvalue(), end="")
        return
    if not name:
        fail(notes[-1] if notes else "no backup made", 5)
    out({"ok": True, "name": name, "size": os.path.getsize(os.path.join(BACKUP_DIR, name)), "notes": notes})


def backup_maps(path):
    try:
        with tarfile.open(path) as t:
            return sorted({m.group(1) for m in (re.search(r"Worlds/Dedicated/([^/]+)/world\.db$", n) for n in t.getnames()) if m})
    except (OSError, tarfile.TarError):
        return []


def cmd_backups():
    index = read_json(BACKUP_INDEX, {}) or {}
    rows = []
    for n in backup_files():
        p = os.path.join(BACKUP_DIR, n)
        rows.append({"name": n, "size": os.path.getsize(p), "created": backup_time(n), "reason": index.get(n),
                     "maps": backup_maps(p)})
    out({"backups": rows, "path": "flux/backups", "pending": (read_json(RESTORE_FILE, {}) or {}).get("backup")})


def pend(action, value, reason):
    write_json(RESTORE_FILE, {"action": action, "backup": value, "map": current_settings()["map"],
                              "at": int(time.time())}, indent=None)
    restarting = bool(game_pids()) and request_restart(f"requested: {reason}")
    out({"ok": True, "backup": value, "serverQuit": restarting, "restarting": restarting, "appliesOn": "restart"})


def cmd_restore(name):
    if not BACKUP_NAME_RE.match(str(name)) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("no such backup", 2)
    pend("restore", name, f"restore {name}")


def remove_upload(name):
    try:
        os.remove(os.path.join(UPLOADS_DIR, os.path.basename(str(name))))
    except OSError:
        pass


def check_world_db(path):
    """A Soulmask world: SQLite that passes quick_check and has the game's actor_table. Raises
    ValueError with the reason otherwise."""
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            if con.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise ValueError("the database is damaged")
            if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='actor_table'").fetchone():
                raise ValueError("an SQLite database, but not a Soulmask world (no actor_table)")
        finally:
            con.close()
    except sqlite3.Error as e:
        raise ValueError(f"not a readable database ({e})")


def world_usable(path):
    try:
        if os.path.getsize(path) == 0:
            return False
        check_world_db(path)
        return True
    except (OSError, ValueError):
        return False


def cmd_import(name):
    """A file the owner uploaded to flux/uploads: a world.db (SQLite) becomes the current map's
    world; one of our backups is restored (see extract_backup). A file that is neither is refused
    and removed."""
    if "/" in name or name.startswith(".") or not os.path.isfile(os.path.join(UPLOADS_DIR, name)):
        fail("no such file in flux/uploads", 2)
    path = os.path.join(UPLOADS_DIR, name)
    with open(path, "rb") as f:
        head = f.read(16)
    if head.startswith(b"SQLite format 3"):
        try:
            check_world_db(path)
        except ValueError as e:
            remove_upload(name)
            fail(f"not a Soulmask world: {e}", 2)
        pend("import-db", name, f"import {name}")
    elif head[:2] == b"\x1f\x8b" and backup_maps(path):
        pend("import-backup", name, f"import {name}")
    else:
        remove_upload(name)
        fail("not a Soulmask world (world.db) or one of this panel's backups", 2)


def cmd_new_world():
    pend("new-world", None, "a new world")


def remove_world(world_dir):
    for f in ("world.db", "world.db-wal", "world.db-shm", "world.db-journal"):
        try:
            os.remove(os.path.join(world_dir, f))
        except OSError:
            pass


def put_world(src, the_map):
    """src (a checked world.db) becomes the_map's world, atomically."""
    world_dir = os.path.join(WORLDS_DIR, the_map)
    os.makedirs(world_dir, exist_ok=True)
    shutil.copy2(src, os.path.join(world_dir, "world.db.flux-new"))
    remove_world(world_dir)
    os.replace(os.path.join(world_dir, "world.db.flux-new"), os.path.join(world_dir, "world.db"))


def extract_backup(src, the_map, worlds_only=False):
    """Our backup back, through a staging folder (a broken archive changes nothing).

    The worlds: the_map's (the one this server runs) is replaced, and the backup must have it.
    Another map's world in the backup is put back only where this server has no usable world
    for that map, so restoring never rolls back (or deletes) the world of a map not in use.
    Then, unless worlds_only: GameplaySettings, the permission lists and flux/gameplay.json."""
    staging = tempfile.mkdtemp(dir=DATA_DIR, prefix=".flux-restore-")
    try:
        with tarfile.open(src) as t:
            members = [m for m in t.getmembers() if m.name.startswith(("Saved/", "flux/gameplay.json"))
                       and not is_conflict(m.name)]
            if not members or any(m.issym() or m.islnk() or ".." in m.name.split("/") for m in members):
                raise ValueError("not a Soulmask backup")
            if worlds_only:
                members = [m for m in members if m.name.startswith("Saved/Worlds/")]
            t.extractall(staging, members=members, filter="data")
        worlds_src = os.path.join(staging, "Saved", "Worlds", "Dedicated")
        mine = os.path.join(worlds_src, the_map, "world.db")
        if not os.path.isfile(mine):
            raise ValueError(f"the backup has no {MAPS.get(the_map, the_map)} world")
        check_world_db(mine)
        put_world(mine, the_map)
        for other in sorted(os.listdir(worlds_src)):
            db = os.path.join(worlds_src, other, "world.db")
            if other == the_map or other not in MAPS or not os.path.isfile(db):
                continue
            if not world_usable(os.path.join(WORLDS_DIR, other, "world.db")) and world_usable(db):
                put_world(db, other)
                print(f"# the {MAPS[other]} world was missing here: put back from the backup too")
        if worlds_only:
            return
        gs = os.path.join(staging, "Saved", "GameplaySettings")
        if os.path.isdir(gs):
            shutil.rmtree(os.path.join(SAVED_DIR, "GameplaySettings"), ignore_errors=True)
            os.replace(gs, os.path.join(SAVED_DIR, "GameplaySettings"))
        for f in os.listdir(os.path.join(staging, "Saved")):
            if f.endswith(".txt"):
                os.replace(os.path.join(staging, "Saved", f), os.path.join(SAVED_DIR, f))
        gp = os.path.join(staging, "flux", "gameplay.json")
        if os.path.isfile(gp):
            os.replace(gp, GAMEPLAY_FILE)
            # The restored GameXishu.json and gameplay.json agree: nothing to adopt from the game.
            shutil.copy2(GAMEPLAY_FILE, GAMEPLAY_APPLIED)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def record_last_action(kind, name, ok, error=None):
    """status.lastAction: the restore / import / new world the panel asked for, as the start that
    applied (or refused) it saw it. generation = the start it belongs to (the one about to run)."""
    data = read_json(STATE_FILE, {}) or {}
    data["lastAction"] = {"kind": kind, "name": name, "generation": int(data.get("generation") or 0) + 1,
                          "ok": bool(ok), "error": error, "at": iso_now()}
    write_json(STATE_FILE, data, indent=None)


ACTION_KIND = {"restore": "restore", "import-db": "import", "import-backup": "import", "new-world": "new-world"}


def cmd_do_restore():
    """The supervisor, before a start: the pending restore, import or new world. A safety backup
    first; a broken archive or database leaves everything as it was."""
    pending = read_json(RESTORE_FILE)
    if not isinstance(pending, dict):
        return
    try:
        os.remove(RESTORE_FILE)
    except OSError:
        pass
    action = pending.get("action", "restore")
    kind = ACTION_KIND.get(action, action)
    name = pending.get("backup") or None
    the_map = pending.get("map") if pending.get("map") in MAPS else current_settings()["map"]
    world_dir = os.path.join(WORLDS_DIR, the_map)
    try:
        if action == "restore":
            src = os.path.join(BACKUP_DIR, name or "")
            if not BACKUP_NAME_RE.match(name or "") or not os.path.isfile(src):
                raise ValueError(f"{name} is not a backup")
            cmd_backup("before restoring " + name, "force")
            extract_backup(src, the_map)
            print(f"# restored {name} ({MAPS[the_map]})")
        elif action == "import-backup":
            src = os.path.join(UPLOADS_DIR, os.path.basename(name or ""))
            cmd_backup("before importing " + name, "force")
            extract_backup(src, the_map)
            remove_upload(name)
            print(f"# imported the backup {name} ({MAPS[the_map]})")
        elif action == "import-db":
            src = os.path.join(UPLOADS_DIR, os.path.basename(name or ""))
            check_world_db(src)
            cmd_backup("before importing " + name, "force")
            put_world(src, the_map)
            remove_upload(name)
            print(f"# imported {name} as the {MAPS[the_map]} world")
        elif action == "new-world":
            cmd_backup("before a new world", "force")
            remove_world(world_dir)
            seen = read_json(WORLDS_SEEN, {}) or {}
            seen[the_map] = {"newWorld": int(time.time())}
            write_json(WORLDS_SEEN, seen, indent=None)
            print(f"# the {MAPS[the_map]} world starts over (the old one is in the backup just made)")
        else:
            raise ValueError(f"unknown action {action}")
    except (OSError, tarfile.TarError, ValueError, sqlite3.Error) as e:
        if action in ("import-db", "import-backup"):
            remove_upload(name)
        print(f"# WARN {action} of {name or the_map} failed ({e}); nothing changed")
        record_last_action(kind, name, False, str(e))
        return
    record_last_action(kind, name, True)


# ------------------------------------------------------------------------------------------------
# The world guard (before every start). Flux runs this app on two nodes with the data volume
# synced (Syncthing): a node can start on a volume whose world.db has not arrived yet, and the
# game then makes a NEW world without a word, which syncs back over the real one. So: when the
# map's world is missing (or unusable) but this server had one (flux/worlds.json, a backup with
# that map, or other files in its folder), the game is not started on nothing: the newest backup
# with that map is put back, or, with none, the start waits for the world to arrive. A new
# world the panel asked for (new-world) is let through. Sync-conflict copies are moved aside.
# ------------------------------------------------------------------------------------------------

def quarantine_conflicts():
    moved = []
    for root, _dirs, files in os.walk(SAVED_DIR):
        if os.path.islink(root) or os.path.basename(root) == "Logs":
            continue
        for f in files:
            if is_conflict(f):
                os.makedirs(CONFLICTS_DIR, exist_ok=True)
                rel = os.path.relpath(os.path.join(root, f), SAVED_DIR).replace(os.sep, "__")
                try:
                    os.replace(os.path.join(root, f), os.path.join(CONFLICTS_DIR, rel))
                    moved.append(rel)
                except OSError:
                    pass
    return moved


def mark_world_seen(the_map, db):
    seen = read_json(WORLDS_SEEN, {}) or {}
    if not isinstance(seen, dict):
        seen = {}
    seen[the_map] = {"seen": int(time.time()), "size": os.path.getsize(db)}
    write_json(WORLDS_SEEN, seen, indent=None)


def cmd_world_seen():
    """The watcher, once the server is up: the current map's world exists (it is now one this
    server must never silently replace)."""
    the_map = current_settings()["map"]
    db = os.path.join(WORLDS_DIR, the_map, "world.db")
    if world_usable(db):
        mark_world_seen(the_map, db)


def cmd_world_guard():
    """Exit 0: start the game (the world is there, was put back from a backup, or is a new one
    on purpose). Exit 3: do not start, wait (the reason is the last line)."""
    the_map = current_settings()["map"]
    label = MAPS[the_map]
    world_dir = os.path.join(WORLDS_DIR, the_map)
    db = os.path.join(world_dir, "world.db")
    for rel in quarantine_conflicts():
        print(f"# WARN a Syncthing conflict copy {rel} was moved to flux/sync-conflicts/")
    seen = read_json(WORLDS_SEEN, {}) or {}
    entry = (seen.get(the_map) if isinstance(seen, dict) else None) or {}
    if world_usable(db):
        mark_world_seen(the_map, db)
        try:
            os.remove(WORLD_MISSING)
        except OSError:
            pass
        return 0
    if entry.get("newWorld"):
        print(f"# a new {label} world, as the panel asked: the game makes one")
        return 0
    evidence = []
    if entry.get("seen"):
        evidence.append(f"this server ran it ({time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(entry['seen']))})")
    with_map = [n for n in backup_files() if the_map in backup_maps(os.path.join(BACKUP_DIR, n))]
    if with_map:
        evidence.append(f"{len(with_map)} backup(s) have it")
    leftovers = [f for f in (os.listdir(world_dir) if os.path.isdir(world_dir) else []) if not is_conflict(f)]
    if leftovers:
        evidence.append(f"its folder has {', '.join(sorted(leftovers)[:4])}")
    if not evidence:
        return 0
    why = "missing" if not os.path.exists(db) else "unusable"
    # Wait for Syncthing first. The backups are on the synced volume too and can arrive before the
    # world.db: putting one back at once would give the file a new time, and Syncthing could then
    # send that OLDER world over the real one still on its way. Only a missing world waits; an
    # unusable one is not going to get better.
    if why == "missing" and WORLD_SYNC_GRACE > 0:
        missing = read_json(WORLD_MISSING, {}) or {}
        since = missing.get(the_map) if isinstance(missing, dict) else None
        if not isinstance(since, (int, float)):
            since = time.time()
            missing = missing if isinstance(missing, dict) else {}
            missing[the_map] = since
            write_json(WORLD_MISSING, missing, indent=None)
        left = int(WORLD_SYNC_GRACE - (time.time() - since))
        if left > 0:
            print(f"The {label} world is missing on this node, but this server had one "
                  f"({'; '.join(evidence)}). Waiting for it to sync before putting a backup back "
                  f"(about {max(1, (left + 59) // 60)} min).")
            return 3
    if os.path.exists(db):
        aside = f"{db}.flux-unusable-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}"
        try:
            os.replace(db, aside)
            print(f"# WARN the {label} world.db is unusable: kept as {os.path.basename(aside)}")
        except OSError:
            pass
    for name in with_map:
        try:
            extract_backup(os.path.join(BACKUP_DIR, name), the_map, worlds_only=True)
        except (OSError, tarfile.TarError, ValueError, sqlite3.Error) as e:
            print(f"# WARN the backup {name} could not be restored ({e}); trying an older one")
            continue
        mark_world_seen(the_map, db)
        try:
            os.remove(WORLD_MISSING)
        except OSError:
            pass
        msg = (f"The {label} world was {why} on this node ({'; '.join(evidence)}): "
               f"restored the newest backup that has it, {name}, instead of starting a new world")
        print(f"# WARN {msg}")
        data = read_json(STATE_FILE, {}) or {}
        data["worldRestored"] = {"backup": name, "map": the_map, "at": iso_now(), "reason": why}
        write_json(STATE_FILE, data, indent=None)
        return 0
    print(f"The {label} world is {why} on this node, but this server had one ({'; '.join(evidence)}) "
          f"and no backup has it. Not starting a new world over it: waiting for it to sync. "
          f"The panel's New world starts over instead.")
    return 3


# ------------------------------------------------------------------------------------------------
# Game updates that did not land: a planned update restart remembers its target; after the update
# step a target the install did not reach is remembered as failed, and the watcher leaves that
# build alone for 6 hours instead of restarting the server for it every half hour.
# ------------------------------------------------------------------------------------------------

def cmd_update_target(build):
    write_json(UPDATE_TARGET_FILE, {"build": str(build), "at": int(time.time())}, indent=None)


def cmd_update_check():
    target = read_json(UPDATE_TARGET_FILE)
    if not isinstance(target, dict):
        return
    try:
        os.remove(UPDATE_TARGET_FILE)
    except OSError:
        pass
    now_build = installed_build()
    if now_build and now_build != target.get("build"):
        write_json(UPDATE_FAILED_FILE, {"build": target.get("build"), "at": int(time.time())}, indent=None)
        print(f"# WARN the update to build {target.get('build')} did not install (still {now_build}); "
              f"not retried for {UPDATE_FAILED_SKIP // 3600} hours")


def cmd_update_skip(build):
    failed = read_json(UPDATE_FAILED_FILE)
    if isinstance(failed, dict) and failed.get("build") == str(build) and time.time() - failed.get("at", 0) < UPDATE_FAILED_SKIP:
        sys.exit(0)
    sys.exit(1)


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 64
    cmd, rest = argv[0], argv[1:]
    commands = {
        "apply": (cmd_apply, (0,)),
        "state": (cmd_state, (1, 2)),
        "note": (cmd_note, (1, 2)),
        "status": (cmd_status, (0,)),
        "connect": (cmd_connect, (0,)),
        "players": (cmd_players, (0,)),
        "gameplay": (cmd_gameplay, (0,)),
        "preset": (cmd_preset, (1,)),
        "apply-live": (cmd_apply_live, (0,)),
        "bans": (cmd_bans, (0,)),
        "ban": (lambda i: cmd_ban(i, True), (1,)),
        "unban": (lambda i: cmd_ban(i, False), (1,)),
        "restart": (cmd_restart, (0, 1)),
        "backup": (cmd_backup_cli, (1, 2)),
        "backups": (cmd_backups, (0,)),
        "restore": (cmd_restore, (1,)),
        "import": (cmd_import, (1,)),
        "new-world": (cmd_new_world, (0,)),
        "do-restore": (cmd_do_restore, (0,)),
        "world-guard": (lambda: sys.exit(cmd_world_guard()), (0,)),
        "world-seen": (cmd_world_seen, (0,)),
        "whitelist": (cmd_whitelist, (0, 1, 2)),
        "update-target": (cmd_update_target, (1,)),
        "update-check": (cmd_update_check, (0,)),
        "update-skip": (cmd_update_skip, (1,)),
    }
    if cmd == "console":
        cmd_console(*rest)
        return 0
    if cmd not in commands:
        print(__doc__, file=sys.stderr)
        return 64
    fn, arity = commands[cmd]
    if len(rest) not in arity:
        print(__doc__, file=sys.stderr)
        return 64
    fn(*rest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
