"""CS 1.6 server dashboard: live state + controls over GoldSrc RCON, stats from the ServerTools SQLite DB,
server room (health, console, demos over the Docker socket) and weapon finishes."""
import json
import os
import re
import socket
import sqlite3
import threading
import time

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

RCON_HOST = os.environ.get("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("RCON_PORT", "27015"))
RCON_PASSWORD = os.environ["RCON_PASSWORD"]
SV_PASSWORD = os.environ.get("SV_PASSWORD", "")
PANEL_PORT = int(os.environ.get("PANEL_PORT", "8016"))
DB_PATH = os.environ.get("DB_PATH", "/data/servertools.sq3")
MODES_INI = os.environ.get("MODES_INI", "/cfg/servertools.ini")
STATIC = os.path.join(os.path.dirname(__file__), "static")

app = FastAPI()
_lock = threading.Lock()


# ---------- GoldSrc RCON (UDP, challenge based) ----------

HDR = b"\xff\xff\xff\xff"


def rcon(cmd: str) -> str:
    with _lock:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        try:
            addr = (RCON_HOST, RCON_PORT)
            s.sendto(HDR + b"challenge rcon\n", addr)
            data = s.recv(4096)
            m = re.search(rb"challenge rcon (\d+)", data)
            if not m:
                raise RuntimeError("no rcon challenge")
            s.sendto(HDR + f'rcon {m.group(1).decode()} "{RCON_PASSWORD}" {cmd}\n'.encode(), addr)
            out = b""
            s.settimeout(0.35)
            try:
                while True:
                    pkt = s.recv(65535)
                    if pkt.startswith(HDR):
                        pkt = pkt[4:]
                        if pkt[:1] == b"l":
                            pkt = pkt[1:]
                    out += pkt.rstrip(b"\0")
            except socket.timeout:
                pass
            text = out.decode(errors="replace")
            if "Bad rcon_password" in text:
                raise RuntimeError("rcon auth failed")
            return text
        finally:
            s.close()


# ---------- DB (read-only) ----------

def q(sql, *args):
    if not os.path.exists(DB_PATH):
        return []
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=3)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute(sql, args).fetchall()]
    finally:
        conn.close()


def iso(ts):
    return ts.replace(" ", "T") if ts else None


def modes():
    out = []
    try:
        for line in open(MODES_INI):
            line = line.strip()
            if not line or line[0] in ";#/":
                continue
            key, name, maps = (x.strip() for x in line.split("|", 2))
            out.append({"key": key, "name": name, "maps": [{"name": m, "workshop": None} for m in maps.split()]})
    except Exception as e:
        print("modes:", e, flush=True)
    return out


def public_ip():
    now = time.time()
    if now - public_ip.ts > 600:
        try:
            import urllib.request
            public_ip.val = urllib.request.urlopen("https://api.ipify.org", timeout=3).read().decode().strip()
            public_ip.ts = now
        except Exception:
            pass
    return public_ip.val


public_ip.ts = 0
public_ip.val = None


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.168.0.1", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


# ---------- API ----------

@app.get("/api/info")
def info():
    return {"lanUrl": f"http://{lan_ip()}:{PANEL_PORT}", "password": SV_PASSWORD, "publicIp": public_ip(), "port": RCON_PORT}


@app.get("/api/state")
def state():
    try:
        out = rcon("st_state")
        parts = {}
        total = None
        for m in re.finditer(r"STATEPART (\d+) (\d+) ([^\r\n]*)", out):
            parts[int(m.group(1))] = m.group(3)
            total = int(m.group(2))
        if not total or len(parts) != total:
            raise RuntimeError("incomplete state")
        st = json.loads("".join(parts[i] for i in range(total)))
        st["online"] = True
    except Exception as e:  # server down or still loading
        return {"online": False, "error": str(e)}
    st["modes"] = modes()
    st["password"] = SV_PASSWORD
    st["publicIp"] = public_ip()
    st["port"] = RCON_PORT
    return st


