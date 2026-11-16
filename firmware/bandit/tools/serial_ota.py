"""Push a .banditfw over the dongle's serial console with `OTA` lines, using the app's update protocol
and flow control (a window beyond the last ACK, rewinding on RESEND). Tests the whole update path
(signature, flash write, slot switch, probation) over USB.

    serial_ota.py PORT PACKAGE ok|tamper WATCH_SECONDS

`tamper` flips a signature bit: the dongle must refuse it before writing anything.
"""
import base64, re, struct, sys, time
import serial
device, path, mode, watch = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
package = bytearray(open(path, "rb").read())
if mode == "tamper": package[100] ^= 1
port = serial.Serial()
port.port, port.baudrate, port.timeout = device, 115200, 0
port.dtr = False; port.rts = False
port.open()
log, seen = b"", 0
def replies():
    global log, seen
    log += port.read(65536)
    text = log.decode(errors="replace")
    complete = text.rfind("\n") + 1   # only whole lines
    found = re.findall(r"UPDATE reply (8[0-9a-f]) ?([^\r\n\x1b]*)", text[seen:complete])
    seen = max(seen, complete)
    return found
def drain(seconds):
    end = time.time() + seconds
    while time.time() < end: replies(); time.sleep(0.02)
drain(12)
import hashlib
send = lambda payload: port.write(b"OTA " + base64.b64encode(payload) + b" " + hashlib.sha256(payload).hexdigest()[:8].encode() + b"\n")
# The dongle ACKs every 4 KB, so the window must be larger (the app uses 8 KB).
started, chunk, window = time.time(), 240, 6144
send(b"\x01" + struct.pack("<I", len(package)))
acked, offset, done, last_progress = 0, 0, None, time.time()
give_up = time.time() + 300
while done is None and time.time() < give_up:
    for code, arg in replies():
        if code == "81": acked = max(acked, int(arg)); last_progress = time.time()
        elif code == "82": offset = acked = int(arg); print("RESEND from", arg)
        elif code in ("83", "84"): done = (code, arg)
    if offset < len(package) and offset - acked < window:
        send(b"\x02" + struct.pack("<I", offset) + bytes(package[offset:offset + chunk]))
        offset += chunk
        time.sleep(0.002)
    else:
        time.sleep(0.01)
        if time.time() - last_progress > 5 and offset > acked:
            offset = acked; print("timeout: resend from", acked); last_progress = time.time() - 1
print(f"result {done} after {time.time() - started:.1f} s")
drain(watch)
text = re.sub(r"\x1b\[[0-9;]*m", "", log.decode(errors="replace"))
open("target/serial-ota.log", "w").write(text)
keep = ("UPDATE:", "UPDATE FAILED", "bandit v", "rst:", "Loaded app", "RESULT", "abort", "failed")
print("\n".join(l for l in text.splitlines() if any(k in l for k in keep)))
