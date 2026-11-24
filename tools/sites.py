#!/usr/bin/env python3
"""Generate Retakes/Rush site spawns from a map's bomb targets (.bsp) and its YaPB graph.

Usage: sites.py <folder with .bsp files> [map ...]     (writes overlay/addons/amxmodx/configs/sites/<map>.ini)

Every spawn is a YaPB node (a spot bots can stand on and walk from), so nobody gets stuck:
  P = plant spot (inside the bomb target)      S = on/around the site (retakes Ts, rush CTs)
  E = entrance, a 5-9 s run from the site (retakes CTs, rush Ts)
Line format: <A|B> <P|S|E> x y z yaw node
"""
import heapq, math, os, re, struct, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "overlay/addons/amxmodx/configs/sites")
GRAPHS = os.path.join(ROOT, "yapb-graph")
DEFAULT = "de_dust2 de_inferno de_nuke de_train de_aztec de_dust de_cbble de_vertigo de_prodigy".split()
# Bomb targets carry no A/B label in the BSP. Sites are listed as (x, y, z) near site A per map.
SITE_A = {
    "de_dust2": (1152, 2464, 144), "de_inferno": (1984, 456, 193), "de_nuke": (680, -776, -368), "de_train": (1296, -160, -164),
    "de_aztec": (-536, -1512, -192), "de_dust": (1952, 608, 80), "de_cbble": (-2800, -1744, 128), "de_vertigo": (-312, 208, 40),
    "de_prodigy": (1984, -84, -400),   # prodigy has no letters painted in the map, A/B is our pick
}

F_CROUCH, F_LADDER, F_GOAL, F_NARROW, F_LIFT = 1 << 2, 1 << 5, 1 << 4, 1 << 10, 1 << 1


def ulz(src, size):
    out, i, n = bytearray(), 0, len(src)

    def varint():
        nonlocal i
        x = 0
        for s in range(0, 22, 7):
            c = src[i]; i += 1
            x += c << s
            if c < 128:
                break
        return x

    while i < n:
        tok = src[i]; i += 1
        if tok >= 32:
            run = tok >> 5
            if run == 7:
                run += varint()
            out += src[i:i + run]; i += run
            if i >= n:
                break
        ln = (tok & 15) + 4
        if ln == 19:
            ln += varint()
        dist = ((tok & 16) << 12) + src[i] + (src[i + 1] << 8); i += 2
        p = len(out) - dist
        for k in range(ln):
            out.append(out[p + k])
    assert len(out) == size, (len(out), size)
    return bytes(out)


def load_graph(path):
    d = open(path, "rb").read()
    magic, ver, opt, length, comp, unc = struct.unpack_from("<6i", d)
    body = ulz(d[24:24 + comp], unc)
    nodes = []
    for k in range(length):
        o = k * 220
        num, flags, x, y, z = struct.unpack_from("<ii3f", body, o)
        links = []
        for j in range(8):
            vx, vy, vz, dist, fl, idx = struct.unpack_from("<3fiHh", body, o + 56 + j * 20)
            if 0 <= idx < length:
                links.append((idx, max(dist, 1), fl))
        nodes.append(dict(id=k, flags=flags, pos=(x, y, z), links=links))
    return nodes


def bsp_info(path):
    d = open(path, "rb").read()
    lump = lambda i: struct.unpack_from("<ii", d, 4 + i * 8)
    o, n = lump(0)
    ents = []
    for m in re.finditer(r"\{([^}]*)\}", d[o:o + n].decode("latin1")):
        ents.append(dict(re.findall(r'"([^"]*)"\s+"([^"]*)"', m.group(1))))
    mo, _ = lump(14)
    sites, cts, ts = [], [], []
    vec = lambda s: tuple(float(v) for v in s.split()[:3])
    for e in ents:
        c = e.get("classname")
        if c in ("func_bomb_target", "info_bomb_target"):
            if e.get("model", "").startswith("*"):
                i = int(e["model"][1:])
                b = struct.unpack_from("<6f", d, mo + i * 64)
                sites.append((b[:3], b[3:]))
            elif "origin" in e:
                p = vec(e["origin"])
                sites.append((tuple(v - 96 for v in p), tuple(v + 96 for v in p)))
        elif c == "info_player_start" and "origin" in e:
            cts.append(vec(e["origin"]))
        elif c == "info_player_deathmatch" and "origin" in e:
            ts.append(vec(e["origin"]))
    return sites, cts, ts


def center(b): return tuple((b[0][i] + b[1][i]) / 2 for i in range(3))
def d2(a, b): return math.dist(a, b)


def merge(boxes):
    """Several brushes can form one site: merge the closest boxes until 2 remain."""
    boxes = list(boxes)
    while len(boxes) > 2:
        i, j = min(((i, j) for i in range(len(boxes)) for j in range(i)), key=lambda p: d2(center(boxes[p[0]]), center(boxes[p[1]])))
        a, b = boxes[i], boxes[j]
        boxes = [x for k, x in enumerate(boxes) if k not in (i, j)]
        boxes.append((tuple(map(min, a[0], b[0])), tuple(map(max, a[1], b[1]))))
    return boxes