@app.get("/api/stats")
def stats():
    empty = {"humans": [], "bots": [], "weapons": [], "matches": [], "rivalry": [],
             "totals": {"kills": 0, "hs": 0, "pkills": 0, "bkills": 0, "matches": 0, "humans": 0}}
    try:
        q("SELECT 1 FROM st_players LIMIT 1")
    except Exception:
        return empty
    players = q("""
        SELECT p.id, p.name, p.is_bot, p.best_streak, p.last_seen,
          (SELECT COUNT(*) FROM st_kills k WHERE k.killer_id = p.id) AS kills,
          (SELECT COUNT(*) FROM st_kills k JOIN st_players v ON v.id = k.victim_id AND v.is_bot = 0
             WHERE k.killer_id = p.id AND k.victim_id <> p.id) AS pkills,
          (SELECT COUNT(*) FROM st_kills k JOIN st_players v ON v.id = k.victim_id AND v.is_bot = 1
             WHERE k.killer_id = p.id) AS bkills,
          (SELECT COUNT(*) FROM st_kills k WHERE k.victim_id = p.id) AS deaths,
          (SELECT COUNT(*) FROM st_kills k WHERE k.killer_id = p.id AND k.headshot = 1) AS hs,
          (SELECT COUNT(*) FROM st_matches m WHERE m.winner_id = p.id) AS wins,
          (SELECT k.weapon FROM st_kills k WHERE k.killer_id = p.id GROUP BY k.weapon ORDER BY COUNT(*) DESC LIMIT 1) AS fav
        FROM st_players p
    """)
    for p in players:
        p["kd"] = round(p["kills"] / max(p["deaths"], 1), 2)
        p["hsPct"] = round(100 * p["hs"] / p["kills"]) if p["kills"] else 0
        p["last_seen"] = iso(p["last_seen"])
    humans = sorted([p for p in players if not p["is_bot"]], key=lambda p: (-p["wins"], -p["kills"]))
    bots = sorted([p for p in players if p["is_bot"]], key=lambda p: -p["kills"])[:5]

    weapons = q("""SELECT k.weapon, COUNT(*) AS kills, SUM(k.headshot) AS hs FROM st_kills k
                   JOIN st_players p ON p.id = k.killer_id AND p.is_bot = 0
                   GROUP BY k.weapon ORDER BY kills DESC LIMIT 8""")
    matches = q("SELECT ts, map, mode, winner_name, winner_bot FROM st_matches ORDER BY id DESC LIMIT 12")
    for m in matches:
        m["ts"] = iso(m["ts"])
    totals = q("""SELECT COUNT(*) AS kills, COALESCE(SUM(headshot),0) AS hs,
                  (SELECT COUNT(*) FROM st_kills k JOIN st_players v ON v.id = k.victim_id AND v.is_bot = 0
                     JOIN st_players a ON a.id = k.killer_id AND a.is_bot = 0 WHERE k.killer_id <> k.victim_id) AS pkills,
                  (SELECT COUNT(*) FROM st_kills k JOIN st_players v ON v.id = k.victim_id AND v.is_bot = 1
                     JOIN st_players a ON a.id = k.killer_id AND a.is_bot = 0) AS bkills,
                  (SELECT COUNT(*) FROM st_matches) AS matches,
                  (SELECT COUNT(*) FROM st_players WHERE is_bot = 0) AS humans FROM st_kills""")[0]
    rivalry = q("""SELECT pk.name AS killer, pv.name AS victim, COUNT(*) AS n FROM st_kills k
                   JOIN st_players pk ON pk.id = k.killer_id AND pk.is_bot = 0
                   JOIN st_players pv ON pv.id = k.victim_id AND pv.is_bot = 0
                   WHERE k.killer_id <> k.victim_id
                   GROUP BY k.killer_id, k.victim_id ORDER BY n DESC LIMIT 5""")
    return {"humans": humans, "bots": bots, "weapons": weapons, "matches": matches,
            "totals": {k: int(v or 0) for k, v in totals.items()}, "rivalry": rivalry}


class Action(BaseModel):
    action: str
    value: str | None = None
    map: str | None = None


TOGGLES = {"colors", "lowgrav", "headshot", "speed", "adaptive", "announcer", "takeover"}
SAFE = re.compile(r"^[A-Za-z0-9_\-]{1,64}$")
SAY = re.compile(r'^[^";\r\n]{1,120}$')


