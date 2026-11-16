FROM steamcmd/steamcmd:ubuntu-24
RUN dpkg --add-architecture i386 && apt-get update && \
    apt-get install -y --no-install-recommends lib32gcc-s1 lib32stdc++6 libc6-i386 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
# app 90 is flaky: retry until hlds_linux exists
RUN for i in 1 2 3 4 5 6; do \
      steamcmd +force_install_dir /hlds +login anonymous \
        +app_set_config 90 mod cstrike \
        +app_update 90 -beta steam_legacy validate \
        +quit; \
      [ -f /hlds/hlds_linux ] && [ -d /hlds/cstrike ] && break; done; \
    test -f /hlds/hlds_linux && test -d /hlds/cstrike
RUN mkdir -p /root/.steam/sdk32 && ln -sf /root/.local/share/Steam/steamcmd/linux32/steamclient.so /root/.steam/sdk32/steamclient.so || true

# ReHLDS: replace Valve HLDS binaries so non-Steam clients can be accepted (by Reunion)
ARG REHLDS_VER=3.15.0.896
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip && rm -rf /var/lib/apt/lists/* && \
    curl -fsSL -o /tmp/rehlds.zip "https://github.com/rehlds/ReHLDS/releases/download/${REHLDS_VER}/rehlds-bin-${REHLDS_VER}.zip" && \
    unzip -q /tmp/rehlds.zip -d /tmp/rehlds && \
    cp -f /tmp/rehlds/bin/linux32/hlds_linux /hlds/hlds_linux && \
    cp -f /tmp/rehlds/bin/linux32/engine_i486.so /hlds/engine_i486.so && \
    cp -f /tmp/rehlds/bin/linux32/filesystem_stdio.so /hlds/filesystem_stdio.so && \
    cp -f /tmp/rehlds/bin/linux32/core.so /hlds/core.so && \
    cp -f /tmp/rehlds/bin/linux32/demoplayer.so /hlds/demoplayer.so && \
    cp -f /tmp/rehlds/bin/linux32/proxy.so /hlds/proxy.so && \
    cp -f /tmp/rehlds/bin/linux32/hltv /hlds/hltv && \
    chmod +x /hlds/hlds_linux /hlds/hltv && \
    rm -rf /tmp/rehlds /tmp/rehlds.zip
WORKDIR /hlds
ENTRYPOINT ["./hlds_run", "-game", "cstrike", "-strictportbind", "-ip", "0.0.0.0", "-port", "27015"]
CMD ["+map", "de_dust2", "+maxplayers", "16", "+sv_lan", "1"]
