#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxsm.py's file handling. No Docker, no
# Steam, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# The daily restart is in TZ: the expectations below are UTC unless a test sets its own.
export TZ=UTC

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Inputs ------------------------------------------------------------------------------------
check "8777 is a port" "8777" "$(flux_port 8777 8777)"
check "unset takes the default" "27015" "$(flux_port '' 27015)"
check "a leading zero is not octal" "7778" "$(flux_port 07778 1)"
check "port 80 is refused" "1" "$(status flux_port 80 1)"
check "the console's port is refused" "1" "$(status flux_port 18888 1)"
check "65536 is refused" "1" "$(status flux_port 65536 1)"
check "a word is not a port" "1" "$(status flux_port abc 1)"
check "restart time 5:00" "05:00" "$(flux_restart_time 5:00)"
check "restart time off" "" "$(flux_restart_time off)"
check "restart time 24:00 refused" "1" "$(status flux_restart_time 24:00)"
# 2026-10-11 12:00 UTC = 1791720000
check "next 05:00 after noon is tomorrow" "$((1791720000 - 43200 + 86400 + 18000))" "$(flux_next_daily 1791720000 05:00)"
check "next 13:30 after noon is today" "$((1791720000 + 5400))" "$(flux_next_daily 1791720000 13:30)"
check "the time is the zone's (Lisbon is UTC+1 in October)" "$((1791720000 + 5400 - 3600))" "$(TZ=Europe/Lisbon flux_next_daily 1791720000 13:30)"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts drop out of the window" "950 990" "$(flux_restarts_in_window 1000 100 800 950 990)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "a game update does not count" "1" "$(status flux_restart_counts 'planned: game update 1 -> 2')"
check "a panel restart does not count" "1" "$(status flux_restart_counts 'requested: from the panel')"
check "prune keeps the newest" "c d" "$(flux_files_to_prune 2 a b c d | tr '\n' ' ' | sed 's/ $//')"
printf 'requested: x\nnotbefore=1234\n' >"${tmp}/marker"
check "the marker's not-before" "1234" "$(flux_marker_not_before "${tmp}/marker")"
check "no marker is 0" "0" "$(flux_marker_not_before "${tmp}/none")"

# --- Steam builds ------------------------------------------------------------------------------
printf '"AppState"\n{\n\t"appid"\t\t"3017300"\n\t"buildid"\t\t"25955350"\n}\n' >"${tmp}/manifest.acf"
check "installed build" "25955350" "$(flux_installed_build "${tmp}/manifest.acf")"
check "public build from app_info" "25960000" "$(printf '%s\n' '"3017300"' '{' '"branches"' '{' '"public"' '{' '"buildid"		"25960000"' '}' '"beta"' '{' '"buildid"		"1"' '}' | flux_public_build)"

# --- fluxsm.py ---------------------------------------------------------------------------------
data="${tmp}/data"
server="${tmp}/server"
tpl="${server}/WS/Config/GameplaySettings"
mkdir -p "${tpl}" "${data}/Saved/GameplaySettings"
# The game's templates, cut down: three blocks, the PvE block with its own values.
cat >"${tpl}/GameXishu_Template.json" <<'EOF'
{"0": {"ExpRatio": 1, "MaxLevel": 60, "GameWorldDayTimePortion": 0.7, "BinSiKaiGuan": 1, "HuXIangShangHaiKaiGuan": 0},
 "1": {"ExpRatio": 1, "MaxLevel": 60, "GameWorldDayTimePortion": 0.8, "BinSiKaiGuan": 1},
 "2": {"ExpRatio": 1, "MaxLevel": 60, "GameWorldDayTimePortion": 0.7, "BinSiKaiGuan": 1}}
EOF
cat >"${tpl}/GameXishu_Template_PvE_04P_3x.json" <<'EOF'
{"0": {}, "1": {"ExpRatio": 3}, "2": {}}
EOF
cat >"${tpl}/GameXishu_Template_Dashi.json" <<'EOF'
{"0": {"ExpRatio": 3, "BinSiKaiGuan": 0}, "1": {"ExpRatio": 1, "BinSiKaiGuan": 1}, "2": {"ExpRatio": 3, "BinSiKaiGuan": 0}}
EOF
sm() { # VAR=value... command args: fluxsm.py with exactly these variables
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${server}" FLUX_PLAYERS_CACHE="${tmp}/players.json" \
    FLUX_RESTART_MARKER="${tmp}/restart-marker" FLUX_GAME_PROCESS="no-such-process-flux-test" "${vars[@]}" python3 scripts/fluxsm.py "$@"
}
jget() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d=d[int(k)] if isinstance(d,list) else d.get(k)
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$@"; }
live="${data}/Saved/GameplaySettings/GameXishu.json"

