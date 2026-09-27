#!/usr/bin/env bash
#
# Rebuild AirliftFFI's iOS static library.
#
#   Vendor/AirliftFFI/rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a
#       the artifact
#   Vendor/AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a
#       what the app links (the de-duplicated copy, via scripts/dedupe-airlift-archive.py)
#
# Why this script exists rather than a `cargo build` in your terminal:
#
#   * The crate is a `staticlib` for iOS, so `cargo build` alone fails on Linux
#     and on macOS-without-CLI-tools: `cc-rs` shells out to **`xcrun`** to find
#     the iPhoneOS SDK, and there is no `xcrun` in either case. The fix is to
#     hand `cc-rs` what it was going to ask `xcrun` for:
#
#       SDKROOT                       the SDK path
#       CC_aarch64_apple_ios         a clang that understands the Mach-O target
#       CFLAGS_aarch64_apple_ios     --target + -isysroot, so no `xcrun` lookup
#       AR_aarch64_apple_ios         ar, which is not BSD-format on Linux
#
#     The SDK comes from the Darwin Swift SDK that `xtool sdk install` puts in
#     place — the same one the app itself is built against, so the two cannot
#     drift to different iOS versions. The deployment target is read from
#     Package.swift rather than hardcoded, for the same reason.
#
#   * The archive must be de-duplicated against `libidevice_ffi.a` before the app
#     will link, and the de-duplication has to be re-run on every rebuild —
#     1680 symbols are defined by both archives and ld will not take them.
#     `--install` does both steps; building alone leaves the working copy stale,
#     which is the quiet way to ship a fix that never made it into the app.
#
# Usage:
#   scripts/build-airlift-ffi-ios.sh            # build only; print where the .a is
#   scripts/build-airlift-ffi-ios.sh --install  # build, swap into Vendor, de-duplicate
#   scripts/build-airlift-ffi-ios.sh --check    # verify the installed copy is the current build

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$REPO/Vendor/AirliftFFI/rust-core"
XCF="$REPO/Vendor/AirliftFFI.xcframework/ios-arm64"
TARGET="aarch64-apple-ios"
DEPLOYMENT_TARGET="$(sed -n 's/.*\.iOS("\([0-9.]*\)").*/\1/p' "$REPO/Package.swift" | head -1)"

INSTALL=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --check)   CHECK=1 ;;
    *) echo "usage: $0 [--install|--check]" >&2; exit 2 ;;
  esac
done

artifact() { echo "$CORE/target/$TARGET/release/libairlift_ffi.a"; }

# ---------------------------------------------------------------------------
# --check: is the archive the app links the one that was built from this source?
# ---------------------------------------------------------------------------

if [[ $CHECK -eq 1 ]]; then
  # The content check lives in its own script: proving that the archive the app
  # links came from *this* build is a matter of member bytes, not of the `al_*`
  # export set, and the export set is identical for a stale archive and a
  # current one — so a check written against symbols reports "matches" for both.
  if [[ ! -f "$(artifact)" ]]; then
    echo "error: nothing built; run without --check first" >&2
    exit 1
  fi
  exec python3 "$REPO/scripts/check-airlift-install.py"
fi

# ---------------------------------------------------------------------------
# 1. The SDK cc-rs would have asked xcrun for
# ---------------------------------------------------------------------------

[[ -n "$DEPLOYMENT_TARGET" ]] \
  || { echo "error: could not read the deployment target from Package.swift" >&2; exit 1; }

if ! command -v xcrun >/dev/null 2>&1; then
  SDK_ROOT="$(xtool sdk status 2>/dev/null | sed -n 's/^  Path: //p' | head -1)"
  if [[ -z "$SDK_ROOT" || ! -d "$SDK_ROOT" ]]; then
    echo "error: no xcrun, and xtool's Darwin SDK is not installed." >&2
    echo "       xtool sdk install, then re-run." >&2
    exit 1
  fi
  SDK="$SDK_ROOT/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
  [[ -d "$SDK" ]] || { echo "error: no iPhoneOS.sdk inside $SDK_ROOT" >&2; exit 1; }

  # The SDK ships as `iPhoneOS.sdk` pointing at a versioned directory; resolve it
  # so the compiler gets a real path and the log line below names a version.
  if [[ -L "$SDK" ]]; then
    SDK="$(readlink -f "$SDK")"
  fi

  CC_FOR_TARGET="$(command -v clang)"
  AR_FOR_TARGET="$(command -v ar)"
  export SDKROOT="$SDK"
  export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  export CC_aarch64_apple_ios="$CC_FOR_TARGET"
  export CFLAGS_aarch64_apple_ios="--target=arm64-apple-ios$DEPLOYMENT_TARGET -isysroot $SDK"
  export AR_aarch64_apple_ios="$AR_FOR_TARGET"
  echo "==> no xcrun; cross-building against $(basename "$SDK") from the xtool Darwin SDK"
  echo "==> clang: $($CC_FOR_TARGET --version | head -1)"
else
  echo "==> xcrun present; letting cc-rs find the SDK itself"
  export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
fi

# ---------------------------------------------------------------------------
# 2. Build
# ---------------------------------------------------------------------------

echo "==> $(cargo --version), target $TARGET (iOS $DEPLOYMENT_TARGET)"
cd "$CORE"
cargo build --release --target "$TARGET"

BUILT="$(artifact)"
[[ -f "$BUILT" ]] || { echo "error: cargo finished but there is no $BUILT" >&2; exit 1; }
echo "==> built $BUILT ($(du -h "$BUILT" | cut -f1))"

# ---------------------------------------------------------------------------
# 3. Install + de-duplicate
# ---------------------------------------------------------------------------

if [[ $INSTALL -eq 0 ]]; then
  echo "==> not installed; pass --install to swap it into Vendor/ and de-duplicate"
  exit 0
fi

if [[ ! -f "$XCF/libairlift_ffi.a" ]]; then
  echo "error: no existing archive at ${XCF#"$REPO"/} to back up" >&2
  exit 1
fi
BACKUP="$(mktemp -d)/libairlift_ffi.a"
cp "$XCF/libairlift_ffi.a" "$BACKUP"
cp "$BUILT" "$XCF/libairlift_ffi.a.pristine"
cp "$BUILT" "$XCF/libairlift_ffi.a"
echo "==> previous working copy backed up to $BACKUP"

python3 "$REPO/scripts/dedupe-airlift-archive.py"

echo "==> installed: $XCF/libairlift_ffi.a ($(du -h "$XCF/libairlift_ffi.a" | cut -f1))"
echo "==> run scripts/check-linked-symbols.py, then xtool dev"
