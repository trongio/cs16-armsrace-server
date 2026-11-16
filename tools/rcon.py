#!/usr/bin/env python3
"""GoldSrc RCON client for the local CS 1.6 server. Usage: rcon.py <command...>"""
import os, re, socket, sys
env = dict(l.strip().split('=', 1) for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")) if '=' in l)
H = b'\xff\xff\xff\xff'; addr = ('127.0.0.1', 27015)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(H + b'challenge rcon\n', addr)
ch = re.search(rb'challenge rcon (\d+)', s.recv(4096)).group(1).decode()
s.sendto(H + f'rcon {ch} "{env["RCON_PASSWORD"]}" {" ".join(sys.argv[1:])}\n'.encode(), addr)
s.settimeout(1)
try:
    while True:
        p = s.recv(65535)
        print(p[5:].rstrip(b'\0').decode(errors='replace') if p.startswith(H) else p.decode(errors='replace'), end='')
except socket.timeout:
    pass
