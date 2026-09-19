#!/bin/sh
#
# Patches the vendored idevice FFI so Backup/Restore send `TargetIdentifier`.
#
# WHY THIS EXISTS
# ---------------
# The device refuses (and then wedges) its mobilebackup2 daemon when the
# `Backup` request carries no `TargetIdentifier`.  Every reference client sends
# it -- libimobiledevice makes the argument non-optional
# (`mobilebackup2_send_request(..., target_identifier, ...)`) and
# pymobiledevice3 sends `{"MessageName": "Backup", "TargetIdentifier": <udid>}`.
#
# The vendored library cannot: its `Idevice` handle only learns its UDID on the
# usbmuxd/lockdown connect path (`idevice/src/lib.rs`: `lockdown.get_value
# ("UniqueDeviceID")` -> `set_udid`).  This PoC connects over RSD, which never
# runs that code, so `self.idevice.udid()` is `None`, and `send_request` builds
# its dictionary with an optional-include macro:
#
#     "TargetIdentifier":? target_identifier,   // None -> key omitted entirely
#     "SourceIdentifier":? source_identifier,   // our UDID ends up here instead
#
# Result on the wire: `{MessageName: Backup, SourceIdentifier: <udid>, ...}` --
# a request no other client would ever send.  The device answers the Hello /
# version exchange, then closes the flow without a response, which jktcp reports
# as `Socket(Custom { kind: BrokenPipe, error: "channel closed" })`.
#
# There is no FFI escape hatch: `mobilebackup2_backup` has no target-identifier
# parameter, `idevice_tcp_provider_new` takes no UDID, and no `idevice_set_udid`
# is exported.  So the fix is made at the binary level.
#
# HOW IT WORKS
# ------------
# "SourceIdentifier" and "TargetIdentifier" are both exactly 16 bytes, and Rust
# `&str` literals are addressed by (pointer, length) rather than NUL-terminated,
# so an equal-length in-place substitution changes which key is emitted without
# shifting a single offset.  All three occurrences (one per codegen unit that
# inlined `send_request`) are replaced, so the source slot now emits
# `TargetIdentifier`.
#
#   before:  {MessageName: Backup, SourceIdentifier: <udid>, Options: {}}  -> device wedges
#   after:   {MessageName: Backup, TargetIdentifier: <udid>, Options: {}}  -> matches pymobiledevice3
#
# CAVEAT
# ------
# `send_request` serves Backup AND Restore, so Restore also emits
# `TargetIdentifier` where it used to emit `SourceIdentifier`.  In this PoC the
# two are the same device UDID, but a real Restore wants both keys.  This is a
# hypothesis test, not the final fix -- the real fix is a rebuilt Rust lib with
# `let target = self.idevice.udid().or(Some(source))` in `backup_from_path`
# (reachable now that scripts/build-idevice-ios.sh can rebuild the archive).
# Revert with `--revert` once that lands.
#
# `libidevice_ffi.a.orig` is the pristine shipped binary and is git-tracked; it
# is NOT the revert target.  --revert restores $BAK, the archive as it was
# immediately before this script patched it (which may already carry other
# patches, e.g. the jktcp rebuild).
#
# SUPERSEDED 2026-09-19 -- do not run this against a rebuilt archive.
#
# Vendor/patches/idevice-ffi/factory_info.patch fixes it at the source:
# `send_request` in idevice/src/services/mobilebackup2.rs now sends
# `target_identifier.or(source_identifier)`, so Backup and Restore both carry
# TargetIdentifier *and* keep SourceIdentifier. Re-running the byte substitution
# on such an archive would rename the SourceIdentifier literal too, leaving the
# request with two TargetIdentifiers and no SourceIdentifier.
#
# Bare invocation now refuses; --force is there for a binary that genuinely
# still needs it. --revert is unaffected (it just restores $BAK).
#
# usage: scripts/patch-idevice-target-identifier.sh [--revert|--force]
#
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a"
BAK="$ROOT/Vendor/patches/libidevice_ffi.a.pre-targetid"

FROM='SourceIdentifier'
TO='TargetIdentifier'

[ -f "$LIB" ] || { echo "error: $LIB not found" >&2; exit 1; }

count() {
    # -a so the binary is treated as text; -o prints each hit on its own line.
    grep -ao "$1" "$2" | wc -l | tr -d ' '
}

revert() {
    [ -f "$BAK" ] || { echo "error: no backup at $BAK -- nothing to revert to" >&2; exit 1; }
    cp "$BAK" "$LIB"
    echo "reverted: $(basename "$LIB") restored from $BAK"
    echo "  $FROM=$(count "$FROM" "$LIB")  $TO=$(count "$TO" "$LIB")"
}

case "${1:-}" in
    --revert|-r) revert; exit 0 ;;
    --force) ;;
    '')
        echo "error: superseded by Vendor/patches/idevice-ffi/factory_info.patch" >&2
        echo "  the rebuilt archive sends TargetIdentifier from Rust; see the" >&2
        echo "  SUPERSEDED note in $0. Use --force only for an archive that" >&2
        echo "  really still lacks it." >&2
        exit 1
        ;;
    *) echo "usage: $0 [--revert|--force]" >&2; exit 2 ;;
esac

# Keep whatever the archive looked like right before this patch, so --revert
# undoes this patch and nothing else.
if [ ! -f "$BAK" ]; then
    mkdir -p "$(dirname "$BAK")"
    cp "$LIB" "$BAK"
    echo "backed up -> $BAK"
fi

size_before=$(wc -c < "$LIB" | tr -d ' ')
from_before=$(count "$FROM" "$LIB")

if [ "$from_before" -eq 0 ]; then
    echo "already patched ($FROM=0, $TO=$(count "$TO" "$LIB"))"
    exit 0
fi

# Binary-safe in-place substitution: -0777 slurps the whole file, so the
# patterns and the replacement are never split across lines.
/usr/bin/perl -0777 -pi -e "s/$FROM/$TO/g" "$LIB"

size_after=$(wc -c < "$LIB" | tr -d ' ')
from_after=$(count "$FROM" "$LIB")
to_after=$(count "$TO" "$LIB")

echo "patched $LIB"
echo "  size      : $size_before -> $size_after"
echo "  $FROM : $from_before -> $from_after"
echo "  $TO : $((to_after - from_before)) -> $to_after"

# A length change would have shifted every following offset and corrupted the
# archive; both keys are 16 bytes so this must never trip.
[ "$size_before" = "$size_after" ] || { echo "error: file size changed -- reverting" >&2; revert; exit 1; }
[ "$from_after" = "0" ] || { echo "error: $FROM still present -- reverting" >&2; revert; exit 1; }

echo "ok: Backup/Restore now emit $TO (revert with $0 --revert)"
