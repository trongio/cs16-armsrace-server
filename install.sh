#!/bin/bash
# CS 1.6 Arms Race server: one-time install on Ubuntu 24.04.
# Run from the folder:  ./install.sh
# Optional admins (SteamID64, comma separated):  ADMINS=7656119...,7656119... ./install.sh
# Safe to run again. Needs sudo for packages and the firewall.
set -euo pipefail
ADMINS="${ADMINS:-}"
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$DIR"

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

. /etc/os-release
[[ "${VERSION_ID:-}" == 24.04 ]] || echo "Warning: made for Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}. Continuing."

say "Installing Docker and helpers"
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 curl jq xclip libnotify-bin unzip openssl
sudo systemctl enable --now docker
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  echo "Added $USER to the docker group (takes effect after logging out and back in)."
fi
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
mkdir -p data yapb-graph
"${DOCKER[@]}" build -t cs16-hlds -f Dockerfile .
"${DOCKER[@]}" compose build

say "Firewall"
if sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow 27015/udp
  sudo ufw allow 27015/tcp
  sudo ufw allow 27080/tcp
  sudo ufw allow from 192.168.0.0/16 to any port 8016 proto tcp
else
  echo "ufw is not active, nothing to open."
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
Comment=Live scoreboard, stats and server controls
Exec=sh -c 'cd "$DIR" && docker compose up -d panel && sleep 2 && xdg-open http://localhost:8016'
Icon=utilities-system-monitor
Terminal=false
Categories=Game;
EOF
chmod +x launch.sh tools/*.py "$APPS"/cs16-*.desktop
DESK=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")
if [[ -d "$DESK" ]]; then
  cp "$APPS/cs16-server.desktop" "$APPS/cs16-dashboard.desktop" "$DESK/"
  chmod +x "$DESK"/cs16-*.desktop
  gio set "$DESK/cs16-server.desktop" metadata::trusted true 2>/dev/null || true
  gio set "$DESK/cs16-dashboard.desktop" metadata::trusted true 2>/dev/null || true
fi

cat <<EOF

Done. Start with the "CS 1.6 Server" shortcut, or:  cd "$DIR" && ./launch.sh
Dashboard: http://localhost:8016   Server password: $SVPW
For friends over the internet, forward on the router to this PC:
  27015 (TCP+UDP) and 27080 (TCP).
If docker says "permission denied", log out and back in once.
EOF
