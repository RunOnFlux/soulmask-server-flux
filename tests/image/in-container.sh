#!/bin/bash
# shellcheck disable=SC2016  # wait_for conditions are single-quoted and eval-ed later, on purpose
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t
# and scripts/ at /s.
set -uo pipefail
export LC_ALL=C
# The world guard waits 5 min for Syncthing before it puts a backup back (tests/test-flux.sh tests
# that wait); here the missing world is put back at once.
export FLUX_WORLD_SYNC_GRACE_SECONDS=0

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
# Waits up to $2 seconds for the command in $1 to succeed.
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}
jstate() { python3 -c 'import json,sys;print(json.load(open("/mnt/soulmask/data/flux/state.json")).get(sys.argv[1]))' "$1" 2>/dev/null; }

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 setpriv pgrep pkill timeout tail tar gzip find; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "python has sqlite3" "0" "$(status python3 -c 'import sqlite3')"
check "flux-soulmask is on the PATH" "0" "$(status command -v flux-soulmask)"
check "flux-soulmask starts (usage)" "64" "$(status flux-soulmask)"
for script in flux-entrypoint.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "the image's scripts are the repository's" "0" "$(status diff -r --exclude=__pycache__ /s /opt/flux)"
check "the unit tests pass with the image's Python" "0" "$(status bash -c 'cd /tmp && rm -rf repo && mkdir repo && cp -r /s repo/scripts && cp -r /t repo/tests && cd repo && ./tests/test-flux.sh')"

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd "installs" a server that behaves like Soulmask where it matters: it refuses root, writes
# "[ GAME STARTED. ]" to Saved/Logs/WS.log, answers the maintenance console on 127.0.0.1:18888
# (sav 1, qi, lp, sc, usp, close <s>), writes its world on a save and exits on SIGTERM.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  shift
done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/linux64" "${dir}/WS/Binaries/Linux" "${dir}/WS/Config/GameplaySettings" "${dir}/steamapps"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_3017300.acf"
printf '{"0": {"ExpRatio": 1, "MaxLevel": 60}, "1": {"ExpRatio": 1, "MaxLevel": 60}, "2": {"ExpRatio": 1, "MaxLevel": 60}}\n' >"${dir}/WS/Config/GameplaySettings/GameXishu_Template.json"
printf '{"0": {"ExpRatio": 3}, "1": {"ExpRatio": 3}, "2": {"ExpRatio": 3}}\n' >"${dir}/WS/Config/GameplaySettings/GameXishu_Template_Fast.json"
cp /t/image/standin-server.py "${dir}/WS/Binaries/Linux/WSServer-Linux-Shipping"
chmod +x "${dir}/WS/Binaries/Linux/WSServer-Linux-Shipping"
STUB
chmod +x /usr/local/bin/steamcmd

data=/mnt/soulmask/data
server=/mnt/soulmask/server
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 SM_SERVER_NAME="Image Test" SM_MAX_PLAYERS=4 SM_ADMIN_PASSWORD=gm1
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up" "0" "$(status wait_for '[ "$(jstate state)" = running ]' 30)"
check "not as root" "1000" "$(ps -o uid= -p "$(pgrep -f '/WSServer-Linux-Shipping ' | head -1)" | tr -d ' ')"
check "Saved is on the data volume" "${data}/Saved" "$(readlink ${server}/WS/Saved)"
check "and its logs are local" "${server}/flux-logs" "$(readlink ${data}/Saved/Logs)"
check "the game log reaches docker logs" "1" "$(grep -c 'GAME STARTED' /tmp/entry.log)"
check "the name is on the command line" "1" "$(grep -c -- '-SteamServerName=Image Test' ${server}/flux-logs/WS.log)"
check "the invite code is kept" "0" "$(status wait_for '[ "$(jstate inviteCode)" = STANDINCODE1234567890 ]' 20)"
check "status has the invite code" "STANDINCODE1234567890" "$(flux-soulmask status | python3 -c 'import json,sys;print(json.load(sys.stdin)["inviteCode"])')"
check "status lists the online players" "Chief Ana" "$(flux-soulmask status | python3 -c 'import json,sys;print(json.load(sys.stdin)["players"][0]["name"])')"
check "the console answers" "send to all online players. Done." "$(flux-soulmask console say hi | head -1)"
check "the console refuses close" "2" "$(status flux-soulmask console close 5)"
check "a ban goes to the live server" "True" "$(flux-soulmask ban 76561198000000005 | python3 -c 'import json,sys;print(json.load(sys.stdin)["live"])')"
check "and is listed" '["76561198000000005"]' "$(flux-soulmask bans | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["bans"]))')"
printf '{"ExpRatio": 4}\n' >"${data}/flux/gameplay.json"
check "apply-live sets what differs" "1" "$(flux-soulmask apply-live | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["changed"]))')"
check "the server wrote it" "4" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/Saved/GameplaySettings/GameXishu.json"))["1"]["ExpRatio"])')"
check "a panel backup" "True" "$(flux-soulmask backup manual force | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')"
check "made after a forced save" "0" "$(status test -f ${data}/Saved/Worlds/Dedicated/Level01_Main/world.db)"
check "the passwords never reach docker logs" "0" "$(grep -c 'gm1' /tmp/entry.log)"
check "the command line is there, hidden" "1" "$(grep -c -- '-adminpsw=<hidden>' /tmp/entry.log)"
check "the first forced save comes before running" "1" "$(grep -c 'first forced save in' /tmp/entry.log)"
check "status: lastAction is null before any" "None" "$(flux-soulmask status | python3 -c 'import json,sys;print(json.load(sys.stdin)["lastAction"])')"
# The whitelist, live.
check "whitelist add, live" '{"ok": true}' "$(flux-soulmask whitelist add 76561198000000001)"
check "whitelist on, live: no restart" '{"ok": true, "restart": false}' "$(flux-soulmask whitelist on)"
check "whitelist: on, with the player's name" '{"enabled": true, "ids": [{"id": "76561198000000001", "name": "Chief Ana"}]}' "$(flux-soulmask whitelist)"
check "in the game's file" "76561198000000001" "$(cat ${data}/Saved/WhiteAccountList.txt)"
# preset -> apply-live -> a GM's sc in game -> restart: all of it kept (1.0.1 took the stale block
# "0" back and reverted everything).
flux-soulmask preset Fast >/dev/null
check "apply-live after a preset" "True" "$(flux-soulmask apply-live | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')"
flux-soulmask console sc MaxLevel 70 >/dev/null

