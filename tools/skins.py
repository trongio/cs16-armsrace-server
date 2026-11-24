#!/usr/bin/env python3
"""Make weapon finishes by recoloring the stock view models' texture palettes (no new art, no downloads).

Usage: skins.py <cstrike/models folder> <output folder>   -> <output>/<finish>/v_<weapon>.mdl
Weapon textures are mapped onto the finish's dark->mid->light gradient; hands stay, gloves get a hint of it.
Keep FINISHES and WEAPONS in sync with st_skins.inl and panel/app.py.
"""
import os, struct, sys

WEAPONS = "knife ak47 m4a1 awp scout famas galil deagle usp glock18 mp5 m3".split()
FINISHES = {
    "royalty": ((18, 4, 40), (112, 36, 190), (255, 214, 110)),
    "gold": ((46, 14, 0), (214, 120, 12), (255, 232, 140)),
    "neon": ((20, 0, 34), (236, 22, 150), (70, 250, 255)),
    "ocean": ((0, 14, 40), (14, 96, 190), (150, 240, 255)),
    "toxic": ((6, 20, 4), (60, 160, 20), (214, 255, 70)),
    "crimson": ((16, 0, 2), (170, 14, 24), (255, 150, 130)),
}
HANDS = ("view_skin", "view_finger", "newhand")
SKIP = ("reticle",)


def ramp(c, l):
    a, b, t = (c[0], c[1], l * 2) if l < 0.5 else (c[1], c[2], l * 2 - 1)
    return [a[i] + (b[i] - a[i]) * t for i in range(3)]


def recolor(src, colors):
    d = bytearray(src)
    assert d[:4] == b"IDST"
    n, ti = struct.unpack_from("<ii", d, 180)
    for k in range(n):
        o = ti + 80 * k
        name = bytes(d[o:o + 64]).split(b"\0")[0].decode("latin1").lower()
        flags, w, h, idx = struct.unpack_from("<4i", d, o + 64)
        if name.startswith(HANDS + SKIP):
            continue
        mix = 0.35 if name.startswith("view_glove") else 0.85
        pal = idx + w * h
        for i in range(255 if flags & 0x40 else 256):   # 0x40 = masked: entry 255 is the transparent key
            px = d[pal + i * 3:pal + i * 3 + 3]
            lum = min(1.0, (0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]) / 255 * 1.5)
            t = ramp(colors, lum)
            for j in range(3):
                d[pal + i * 3 + j] = max(0, min(255, round(px[j] * (1 - mix) + t[j] * mix)))
    return bytes(d)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    total = 0
    for f, colors in FINISHES.items():
        os.makedirs(os.path.join(sys.argv[2], f), exist_ok=True)
        for w in WEAPONS:
            out = recolor(open(os.path.join(sys.argv[1], f"v_{w}.mdl"), "rb").read(), colors)
            open(os.path.join(sys.argv[2], f, f"v_{w}.mdl"), "wb").write(out)
            total += len(out)
    print(f"{len(FINISHES)} finishes x {len(WEAPONS)} weapons, {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
