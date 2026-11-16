#!/usr/bin/env bash
# Gala Engine recipe: build an unsigned Release device IPA of NP Dongle (the band remote dongle's
# app, with its Live Activity extension).
set -euo pipefail

: "${GALA_BUILD_DIR:?Gala build directory is required}"
: "${GALA_ARTIFACT_DIR:?Gala artifact directory is required}"
cd "$(dirname "$0")"
APP=NPDongle

# Keep the generated project in sync with project.yml when XcodeGen is available.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

# Build settings that stay out of git (see .env.example): ./.env, then
# ~/.config/neural-playground/build.env (which also reaches Gala's synced copy, where .env isn't).
SETTINGS=()
for env in .env "$HOME/.config/neural-playground/build.env"; do
  # shellcheck disable=SC1090
  if [ -f "$env" ]; then . "$env"; fi
done
for name in DONGLE_RELEASES_HOST; do
  if [ -n "${!name:-}" ]; then SETTINGS+=("$name=${!name}"); fi
done

DERIVED_DATA="$GALA_BUILD_DIR/DerivedData"
xcodebuild -quiet \
  -project NeuralPlayground.xcodeproj -scheme "$APP" \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" -packageCachePath "$GALA_BUILD_DIR/SwiftPM" \
  CODE_SIGNING_ALLOWED=NO ${SETTINGS[@]+"${SETTINGS[@]}"} build

BUNDLE="$DERIVED_DATA/Build/Products/Release-iphoneos/$APP.app"
test -d "$BUNDLE"
if [ ! -d "$BUNDLE/PlugIns/NPDongleWidgets.appex" ]; then
  echo "NPDongle.app has no PlugIns/NPDongleWidgets.appex (the Live Activities)" >&2; exit 1
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/neuralplayground-gala.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" "$GALA_ARTIFACT_DIR"
ditto "$BUNDLE" "$STAGE/Payload/$APP.app"
IPA="$GALA_ARTIFACT_DIR/$APP.ipa"
rm -f "$IPA"
(cd "$STAGE" && zip -qry "$IPA" Payload)
shasum -a 256 "$IPA"
