#!/usr/bin/env bash
# Checks the filter that decides what `build_folder_archive` puts in an injected
# folder: junk is dropped, payload is not.
#
#   scripts/zip-junk-check.sh
#
# The predicate is lifted out of the shipping source rather than restated here,
# so this cannot pass against a copy that has since drifted: if
# `is_zip_junk` is renamed, moved, or its body edited, either the extraction
# finds nothing and the build fails, or the extracted body is what gets tested.
# `cargo test` is not an option here — the crate only builds for
# `aarch64-apple-ios` (see `rustup target list --installed`), and a test module
# inside the crate would never run.
#
# What it pins, in order of how much it mattered:
#
#   * `.com.apple.posterkit.provider.contents.configurableOptions.plist` is
#     KEPT. It is the one dot-prefixed file a PosterKit descriptor carries, and
#     it is the only spelling it ever uses. Dropping it injected a wallpaper
#     with default presentation and no dark-aware title colour, silently.
#   * `__MACOSX`, `.DS_Store` and AppleDouble `._*` are dropped, which is the
#     whole reason the old `starts_with('.')` rule existed.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo/Vendor/AirliftFFI/rust-core/src/exploit.rs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The predicate and nothing else: from `fn is_zip_junk` to the line before the
# next top-level `fn`.
if ! awk '/^fn is_zip_junk\(/,/^}$/' "$source_file" > "$work/junk.rs"; then
  echo "  ✗ could not extract is_zip_junk from ${source_file#"$repo"/}" >&2
  exit 1
fi
if ! grep -q 'fn is_zip_junk' "$work/junk.rs"; then
  echo "  ✗ is_zip_junk not found in exploit.rs — rename it and this check" >&2
  exit 1
fi

cat > "$work/main.rs" <<'RUST'
include!("junk.rs");

fn main() {
    let mut failures = 0;
    let kept: &[&str] = &[
        ".com.apple.posterkit.provider.contents.configurableOptions.plist",
        "providerInfo.plist",
        "com.apple.posterkit.provider.contents.userInfo",
        "com.apple.posterkit.provider.descriptor.identifier",
    ];
    let dropped: &[&str] = &["__MACOSX", ".DS_Store", "._providerInfo.plist", "__MACOSX/x.plist"];

    for name in kept {
        if is_zip_junk(name) {
            println!("  ✗ dropped payload: {name}");
            failures += 1;
        } else {
            println!("  ✓ kept {name}");
        }
    }
    for name in dropped {
        if is_zip_junk(name) {
            println!("  ✓ dropped {name}");
        } else {
            println!("  ✗ kept junk: {name}");
            failures += 1;
        }
    }
    std::process::exit(if failures == 0 { 0 } else { 1 });
}
RUST

rustc -O -o "$work/check" "$work/main.rs" 2>/dev/null
if ! "$work/check"; then
  echo "zip-junk check FAILED" >&2
  exit 1
fi
echo "zip-junk check passed"
