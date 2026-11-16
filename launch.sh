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
started=$(docker inspect -f '{{.State.StartedAt}}' cs16)
for _ in $(seq 90); do
  docker logs --since "$started" cs16 2>&1 | grep -qE 'Connection to Steam servers successful|VAC secure mode' && break
  sleep 2
done
printf 'connect 127.0.0.1:27015; password %s' "$PW" | xclip -selection clipboard
notify-send -i steam_icon_10 "CS 1.6 server ready" "Joining 127.0.0.1:27015 (password $PW). Friends: <your IP>:27015"
xdg-open http://localhost:8016 >/dev/null 2>&1 &
steam "steam://connect/127.0.0.1:27015/$PW"
