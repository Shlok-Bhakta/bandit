#!/usr/bin/env bash
# Builds band-probe and runs it inside a minimal .app bundle, so macOS grants it Bluetooth
# (a bare CLI inherits the parent app's privacy context and is killed without a usage string).
# Usage: Scripts/run-probe.sh <claim-probe|legacy|scan> [seconds] [log file]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product band-probe -c debug >/dev/null
BIN="$(swift build --product band-probe -c debug --show-bin-path)/band-probe"
APP="${TMPDIR:-/tmp}/BandProbe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/band-probe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.neuralplayground.bandprobe</string>
<key>CFBundleName</key><string>BandProbe</string>
<key>CFBundleExecutable</key><string>band-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>BandProbe talks to your Meta Neural Band to test the protocol.</string>
</dict></plist>
PLIST
# A stable signing identity keeps macOS's Bluetooth permission across rebuilds (ad-hoc signatures
# look like a new app every time). Falls back to ad-hoc when no Apple Development identity exists.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1
LOG="${3:-${TMPDIR:-/tmp}/band-probe.log}"
: > "$LOG"
ENV_ARGS=()
[ -n "${NP_EMG:-}" ] && ENV_ARGS+=(--env "NP_EMG=$NP_EMG")
[ -n "${NP_OWNER_FILE:-}" ] && ENV_ARGS+=(--env "NP_OWNER_FILE=$NP_OWNER_FILE")
open -W -n ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} --stdout "$LOG" --stderr "$LOG" "$APP" --args "${1:-claim-probe}" "${2:-75}"
cat "$LOG"
