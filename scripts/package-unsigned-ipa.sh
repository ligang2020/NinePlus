#!/usr/bin/env bash
# Build a device Release app without signing and wrap it as an unsigned IPA.
# The same script is used locally and by GitHub Actions.
set -euo pipefail

PROJECT="mini-ninebot/mini-ninebot.xcodeproj"
SCHEME="mini-ninebot"
CONFIGURATION="Release"
OUTPUT_DIR="${PWD}/build/ipa"
DERIVED_DATA="${PWD}/build/DerivedData"

usage() {
  cat <<'USAGE'
Usage: scripts/package-unsigned-ipa.sh [--output <directory>] [--derived-data <directory>]

Builds the iPhoneOS Release app with signing disabled, packages a versioned
unsigned IPA, writes a SHA-256 checksum, and prints the IPA path.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a directory" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --derived-data)
      [[ $# -ge 2 ]] || { echo "--derived-data requires a directory" >&2; exit 2; }
      DERIVED_DATA="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$OUTPUT_DIR" "$DERIVED_DATA"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  NINEPLUS_APP_ACCESS_TOKEN="${NINEPLUS_APP_ACCESS_TOKEN:-}" \
  -quiet \
  build >&2

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
test -d "$APP_PATH"
test -d "$APP_PATH/PlugIns/NinebotWidgets.appex"
test -f "$APP_PATH/Assets.car"
plutil -lint "$APP_PATH/Info.plist" >&2

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
IPA_BASENAME="NinePlus-LiveRide-v${VERSION}-unsigned.ipa"
IPA_PATH="$OUTPUT_DIR/$IPA_BASENAME"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nineplus-ipa.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Payload"
ditto "$APP_PATH" "$WORK_DIR/Payload/${SCHEME}.app"
(
  cd "$WORK_DIR"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$IPA_PATH")" > "$(basename "$IPA_PATH").sha256"
)
printf '%s\n' "$IPA_PATH"
