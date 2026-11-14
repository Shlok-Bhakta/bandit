"""Talk to the dongle's serial console without resetting it.

    serial_console.py PORT SECONDS [wait=N] [LINE ...]

With wait=N, first watches for N seconds (the hosts reconnect after the reset). Then sends each LINE (an app control command like `status`, or OWNER/FORGET/PAUSE/...), then prints
the dongle's log for SECONDS. Opening the port can reset the chip on some hosts; the log shows it.
"""
import re
import sys
import time

import serial

port = serial.Serial()
port.port, port.baudrate, port.timeout = sys.argv[1], 115200, 0.1
port.dtr = False
port.rts = False
port.open()
seconds = float(sys.argv[2])
lines = sys.argv[3:]
buffer = b""
if lines and lines[0].startswith("wait="):
    end = time.time() + float(lines.pop(0)[5:])
    while time.time() < end:
        buffer += port.read(4096)
for line in lines:
    port.write((line + "\n").encode())
    time.sleep(0.4)
end = time.time() + seconds
while time.time() < end:
    buffer += port.read(4096)
text = re.sub(r"\x1b\[[0-9;]*m", "", buffer.decode(errors="replace"))
print("\n".join(line for line in text.splitlines() if "band_dongle" in line and "band-core: packet" not in line))
