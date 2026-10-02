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
#
# Two icon paths:
#   * When Apple's actool has written a car back into the tree
#     (.github/workflows/assets-car.yml), that car is authoritative and is
#     copied through unchanged.  It carries the Icon Composer iconstack
#     (part 245/246) and the tintable appearance CoreUI can only make on
#     macOS.
#   * Otherwise the shim compiles the catalog itself.  It now understands an
#     Icon Composer `.icon` primary: it expands the bundle's base and dark
#     artwork into a classic `.appiconset` (part 220) with both appearances and
#     resamples each slot, so the app still ships a correctly named `AppIcon`
#     with a dark variant.  Set ASSETKIT_SHIM_FORCE=1 to take this path even
#     when an actool car is committed -- useful for testing the Linux path
#     without wiping the authoritative car.
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

ACTOOL_CAR="$ROOT/layout/Applications/GoldenNuggetMobile.app/Assets.car"
FORCE_SHIM="${ASSETKIT_SHIM_FORCE:-0}"

if [[ -s "$ACTOOL_CAR" && "$FORCE_SHIM" != "1" ]]; then
    # Authoritative path.  The car comes from Apple's own actool via
    # .github/workflows/assets-car.yml.
    echo "compile-assets: using the actool car ($(stat -c%s "$ACTOOL_CAR") bytes)"
    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp "$ACTOOL_CAR" "$OUT/Assets.car"
    cp "$ROOT/layout/Applications/GoldenNuggetMobile.app/AppIcon-partial.plist" \
       "$OUT/AppIcon-partial.plist" 2>/dev/null || true
    echo "compile-assets: wrote $(ls -1 "$OUT" | wc -l) files to build/assets"
    exit 0
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
