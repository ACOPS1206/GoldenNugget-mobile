#!/bin/zsh
# Type-check the PoC sources WITHOUT running xcodebuild.
#
# Why this exists: `xcodebuild` needs to evaluate SwiftPM manifests, which means
# it shells out to `sandbox-exec` and writes ~/.swiftpm.  In a sandboxed
# environment that fails with "sandbox_apply: Operation not permitted", leaving
# no compiler gate at all.  `swiftc -typecheck` needs none of that — it only
# reads the SDK and the already-built .swiftmodule files, so it runs anywhere.
#
# The gate is only as fresh as those .swiftmodule files.  If you changed
# anything under Vendor/, rebuild once with Xcode first, or the check will
# report phantom "has no member" errors for symbols you just added.
#
# Usage: scripts/typecheck.sh [path/to/Products-iphoneos]
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCTS="${1:-}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

# Default to the FRESHEST Products dir.  Debug and Release are built at
# different times, and picking the older one turns API a recent build added into
# phantom "has no member" errors.  Prefer whichever main module is newest.
if [[ -z "$PRODUCTS" ]]; then
  best=""; best_mtime=0
  for candidate in build/xderived/Build/Products/Debug-iphoneos \
                   build/xderived/Build/Products/Release-iphoneos; do
    [[ -d "$candidate" ]] || continue
    mtime="$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    if (( mtime > best_mtime )); then best="$candidate"; best_mtime="$mtime"; fi
  done
  PRODUCTS="$best"
fi

if [[ -z "$PRODUCTS" || ! -d "$PRODUCTS/Minimuxer.swiftmodule" ]]; then
  echo "error: no built Swift modules found (looked in build/xderived/Build/Products/)" >&2
  echo "       build once with Xcode so the vendored modules exist, or pass the" >&2
  echo "       path to a Products-iphoneos directory as \$1." >&2
  exit 2
fi
echo "modules: $PRODUCTS"

# Source list comes from Package.swift so it cannot drift from the real target.
python3 - > /tmp/typecheck-sources.txt <<'PY'
import re, pathlib
src = pathlib.Path("Package.swift").read_text()
for p in sorted(set(re.findall(r'"([^"]+\.swift)"', src))):
    print(p)
PY

echo "type-checking $(wc -l < /tmp/typecheck-sources.txt) sources against $SDK"

# Staleness guard.  The gate reads the .swiftmodule files, not the vendored
# sources, so a Vendor/ edit that has not been rebuilt shows up as a phantom
# "has no member" / "extra argument" error on a perfectly good call site.
stale="$(find Vendor -name '*.swift' -newer "$PRODUCTS/Minimuxer.swiftmodule" -print -quit 2>/dev/null || true)"
if [[ -n "$stale" ]]; then
  echo "WARNING: $stale is newer than the modules in $PRODUCTS." >&2
  echo "         Errors naming a vendor symbol are PHANTOM until you rebuild with" >&2
  echo "         Xcode; errors in Nugget/ are real either way." >&2
fi

xargs < /tmp/typecheck-sources.txt xcrun swiftc -typecheck \
  -disable-sandbox \
  -sdk "$SDK" \
  -target arm64-apple-ios16.0 \
  -swift-version 5 \
  -I "$PRODUCTS" \
  -I Vendor/IDevice.xcframework/ios-arm64/Headers \
  -I Vendor/EMProxy.xcframework/ios-arm64/Headers \
  -I Vendor/libimobiledevice.xcframework/ios-arm64/Headers \
  > /tmp/typecheck.log 2>&1 || true

# `-disable-sandbox` is load-bearing: without it the driver sandboxes
# swift-plugin-server, which cannot run nested, so every SwiftUI `@State` macro
# fails to expand and the run reports ~80 phantom errors cascading out of
# PoCView.swift ("cannot find '$bundleID' in scope", "cannot assign to property:
# 'logs' is immutable").  Journal only the line count, never `| head` — closing
# the pipe early SIGPIPEs the compiler and leaves a truncated log that reads as
# a clean pass.

# `grep -c` exits 1 on zero matches, hence the `|| true` guards.
errors=$(grep -c 'error:' /tmp/typecheck.log || true)
warnings=$(grep -c 'warning:' /tmp/typecheck.log || true)
own=$(grep -cE '^Nugget/(Core|Views|AppPackage|Tunnel|NuggetApp)[^:]*:.*(warning|error):' /tmp/typecheck.log || true)
echo "=== $errors error(s), $warnings warning(s) ($own in Nugget/ app code) ==="
exit "$errors"