def run_dist(nodes, rev, sources):
    """Walking distance from every node to the site (over reversed links)."""
    dist, q = {}, [(0, s) for s in sources]
    for _, s in q:
        dist[s] = 0
    heapq.heapify(q)
    while q:
        d, u = heapq.heappop(q)
        if d > dist[u]:
            continue
        for v, w in rev[u]:
            nd = d + w
            if nd < dist.get(v, 1e18):
                dist[v] = nd
                heapq.heappush(q, (nd, v))
    return dist


def spread(cands, n, gap):
    """Greedy farthest-point pick so spawns are not clumped together."""
    cands = list(cands)
    if not cands:
        return []
    pick = [cands[0]]
    while len(pick) < n:
        best = max(cands, key=lambda c: min(d2(c["pos"], p["pos"]) for p in pick))
        if min(d2(best["pos"], p["pos"]) for p in pick) < gap:
            break
        pick.append(best)
    return pick


def yaw(a, b): return math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))


def build(name, bspdir):
    boxes, cts, ts = bsp_info(os.path.join(bspdir, name + ".bsp"))
    nodes = load_graph(os.path.join(GRAPHS, name + ".graph"))
    boxes = merge(boxes)
    if not boxes:
        raise SystemExit(f"{name}: no bomb target")
    a = SITE_A.get(name)
    boxes.sort(key=lambda b: d2(center(b), a) if a else center(b)[0])
    rev = [[] for _ in nodes]
    for nd in nodes:
        for v, w, fl in nd["links"]:
            rev[v].append((nd["id"], w))
    ok = lambda nd: not nd["flags"] & (F_CROUCH | F_LADDER | F_NARROW | F_LIFT) and len(nd["links"]) >= 2
    inside = lambda nd, b, m: all(b[0][i] - m <= nd["pos"][i] <= b[1][i] + (m if i < 2 else max(m, 72)) for i in range(3))
    site_src = []
    for b in boxes:
        src = [nd["id"] for nd in nodes if inside(nd, b, 0)] or [min(nodes, key=lambda nd: d2(nd["pos"], center(b)))["id"]]
        site_src.append(src)
    dists = [run_dist(nodes, rev, s) for s in site_src]
    lines = []
    for si, b in enumerate(boxes):
        d, c, label = dists[si], center(b), "AB"[si]
        other = dists[1 - si] if len(boxes) > 1 else {}
        plant = spread([nd for nd in nodes if inside(nd, b, 0) and ok(nd)] or [nodes[site_src[si][0]]], 4, 60)
        pids = {p["id"] for p in plant}
        near = [nd for nd in nodes if ok(nd) and nd["id"] not in pids and d.get(nd["id"], 1e9) <= 520 and d2(nd["pos"], c) < 700]
        # 250 u/s: 1200..2200 units is a 5-9 s run. Closer to this site than to the other one.
        ent = [nd for nd in nodes if ok(nd) and 1200 <= d.get(nd["id"], 1e9) <= 2200 and d[nd["id"]] < other.get(nd["id"], 1e9) + 300]
        if len(spread(ent, 8, 90)) < 8:
            ent = [nd for nd in nodes if ok(nd) and 800 <= d.get(nd["id"], 1e9) <= 2600]
        ent.sort(key=lambda nd: abs(d[nd["id"]] - 1600))
        near.sort(key=lambda nd: -d[nd["id"]])
        for kind, pts, n, gap in (("P", plant, 4, 60), ("S", near, 10, 70), ("E", ent, 10, 110)):
            for p in spread(pts, n, gap):
                if kind == "E":   # look where the path to the site goes
                    nxt = min((l[0] for l in p["links"] if l[0] in d), key=lambda v: d[v], default=None)
                    nxt2 = min((l[0] for l in nodes[nxt]["links"] if l[0] in d), key=lambda v: d[v], default=nxt) if nxt is not None else None
                    ang = yaw(p["pos"], nodes[nxt2]["pos"]) if nxt2 is not None and nxt2 != p["id"] else yaw(p["pos"], c)
                else:             # on site: look outward, at the closest way in
                    ang = yaw(c, p["pos"]) if d2(c, p["pos"]) > 40 else 0
                lines.append((label, kind, *p["pos"], ang, p["id"]))
    return boxes, lines


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    os.makedirs(OUT, exist_ok=True)
    for name in sys.argv[2:] or DEFAULT:
        boxes, lines = build(name, sys.argv[1])
        with open(os.path.join(OUT, name + ".ini"), "w") as f:
            f.write(f"; {name}: generated by tools/sites.py  (site  P plant / S on site / E entrance  x y z yaw node)\n")
            for l in lines:
                f.write("%s %s %.0f %.0f %.0f %.0f %d\n" % l)
        cnt = {(s, k): sum(1 for l in lines if l[0] == s and l[1] == k) for s in "AB" for k in "PSE"}
        print(name, [tuple(round(v) for v in center(b)) for b in boxes], {f"{s}{k}": v for (s, k), v in cnt.items()})


if __name__ == "__main__":
    main()
