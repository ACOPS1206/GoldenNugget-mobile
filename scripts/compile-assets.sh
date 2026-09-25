#!/usr/bin/env bash
# Compile Assets.xcassets into Assets.car + loose icon PNGs, on Linux.
#
# Why this is a separate step instead of letting xtool drive actool:
# xtool copies actool out of the darwin SDK into xtool/.xtool-tmp/actool and
# execs it.  The copy does not keep the executable bit -- the SDK's actool is
# 0755 and the copy lands 0664 -- so the launch dies with "is not an
# executable file" before any argument parsing happens.  There is no hook
# between the copy and the exec, and xtool execs an absolute path, so PATH
# does not help either.  The SDK actool is arm64 Mach-O anyway, which this
# x86_64 host cannot execute even with the bit restored.
#
# So: this script runs the AssetKit-backed actool shim over the catalog and
# leaves the results in build/assets/, and xtool.yml ships them as ordinary
# resources.  A build is then plain `xtool dev build` plus this step first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/layout/Applications/GoldenNuggetMobile.app/Assets.xcassets"
OUT="$ROOT/build/assets"
SHIM="$ROOT/tools/assetkit-cli/.build/release/assetkit-cli"

# Keep in sync with project.yml / pbxproj / xtool.yml deploymentTarget.
DEPLOYMENT_TARGET="26.0"

if [[ ! -d "$CATALOG" ]]; then
    echo "compile-assets: no catalog at $CATALOG" >&2
    exit 1
fi

echo "compile-assets: building the shim"
(cd "$ROOT/tools/assetkit-cli" && swift build -c release)

rm -rf "$OUT"
mkdir -p "$OUT"

ASSETKIT_SHIM_LOG=/dev/null "$SHIM" \
    --compile "$OUT" \
    --app-icon AppIcon \
    --minimum-deployment-target "$DEPLOYMENT_TARGET" \
    --platform iphoneos \
    --output-partial-info-plist "$OUT/AppIcon-partial.plist" \
    "$CATALOG"

# Prefer a car compiled by Apple's own actool, when one has been fetched from
# the Assets.car workflow (.github/workflows/assets-car.yml writes it next to
# the catalog).  The shim is a clean-room writer: it matches actool's rendition
# key layout, but its BITMAPKEYS descriptor is a guess, and a catalog with a
# wrong descriptor is rejected by CoreUI -- the app then has no icon at all.
# actool's output is authoritative, so it always wins; the shim is only the
# offline fallback, and it stays on for the loose PNGs, which the shim is the
# only thing here that emits.
ACTOOL_CAR="$ROOT/layout/Applications/GoldenNuggetMobile.app/Assets.car"
if [[ -s "$ACTOOL_CAR" ]]; then
    echo "compile-assets: using actool car ($(stat -c%s "$ACTOOL_CAR") bytes)"
    cp "$ACTOOL_CAR" "$OUT/Assets.car"
fi

# Report what the catalog actually produced, so a dropped appearance is visible
# in the build log instead of only in the IPA.
ASSETKIT_SHIM_LOG=/dev/null "$SHIM" \
    --compile "$OUT" \
    --app-icon AppIcon \
    --minimum-deployment-target "$DEPLOYMENT_TARGET" \
    --platform iphoneos \
    --dump-renditions "$CATALOG" \
    | awk -F'\t' '{print $4}' | sort | uniq -c

echo "compile-assets: wrote $(ls -1 "$OUT" | wc -l) files to build/assets"
