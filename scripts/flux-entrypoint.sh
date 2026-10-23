#!/bin/bash
# PID 1, and the supervisor of the Soulmask server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and becomes a save, and a
# server that ends on its own is followed by the next one in place:
#
#   - every start: SteamCMD update, the game's Saved/ linked to the data volume, a pending
#     restore / import / new world, a backup, GameXishu.json from the panel's gameplay settings
#     and the command line from the environment (fluxsm.py apply), then the server as uid 1000
#   - before the game starts, the world guard: a world this server had that is missing (a
#     half-synced data volume) comes back from the newest backup, or the start waits for it
#   - SIGTERM/SIGINT from Docker: a forced save on the game's console (`sav 1`, 2-4 s measured
#     once the first, slow one is done before "running"), then SIGKILL to the server at once (its own SIGTERM shutdown takes about 45 s, Flux allows
#     10 s in all); if the save does not answer within 8 s, SIGTERM and the last periodic save
#   - a new build on Steam: an outdated server refuses players on the new client, so it is
#     restarted onto it, when nobody is playing or after FLUX_UPDATE_WAIT_MINUTES with the
#     game's own countdown in chat
#   - SM_RESTART_TIME: a daily restart at that time (in TZ), the same way
#   - the server ending on its own (or the game's own SaveAndExit): a new generation in the same
#     container; FLUX_RESTART_MAX_ATTEMPTS unplanned ones inside FLUX_RESTART_WINDOW seconds end the
#     container with 42
#   - backups of the worlds on start (unless one is under an hour old) and every FLUX_BACKUP_HOURS
#     (fluxsm.py backup has the rules)
#   - the panel's restart (flux-soulmask restart) is a marker: the supervisor stops the server for it
#
# Same shape as runonflux/corekeeper-server-flux and runonflux/tf2-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. Docker's own deadline on Flux is
# ten seconds, so this only matters for a restart, where nobody is waiting on us.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-90}"
# The forced save before a stop: at most this long, so the SIGTERM still lands inside Docker's 10 s.
FLUX_STOP_SAVE_SECONDS="${FLUX_STOP_SAVE_SECONDS:-8}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
export FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-10}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_WAIT_MINUTES="${FLUX_UPDATE_WAIT_MINUTES:-60}"
FLUX_RESTART_WAIT_MINUTES="${FLUX_RESTART_WAIT_MINUTES:-30}"
# The game's own countdown (players are told in chat) when a planned restart finds players on.
FLUX_COUNTDOWN_SECONDS="${FLUX_COUNTDOWN_SECONDS:-300}"

