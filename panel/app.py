"""CS 1.6 server dashboard: live state + controls over GoldSrc RCON, stats from the ServerTools SQLite DB."""
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


TOGGLES = {"colors", "lowgrav", "headshot", "speed", "adaptive", "announcer"}
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


# ---------- Shutdown (Docker API over the mounted socket) ----------

SHUTDOWN_ORDER = ["cs16", "cs16-fastdl", "cs16-panel"]  # panel last: it stops itself


def _docker_stop(name):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    try:
        s.connect("/var/run/docker.sock")
        s.sendall(f"POST /containers/{name}/stop?t=10 HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n".encode())
        s.recv(1024)
    finally:
        s.close()


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


app.mount("/static", StaticFiles(directory=STATIC), name="static")


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC, "index.html"))
