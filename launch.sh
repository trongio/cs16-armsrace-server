#!/bin/bash
# Start the CS 1.6 server (Docker) and join it. "launch.sh stop" stops it.
cd "$(dirname "$(readlink -f "$0")")" || exit 1
PW=$(grep -oP 'sv_password "\K[^"]*' cfg/server.cfg)
if [ "${1:-}" = stop ]; then
  docker compose stop && notify-send -i steam_icon_10 "CS 1.6 server stopped"
  exit
fi
docker compose up -d || { notify-send -i steam_icon_10 "CS 1.6 server failed to start"; exit 1; }
notify-send -i steam_icon_10 "CS 1.6 server starting" "Password: $PW"
# Waits for the boot, then health check; repairs what it can.
if ! tools/doctor.sh auto; then
  notify-send -u critical -i steam_icon_10 "CS 1.6 server is broken" "$(jq -r '.problems | join("; ")' runtime/doctor.json 2>/dev/null)"
  xdg-open http://localhost:8016 >/dev/null 2>&1 &
  exit 1
fi
printf 'connect 127.0.0.1:27015; password %s' "$PW" | xclip -selection clipboard
notify-send -i steam_icon_10 "CS 1.6 server ready" "Joining 127.0.0.1:27015 (password $PW). Friends: <your IP>:27015"
xdg-open http://localhost:8016 >/dev/null 2>&1 &
steam "steam://connect/127.0.0.1:27015/$PW"
