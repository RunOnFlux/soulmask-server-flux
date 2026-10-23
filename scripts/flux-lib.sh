#!/bin/bash
# Shared helpers for the Soulmask image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Two volumes: the install (SteamCMD's, disposable, local to the node) and the data (the
# game's Saved/ and ours). The data is the only thing that has to survive.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/soulmask/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/soulmask/data}"
# The game's Saved/ (worlds, GameplaySettings/GameXishu.json, the ban lists). The install's
# WS/Saved is a link to it.
FLUX_SAVED_DIR="${FLUX_SAVED_DIR:-${FLUX_DATA_DIR}/Saved}"
FLUX_STATE_DIR="${FLUX_STATE_DIR:-${FLUX_DATA_DIR}/flux}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced data volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
# The game's logs (Saved/Logs is a link here): on the INSTALL volume, local and never synced.
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_GAME_LOG_MAX_BYTES="${FLUX_GAME_LOG_MAX_BYTES:-52428800}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-10}"
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_STATE_DIR}/backups}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-WSServer-Linux-Shipping}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-3017300}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
# The game's maintenance console ("echo port"): a telnet-like TCP socket the server binds on
# 127.0.0.1 only (measured). Never published; the hub reaches it through `flux-soulmask console`.
FLUX_ECHO_PORT="${FLUX_ECHO_PORT:-18888}"
# The server runs as this uid (Unreal refuses root); the volumes are chowned to it on every start.
FLUX_UID="${FLUX_UID:-1000}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  local line="$1"
  # A password option on a line (the game's command line, an error quoting it) is never logged.
  if [[ "${line,,}" == *psw=* ]]; then
    line="$(printf '%s\n' "${line}" | flux_log_filter)"
  fi
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

# stdin -> stdout, line by line (unbuffered): what the game's log may show. NUL bytes are dropped
# (a log emptied under the game reads back as a run of them), and the value of -adminpsw=,
# -PSW= and -rconpsw= (the game prints its whole command line at start) becomes <hidden>.
flux_log_filter() {
  sed -u -E -e 's/\x00//g' -e 's/(-(adminpsw|psw|rconpsw)=)("[^"]*"|[^ ]*)/\1<hidden>/Ig'
}

# Caps a log the game keeps open and writes at its own offset. $1 = the file, $2 = the most it may
# take ON DISK, $3 = the bytes at its end to keep. Over $2, everything before the last $3 is
# punched out (fallocate: the length stays, the start becomes a hole the disk does not hold);
# where the filesystem cannot, the file is emptied (the readers filter the NULs that leaves).
# Prints one line saying what it did; nothing when under the cap.
flux_log_cap() {
  local file="$1" max="$2" keep="$3" blocks bsize size disk len
  read -r blocks bsize size < <(stat -c '%b %B %s' "${file}" 2>/dev/null) || return 0
  disk=$((blocks * bsize))
  [ "${disk}" -gt "${max}" ] 2>/dev/null || return 0
  len=$(((size - keep) / 4096 * 4096))
  if [ "${len}" -gt 0 ] && fallocate --punch-hole --offset 0 --length "${len}" "${file}" 2>/dev/null; then
    printf 'the game log reached %s MB on disk: its first %s MB punched out (the last %s MB kept)\n' \
      "$((disk / 1048576))" "$((len / 1048576))" "$((keep / 1048576))"
  else
    : >"${file}"
    printf 'the game log reached %s MB on disk: emptied\n' "$((disk / 1048576))"
  fi
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = a port as given, $2 = the default. Prints the port; returns 1 for anything that is not a
# port from 1024 to 65535. The echo port (18888) is refused: the server binds it itself.
flux_port() {
  local value="${1:-$2}"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65535 ] && [ "${value}" != "${FLUX_ECHO_PORT}" ] || return 1
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. A restart the supervisor planned (a game update, the
# daily restart, one the panel asked for) is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The daily restart. A Soulmask world holds ~11,000 creatures and its memory only grows over a
# long session; a restart at a quiet hour keeps it fresh. Players are warned in chat first.
# ---------------------------------------------------------------------------------------------

# $1 = SM_RESTART_TIME as given. Prints HH:MM (in TZ), or "" when off. Returns 1 for a value that
# is not a time.
flux_restart_time() {
  local value="${1-}" h m
  case "${value,,}" in
    "" | off | none | false | 0) printf ''; return 0 ;;
  esac
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%02d:%02d' "${h}" "${m}"
}

# $1 = now (epoch seconds), $2 = HH:MM in the container's time zone (TZ; UTC when unset). Prints
# the epoch of the next time it is $2: today when that is still ahead, tomorrow otherwise.
flux_next_daily() {
  local now="$1" at
  at="$(date -d "$(date -d "@${now}" +%F) $2" +%s 2>/dev/null)" || return 1
  if [ "${at}" -le "${now}" ]; then
    at="$(date -d "$(date -d "@$((now + 86400))" +%F) $2" +%s 2>/dev/null)" || return 1
  fi
  printf '%s' "${at}"
}

# ---------------------------------------------------------------------------------------------
# Rotation of the game logs and the backups.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are the game's, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# Steam builds: an outdated server refuses players on the new client, so a new build means a
# restart (onto it). The installed buildid (appmanifest) is compared with the public branch's.
# ---------------------------------------------------------------------------------------------

# $1 = an appmanifest_<app>.acf. Prints its buildid.
flux_installed_build() {
  [ -f "$1" ] || return 0
  awk -F'"' '$2 == "buildid" { print $4; exit }' "$1"
}

# stdin = steamcmd +app_info_print output. Prints the public branch's buildid.
flux_public_build() {
  awk '
    /"branches"/ { inb = 1 }
    inb && /"public"/ { inp = 1 }
    inp && /"buildid"/ { gsub(/"/, "", $2); print $2; exit }
  '
}

# The game's own log of the current generation: Unreal writes Saved/Logs/WS.log (a link to the
# local log folder) and renames the previous one to WS-backup-<date>.log at every start.
flux_game_log() {
  printf '%s' "${FLUX_GAME_LOG:-${FLUX_GAME_LOG_DIR}/WS.log}"
}

# The server binary, not WSServer.sh (a sh wrapper that does not pass signals on).
flux_game_pid() {
  pgrep -f "/${FLUX_GAME_PROCESS} " 2>/dev/null | head -1
}

# $1 = the restart marker. Prints the earliest epoch the supervisor may stop the server for it
# (a countdown restart lets the game's own countdown run first), 0 when it says nothing.
flux_marker_not_before() {
  local value
  value="$(sed -n 's/^notbefore=//p' "$1" 2>/dev/null | head -1)"
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}
