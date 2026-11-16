"""Read or replace the dongle's gesture profile set over its USB serial console.

    profiles_tool.py PORT get FILE     the set the dongle runs, pretty-printed into FILE
    profiles_tool.py PORT put FILE     FILE (minified) onto the dongle; prints why if it refuses

Opening the port restarts the dongle on some Macs, so both wait for it to come up first. After a
put, the phone's Bandit app shows a different set: Get the dongle's set there picks it up.
"""
import base64
import hashlib
import json
import re
import sys
import time

import serial

BOOT_WAIT = 4.0


def open_port(name):
    port = serial.Serial()
    port.port, port.baudrate, port.timeout = name, 115200, 0.1
    port.dtr = False
    port.rts = False
    port.open()
    return port


def lines_until(port, done, seconds):
    """Dongle log lines (colour codes stripped) until `done(line)` or the time runs out."""
    buffer, end, seen = b"", time.time() + seconds, []
    while time.time() < end:
        buffer += port.read(4096)
        *complete, buffer = buffer.split(b"\n")
        for raw in complete:
            line = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode(errors="replace")).strip()
            seen.append(line)
            if done(line):
                return seen
    return seen


def settle(port):
    """Waits out a restart caused by opening the port (or a quiet moment if there was none)."""
    lines_until(port, lambda line: "HOST side: advertising" in line, BOOT_WAIT)
    time.sleep(0.5)


def send(port, line):
    port.write((line + "\n").encode())
    time.sleep(0.05)


def get(port, path):
    settle(port)
    send(port, "profiles show")
    lines = lines_until(port, lambda line: "PROFILES: show end" in line, 20)
    begin, chunks = None, {}
    for line in lines:
        if "PROFILES: show begin " in line:
            begin = line.split("PROFILES: show begin ", 1)[1].split()
        elif "PROFILES: show data " in line:
            offset, data = line.split("PROFILES: show data ", 1)[1].split()
            chunks[int(offset)] = base64.b64decode(data)
    if begin is None or not any("PROFILES: show end" in line for line in lines):
        sys.exit("no answer from the dongle (firmware 0.12.1 or later?)")
    data = b"".join(chunks[offset] for offset in sorted(chunks))
    length, sha8 = int(begin[0]), begin[1]
    if len(data) != length or hashlib.sha256(data).hexdigest()[:8] != sha8:
        sys.exit(f"got {len(data)} bytes that don't match the dongle's {length} bytes {sha8}: try again")
    with open(path, "w") as out:
        json.dump(json.loads(data), out, indent=2, ensure_ascii=False)
        out.write("\n")
    print(f"{path}: {length} bytes, {sha8}{' (the built-in set)' if 'builtin' in begin[2:] else ''}")


def put(port, path):
    with open(path) as source:
        data = json.dumps(json.load(source), separators=(",", ":"), ensure_ascii=False).encode()
    sha8 = hashlib.sha256(data).hexdigest()[:8]
    settle(port)
    send(port, f"profiles begin {len(data)} {sha8}")
    for offset in range(0, len(data), 150):
        send(port, f"profiles data {offset} {base64.b64encode(data[offset:offset + 150]).decode()}")
    send(port, "profiles commit")
    lines = lines_until(port, lambda line: "PROFILES: saved" in line or "PROFILES: refused" in line, 15)
    result = next((line for line in reversed(lines) if "PROFILES: saved" in line or "PROFILES: refused" in line), None)
    if result is None:
        sys.exit("the dongle didn't answer")
    print(result.split("bandit::profiles: ", 1)[-1])
    if "refused" in result:
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[2] not in ("get", "put"):
        sys.exit(__doc__)
    port = open_port(sys.argv[1])
    (get if sys.argv[2] == "get" else put)(port, sys.argv[3])
