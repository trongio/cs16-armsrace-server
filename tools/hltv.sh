#!/bin/bash
# HLTV recorder (runs in the cs16-hltv container): records every map to /demos, keeps the newest 40.
cd /hlds || exit 1
umask 000   # the dashboard and the host user can delete demos
mkdir -p /demos
# HLTV writes demos into the game folder
rm -rf cstrike/demos && ln -sfn /demos cstrike/demos
prune() {
  # finished recordings only; tiny ones are empty maps
  find /demos -name '*.dem' -size -200k -mmin +5 -delete 2>/dev/null
  ls -1t /demos/*.dem 2>/dev/null | tail -n +41 | xargs -r rm -f
}
(while sleep 120; do prune; done) &
export LD_LIBRARY_PATH=.:$LD_LIBRARY_PATH
cat > hltv.cfg <<EOF
name "HLTV"
hostname "CS 1.6 Arms Race HLTV"
delay 10
maxclients 0
autoretry 1
chatmode 0
serverpassword "${SV_PASSWORD:-}"
EOF
while :; do
  ./hltv -ip 127.0.0.1 -port 27020 +exec hltv.cfg +record demos/auto +connect "127.0.0.1:${PORT:-27015}"
  sleep 10
done