s="${FLUX_SERVER_DIR}"
sm() { python3 /opt/flux/fluxsm.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${FLUX_SAVED_DIR}" "${FLUX_STATE_DIR}" "${FLUX_GAME_LOG_DIR}" "${FLUX_STATE_DIR}/uploads"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_STATE_DIR}/flux.log"
flux_banner "Soulmask"
# A container killed mid-run leaves state.json saying "running": say what is true before anything
# else, so the panel does not read the last container's state.
sm state updating "Starting the container"

for var in GAME_PORT:8777 QUERY_PORT:27015; do
  name="${var%%:*}"
  if ! value="$(flux_port "${!name:-}" "${var#*:}")"; then
    flux_log "ERROR ${name}='${!name:-}' is not a port from 1024 to 65535 (and not ${FLUX_ECHO_PORT}, the console's); refusing to start"
    sm state crashed "${name} is not a usable port"
    exit 42
  fi
  export "${name}=${value}"
done
if [ "${GAME_PORT}" = "${QUERY_PORT}" ]; then
  flux_log "ERROR GAME_PORT and QUERY_PORT are both ${GAME_PORT}; they must differ"
  sm state crashed "GAME_PORT and QUERY_PORT must differ"
  exit 42
fi
if ! restart_at="$(flux_restart_time "${SM_RESTART_TIME:-}")"; then
  flux_log "WARN SM_RESTART_TIME='${SM_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}): game UDP ${GAME_PORT}, Steam query UDP ${QUERY_PORT}"

game_pid=""
tail_pid=""
watch_pid=""
backup_pid=""
cap_pid=""
terminating=0
generation=0
restart_history=()

# A forced save on the game's console, then SIGTERM. $1 = the most the save may take.
save_and_term() {
  local pid
  pid="$(flux_game_pid)"
  pid="${pid:-${game_pid}}"
  [ -n "${pid}" ] || return 0
  if timeout "$1" python3 /opt/flux/fluxsm.py console "sav 1" >/tmp/flux-stop-save.txt 2>&1; then
    flux_log "saved: $(grep -o 'WORLD IS SAVED.*' /tmp/flux-stop-save.txt | head -1)"
    # The game's own shutdown takes 45 s measured (it would be SIGKILLed at 10 s anyway) and the
    # world is on disk: with $2 = hard, end it now instead of leaving the container to Docker.
    if [ "${2:-}" = "hard" ]; then
      sleep 0.3
      kill -KILL "${pid}" 2>/dev/null
      return 0
    fi
  else
    flux_log "WARN the forced save did not answer within $1 s; stopping on the last save"
  fi
  kill -TERM "${pid}" 2>/dev/null
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: saving the world and shutting down, no restart will follow"
  save_and_term "${FLUX_STOP_SAVE_SECONDS}" hard
}
trap term_handler TERM INT

# One SteamCMD run with a deadline, in the background so a stop is not held up by it (bash runs
# a trap only between foreground commands). $1 = seconds, the rest = SteamCMD's arguments.
# Returns 124 on the deadline, 143 when the container is stopping.
steamcmd_run() {
  local limit="$1" pid rc
  shift
  timeout -k 10 "${limit}" steamcmd "$@" >/tmp/steamcmd.log 2>&1 &
  pid=$!
  wait "${pid}"
  rc=$?
  if [ "${terminating}" = "1" ]; then
    kill "${pid}" 2>/dev/null
    pkill -f 'steamcmd' 2>/dev/null
    return 143
  fi
  return "${rc}"
}

# Installs or updates the server. A node that cannot reach Steam's CDN must not leave the
# container "updating" forever: every SteamCMD run has a deadline (FLUX_STEAMCMD_TIMEOUT, 30 min
# for a first install, FLUX_STEAMCMD_UPDATE_TIMEOUT 10 min over an install). With a build already
# installed, two failed tries start that build; with none, it retries for ever with a growing
# pause (30 s doubling to 10 min) and says so in the state. Returns 2 when stopping.
update_server() {
  local attempt=0 validate="" limit rc pause=30 installed=0
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/WS/Binaries/Linux/${FLUX_GAME_PROCESS}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  sm state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP})"
  while true; do
    attempt=$((attempt + 1))
    installed=0
    [ -x "${s}/WS/Binaries/Linux/${FLUX_GAME_PROCESS}" ] && installed=1
    limit="${FLUX_STEAMCMD_TIMEOUT:-1800}"
    [ "${installed}" = "1" ] && limit="${FLUX_STEAMCMD_UPDATE_TIMEOUT:-600}"
    # app_info_update + a second app_update in the same run: SteamCMD answers "Missing
    # configuration" to a first app_update now and then.
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd_run "${limit}" +force_install_dir "${s}" +login anonymous +@sSteamCmdForcePlatformType linux +app_info_update 1 +app_update "${FLUX_STEAM_APP}" +app_update "${FLUX_STEAM_APP}" ${validate} +quit
    rc=$?
    [ "${terminating}" = "1" ] && return 2
    if [ "${rc}" = "0" ] && [ -x "${s}/WS/Binaries/Linux/${FLUX_GAME_PROCESS}" ]; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      return 0
    fi
    local why
    why="$(grep -aE 'ERROR|Error|error|Timeout|timed out' /tmp/steamcmd.log | tail -2 | tr '\n' ' ')"
    [ "${rc}" = "124" ] && why="no answer within ${limit} s (Steam's servers unreachable from this node?) ${why}"
    if [ "${installed}" = "1" ]; then
      if [ "${attempt}" -ge "${FLUX_STEAMCMD_UPDATE_TRIES:-2}" ]; then
        flux_log "WARN could not update from Steam (${why}); starting the build already installed ($(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf"))"
        sm state updating "Steam did not answer: starting the build already installed"
        return 0
      fi
      flux_log "WARN steamcmd failed (attempt ${attempt}): ${why}; retrying in 5s with validate"
      validate="validate"
      sleep 5 &
      wait $!
      continue
    fi
    flux_log "WARN the server could not be downloaded from Steam (attempt ${attempt}): ${why}; retrying in ${pause}s"
    sm state updating "Could not download the server from Steam (attempt ${attempt}): retrying in ${pause} s"
    validate="validate"
    sleep "${pause}" &
    wait $!
    [ "${terminating}" = "1" ] && return 2
    pause=$((pause * 2))
    [ "${pause}" -gt 600 ] && pause=600
  done
}

