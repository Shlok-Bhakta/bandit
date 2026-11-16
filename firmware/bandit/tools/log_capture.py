"""Keep the dongle's serial console open and write everything it says to disk, for crash hunting.

    log_capture.py PORT [DIR]

Opening the port resets the chip, so this opens it once and holds it: a later reset in the log is
the dongle's own (a panic, a watchdog, running out of memory). Writes DIR/dongle-<date>.log (every
line, timestamped; the band's packet lines and NimBLE's "unhandled event: 12" floods are counted,
not kept) and DIR/crashes.log (boots, panics, asserts, failed allocations, and the dongle's memory
reports). Reopens the port if it goes away (unplugged, re-enumerated). Lines appended to
DIR/send (`make capture-cmd C='...'`) go to the dongle as serial commands, without reopening the port.
"""
import os
import re
import sys
import time

import serial

PORT = sys.argv[1]
DIR = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/bandit/logs")
NOISE = re.compile(r"unhandled event: 12|band-core: packet")
CRASH = re.compile(r"rst:0x|Guru Meditation|panic|abort\(\)|assert|Backtrace|alloc|out of memory|"
                   r"stack overflow|watchdog|WDT|Brownout|bandit v|memory: |Rebooting", re.I)
ANSI = re.compile(r"\x1b\[[0-9;]*m")

os.makedirs(DIR, exist_ok=True)


def write(name, line):
    with open(os.path.join(DIR, name), "a") as out:
        out.write(line + "\n")


def stamp():
    return time.strftime("%Y-%m-%d %H:%M:%S")


noise, noise_since = 0, time.time()
lost = False  # logged once per outage, not on every retry while the dongle is unplugged
while True:
    try:
        port = serial.Serial()
        port.port, port.baudrate, port.timeout = PORT, 115200, 1
        port.dtr = False
        port.rts = False
        port.open()
        lost = False
        write("crashes.log", f"{stamp()} [capture] port open")
        pending = b""
        while True:
            pending += port.read(4096)
            outbox = os.path.join(DIR, "send")
            if os.path.exists(outbox):
                with open(outbox) as commands:
                    text = commands.read()
                os.remove(outbox)
                for command in text.splitlines():
                    if command.strip():
                        port.write(command.strip().encode() + b"\r\n")
                        write(f"dongle-{time.strftime('%Y%m%d')}.log", f"{stamp()} [capture] sent: {command.strip()}")
            *lines, pending = pending.split(b"\n")
            for raw in lines:
                line = ANSI.sub("", raw.decode(errors="replace")).rstrip("\r")
                if NOISE.search(line):
                    noise += 1
                    continue
                write(f"dongle-{time.strftime('%Y%m%d')}.log", f"{stamp()} {line}")
                if CRASH.search(line):
                    write("crashes.log", f"{stamp()} {line}")
            if noise and time.time() - noise_since >= 60:
                write(f"dongle-{time.strftime('%Y%m%d')}.log", f"{stamp()} [capture] {noise} packet/event-12 lines in the last minute")
                noise, noise_since = 0, time.time()
    except (serial.SerialException, OSError) as error:
        if not lost:
            write("crashes.log", f"{stamp()} [capture] port lost: {error}")
            lost = True
        time.sleep(2)
