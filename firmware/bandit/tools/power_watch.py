"""Measure what the band's states cost: log the dongle over serial for hours and summarise.

    power_watch.py PORT OUTDIR PHASE [PHASE ...]

Each PHASE is `name:minutes`, run in order: `auto` (the firmware decides), `motion` (wrist
motion forced on), `writing` (the handwriting model forced on), `both`, or `wait` (until the band
reports it's off its charger, at most that long). While it runs, a line
written to OUTDIR/commands is sent to the dongle (e.g. `status`). Everything the dongle logs goes
to OUTDIR/power.log with wall-clock times; OUTDIR/summary.txt is rewritten every minute:

- the band's own current draw (mA, averaged; it reports it with each battery read, every 15 s
  while measuring) and voltage: the measurement that answers within minutes,
- the band's battery (%) at the start and end of each phase, and %/hour (only while it isn't
  charging, which gains instead),
- the band's radio traffic (SDUs and bytes a second, from the `streaming:` lines), gyro samples
  a second, and whether motion and handwriting were on.

The battery is reported in 1 % steps, so a phase needs an hour or more to say much; traffic is
exact at once and is most of what the dongle controls.
"""
import os
import re
import sys
import time

import serial

PHASE_COMMANDS = {
    "auto": ["power motion auto", "power writing auto"],
    "motion": ["power motion on", "power writing auto"],
    "writing": ["power motion auto", "power writing on"],
    "both": ["power motion on", "power writing on"],
}
BATTERY = re.compile(r"battery (\d+)% charging (Some\(true\)|Some\(false\)|None)(?: · (\d+|\?) mV, (-?\d+|\?) mA, ([\d.]+|\?) °C)?")
# Battery reads every this many seconds while measuring (each wakes the band's radio a little).
SAMPLE_SECONDS = 15
STREAMING = re.compile(r"streaming: (\d+) packets \((\d+) SDUs, (\d+) B\), (\d+) gyro, (\d+) gestures(?:, motion (\w+), writing (\w+))?")


class Phase:
    def __init__(self, name, minutes):
        self.name, self.minutes = name, minutes
        self.started = self.ended = None
        self.battery = []  # (time, level) while not charging
        self.current = []  # (time, mA, mV) while not charging: the band's own reading
        self.charging = False
        self.traffic = []  # (time, sdus, bytes, gyro, gestures, motion, writing)

    def rate(self, index):
        """Per second between the phase's first and last streaming line (a reconnect resets the counters)."""
        total, seconds = 0.0, 0.0
        for a, b in zip(self.traffic, self.traffic[1:]):
            if b[index] >= a[index]:
                total += b[index] - a[index]
                seconds += b[0] - a[0]
        return total / seconds if seconds else None

    def describe(self):
        hours = ((self.ended or time.time()) - self.started) / 3600 if self.started else 0
        parts = [f"{self.name:8} {hours * 60:6.1f} min"]
        if len(self.battery) >= 2:
            (t0, b0), (t1, b1) = self.battery[0], self.battery[-1]
            span = (t1 - t0) / 3600
            per_hour = (b0 - b1) / span if span > 0 else 0
            parts.append(f"battery {b0}% -> {b1}% over {span * 60:.0f} min = {per_hour:.2f} %/h")
        elif self.battery:
            parts.append(f"battery {self.battery[0][1]}% (one reading)")
        if self.current:
            amps = [ma for _, ma, _ in self.current]
            volts = [mv for _, _, mv in self.current if mv]
            parts.append(f"current {sum(amps) / len(amps):.1f} mA avg (min {min(amps)}, max {max(amps)}, n={len(amps)})")
            if volts:
                parts.append(f"{volts[0]}->{volts[-1]} mV")
        if self.charging:
            parts.append("CHARGED during the phase (battery excluded while charging)")
        for label, index in (("SDU/s", 1), ("B/s", 2), ("gyro/s", 3)):
            value = self.rate(index)
            if value is not None:
                parts.append(f"{label} {value:.2f}")
        states = {(t[5], t[6]) for t in self.traffic if t[5]}
        if states:
            parts.append("motion/writing " + ", ".join(f"{m}/{w}" for m, w in sorted(states)))
        return "  ".join(parts)


def main():
    port_name, outdir, *specs = sys.argv[1:]
    phases = [Phase(name, float(minutes)) for name, minutes in (spec.split(":") for spec in specs)]
    os.makedirs(outdir, exist_ok=True)
    log = open(os.path.join(outdir, "power.log"), "a", buffering=1)
    commands = os.path.join(outdir, "commands")
    open(commands, "a").close()
    command_offset = os.path.getsize(commands)

    port = serial.Serial()
    port.port, port.baudrate, port.timeout = port_name, 115200, 0.2
    port.dtr = False
    port.rts = False
    port.open()

    def send(line):
        port.write((line + "\n").encode())
        log.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} >>> {line}\n")
        time.sleep(0.3)

    send(f"power sample {SAMPLE_SECONDS}")
    index, buffer, last_summary = -1, b"", 0.0
    phase_end = 0.0
    while True:
        now = time.time()
        if now >= phase_end:
            if 0 <= index < len(phases):
                phases[index].ended = now
            index += 1
            if index >= len(phases):
                break
            phase = phases[index]
            phase.started, phase_end = now, now + phase.minutes * 60
            log.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} === phase {phase.name} for {phase.minutes} min\n")
            for command in PHASE_COMMANDS.get(phase.name, []):
                send(command)
        size = os.path.getsize(commands)
        if size > command_offset:
            with open(commands) as file:
                file.seek(command_offset)
                for line in file.read().splitlines():
                    if line.strip():
                        send(line.strip())
            command_offset = size
        buffer += port.read(4096)
        *lines, buffer = buffer.split(b"\n")
        for raw in lines:
            line = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode(errors="replace")).strip()
            if not line or "band-core: packet" in line:
                continue
            log.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")
            phase = phases[index]
            if match := BATTERY.search(line):
                if match.group(2) == "Some(true)":
                    phase.charging = True
                elif phase.name == "wait":
                    # Off the charger: the measured phases start now.
                    phase_end = time.time()
                else:
                    phase.battery.append((time.time(), int(match.group(1))))
                    if match.group(4) not in (None, "?"):
                        volts = int(match.group(3)) if match.group(3) not in (None, "?") else None
                        phase.current.append((time.time(), int(match.group(4)), volts))
            if match := STREAMING.search(line):
                values = [int(match.group(i)) for i in range(2, 6)]
                phase.traffic.append((time.time(), *values, match.group(6), match.group(7)))
        if now - last_summary >= 60:
            last_summary = now
            write_summary(outdir, phases)
    for command in PHASE_COMMANDS["auto"] + ["power sample 120"]:
        send(command)
    write_summary(outdir, phases)
    port.close()


def write_summary(outdir, phases):
    text = "\n".join(phase.describe() for phase in phases if phase.started)
    with open(os.path.join(outdir, "summary.txt"), "w") as file:
        file.write(time.strftime("%Y-%m-%d %H:%M:%S") + "\n" + text + "\n")


if __name__ == "__main__":
    main()