# The game writes everything it keeps under WS/Saved in the INSTALL, which is local to the node.
# That folder is a link to Saved/ on the data volume (synced), and Saved/Logs is a link back to
# the local log folder (the log is written all the time; it must not be synced). A real WS/Saved
# already there (a first run before the link) is moved across once, never over our files.
link_saved() {
  local saved="${s}/WS/Saved" item
  mkdir -p "${s}/WS"
  if [ -L "${saved}" ]; then
    [ "$(readlink "${saved}")" = "${FLUX_SAVED_DIR}" ] || { rm -f "${saved}"; ln -s "${FLUX_SAVED_DIR}" "${saved}"; }
  else
    if [ -d "${saved}" ]; then
      for item in "${saved}"/* "${saved}"/.[!.]*; do
        [ -e "${item}" ] || continue
        [ "$(basename "${item}")" = "Logs" ] && continue
        if [ ! -e "${FLUX_SAVED_DIR}/$(basename "${item}")" ] && mv "${item}" "${FLUX_SAVED_DIR}/"; then
          flux_log "moved Saved/$(basename "${item}") from the install onto the data volume"
        fi
      done
      rm -rf "${saved}"
    fi
    ln -s "${FLUX_SAVED_DIR}" "${saved}"
  fi
  if [ ! -L "${FLUX_SAVED_DIR}/Logs" ]; then
    rm -rf "${FLUX_SAVED_DIR}/Logs"
    ln -s "${FLUX_GAME_LOG_DIR}" "${FLUX_SAVED_DIR}/Logs"
  fi
}

# Unreal refuses to run as root: the server runs as FLUX_UID, so everything it writes is its.
own_files() {
  find "${FLUX_DATA_DIR}" "${FLUX_GAME_LOG_DIR}" -xdev ! -uid "${FLUX_UID}" -exec chown -h "${FLUX_UID}:${FLUX_UID}" {} + 2>/dev/null
  find "${s}" -xdev ! -uid "${FLUX_UID}" -exec chown -h "${FLUX_UID}:${FLUX_UID}" {} + 2>/dev/null
  return 0
}

# A backup (fluxsm.py backup: what goes in, what is skipped and what is kept). $2 = force.
backup_world() {
  local line
  while IFS= read -r line; do
    flux_log "${line#\# }"
  done < <(FLUX_BACKUP_TEXT=1 sm backup "$1" ${2:+"$2"} 2>&1)
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    backup_world "every ${FLUX_BACKUP_HOURS}h"
  done
}

# How many players are on the server now (the console's `lp`). "" when it cannot tell.
player_count() {
  python3 -c '
import json, subprocess
try:
    print(len(json.loads(subprocess.run(["python3", "/opt/flux/fluxsm.py", "players"], capture_output=True, text=True, timeout=30).stdout)["online"]))
except Exception:
    pass
' 2>/dev/null
}

# Asks the supervisor to restart the server: the marker says why; wait_for_generation stops it.
# $2 = seconds of the game's own countdown first (0 = none).
request_restart() {
  local delay="${2:-0}"
  [ -f "${FLUX_RESTART_MARKER}" ] && return 0
  if [ "${delay}" -gt 0 ]; then
    printf '%s\nnotbefore=%s\n' "$1" "$(($(date -u +%s) + delay + 60))" >"${FLUX_RESTART_MARKER}"
    timeout 15 python3 /opt/flux/fluxsm.py console "close ${delay}" >/dev/null 2>&1 \
      || printf '%s\nnotbefore=0\n' "$1" >"${FLUX_RESTART_MARKER}"
    flux_log "$1: restarting the server after the game's ${delay} s countdown"
  else
    printf '%s\nnotbefore=0\n' "$1" >"${FLUX_RESTART_MARKER}"
    flux_log "$1: restarting the server"
  fi
}

# Waits for an empty server for up to $1 minutes, checking every minute. Prints the seconds of
# countdown the restart should give: 0 when it is empty, FLUX_COUNTDOWN_SECONDS otherwise.
wait_for_empty() {
  local until=$(($(date -u +%s) + $1 * 60)) n
  while true; do
    n="$(player_count)"
    if [ "${n}" = "0" ]; then
      printf '0'
      return 0
    fi
    [ "$(date -u +%s)" -ge "${until}" ] && break
    sleep 60
  done
  printf '%s' "${FLUX_COUNTDOWN_SECONDS}"
}

# shellcheck disable=SC2329  # run in the background below
# The current game log, capped at FLUX_GAME_LOG_MAX_BYTES on disk. Unreal writes WS.log at its own
# offset (no O_APPEND): emptying it (`: >`) only made a sparse file that read back as megabytes
# of NUL bytes, into docker logs, every minute. Instead the old part is punched out
# (flux_log_cap: the file keeps its length, its start reads as a hole, the disk is given back)
# and the size that counts is what is on disk.
log_capper() {
  local current line
  current="$(flux_game_log)"
  while true; do
    sleep 60
    line="$(flux_log_cap "${current}" "${FLUX_GAME_LOG_MAX_BYTES}" 5242880)" && [ -n "${line}" ] && flux_log "${line}"
  done
}

# shellcheck disable=SC2329  # run in the background below
# Marks the server running once the world is up, keeps its invite code, then follows Steam for a
# newer build and keeps the daily restart.
watcher() {
  local line build public last_check=0 next_restart="" now code i countdown
  while IFS= read -r line; do
    if [[ "${line}" == *"[ GAME STARTED. ]"* ]]; then
      break
    fi
  done < <(tail -n +1 -F "$(flux_game_log)" 2>/dev/null)
  # "GAME STARTED" is not ready: the server then builds the world's dungeons with its game thread
  # blocked for about a minute (measured: frame 4 to frame 27 took 49 s), and answers nothing,
  # players or console. Ready is the console answering: the invite code (QueryInvitationCode),
  # which players can also join with from the game's menu.
  sm state starting "Building the world's dungeons"
  for i in $(seq 1 40); do
    code="$(timeout 25 python3 /opt/flux/fluxsm.py console qi 2>/dev/null | grep -oE '^[A-Z0-9]{16,40}$' | head -1)"
    if [ -n "${code}" ]; then
      sm note inviteCode "${code}"
      flux_log "invite code ${code}"
      break
    fi
    sleep 5
  done
  # A first forced save BEFORE saying running: the first save of a session is the slow one (9.9 s
  # and 10.7 s measured, 2-4 s after) and a stop's save has 8 s inside Docker's 10. Done here, the
  # panel never shows a running server whose next save could not fit in a stop.
  local t0
  t0="$(date +%s%N)"
  if timeout 40 python3 /opt/flux/fluxsm.py console "sav 1" 2>/dev/null | grep -q 'WORLD IS SAVED'; then
    flux_log "first forced save in $((($(date +%s%N) - t0) / 1000000)) ms (the slow one; later ones take 2-4 s)"
  else
    flux_log "WARN the first forced save did not answer"
  fi
  sm world-seen
  sm state running
  flux_log "the server is up (generation ${generation})"
  if [ -n "${restart_at}" ]; then
    next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
    sm note nextRestart "${next_restart}"
  else
    sm note nextRestart
  fi
  sm note updateWaiting
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      # A deadline: a SteamCMD that never answers would end the update checks and the daily
      # restart for the whole generation.
      public="$(timeout -k 10 "${FLUX_STEAMCMD_QUERY_TIMEOUT:-180}" steamcmd +login anonymous +app_info_update 1 +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_build)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ] && ! sm update-skip "${public}"; then
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it when the server is empty, at most ${FLUX_UPDATE_WAIT_MINUTES} min from now"
        sm note updateWaiting "${public}"
        countdown="$(wait_for_empty "${FLUX_UPDATE_WAIT_MINUTES}")"
        sm update-target "${public}"
        request_restart "planned: game update ${build} -> ${public}" "${countdown}"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      flux_log "daily restart (${restart_at} ${TZ:-UTC}): waiting up to ${FLUX_RESTART_WAIT_MINUTES} min for an empty server"
      countdown="$(wait_for_empty "${FLUX_RESTART_WAIT_MINUTES}")"
      request_restart "planned: the daily restart (${restart_at} ${TZ:-UTC})" "${countdown}"
      exit 0
    fi
  done
}

# Before every start: a restore / import / new world the panel asked for, then the world guard
# (fluxsm.py world-guard): never start the game on a missing world this server had, which on a
# half-synced volume would make a new world and sync it over the real one. A restore from a backup
# is said in flux.log and the state; with no backup it waits, checking every 30 s (the world may
# still be on its way, or the panel may ask for a restore or a new world). Returns 1 when stopping.
guard_world() {
  local line out rc said=""
  while true; do
    while IFS= read -r line; do flux_log "restore: ${line#\# }"; done < <(sm do-restore 2>&1)
    out="$(sm world-guard 2>&1)"
    rc=$?
    while IFS= read -r line; do
      [ -n "${line}" ] && [[ "${line}" == "# "* ]] && flux_log "world: ${line#\# }"
    done <<<"${out}"
    if [ "${rc}" = "0" ]; then
      line="$(grep -o 'restored the newest backup that has it, [^ ,]*' <<<"${out}" | head -1)"
      [ -n "${line}" ] && world_note="the world was missing on this node: backup ${line#restored the newest backup that has it, } put back"
      return 0
    fi
    line="$(grep -v '^# ' <<<"${out}" | tail -1)"
    if [ "${said}" != "${line}" ]; then
      flux_log "WARN ${line}"
      said="${line}"
    fi
    sm state updating "${line}"
    sleep 30 &
    wait $!
    [ "${terminating}" = "1" ] && return 1
  done
}

start_generation() {
  local line args=() current applied rc
  world_note=""
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}" /tmp/flux-players.json

  update_server
  rc=$?
  if [ "${rc}" = "2" ] || [ "${terminating}" = "1" ]; then
    return 2
  fi
  [ "${rc}" = "0" ] || return 1
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(sm update-check 2>&1)
  [ "${terminating}" = "1" ] && return 2
  link_saved
  guard_world || return 2
  backup_world "start"

  # apply's stdout is the arguments (and "# " notes); its stderr is only ever logged.
  if applied="$(sm apply 2>/tmp/flux-apply.err)"; then
    while IFS= read -r line; do
      case "${line}" in
        "# "*) flux_log "config: ${line#\# }" ;;
        "") ;;
        *) args+=("${line}") ;;
      esac
    done <<<"${applied}"
  else
    flux_log "ERROR the settings could not be prepared: $(tail -3 /tmp/flux-apply.err | tr '\n' ' ')"
    return 1
  fi

  current="$(flux_game_log)"
  flux_prune "${FLUX_GAME_LOG_DIR}" 'WS-*.log' "${FLUX_GAME_LOG_KEEP}"
  # Unreal renames the last WS.log to WS-backup-<date>.log itself; a leftover would read as this
  # generation's (the watcher waits for "GAME STARTED" in it).
  if [ -s "${current}" ]; then
    mv "${current}" "${FLUX_GAME_LOG_DIR}/WS-flux-$(date -u +%Y%m%d-%H%M%S).log"
  fi
  : >"${current}"
  own_files
  [ "${terminating}" = "1" ] && return 2

  sm state starting "Loading the world${world_note:+ (${world_note})}"
  flux_banner "Soulmask"
  flux_log "starting the server (generation ${generation})"

  # The game's log (Saved/Logs/WS.log), onto the container's output. The server's own stdout
  # repeats it with every level-streaming line, so it goes nowhere.
  # flux_log_filter: no NUL bytes, and the passwords on the game's "Command Line:" line hidden.
  tail -n 0 -F "${current}" 2>/dev/null | flux_log_filter &
  tail_pid=$!

  (
    cd "${s}" || exit 1
    export LD_LIBRARY_PATH="${s}/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export HOME=/tmp/flux-home
    mkdir -p "${HOME}" && chown "${FLUX_UID}:${FLUX_UID}" "${HOME}"
    chmod +x "${s}/WS/Binaries/Linux/${FLUX_GAME_PROCESS}"
    exec setpriv --reuid="${FLUX_UID}" --regid="${FLUX_UID}" --clear-groups \
      "${s}/WS/Binaries/Linux/${FLUX_GAME_PROCESS}" WS "${args[@]}" </dev/null >/dev/null 2>&1
  ) &
  game_pid=$!

  watcher &
  watch_pid=$!
  backupper &
  backup_pid=$!
  log_capper &
  cap_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${tail_pid}" "${watch_pid}" "${backup_pid}" "${cap_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  tail_pid="" watch_pid="" backup_pid="" cap_pid=""
  pkill -f "tail -n [0+1]* -F $(flux_game_log)" 2>/dev/null
  pkill -KILL -f "/${FLUX_GAME_PROCESS} " 2>/dev/null
  game_pid=""
}

# Waits for the game to end. A requested stop or restart that is not honoured within
# FLUX_STOP_GRACE ends it by force; the grace runs from when the request was first seen.
wait_for_generation() {
  local asked_at=0 now signalled=0
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if [ "${signalled}" = "0" ] && [ "${terminating}" = "0" ] && [ -f "${FLUX_RESTART_MARKER}" ] \
      && [ "$(date -u +%s)" -ge "$(flux_marker_not_before "${FLUX_RESTART_MARKER}")" ]; then
      signalled=1
      save_and_term 30
    fi
    if [ "${terminating}" = "1" ] || [ "${signalled}" = "1" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
        pkill -KILL -f "/${FLUX_GAME_PROCESS} " 2>/dev/null
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    sm state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    sm state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    sm state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(head -1 "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    sm state stopped
    exit 0
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      sm state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi

  sm state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