# The command line.
sm SM_SERVER_NAME='My "Tribe" Server' SM_MAX_PLAYERS=40 SM_MODE=PvP SM_MAP=shifting-sands SM_PASSWORD=pw GAME_PORT=8800 QUERY_PORT=27100 \
  SM_ADMIN_PASSWORD=gm SM_MODS='https://steamcommunity.com/sharedfiles/filedetails/?id=3810145650, 3764353038' apply >"${tmp}/args"
args="$(grep -v '^# ' "${tmp}/args")"
check "the map comes first" "DLC_Level01_Main" "$(head -1 <<<"${args}")"
check "the name, quotes taken out" "1" "$(grep -cx -- '-SteamServerName=My Tribe Server' <<<"${args}")"
check "players" "1" "$(grep -cx -- '-MaxPlayers=40' <<<"${args}")"
check "the mode" "1" "$(grep -cx -- '-pvp' <<<"${args}")"
check "the ports" "2" "$(grep -cxE -- '-Port=8800|-QueryPort=27100' <<<"${args}")"
check "the console port is the image's" "1" "$(grep -cx -- '-EchoPort=18888' <<<"${args}")"
check "the join password" "1" "$(grep -cx -- '-PSW=pw' <<<"${args}")"
check "the GM password" "1" "$(grep -cx -- '-adminpsw=gm' <<<"${args}")"
check "mods from a link and an id" "1" "$(grep -cx -- '-mod=3810145650,3764353038' <<<"${args}")"
check "saves every 5 min by default" "2" "$(grep -cxE -- '-saving=300|-backup=300' <<<"${args}")"

sm SM_MAX_PLAYERS=500 SM_MAP=mars SM_MODE=hardcore apply >"${tmp}/args"
check "too many players falls back to 20" "1" "$(grep -cx -- '-MaxPlayers=20' "${tmp}/args")"
check "and says so" "1" "$(grep -c 'SM_MAX_PLAYERS' "${tmp}/args")"
check "an unknown map is Cloud Mist Forest" "Level01_Main" "$(grep -v '^# ' "${tmp}/args" | head -1)"
check "an unknown mode is PvE" "1" "$(grep -cx -- '-pve' "${tmp}/args")"
check "no password, no -PSW" "0" "$(grep -c -- '-PSW=' "${tmp}/args")"
check "no GM password given: one is chosen" "1" "$(grep -cE -- '^-adminpsw=[A-Za-z0-9]{16}$' "${tmp}/args")"
first="$(grep -- '-adminpsw=' "${tmp}/args")"
sm apply >"${tmp}/args"
check "and kept" "${first}" "$(grep -- '-adminpsw=' "${tmp}/args")"
check "SM_EXTRA_ARGS cannot move the ports" "0" "$(sm SM_EXTRA_ARGS='-Port=1 -initbackup' apply | grep -c -- '^-Port=1$')"
check "but adds an option" "1" "$(sm SM_EXTRA_ARGS='-Port=1 -initbackup' apply | grep -cx -- '-initbackup')"
check "empty env is unset" "1" "$(sm SM_SERVER_NAME= apply | grep -cx -- '-SteamServerName=Soulmask on Flux')"

# Gameplay settings: no panel values, no file: nothing written.
check "no panel values: the server's file is left alone" "1" "$(status test -f "${live}")"
printf '{"ExpRatio": 2.5, "NotAKey": 9}\n' >"${data}/flux/gameplay.json"
sm apply >"${tmp}/args"
check "the file is made from the template" "2.5" "$(jget "${live}" 1.ExpRatio)"
check "into every block" "2.5 2.5" "$(jget "${live}" 0.ExpRatio) $(jget "${live}" 2.ExpRatio)"
check "a block keeps its own other values" "0.8" "$(jget "${live}" 1.GameWorldDayTimePortion)"
check "an unknown key is not written" "None" "$(jget "${live}" 1.NotAKey)"
check "and is reported" "1" "$(grep -c 'unknown key' "${tmp}/args")"
# A GM changed MaxLevel in game (the server wrote its file); the panel changed ExpRatio.
python3 -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["1"]["MaxLevel"]=50; json.dump(d,open(p,"w"))' "${live}"
printf '{"ExpRatio": 3, "MaxLevel": 60}\n' >"${data}/flux/gameplay.json"
printf '{"ExpRatio": 2.5, "MaxLevel": 60}\n' >"${data}/flux/gameplay.applied.json"
sm apply >"${tmp}/args"
check "a value changed in game is kept" "50" "$(jget "${data}/flux/gameplay.json" MaxLevel)"
check "and written everywhere" "50 50" "$(jget "${live}" 0.MaxLevel) $(jget "${live}" 2.MaxLevel)"
check "the panel's own change wins where it made one" "3" "$(jget "${live}" 1.ExpRatio)"
check "and is reported" "1" "$(grep -c 'changed in game' "${tmp}/args")"
check "the applied snapshot follows" "50" "$(jget "${data}/flux/gameplay.applied.json" MaxLevel)"

