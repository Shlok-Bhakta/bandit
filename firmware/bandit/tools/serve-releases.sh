#!/usr/bin/env bash
# Serves dongle releases (firmware/dist) to your tailnet for the app's "Check for update":
# a localhost-only file server under launchd, proxied by Tailscale at https://<this mac>.ts.net/dongle/.
# (Tailscale's sandboxed app can't read every volume itself, hence the proxy.)
# Usage: serve-releases.sh install | status | uninstall
set -euo pipefail
cd "$(dirname "$0")/../.."
DIST="$PWD/dist"
LABEL=io.github.shlok-bhakta.bandit-releases
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${RELEASES_PORT:-8796}"
PYTHON="${PYTHON:-$(command -v python3)}"
TAILSCALE="${TAILSCALE:-$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)}"

case "${1:-status}" in
  install)
    mkdir -p "$DIST" "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string><string>-m</string><string>http.server</string><string>$PORT</string>
    <string>--bind</string><string>127.0.0.1</string>
    <string>--directory</string><string>$DIST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/dongle-releases.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    "$TAILSCALE" serve --bg --set-path /dongle "http://127.0.0.1:$PORT"
    echo "Serving $DIST at https://<this mac>.ts.net/dongle/ (tailnet only)."
    echo "Put that host in ~/.config/bandit/build.env as DONGLE_RELEASES_HOST=… and rebuild the app."
    ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|pid" || echo "file server: not installed"
    "$TAILSCALE" serve status 2>/dev/null | grep -E "ts.net|/dongle" || echo "tailscale: not serving /dongle"
    if [ -f "$DIST/latest.json" ]; then echo "published: $(cat "$DIST/latest.json")"; else echo "published: nothing (make release)"; fi
    ;;
  uninstall)
    "$TAILSCALE" serve --set-path /dongle off 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    ;;
  *) echo "usage: $0 install | status | uninstall" >&2; exit 2 ;;
esac
