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
sudo apt-get install -y curl jq xclip libnotify-bin unzip openssl python3
# Keep an existing Docker (docker-ce conflicts with docker.io).
docker compose version >/dev/null 2>&1 || sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  echo "Added $USER to the docker group (takes effect after logging out and back in)."
fi
DOCKER=(docker); docker info >/dev/null 2>&1 || DOCKER=(sudo docker)

ADMINS="$ADMINS" tools/setup.sh
SVPW=$(grep -oP '^SV_PASSWORD=\K.*' .env)

say "Firewall"
if sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow 27015/udp
  sudo ufw allow 27015/tcp
  sudo ufw allow 27080/tcp
  sudo ufw allow from 192.168.0.0/16 to any port 8016 proto tcp
else
  echo "ufw is not active, nothing to open."
fi

DESK=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")
if [[ -d "$DESK" ]]; then
  cp "$HOME/.local/share/applications/cs16-server.desktop" "$DESK/"
  chmod +x "$DESK/cs16-server.desktop"
  gio set "$DESK/cs16-server.desktop" metadata::trusted true 2>/dev/null || true
fi

cat <<EOF

Done. Start with the "CS 1.6 Server" shortcut, or:  cd "$DIR" && ./launch.sh
Dashboard: http://localhost:8016   Server password: $SVPW
For friends over the internet, forward on the router to this PC:
  27015 (TCP+UDP) and 27080 (TCP).
If docker says "permission denied", log out and back in once.
EOF