# Presets.
check "the presets are the install's templates" '["Dashi", "PvE_04P_3x"]' "$(sm gameplay | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["presets"]))')"
sm SM_MODE=pve preset PvE_04P_3x >/dev/null
check "a sparse preset is the base plus its changes" "3 0.8" "$(jget "${data}/flux/gameplay.json" ExpRatio) $(jget "${data}/flux/gameplay.json" GameWorldDayTimePortion)"
sm SM_MODE=pvp preset Dashi >/dev/null
check "on PvP the base is block 0" "0 0.7" "$(jget "${data}/flux/gameplay.json" BinSiKaiGuan) $(jget "${data}/flux/gameplay.json" GameWorldDayTimePortion)"
sm SM_MODE=pve preset Dashi >/dev/null
check "a difficulty preset (blocks 0 and 2 only) still changes a PvE server" "3 0 0.8" "$(jget "${data}/flux/gameplay.json" ExpRatio) $(jget "${data}/flux/gameplay.json" BinSiKaiGuan) $(jget "${data}/flux/gameplay.json" GameWorldDayTimePortion)"
check "a preset never carries the PvP switch (the mode is SM_MODE's)" "None" "$(jget "${data}/flux/gameplay.json" HuXIangShangHaiKaiGuan)"
printf '{"HuXIangShangHaiKaiGuan": 0, "ExpRatio": 2}\n' >"${data}/flux/gameplay.json"
sm apply >/dev/null
check "nor does the panel's file" "None" "$(jget "${live}" 1.HuXIangShangHaiKaiGuan)"
check "an unknown preset is refused" "2" "$(status sm preset Nope)"
check "a path is not a preset" "2" "$(status sm preset ../../x)"
check "apply-live needs a running server" "3" "$(status sm apply-live)"

# Console tables, as the game prints them (build 25955350).
py() { local code="$1"; shift; PYTHONPATH=scripts python3 -c "import fluxsm, json, sys; ${code}" "$@"; }
lp=$'|              Account |                       PlayerName |                    PawnID |                       Position |\n|    76561198000000001 |                        Chief Ana |                     12345 |  X=1.0 Y=2.0 Z=3.0 |'
check "lp: one player" '[{"id": "76561198000000001", "name": "Chief Ana", "pawn": "12345", "position": "X=1.0 Y=2.0 Z=3.0"}]' "$(py "print(json.dumps(fluxsm.parse_players(sys.argv[1])))" "${lp}")"
check "lp: nobody" "[]" "$(py "print(json.dumps(fluxsm.parse_players(sys.argv[1])))" '|              Account |                       PlayerName |                    PawnID |                       Position |')"
lsp=$'==== SERVER PERMISSION DETAILS ====\n0. WhiteAccountList\n    status: No\n    values:\n1. BlackAccountList\n    status: Yes\n    values:\n    |   76561190000000001\n4. BanSpeek\n    status: Yes\n    values:\n'
check "lsp: the blocked accounts" '["76561190000000001"]' "$(py "print(json.dumps(fluxsm.parse_permissions(sys.argv[1])['BlackAccountList']['values']))" "${lsp}")"
check "lsp: a list's switch" "False" "$(py "print(fluxsm.parse_permissions(sys.argv[1])['WhiteAccountList']['enabled'])" "${lsp}")"
check "close is refused" "True" "$(py "print(fluxsm.console_refused('close 30'))")"
check "Shutdown is refused whatever the case" "True" "$(py "print(fluxsm.console_refused('Shutdown'))")"
check "say is not" "False" "$(py "print(fluxsm.console_refused('say closing time'))")"
check "maps by friendly name" "Level01_Main DLC_Level01_Main None" "$(py "print(fluxsm.map_name('Cloud Mist Forest'), fluxsm.map_name('Shifting_Sands'), fluxsm.map_name('moon'))")"

