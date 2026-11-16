#!/usr/bin/env bash
# Builds the dongle firmware, signs it into an update package, and publishes it (with a Chrome
# flasher page) to ../dist, which Tailscale serves at https://<this mac>.ts.net/dongle/ for the
# app's "Check for update". Usage: ./release.sh "what changed"
set -euo pipefail
cd "$(dirname "$0")"

# Run through `make release` (it sets the toolchain paths from config.mk or espup's defaults).
: "${CARGO_HOME:?run this through make release}" "${EXPORT_ESP:?run this through make release}" "${HOST_TARGET:?run this through make release}"
PATH=$CARGO_HOME/bin:$PATH
. "$EXPORT_ESP"

ELF=target/xtensa-esp32s3-espidf/release/bandit
# With BUILD_HOST, make has built on the other machine and passes its bootloader in BOOTLOADER.
if [ -z "${BOOTLOADER:-}" ]; then
  cargo build --release
  BOOTLOADER=$(ls -td target/xtensa-esp32s3-espidf/release/build/esp-idf-sys-*/out | head -1)/build/bootloader/bootloader.bin
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bandit-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

espflash save-image --chip esp32s3 --flash-size 8mb --flash-freq 80mhz "$ELF" "$WORK/app.bin"
espflash partition-table --to-binary -o "$WORK/partitions.bin" partitions.csv

# Only the newest release stays published.
mkdir -p ../dist
find ../dist -maxdepth 1 -type f \( -name '*.banditfw' -o -name '*-flasher.html' -o -name latest.json \) -delete

PACK=../dongle-pack
# Built from its own directory, so this crate's ESP cross-compile config doesn't apply.
(cd "$PACK" && CARGO_TARGET_DIR="$HOST_TARGET" cargo +stable build --release -q)
"$HOST_TARGET/release/dongle-pack" pack "$WORK/app.bin" ../dist \
  --notes "${1:-}" \
  --version "$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)" \
  --bootloader "$BOOTLOADER" \
  --partitions "$WORK/partitions.bin" \
  --esptool "$PACK/vendor/esptool-js-0.7.1.bundle.js"
