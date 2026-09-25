#!/bin/zsh
# Build an unsigned device IPA from the Xcode project.
# Usage: ./scripts/build-ipa.sh [Debug|Release] [--clean]   (default: Release)
# Output: build/PoC.ipa (unsigned — sideload via AltStore/SideStore/LiveContainer)
#
# --clean wipes build/xderived first.  Reach for it after touching anything
# under Vendor/: an incremental build can refresh a .swiftmodule WITHOUT
# relinking the app, so the build reports success while the IPA still carries
# the previous logic.  The staleness check below catches that either way, which
# is why it looks only at the linked binary and not at the modules.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Release"
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    Debug|Release) CONFIG="$arg" ;;
    --clean)       CLEAN=1 ;;
    *) echo "unknown argument: $arg (expected Debug, Release or --clean)" >&2; exit 2 ;;
  esac
done

DERIVED="$(pwd)/build/xderived"
if (( CLEAN )); then
  echo "cleaning $DERIVED"
  rm -rf "$DERIVED"
fi

xcodebuild -project GoldenNuggetMobile.xcodeproj \
  -scheme PoC \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build

APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphoneos/GoldenNuggetMobile.app"
BINARY="$APP_PATH/GoldenNuggetMobile"
if [ ! -f "$BINARY" ]; then
  echo "error: expected app binary not found at $BINARY" >&2
  exit 1
fi

# Post-build staleness check.  A .swift newer than the linked binary means the
# app was NOT relinked — the exact shape of "build says OK, IPA has old code".
# The scan set is clean: no .swift lives under .build, .swiftpm or patches.
stale="$(find Nugget Vendor -name '*.swift' -newer "$BINARY" -print -quit 2>/dev/null || true)"
if [ -n "$stale" ]; then
  echo "error: $stale is newer than $BINARY" >&2
  echo "       the app binary was not relinked; re-run with --clean" >&2
  exit 1
fi

mkdir -p build
rm -rf build/Payload build/GoldenNugget.ipa
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/GoldenNuggetMobile.app
(cd build && zip -qry GoldenNuggetMobile.ipa Payload && rm -rf Payload)

echo "done: build/GoldenNuggetMobile.ipa (unsigned, ${CONFIG})"
