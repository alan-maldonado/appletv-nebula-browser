#!/usr/bin/env python3
"""Integration probe for the Nebula Remote trackpad WebSocket.

Usage: trackpad_probe.py HOST[:PORT]   (e.g. localhost:8080 or Alans-Apple-TV-4K.local:8080)
Prints PASS/FAIL/SKIP per check; exits non-zero if any check fails. Standard library only.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
import urllib.request

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TARGET = sys.argv[1] if len(sys.argv) > 1 else "localhost:8080"
HOST, _, PORT = TARGET.partition(":")
PORT = int(PORT or 8080)
failures = 0


def report(name, ok, detail=""):
    global failures
    status = "PASS" if ok is True else ("SKIP" if ok is None else "FAIL")
    if ok is False:
        failures += 1
    print(f"{status} {name} {detail}".rstrip())


def cursor():
    with urllib.request.urlopen(f"http://{TARGET}/api/cursor", timeout=5) as response:
        return json.loads(response.read())


def connect(origin=None):
    sock = socket.create_connection((HOST, PORT), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    origin_header = f"Origin: {origin}\r\n" if origin else ""
    sock.sendall((f"GET /api/trackpad HTTP/1.1\r\nHost: {TARGET}\r\nUpgrade: websocket\r\n{origin_header}"
                  f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(1024)
        if not chunk:
            break
        response += chunk
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    return sock, response.decode(errors="replace"), expected


def frame(opcode, payload, masked=True):
    header = bytes([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header += bytes([(0x80 if masked else 0) | length])
    else:
        header += bytes([(0x80 if masked else 0) | 126]) + struct.pack(">H", length)
    if not masked:
        return header + payload
    mask = os.urandom(4)
    return header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def send(sock, message):
    sock.sendall(frame(1, json.dumps(message).encode()))


def read_close_code(sock):
    sock.settimeout(3)
    data = b""
    try:
        while len(data) < 4:
            chunk = sock.recv(64)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    if len(data) >= 4 and data[0] & 0x0F == 8:
        return struct.unpack(">H", data[2:4])[0]
    return None


def wait_for(predicate, timeout=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = cursor()
        if predicate(state):
            return state
        time.sleep(0.05)
    return cursor()


# handshake
sock, response, expected = connect()
report("handshake", response.startswith("HTTP/1.1 101") and f"Sec-WebSocket-Accept: {expected}" in response,
       response.splitlines()[0] if response else "no response")

# origin (cross-site WebSocket hijacking guard)
evil, evil_response, _ = connect("https://evil.example.com")
evil.close()
panel, panel_response, _ = connect(f"http://{TARGET}")
panel.close()
report("origin", evil_response.startswith("HTTP/1.1 403") and panel_response.startswith("HTTP/1.1 101"),
       f"evil -> {evil_response.splitlines()[0] if evil_response else 'none'}, panel -> {panel_response.splitlines()[0] if panel_response else 'none'}")

# click-in-scroll-mode (before moving, which would switch modes on its own)
start = cursor()
if start["mode"] == "scroll":
    send(sock, {"t": "c"})
    after = wait_for(lambda s: s["mode"] == "cursor", 1.0)
    report("click-in-scroll-mode", after["mode"] == "cursor", f"mode {start['mode']} -> {after['mode']}")
else:
    report("click-in-scroll-mode", None, "TV already in cursor mode")

# move (go left first so +100 has room before the right edge)
send(sock, {"t": "m", "dx": -400, "dy": 0})
time.sleep(0.3)
before = cursor()
send(sock, {"t": "m", "dx": 100, "dy": 0})
after = wait_for(lambda s: s["x"] != before["x"])
report("move", abs((after["x"] - before["x"]) - 100) < 1 or after["x"] >= 1919, f"x {before['x']} -> {after['x']}")

# burst-then-still
t0 = time.time()
for _ in range(600):
    send(sock, {"t": "m", "dx": 5, "dy": 0})
elapsed = time.time() - t0
time.sleep(0.2)
first = cursor()
time.sleep(0.3)
second = cursor()
report("burst-then-still", first == second and elapsed < 3, f"sent in {elapsed:.2f}s, x {first['x']} then {second['x']}")

# scroll (must not break the connection)
send(sock, {"t": "s", "dx": 0, "dy": 40})
send(sock, {"t": "m", "dx": -50, "dy": 0})
moved = wait_for(lambda s: s["x"] != second["x"])
report("scroll-keeps-socket", moved["x"] != second["x"], f"x {second['x']} -> {moved['x']}")

# two-clients
other, response2, _ = connect()
before = cursor()
send(sock, {"t": "m", "dx": -10, "dy": 0})
send(other, {"t": "m", "dx": -10, "dy": 0})
after = wait_for(lambda s: before["x"] - s["x"] >= 20)
with urllib.request.urlopen(f"http://{TARGET}/", timeout=5) as page:
    page_status = page.status
report("two-clients", before["x"] - after["x"] >= 20 and page_status == 200 and response2.startswith("HTTP/1.1 101"),
       f"x {before['x']} -> {after['x']}, GET / {page_status}")

# close
other.sendall(frame(8, struct.pack(">H", 1000)))
code = read_close_code(other)
report("close", code == 1000, f"server close code {code}")
other.close()

# unmasked
sock.sendall(frame(1, b'{"t":"c"}', masked=False))
code = read_close_code(sock)
report("unmasked", code == 1002, f"server close code {code}")
sock.close()

# idle-timeout (slow: only with --idle)
if "--idle" in sys.argv:
    idle, _, _ = connect()
    idle.settimeout(75)
    started = time.time()
    try:
        data = idle.recv(64)
        code = struct.unpack(">H", data[2:4])[0] if len(data) >= 4 and data[0] & 0x0F == 8 else None
    except socket.timeout:
        code = None
    waited = time.time() - started
    report("idle-timeout", code == 1001 and 55 <= waited <= 75, f"close {code} after {waited:.0f}s")
    idle.close()

sys.exit(1 if failures else 0)
