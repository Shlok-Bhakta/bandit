"""Time how fast the dongle (re)connects the band, over serial.

    connect_bench.py PORT [ROUNDS] [reboot] [verbose]

Each round releases the band (`PAUSE`), waits for it to advertise again, reclaims it (`RESUME`) and
times it until the dongle logs `CONNECTED:` (with its own breakdown: link, encryption, L2CAP,
handshake). With `reboot`, each round restarts the dongle instead (after releasing the band), like plugging
it in, and also reports when the first computer reconnected. The band must be on and in range.
"""
import re
import statistics
import sys
import time

import serial

CONNECTED = re.compile(r"I \((\d+)\) bandit: CONNECTED: (\d+) ms from seeing the band \((.*)\)")
HOST = re.compile(r"I \((\d+)\) bandit::remote: HOST: .* connected")
ENDED = "band session ended"


def lines(port, seconds):
    """The dongle's log lines for up to `seconds`."""
    buffer, deadline = b"", time.time() + seconds
    while time.time() < deadline:
        try:
            buffer += port.read(4096)
        except (serial.SerialException, OSError):
            # A restart can re-enumerate the USB port.
            port.close()
            time.sleep(0.3)
            try:
                port.open()
            except (serial.SerialException, OSError):
                pass
            continue
        *complete, buffer = buffer.split(b"\n")
        for raw in complete:
            yield re.sub(r"\x1b\[[0-9;]*m", "", raw.decode(errors="replace")).strip()


def send(port, line):
    port.write((line + "\n").encode())


def main():
    port_name = sys.argv[1]
    rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    reboot = "reboot" in sys.argv[3:]
    verbose = "verbose" in sys.argv[3:]
    port = serial.Serial()
    port.port, port.baudrate, port.timeout = port_name, 115200, 0.1
    port.dtr = port.rts = False
    port.open()
    totals, connects, hosts = [], [], []
    for n in range(1, rounds + 1):
        # Release the band cleanly first: a dongle unplugged mid-session leaves the band waiting
        # out its supervision timeout, which plugging in later never sees.
        send(port, "PAUSE")
        for line in lines(port, 5):
            if ENDED in line:
                break
        time.sleep(3)  # the band advertises again
        send(port, "reboot" if reboot else "RESUME")
        started, result, host = time.time(), None, None
        for line in lines(port, 40):
            if verbose and ("bandit" in line or "Reattempt" in line or "NimBLE: GAP" in line):
                print("   ", line[:220])
            if match := HOST.search(line):
                host = host or int(match.group(1))
            if match := CONNECTED.search(line):
                result = match
                if not reboot:
                    break
            if reboot and result and host:
                break
        if not result:
            print(f"round {n}: no CONNECTED within 40 s")
            continue
        boot_ms, ms, steps = int(result.group(1)), int(result.group(2)), result.group(3)
        total = boot_ms if reboot else round_ms(started)
        totals.append(total)
        connects.append(ms)
        if host:
            hosts.append(host)
        extra = f", first computer at {host} ms after boot" if host else ""
        print(f"round {n}: {'boot' if reboot else 'RESUME'} -> live {total} ms; {ms} ms from seeing the band ({steps}){extra}")
        time.sleep(2)
    if totals:
        label = "boot -> live" if reboot else "RESUME -> live"
        print(f"{label}: median {statistics.median(totals):.0f} ms (min {min(totals)}, max {max(totals)}); "
              f"seen -> live median {statistics.median(connects):.0f} ms")
    if hosts:
        print(f"boot -> first computer: median {statistics.median(hosts):.0f} ms")
    port.close()


def round_ms(started):
    return int((time.time() - started) * 1000)


if __name__ == "__main__":
    main()
