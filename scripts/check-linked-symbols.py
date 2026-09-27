#!/usr/bin/env python3
"""Check that every C symbol the gateway's Swift refers to is in the archive that
actually gets linked.

Why this exists: `plist_new_date` is declared in the vendored `plist.h`, so calling it
compiles cleanly — and then the build dies at the link step:

    Undefined symbols for architecture arm64:
      "_plist_new_date", referenced from:
        IdeviceGateway.(plistNode in _…)(from: Any) -> UnsafeMutableRawPointer? in IdeviceGateway.o

The header is not the contract; the *linked archive* is. Two archives in this tree carry
a libplist, and their export sets differ:

    Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a   ← linked (`-lidevice_ffi`)
    Vendor/libimobiledevice.xcframework/ios-arm64/libimobiledevice.a   ← not linked

`libidevice_ffi.a` has no `plist_new_date`, no `plist_copy`, no `plist_to_bin`, no
`plist_from_bin`; `libimobiledevice.a` has all four. So "it is in plist.h" and even "it
is in a library we vendor" are both insufficient — the symbol has to be in the one the
link line names.

Neither a type check nor a compile can see this: it is a link-time property. This script
is the cheap offline stand-in for the link step, over the two files that call into the C
API directly.

Usage:
    scripts/check-linked-symbols.py                 # report and exit 1 on a missing symbol
    scripts/check-linked-symbols.py --linked <archive> [--linked <archive> ...]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The Swift files that call the C libraries directly.
SOURCES = [
    "Vendor/MinimuxerGateway/idevice/IdeviceGateway.swift",
    "Vendor/MinimuxerGateway/idevice/MobileBackup2Delegate.swift",
]

# The archives the app target actually links.  `-lidevice_ffi` in the Xcode link line,
# and `-lsqlite3` (the SDK's own tbd), which the app declares in project.yml.
DEFAULT_ARCHIVES = [
    "Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a",
]

# Prefixes of the C APIs these files use.  `plist_new_date(` in a *comment* is fine —
# only call sites count.
PREFIXES = ("plist_", "installation_proxy_", "idevice_")

# The tail has to be inside *each* alternative.  Written as
# `\b(plist_|idevice_)[a-z0-9_]+\s*\(` it reads as "`plist_` alone, or `idevice_`
# followed by a name", so no `plist_*` call ever matches — and a gate that never sees
# the symbols it was written for reports a clean pass.  (Caught by running it the other
# way round: a probe calling a symbol the archive does not export must FAIL this check,
# and the first version passed it.)
CALL = re.compile(r"\b((?:" + "|".join(PREFIXES) + r")[a-z0-9_]+)\s*\(")


def strip_comments(text: str) -> str:
    """Drop `//` and `///` lines, so a symbol named in a note is not read as a call."""
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("//"))


def exported(archive: Path) -> set[str]:
    """Defined (T) symbols of an archive, with the leading underscore.

    `nm`'s **exit code is deliberately ignored**: `libidevice_ffi.a` is full of
    Rust-produced objects carrying a newer LLVM attribute kind than Apple's `nm`
    understands, so it exits non-zero while still listing every readable symbol —
    including the C ones this script is about. Bailing on that code would make the
    gate useless on the one archive that matters. What is checked instead is that
    the output yielded symbols at all; a genuinely unreadable archive then fails
    loudly rather than passing by default.
    """
    result = subprocess.run(["nm", "-gU", str(archive)], capture_output=True, text=True)
    symbols = {m.group(1) for m in re.finditer(r"^\S+ T (_[A-Za-z0-9_]+)$", result.stdout, re.M)}
    if not symbols:
        sys.exit(f"check-linked-symbols: nm produced no symbols for {archive} "
                 f"(exit {result.returncode}); the check would be vacuous")
    return symbols


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--linked", action="append", default=None,
                        help="archive that gets linked (repeatable); defaults to libidevice_ffi.a")
    parser.add_argument("--sources", nargs="*", default=SOURCES)
    args = parser.parse_args()

    archives = [Path(ROOT / a) if not Path(a).is_absolute() else Path(a)
                for a in (args.linked or DEFAULT_ARCHIVES)]
    for archive in archives:
        if not archive.is_file():
            sys.exit(f"check-linked-symbols: no archive at {archive}")

    symbols: set[str] = set()
    for archive in archives:
        symbols |= exported(archive)

    referenced: dict[str, list[str]] = {}
    for name in args.sources:
        path = Path(name) if Path(name).is_absolute() else ROOT / name
        if not path.is_file():
            sys.exit(f"check-linked-symbols: no source at {path}")
        for line_no, line in enumerate(strip_comments(path.read_text(encoding="utf-8")).splitlines(), 1):
            for call in CALL.findall(line):
                referenced.setdefault(call, []).append(f"{name}:{line_no}")

    missing = {c: where for c, where in referenced.items() if "_" + c not in symbols}

    print(f"linked: {', '.join(a.name for a in archives)}")
    print(f"referenced C symbols: {len(referenced)}")
    if not missing:
        print(f"OK — every one of them is defined in {'these archives' if len(archives) > 1 else 'the archive'}")
        return 0

    print(f"MISSING {len(missing)} symbol(s) — this is a LINK failure, not a compile one:",
          file=sys.stderr)
    for call in sorted(missing):
        print(f"  ✗ {call}  (called from {', '.join(missing[call][:3])})", file=sys.stderr)
    print("\nA symbol being in the vendored header, or in an archive this project vendors "
          "but does not link, is not enough — see this script's header.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