flux-soulmask restart >/dev/null
check "a panel restart starts generation 2" "0" "$(status wait_for '[ "$(jstate generation)" = 2 ] && [ "$(jstate state)" = running ]' 30)"
check "the restart was not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "it saved first" "1" "$(grep -c 'saved: WORLD IS SAVED' /tmp/entry.log)"
check "the restart kept the preset's apply-live and the GM's sc" "3 70" "$(python3 -c 'import json;d=json.load(open("'"${data}"'/Saved/GameplaySettings/GameXishu.json"))["1"];print(d["ExpRatio"],d["MaxLevel"])')"
check "and the panel has both" "3 70" "$(python3 -c 'import json;d=json.load(open("'"${data}"'/flux/gameplay.json"));print(d["ExpRatio"],d["MaxLevel"])')"
check "the whitelist is on again after the restart (-serverpm)" "True" "$(flux-soulmask whitelist | python3 -c 'import json,sys;print(json.load(sys.stdin)["enabled"])')"
flux-soulmask whitelist off >/dev/null

flux-soulmask restart 10 >/dev/null
check "a countdown restart lets the game exit on its own" "0" "$(status wait_for '[ "$(jstate generation)" = 3 ] && [ "$(jstate state)" = running ]' 40)"
check "and is a planned one" "0" "$(grep -c 'ended on its own' /tmp/entry.log)"

# A restore through the panel's command: the supervisor restarts, restores, starts again.
marker_tables() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from sqlite_master where name = ?", ("marker",)).fetchone()[0])' "${data}/Saved/Worlds/Dedicated/Level01_Main/world.db" 2>/dev/null; }
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table marker(v)"); c.commit()' "${data}/Saved/Worlds/Dedicated/Level01_Main/world.db"
backup="$(flux-soulmask backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
check "restore restarts the running server" "True" "$(flux-soulmask restore "${backup}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverQuit"])')"
check "and the next start has the backup's worlds" "0" "$(status wait_for '[ "$(jstate generation)" = 4 ] && [ "$(marker_tables)" = 0 ]' 40)"
check "a safety backup was made first" "0" "$(status grep -q 'before restoring' <(flux-soulmask backups))"
check "lastAction: the restore, by this generation" "restore ${backup} 4 True" "$(flux-soulmask status | python3 -c 'import json,sys;a=json.load(sys.stdin)["lastAction"];print(a["kind"],a["name"],a["generation"],a["ok"])')"

# The server dying on its own: restarted in place, counted.
wait_for '[ "$(jstate state)" = running ]' 20
# A half-synced volume: the world.db is gone when the next start comes (here, after a crash).
rm -f ${data}/Saved/Worlds/Dedicated/Level01_Main/world.db
pkill -KILL -f '/WSServer-Linux-Shipping '
check "a crash is restarted in place" "0" "$(status wait_for '[ "$(jstate generation)" = 5 ] && [ "$(jstate state)" = running ]' 40)"
check "and counted" "1" "$(grep -c 'ended on its own' /tmp/entry.log)"
check "the missing world came back from a backup, not as a new one" "1" "$(grep -c 'restored the newest backup that has it' /tmp/entry.log)"
check "status says it" "Level01_Main" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/flux/state.json"))["worldRestored"]["map"])')"

wait_for '[ "$(jstate state)" = running ]' 20
s=$(date +%s)
kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "inside Docker's 10 s" "1" "$([ $(($(date +%s) - s)) -lt 10 ] && echo 1 || echo 0)"
check "after a save" "3" "$(grep -c 'saved: WORLD IS SAVED' /tmp/entry.log)"
check "and says stopped" "stopped" "$(jstate state)"
check "with no invite code left" "None" "$(jstate inviteCode)"
check "the server's files are uid 1000" "0" "$(find ${data}/Saved ${server} ! -uid 1000 | wc -l)"

# --- Steam that never answers: the installed build starts anyway --------------------------------
printf '#!/bin/bash\nexec sleep 1000\n' >/usr/local/bin/steamcmd
FLUX_STEAMCMD_UPDATE_TIMEOUT=2 /opt/flux/flux-entrypoint.sh >/tmp/entry2.log 2>&1 &
entry=$!
check "a SteamCMD that hangs: the installed build starts" "0" "$(status wait_for '[ "$(jstate state)" = running ]' 40)"
check "and says why" "1" "$(grep -c 'starting the build already installed' /tmp/entry2.log)"
kill -TERM "${entry}"
wait_for '! kill -0 ${entry} 2>/dev/null' 20

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv=/mnt/soulmask/server
fl_data=/mnt/soulmask/data
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "${fl_data}/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q 'Soulmask server image by FluxCloud - https://runonflux.com' /tmp/entry.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/entry.log)" -ge 2 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
