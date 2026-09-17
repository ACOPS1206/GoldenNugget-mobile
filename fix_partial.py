#!/usr/bin/env python3
import subprocess, sys, difflib

P = '/home/awesomenull/projects/random-poc/Nugget/Sparserestore/PoCEngine.swift'

def sh(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    return r.returncode, (r.stdout or ''), (r.stderr or '')

def brief(rc, o, e, n=400):
    return f"rc {rc} | {(o or e).strip()[-n:]}"

src = open(P, encoding='utf-8').read()
lines = src.split('\n')
assert len(lines) == 695, f"expected 695 lines, got {len(lines)}"

# The GN-mirror block to replace: lines 555-568 (1-based) = index 554..567
# Real disk ground truth (from python reads):
#   555: log("Discarding pulled protective data, rebuilding as a minimal file-only 3.3 backup…")
#   556: (blank)
#   557: // Rebuild host-side as a minimal file-only 3.3 backup inside the same
#   558: // authorized working dir (the device-side backup data above is dropped).
#   559: let deviceDir = backupRoot.appendingPathComponent(udid)
#   560: try? FileManager.default.removeItem(at: deviceDir)
#   561: try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
#   562: (blank)
#   563: // Minimal host-side 3.3 metadata (Status.plist Version 3.3, Manifest/Info plists)
#   564: try Self.ensureHostSideManifests(deviceDir: deviceDir, udid: udid)
#   565: (blank)
#   566: // Empty Manifest.db, then inject the single AppDomain row
#   567: try Self.createEmptyManifestDb(deviceDir: deviceDir)

old = [
    '        log("Discarding pulled protective data, rebuilding as a minimal file-only 3.3 backup…")',
    '',
    '        // Rebuild host-side as a minimal file-only 3.3 backup inside the same',
    '        // authorized working dir (the device-side backup data above is dropped).',
    '        let deviceDir = backupRoot.appendingPathComponent(udid)',
    '        try? FileManager.default.removeItem(at: deviceDir)',
    '        try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)',
    '',
    '        // Minimal host-side 3.3 metadata (Status.plist Version 3.3, Manifest/Info plists)',
    '        try Self.ensureHostSideManifests(deviceDir: deviceDir, udid: udid)',
    '',
    '        // Empty Manifest.db, then inject the single AppDomain row',
    '        try Self.createEmptyManifestDb(deviceDir: deviceDir)',
]

new = [
    '        // GoldenNugget mirror (root-cause fix): the protective pull is a',
    '        // minimal BUT REAL keep-set payload (SpringBoard, SystemPreferences,',
    '        // HomeDomain, AddressBook, Messages, PosterBoard…), and iOS 27 only',
    '        // accepts a restore of that pulled keep-set — it permanently rejects',
    '        // a synthetic file-only 3.3.  So we keep the pulled data, inject into',
    '        // it脱水, and restore it (never discarding / rebuilding minimal).',
    '        let deviceDir = backupRoot.appendingPathComponent(udid)',
    '        log(\"Pulled protective keep-set retained (no discard); injecting file…\")',
]

old_text = '\n'.join(old)
new_text = '\n'.join(new)

n = src.count(old_text)
print(f"old-block occurrences: {n}")
assert n == 1, f"expected exactly 1, got {n}"
src2 = src.replace(old_text, new_text)
open(P, 'w', encoding='utf-8').write(src2)

# verify single definition of isTransientRestoreError and no corruption token
import re
ok = True
for token in ['尝试', '\u2026\u6??']:
    pass
if src2.count('尝试') != 0:
    print('WARN remaining 尝试:', src2.count('尝试'))
    ok = False
if src2.count('static func isTransientRestoreError') > 1:
    print('WARN duplicate isTransientRestoreError def')
    ok = False

newlines = src2.split('\n')
print('new TOTAL:', len(newlines))
for i in range(510, min(600, len(newlines))):
    print(f'{i+1:4d}: {newlines[i]}')

# swiftc -parse (ground truth via python subprocess)
rc, o, e = sh(['swiftc', '-parse', P])
print('\nswiftc -parse:', brief(rc, o, e))
sys.exit(0 if rc == 0 and ok else 1)
