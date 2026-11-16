#!/bin/sh
# Once, as root (sudo sh ~/bandit/setup-access.sh): lets the plugdev group (you) open the
# dongle's USB serial port (an ESP32-S3, USB vendor 303a), and keeps ModemManager from probing it
# (its AT commands would reset the dongle).
set -e
cat > /etc/udev/rules.d/60-bandit.rules <<'RULES'
# Bandit dongle (ESP32-S3 USB serial/JTAG): plugdev may use it; ModemManager leaves it be.
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", MODE="0660", GROUP="plugdev", ENV{ID_MM_DEVICE_IGNORE}="1"
RULES
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty
echo "Done: plug the dongle in (or replug it) and it's yours."