@app.post("/api/action")
def action(a: Action):
    if a.action != "say":
        for v in (a.value, a.map):
            if v is not None and not SAFE.match(v):
                raise HTTPException(400, "bad value")
    if a.action == "map" and a.value:
        cmd = f"st_map {a.value}"
    elif a.action == "mode" and a.value:
        cmd = f"st_mode {a.value}" + (f" {a.map}" if a.map else "")
    elif a.action == "bots" and a.value and a.value.isdigit():
        cmd = f"st_bots {a.value}"
    elif a.action == "diff" and a.value in {"0", "1", "2", "3"}:
        cmd = f"st_diff {a.value}"
    elif a.action == "toggle" and a.value in TOGGLES:
        cmd = f"st_toggle {a.value}"
    elif a.action == "restart":
        cmd = "st_restart"
    elif a.action == "vote":
        cmd = "st_vote"
    elif a.action == "say" and a.value and SAY.match(a.value):
        cmd = f'say "[Host] {a.value}"'
    else:
        raise HTTPException(400, "unknown action")
    try:
        return {"ok": True, "out": rcon(cmd).strip()[:500]}
    except Exception as e:
        raise HTTPException(503, f"server unreachable: {e}")


# ---------- Docker API over the mounted socket ----------

SHUTDOWN_ORDER = ["cs16-hltv", "cs16", "cs16-fastdl", "cs16-panel"]  # panel last: it stops itself
RUNTIME = "/runtime"


