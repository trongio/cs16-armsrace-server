#!/bin/bash
# Open the web dashboard (start/stop/manage the server there). Does not start the game server by itself.
cd "$(dirname "$(readlink -f "$0")")" || exit 1
URL=http://localhost:8016
note() { notify-send -a "CS 1.6 Server" -i steam_icon_10 "CS 1.6 dashboard" "$*" 2>/dev/null || true; }
mkdir -p runtime
if [[ ! -f runtime/.setup-done ]]; then
  note "First run: building the server, this takes a few minutes…"
  if ! tools/setup.sh > runtime/setup.log 2>&1; then note "Setup failed, see $PWD/runtime/setup.log"; exit 1; fi
fi
# Create the server containers (stopped) so the dashboard's Start button works, then run only the dashboard.
if ! { docker compose up --no-start && docker compose up -d --no-deps panel; } > runtime/dashboard.log 2>&1; then
  note "Could not start, see $PWD/runtime/dashboard.log"; exit 1
fi
for _ in $(seq 30); do curl -fs -o /dev/null --max-time 2 "$URL/" && { xdg-open "$URL" >/dev/null 2>&1; exit 0; }; sleep 0.5; done
note "The dashboard did not come up, try: docker logs cs16-panel"
exit 1
