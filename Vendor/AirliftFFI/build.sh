#!/bin/bash
# Build AirliftFFI's static archive for iOS on this Linux host, and install it
# into the xcframework as the dedupe script's pristine input.
#
# AirCard-iOS has its own build-ios.sh, but it assumes macOS: it shells out to
# xcodebuild -create-xcframework and lets the Rust build find the SDK through
# xcrun. Here the SDK comes from xtool's artifact bundle, and there is no
# xcodebuild, so the packaging step is just a file copy — the xcframework layout
# is one arm64 library and its headers, and nothing about it needs rebuilding.
#
# After this, run:  python3 scripts/dedupe-airlift-archive.py
# which rewrites libairlift_ffi.a from the .pristine this script writes, and
# rebuild the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"

export PATH="$HOME/.cargo/bin:/home/awesomenull/.local/share/swiftly/bin:$PATH"

# The iOS SDK that xtool installed. It is the only thing here that needs an
# absolute path: cc-rs would otherwise look for it via xcrun, which does not
# exist on this host.
SDKROOT="${SDKROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk}"
if [ ! -d "$SDKROOT" ]; then
  echo "no iOS SDK at $SDKROOT" >&2
  echo "install it with: xtool sdk install" >&2
  exit 1
fi
export SDKROOT

# cc-rs passes --target/--sysroot itself once SDKROOT is set, so the *_CFLAGS
# variables that a plain cross-build wants are not just unnecessary here, they
# conflict: -mmacosx-version-min is rejected against -miphoneos-version-min.
export CC_aarch64_apple_ios=clang
export AR_aarch64_apple_ios=llvm-ar
export IPHONEOS_DEPLOYMENT_TARGET=18.0

# No CARGO_TARGET_*_LINKER: the vendored plist_ffi builds no dylib (see its
# Cargo.toml), so nothing here needs a Mach-O linker, which open-source lld
# cannot provide for iOS anyway. A staticlib is only archived with `ar`.

echo "==> Adding the iOS Rust target"
rustup target add aarch64-apple-ios

cd "$ROOT/rust-core"
echo "==> Building libairlift_ffi.a for aarch64-apple-ios"
cargo build --release --target aarch64-apple-ios

BUILT="$ROOT/rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a"
DEST="$REPO/Vendor/AirliftFFI.xcframework/ios-arm64"
echo "==> Installing into $DEST"
cp "$ROOT/rust-core/include/airlift.h" "$DEST/Headers/AirliftFFI/airlift.h"
cp "$BUILT" "$DEST/libairlift_ffi.a.pristine"

echo "==> Done. Now run: python3 scripts/dedupe-airlift-archive.py"
