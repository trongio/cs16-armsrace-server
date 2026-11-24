#!/bin/bash
# The part of the install that needs no sudo: passwords, images, weapon finishes, shortcuts, health-check unit.
# Run by install.sh, and by dashboard.sh when it is started before the install. Safe to run again.
set -euo pipefail
ADMINS="${ADMINS:-}"
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$DIR"

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
DOCKER=(docker); docker info >/dev/null 2>&1 || DOCKER=(sudo docker)

say "Passwords (.env)"
if [[ ! -f .env ]]; then
  printf 'RCON_PASSWORD=%s\nSV_PASSWORD=%s\n' "$(openssl rand -hex 8)" "$(openssl rand -hex 3)" > .env
fi
chmod 600 .env
RCON=$(grep -oP '^RCON_PASSWORD=\K.*' .env)
SVPW=$(grep -oP '^SV_PASSWORD=\K.*' .env)
sed -i "s/^rcon_password .*/rcon_password \"$RCON\"/; s/^sv_password .*/sv_password \"$SVPW\"/" cfg/server.cfg

say "Admins"
USERS=overlay/addons/amxmodx/configs/users.ini
for sid in ${ADMINS//,/ }; do
  [[ "$sid" =~ ^7656119[0-9]{10}$ ]] || { echo "Skipping invalid SteamID64: $sid"; continue; }
  z=$((sid - 76561197960265728))
  id="STEAM_0:$((z % 2)):$((z / 2))"
  grep -q "\"$id\"" "$USERS" || echo "\"$id\" \"\" \"abcdefghijklmnopqrstu\" \"ce\"" >> "$USERS"
  echo "Admin: $id"
done

say "Public IP for map downloads (FastDL)"
if IP=$(curl -fsS --max-time 5 https://api.ipify.org); then
  sed -i "s|^sv_downloadurl .*|sv_downloadurl \"http://$IP:27080/\"|" cfg/server.cfg
  echo "sv_downloadurl -> http://$IP:27080/"
else
  echo "Could not detect the public IP; edit sv_downloadurl in cfg/server.cfg by hand."
fi

say "Building images (first run downloads HLDS, takes a few minutes)"
mkdir -p data yapb-graph runtime/demos runtime/models
"${DOCKER[@]}" build -t cs16-hlds -f Dockerfile .
"${DOCKER[@]}" compose build

say "Weapon finishes (recolored from the HLDS view models)"
if [[ -z "$(find runtime/models -name '*.mdl' -print -quit)" ]]; then
  "${DOCKER[@]}" run --rm --user "$(id -u):$(id -g)" -v "$DIR/tools:/tools:ro" -v "$DIR/runtime:/out" \
    --entrypoint cp cs16-hlds -r /hlds/cstrike/models /out/stock
  python3 tools/skins.py runtime/stock runtime/models
  rm -rf runtime/stock
fi

say "Desktop shortcuts"
APPS="$HOME/.local/share/applications"
mkdir -p "$APPS"
cat > "$APPS/cs16-server.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CS 1.6 Server
Comment=Start the CS 1.6 server and join it
Exec=$DIR/launch.sh
Icon=steam_icon_10
Terminal=false
Categories=Game;
Actions=stop;

[Desktop Action stop]
Name=Stop CS 1.6 server
Exec=$DIR/launch.sh stop
EOF
cat > "$APPS/cs16-dashboard.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CS 1.6 Dashboard
Comment=Start, stop and manage the CS 1.6 server in the browser
Exec=$DIR/dashboard.sh
Icon=utilities-system-monitor
Terminal=false
Categories=Game;
Actions=stop;

[Desktop Action stop]
Name=Stop server and dashboard
Exec=$DIR/launch.sh stop
EOF
chmod +x launch.sh dashboard.sh tools/*.py tools/*.sh "$APPS"/cs16-*.desktop

say "Health check (systemd user units)"
# tools/doctor.sh runs when the dashboard asks for a check or repair.
UNITS="$HOME/.config/systemd/user"
mkdir -p "$UNITS"
cat > "$UNITS/cs16-doctor.service" <<EOF
[Unit]
Description=CS 1.6 server doctor (health check / repair)

[Service]
Type=oneshot
ExecStart=$DIR/tools/doctor.sh trigger
TimeoutStartSec=30min
EOF
cat > "$UNITS/cs16-doctor.path" <<EOF
[Unit]
Description=Run the CS 1.6 doctor on dashboard requests

[Path]
PathExists=$DIR/runtime/doctor.request
Unit=cs16-doctor.service

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now cs16-doctor.path
DESK=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")
if [[ -d "$DESK" ]]; then
  cp "$APPS/cs16-dashboard.desktop" "$DESK/"
  chmod +x "$DESK/cs16-dashboard.desktop"
  gio set "$DESK/cs16-dashboard.desktop" metadata::trusted true 2>/dev/null || true
fi
touch runtime/.setup-done
