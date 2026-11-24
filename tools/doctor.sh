#!/bin/bash
# CS 1.6 server doctor: health check + self repair.
#
#   doctor.sh check     check the running server, write runtime/doctor.json
#   doctor.sh auto      check; if broken, repair (restart -> rebuild image)
#   doctor.sh repair    repair even if the check passes
#   doctor.sh trigger   entry point for the systemd path unit (dashboard requests in runtime/doctor.request)
#
# Healthy = container running, RCON answers, Metamod plugins and AMXX modules/plugins all run,
# st_state works, and no plugin load errors in this run's log.
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$DIR" || exit 1
RT=runtime
STATE=$RT/doctor.json
LOGF=$RT/doctor.log
REQ=$RT/doctor.request
mkdir -p "$RT"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGF" >&2; }
notify() { DISPLAY=${DISPLAY:-:0} notify-send -a "CS 1.6 Server" -i steam_icon_10 "CS 1.6 doctor" "$*" 2>/dev/null || true; }
rcon() { timeout 15 python3 tools/rcon.py "$@" 2>/dev/null; }
cstate() { docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' cs16 2>/dev/null; }
run_log() {
  local started; started=$(docker inspect -f '{{.State.StartedAt}}' cs16 2>/dev/null) || return
  docker logs -t --tail 4000 cs16 2>&1 | tr -d '\r' | awk -v s="${started:0:19}" 'substr($1,1,19) >= s' | cut -d' ' -f2-
}

wait_ready() {
  local st
  for _ in $(seq 60); do
    read -r st _ < <(cstate)
    [[ "$st" == running ]] || return 1
    rcon st_state | grep -q '^STATEPART 0 ' && { sleep 2; return 0; }
    sleep 2
  done
  return 1
}

write_state() { # healthy status problems-json action
  jq -n --argjson healthy "$1" --arg status "$2" --argjson problems "$3" --arg action "$4" --arg ts "$(date -u +%FT%T)" \
    '{ts:$ts, healthy:$healthy, status:$status, problems:$problems, action:$action}' > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# Sets HEALTHY / STATUS / PROBLEMS (json array). Returns 0 if healthy.
check() {
  local st code problems=()
  read -r st code < <(cstate)
  if [[ "$st" != running ]]; then
    HEALTHY=false
    if [[ -z "$st" ]]; then STATUS=missing; problems+=("cs16 container does not exist")
    elif [[ "$code" == 0 || "$code" == 137 || "$code" == 143 ]]; then STATUS=stopped; HEALTHY=null
    else STATUS=crashed; problems+=("server exited with code $code"); fi
  else
    STATUS=running
    if ! wait_ready; then
      if [[ "$(rcon version)" == "" ]]; then problems+=("RCON does not answer")
      else problems+=("st_state failed (ServerTools broken)"); fi
    else
      local meta mods plugs l
      meta=$(rcon meta list); mods=$(rcon amxx modules); plugs=$(rcon amxx plugins)
      for l in Reunion "AMX Mod X" YaPB; do grep -q "$l.*RUN" <<<"$meta" || problems+=("Metamod plugin $l is not running"); done
      for l in ReAPI SQLite; do grep -qi "$l.*running" <<<"$mods" || problems+=("AMXX module $l is not running"); done
      for l in ServerTools "GunGame AMXX"; do grep -qE "\] +[0-9]+ +$l .* (running|debug)" <<<"$plugs" || problems+=("plugin $l is not running"); done
      while IFS= read -r l; do [[ -n "$l" ]] && problems+=("log: ${l:0:180}"); done < <(run_log | grep -E 'bad load|Plugin file open error|Module is not loaded|Run time error' | sort -u | head -5)
    fi
    HEALTHY=$([[ ${#problems[@]} -eq 0 ]] && echo true || echo false)
  fi
  PROBLEMS=$(printf '%s\n' "${problems[@]}" | jq -R . | jq -sc 'map(select(length>0))')
  [[ "$HEALTHY" == true ]]
}

finish_ok() { log "healthy: $1"; write_state true running '[]' "$1"; notify "Server healthy again: $1"; }

repair() {
  write_state false repairing "${PROBLEMS:-[]}" repairing
  notify "Repairing the server…"
  log "repair: restarting"
  if docker restart -t 10 cs16 >/dev/null 2>&1; then docker restart -t 2 cs16-hltv >/dev/null 2>&1; sleep 5; check && { finish_ok "fixed by a restart"; return 0; }; fi
  log "repair: rebuilding the image"
  if ! docker image inspect cs16-hlds >/dev/null 2>&1; then
    docker build -t cs16-hlds -f Dockerfile . >>"$LOGF" 2>&1 || { log "base image build failed"; write_state false "$STATUS" "$PROBLEMS" "repair failed: HLDS download failed"; return 1; }
  fi
  if docker compose build cs16 >>"$LOGF" 2>&1 && docker compose up -d --force-recreate cs16 hltv >>"$LOGF" 2>&1; then
    sleep 5; check && { finish_ok "fixed by rebuilding the server image"; return 0; }
  fi
  log "repair failed: $PROBLEMS"
  write_state false "$STATUS" "$PROBLEMS" "repair failed, see runtime/doctor.log"
  notify "Repair failed. See runtime/doctor.log"
  return 1
}

auto() {
  if check; then write_state true running '[]' healthy; log healthy; return 0; fi
  if [[ "$STATUS" == stopped ]]; then write_state null stopped '[]' "server stopped"; return 0; fi
  log "unhealthy: $PROBLEMS"
  repair
}

exec 9>"$RT/.doctor.lock"
flock -w 600 9 || { echo "doctor already running"; exit 1; }

case "${1:-check}" in
  check) check; if [[ "$STATUS" == stopped ]]; then write_state null stopped '[]' "server stopped"; else write_state "$HEALTHY" "$STATUS" "$PROBLEMS" checked; fi; cat "$STATE" ;;
  auto) auto ;;
  repair) check; repair ;;
  trigger)
    [[ -f "$REQ" ]] || exit 0
    what=$(cat "$REQ"); rm -f "$REQ"
    log "dashboard request: $what"
    if [[ "$what" == repair ]]; then check; repair
    else check; if [[ "$STATUS" == stopped ]]; then write_state null stopped '[]' "server stopped"; else write_state "$HEALTHY" "$STATUS" "$PROBLEMS" checked; fi; fi ;;
  *) echo "usage: $0 check|auto|repair|trigger"; exit 2 ;;
esac