# Bans with no server: the file.
check "a ban needs a SteamID64" "2" "$(status sm ban 12345)"
sm ban 76561198000000009 >/dev/null
check "a ban with the server down goes to the file" "76561198000000009" "$(cat "${data}/Saved/BlackAccountList.txt")"
sm unban 76561198000000009 >/dev/null
check "and an unban takes it out" "" "$(cat "${data}/Saved/BlackAccountList.txt")"

# Backups: a real SQLite world.
world="${data}/Saved/Worlds/Dedicated/Level01_Main"
mkdir -p "${world}"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table t(v)"); c.execute("insert into t values (1)"); c.commit()' "${world}/world.db"
touch "${world}/2026101820.db"
check "a backup is made" "0" "$(status sm backup manual force)"
name="$(sm backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
check "it lists the map" '["Level01_Main"]' "$(sm backups | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["backups"][0]["maps"]))')"
check "without the game's hourly copies" "0" "$(tar -tzf "${data}/flux/backups/${name}" | grep -c 2026101820)"
check "with the gameplay settings" "1" "$(tar -tzf "${data}/flux/backups/${name}" | grep -c 'flux/gameplay.json')"
check "a second one inside the hour is skipped" "5" "$(status sm backup start)"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("insert into t values (2)"); c.commit()' "${world}/world.db"
sm restore "${name}" >/dev/null
check "a restore with no server waits for the start" "${name}" "$(jget "${data}/flux/restore-pending.json" backup)"
FLUX_BACKUP_MIN_AGE_MINUTES=0 sm do-restore >"${tmp}/restore.out"
check "the restore puts the world back" "1" "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from t").fetchone()[0])' "${world}/world.db")"
check "after a safety backup" "1" "$(grep -c "before restoring" "${data}/flux/backups/index.json")"
check "a restore of nothing is refused" "2" "$(status sm restore ../../etc/passwd)"
# An uploaded world.db for the current map.
mkdir -p "${data}/flux/uploads"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table t(v)"); [c.execute("insert into t values (?)",(i,)) for i in range(7)]; c.commit()' "${data}/flux/uploads/my-world.db"
sm import my-world.db >/dev/null
sm do-restore >/dev/null
check "an uploaded world becomes the map's world" "7" "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from t").fetchone()[0])' "${world}/world.db")"
check "and the upload is removed" "1" "$(status test -f "${data}/flux/uploads/my-world.db")"
echo "not a world" >"${data}/flux/uploads/junk.db"
check "junk is refused" "2" "$(status sm import junk.db)"
sm new-world >/dev/null
sm do-restore >/dev/null
check "a new world removes the map's world" "1" "$(status test -f "${world}/world.db")"
check "keep: newest N plus a day-old and a week-old one" "20261018-120000-soulmask.tar.gz 20261017-110000-soulmask.tar.gz 20261010-110000-soulmask.tar.gz" \
  "$(py "now=fluxsm.backup_time('20261018-120000-soulmask.tar.gz'); names=['20261018-120000-soulmask.tar.gz','20261018-110000-soulmask.tar.gz','20261017-110000-soulmask.tar.gz','20261016-110000-soulmask.tar.gz','20261010-110000-soulmask.tar.gz','20261001-110000-soulmask.tar.gz']; k=fluxsm.backups_to_keep(names,1,now); print(' '.join(n for n in names if n in k and n!='20261018-110000-soulmask.tar.gz'))")"

# State.
sm state starting >/dev/null
sm note inviteCode ABCDEFGHIJKLMNOP >/dev/null
check "a start counts a generation" "1" "$(jget "${data}/flux/state.json" generation)"
sm state starting "Building the world's dungeons" >/dev/null
check "a second step of the same start is the same generation" "1" "$(jget "${data}/flux/state.json" generation)"
sm state running >/dev/null
sm state starting >/dev/null
check "the next start is the next generation" "2" "$(jget "${data}/flux/state.json" generation)"
check "and forgets the last invite code" "None" "$(jget "${data}/flux/state.json" inviteCode)"
check "status is JSON with the map" "Shifting Sands" "$(sm SM_MAP=DLC_Level01_Main status | python3 -c 'import json,sys;print(json.load(sys.stdin)["mapName"])')"
check "an unknown command is usage" "64" "$(status sm nope)"

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