def docker(method, path, timeout=30):
    """Minimal Docker Engine API call. Returns (status, body bytes)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect("/var/run/docker.sock")
        s.sendall(f"{method} {path} HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n".encode())
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    finally:
        s.close()
    head, _, body = data.partition(b"\r\n\r\n")
    status = int(head.split(b" ", 2)[1]) if head else 0
    return status, body


def _docker_stop(name):
    docker("POST", f"/containers/{name}/stop?t=10")


def container(name):
    st, body = docker("GET", f"/containers/{name}/json", timeout=5)
    if st != 200:
        return {"state": "missing"}
    j = json.loads(body)["State"]
    return {"state": j["Status"], "exitCode": j["ExitCode"], "startedAt": j["StartedAt"], "finishedAt": j["FinishedAt"]}


def _shutdown():
    time.sleep(0.5)
    for name in SHUTDOWN_ORDER:
        try:
            _docker_stop(name)
        except Exception as e:
            print(f"shutdown {name}: {e}", flush=True)


@app.post("/api/shutdown")
def shutdown():
    threading.Thread(target=_shutdown, daemon=True).start()
    return {"ok": True}


# ---------- Server health (tools/doctor.sh writes runtime/doctor.json) ----------

def read_json(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


_versions = {"started": None, "ts": 0, "data": {}}


def server_details(started):
    """Versions and plugin lists; they only change on a restart or map change, so ask at most every 30 s."""
    if _versions["started"] == started and time.time() - _versions["ts"] < 30:
        return _versions["data"]
    d = {"rehlds": None, "metamod": None, "amxx": None, "plugins": []}
    try:
        m = re.search(r"ReHLDS version: *(\S+)", rcon("version"))
        d["rehlds"] = m.group(1) if m else None
        m = re.search(r"Metamod-r v?([\d.]+)", rcon("meta version"))
        d["metamod"] = m.group(1) if m else None
        m = re.search(r"AMX Mod X ([\d.]+)", rcon("amxx version"))
        d["amxx"] = m.group(1) if m else None
        # columns: [ n] id  name  version  author  file  status (the name is cut or padded to 23 characters)
        for m in re.finditer(r"^ *\[ *\d+\] +\d+ +(\S.{22}) (\S+) +\S.*? {2,}\S+ +(\w+)(?: \w+)? *$", rcon("amxx plugins"), re.M):
            d["plugins"].append({"name": m.group(1).strip(), "version": m.group(2), "loaded": m.group(3) in ("running", "debug", "paused")})
    except Exception:
        pass
    if d["plugins"]:
        _versions.update(started=started, ts=time.time(), data=d)
    return d


@app.get("/api/server")
def server_info():
    cs16 = container("cs16")
    out = {"cs16": cs16, "hltv": container("cs16-hltv"), "doctor": read_json(f"{RUNTIME}/doctor.json"),
           "requestPending": os.path.exists(f"{RUNTIME}/doctor.request"), "plugins": []}
    if cs16["state"] == "running":
        out.update(server_details(cs16["startedAt"]))
    return out


class ServerCmd(BaseModel):
    action: str


def _restart():
    docker("POST", "/containers/cs16/restart?t=10", timeout=60)
    docker("POST", "/containers/cs16-hltv/restart?t=2", timeout=60)


@app.post("/api/server")
def server_cmd(c: ServerCmd):
    if c.action == "start":
        st, body = docker("POST", "/containers/cs16/start")
        if st not in (204, 304):
            raise HTTPException(500, f"start cs16: {body[:200].decode(errors='replace')}")
        docker("POST", "/containers/cs16-hltv/start")
        docker("POST", "/containers/cs16-fastdl/start")
    elif c.action == "stop":
        for name in ("cs16-hltv", "cs16"):  # the dashboard keeps running
            st, body = docker("POST", f"/containers/{name}/stop?t=10", timeout=40)
            if st not in (204, 304, 404):
                raise HTTPException(500, f"stop {name}: {body[:200].decode(errors='replace')}")
    elif c.action == "restart":
        threading.Thread(target=_restart, daemon=True).start()
    elif c.action in ("check", "repair"):
        with open(f"{RUNTIME}/doctor.request", "w") as f:
            f.write(c.action)
        os.chmod(f"{RUNTIME}/doctor.request", 0o666)
    else:
        raise HTTPException(400, "unknown action")
    return {"ok": True}


# ---------- Console + chat (container log) + RCON ----------

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z=>]|\x1b[=>]")
# Rcon lines contain the password; say lines already arrive as [CHAT].
NOISE = re.compile(r'Rcon: "|Bad Rcon|Server cvar |STATEPART|rcon_password|" say(_team)? "|^\s*$')
CHAT = re.compile(r"^\[CHAT\] (all|team) (\d) (.*?): (.*)$")


@app.get("/api/console")
def console(after: str = "", tail: int = 400):
    cs16 = container("cs16")
    if cs16["state"] == "missing":
        return {"lines": []}
    tail = max(50, min(tail, 3000))
    st, body = docker("GET", f"/containers/cs16/logs?stdout=1&stderr=1&timestamps=1&tail={tail}", timeout=10)
    start = cs16.get("startedAt", "")[:19]
    lines = []
    for raw in body.decode(errors="replace").splitlines():
        ts, _, text = raw.partition(" ")
        if ts[:19] < start or (after and ts <= after):
            continue
        text = ANSI.sub("", text).replace("\r", "")
        if NOISE.search(text):
            continue
        m = CHAT.match(text)
        if m:
            lines.append({"ts": ts, "kind": "chat", "scope": m.group(1), "team": int(m.group(2)),
                          "name": m.group(3), "text": m.group(4)})
            continue
        kind = "error" if re.search(r"error|bad load|failed|exception", text, re.I) else \
               "warn" if re.search(r"warning", text, re.I) else \
               "css" if re.match(r"\[(META|AMXX|YAPB|SITE|TAKEOVER)", text) else "log"
        lines.append({"ts": ts, "kind": kind, "text": text[:600]})
    lines.sort(key=lambda x: x["ts"])
    return {"lines": lines[-tail:]}


class RconCmd(BaseModel):
    cmd: str


@app.post("/api/rcon")
def rcon_cmd(c: RconCmd):
    cmd = c.cmd.strip()
    if not cmd or len(cmd) > 240 or "\n" in cmd or "\r" in cmd:
        raise HTTPException(400, "bad command")
    try:
        return {"out": rcon(cmd)[:20000]}
    except Exception as e:
        raise HTTPException(503, f"server unreachable: {e}")


# ---------- HLTV demos (cs16-hltv container records every map) ----------

DEMO_NAME = re.compile(r"^[A-Za-z0-9_.\-]+\.dem$")
DEMO_DIR = f"{RUNTIME}/demos"
MAP_IN_DEMO = re.compile(r"^auto-\d+-(.+)\.dem$")


def demo_path(name):
    if not DEMO_NAME.match(name):
        raise HTTPException(400, "bad name")
    p = os.path.join(DEMO_DIR, name)
    if os.path.isfile(p):
        return p
    raise HTTPException(404, "no such demo")


@app.get("/api/demos")
def demos():
    out = []
    now = time.time()
    try:
        names = os.listdir(DEMO_DIR)
    except Exception:
        names = []
    for n in names:
        p = os.path.join(DEMO_DIR, n)
        if not DEMO_NAME.match(n) or not os.path.isfile(p):
            continue
        st = os.stat(p)
        m = MAP_IN_DEMO.match(n)
        out.append({"name": n, "size": st.st_size, "mtime": st.st_mtime,
                    "map": m.group(1) if m else None, "recording": now - st.st_mtime < 20})
    out.sort(key=lambda x: -x["mtime"])
    return out


@app.get("/api/demos/{name}")
def demo_download(name: str):
    return FileResponse(demo_path(name), filename=name, media_type="application/octet-stream")


@app.delete("/api/demos/{name}")
def demo_delete(name: str):
    p = demo_path(name)
    if time.time() - os.stat(p).st_mtime < 20:
        raise HTTPException(409, "still recording")
    os.remove(p)
    return {"ok": True}


# ---------- Armory (weapon finishes, see tools/skins.py and st_skins.inl) ----------

WEAPONS = [("knife", "Knife"), ("ak47", "AK-47"), ("m4a1", "M4A1"), ("awp", "AWP"), ("scout", "Scout"), ("famas", "FAMAS"), ("galil", "Galil"),
           ("deagle", "Desert Eagle"), ("usp", "USP"), ("glock18", "Glock-18"), ("mp5navy", "MP5"), ("m3", "M3")]
FINISHES = [("stock", "Stock", ["#2b2f36", "#6b7079", "#b9bec7"]), ("royalty", "Royalty", ["#120428", "#7024be", "#ffd66e"]),
            ("gold", "Fire & Gold", ["#2e0e00", "#d6780c", "#ffe88c"]), ("neon", "Neon", ["#140022", "#ec1696", "#46faff"]),
            ("ocean", "Ocean", ["#000e28", "#0e60be", "#96f0ff"]), ("toxic", "Toxic", ["#061404", "#3ca014", "#d6ff46"]),
            ("crimson", "Crimson", ["#100002", "#aa0e18", "#ff9682"])]
SID = re.compile(r"^(STEAM|VALVE)_\d:\d:\d{1,12}$")


def check_sid(sid):
    if not SID.match(sid):
        raise HTTPException(400, "bad steamid")


@app.get("/api/armory/catalog")
def armory_catalog():
    installed = os.path.isfile(f"{RUNTIME}/models/{FINISHES[1][0]}/v_ak47.mdl")
    return {"installed": installed, "weapons": [{"key": k, "name": n} for k, n in WEAPONS],
            "finishes": [{"key": k, "name": n, "colors": c} for k, n, c in FINISHES]}


@app.get("/api/armory/players")
def armory_players():
    online = set()
    try:
        online = {p.get("id") for p in state().get("players", []) if not p["bot"]}
        rows = q("SELECT id, name FROM st_players WHERE is_bot = 0 ORDER BY last_seen DESC LIMIT 60")
    except Exception:
        return []
    return [{"id": r["id"], "name": r["name"], "online": r["id"] in online} for r in rows if SID.match(r["id"])]


@app.get("/api/armory/{sid}")
def armory_get(sid: str):
    check_sid(sid)
    try:
        rows = q("SELECT weapon, finish FROM st_skins WHERE player_id = ?", sid)
    except Exception:
        rows = []
    return {"skins": {r["weapon"]: r["finish"] for r in rows}}


class SkinSet(BaseModel):
    weapon: str   # weapon key or "all"
    finish: str


@app.post("/api/armory/{sid}")
def armory_set(sid: str, body: SkinSet):
    check_sid(sid)
    if body.weapon != "all" and body.weapon not in dict(WEAPONS):
        raise HTTPException(400, "unknown weapon")
    if body.finish not in {f[0] for f in FINISHES}:
        raise HTTPException(400, "unknown finish")
    try:
        out = rcon(f'st_skin "{sid}" {body.weapon} {body.finish}')
    except Exception as e:
        raise HTTPException(503, f"server unreachable: {e}")
    if "SKIN OK" not in out:
        raise HTTPException(500, out.strip()[:200] or "no answer")
    time.sleep(0.3)  # the plugin writes the DB in the background
    return {"ok": True}


app.mount("/static", StaticFiles(directory=STATIC), name="static")


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC, "index.html"))
