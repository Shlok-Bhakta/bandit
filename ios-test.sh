#!/usr/bin/env bash
# Gala Engine gate: the NeuralBandKit tests (the dongle's control protocol, profiles, merge). They
# run on macOS, so no simulator is needed.
set -euo pipefail

: "${GALA_BUILD_DIR:?Gala build directory is required}"
cd "$(dirname "$0")/NeuralBandKit"
swift test --scratch-path "$GALA_BUILD_DIR/SwiftPMTests" 2>&1 | tail -40
