// Regression harness for the `MBFile` blob the injector writes into Manifest.db.
//
// The device reads a row's *file type* out of the archived `Mode` field.  When it
// cannot read one it answers `MBErrorDomain/205 — "Invalid file type: 00"` and
// abandons the restore, and that message is the only thing it says: `205` is a
// class of error, so the text is the whole diagnosis.
//
// `Mode` was unreadable for every row this app wrote, and the key set never
// showed it: the keys matched the device exactly, the *encoding* did not.
// `NSCoder` has no `UInt32` overload for `encode(_:forKey:)`, so a `UInt32`
// silently takes the `Any?` overload, boxes the value and writes a `$objects`
// **reference** where the device writes an inline integer.  Every integer read
// path then raises on the device:
//
//     -[NSKeyedUnarchiver decodeInt64ForKey:]: value for key (Mode) is not an
//     integer number     // decodeInteger / decodeInt32 / decodeInt64 all raise
//
// So this harness checks three things, none of which needs a device attached:
//
//   1  SHAPE   every scalar of our file and directory rows is inline, and the
//              `Mode` reads back as the mode the device writes (0o100644 /
//              0o40755), not as UNREADABLE.
//   2  DECODE  the real `NSKeyedUnarchiver` reads `Mode` back through the same
//              integer paths the device uses, with the same class name.
//   3  CONTRAST our shapes against the shapes of the device's own blobs in a
//              real backup — the device's rows are the contract, and every one
//              of its 34918 scalar fields is inline.
//
// Run:
//   mkdir -p /tmp/blob-shape \
//     && cat Nugget/Core/MBFileBlob.swift scripts/blob-shape-check.swift > /tmp/blob-shape/main.swift \
//     && xcrun swiftc -O /tmp/blob-shape/main.swift -o /tmp/blob-shape/check \
//     && /tmp/blob-shape/check [path/to/Manifest.db]
//
// With no argument it uses the iPad16,2 / iOS 27.0 backup this project measured
// every constant against, and skips the contrast step if that backup is absent.
//
// Expected output:
//   SHAPE   ours  file: mode=33188 (=0o100644) references=[ExtendedAttributes,RelativePath]
//   SHAPE   ours   dir: mode=16877 (=0o40755) references=[RelativePath]
//   DECODE  ours  file: OK Mode=33188 via decodeInteger/decodeInt32/decodeInt64
//   CONTRAST  3000 device blob(s), 0 with UNREADABLE Mode, 0 with a referenced scalar
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation
import SQLite3

// MARK: - 1. the rows the injector writes

// `BackupInjector.inject` composes exactly these, for
// AppDomain-<bundleId>/Documents/<file>.
let fileMode = Int(MODE_FILE_DEFAULT) | Int(S_IFREG)
let dirMode = Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)

let fileBlob = buildMBFileBlob(
    relativePath: "Documents/poc.txt", mode: fileMode, size: 5,
    protectionClass: PROTECTION_CLASS_FILE, inodeNumber: 123_456,
    extendedAttributes: buildDataprotectionExtendedAttributes())
let dirBlob = buildMBFileBlob(
    relativePath: "Documents", mode: dirMode, size: 0,
    protectionClass: PROTECTION_CLASS_DIR, inodeNumber: 654_321)

func report(_ label: String, _ blob: Data) {
    let mode = mbFileBlobMode(blob)
    let octal = mode.map { String($0, radix: 8) } ?? "-"
    print("SHAPE   \(label): \(mbFileBlobShape(blob)) (=0o\(octal))")
    print("        \(label) keys: \(mbFileBlobKeys(blob))")
}

print("--- 1. shape of what we write ---")
report("ours  file", fileBlob)
report("ours   dir", dirBlob)

// MARK: - 2. can the real unarchiver read the Mode back?

/// Stands in for the device's `MBFile`, mapped onto the archived class name so
/// the archive can be decoded without redeclaring `MBFile` (the app's archiver
/// already owns that name in this translation unit).
@objc(MBShapeProbe) final class MBShapeProbe: NSObject, NSCoding {
    var modeViaInteger = -1
    var modeViaInt32: Int32 = -1
    var modeViaInt64: Int64 = -1
    var relativePath = "?"

    override init() { super.init() }
    required init?(coder aDecoder: NSCoder) {
        super.init()
        relativePath = aDecoder.decodeObject(forKey: "RelativePath") as? String ?? "?"
        // The order matters: the first one that raises aborts the process, so a
        // crash names the path that failed instead of hiding behind a default.
        modeViaInteger = aDecoder.decodeInteger(forKey: "Mode")
        modeViaInt32 = aDecoder.decodeInt32(forKey: "Mode")
        modeViaInt64 = aDecoder.decodeInt64(forKey: "Mode")
    }
    func encode(with coder: NSCoder) {}
}

NSKeyedUnarchiver.setClass(MBShapeProbe.self, forClassName: "MBFile")

func decodeCheck(_ label: String, _ blob: Data) {
    // The legacy entry point on purpose: `unarchivedObject(ofClass:from:)` ignores
    // `setClass(_:forClassName:)`, and this binary cannot declare a probe named
    // `MBFile` outright because `MBFileBlob.swift` already owns that name. The
    // decode path exercised here is the same one (`decodeInteger`-family).
    guard let probe = NSKeyedUnarchiver.unarchiveObject(with: blob) as? MBShapeProbe else {
        print("DECODE  \(label): NOT DECODABLE at all")
        return
    }
    let mode = UInt32(truncatingIfNeeded: probe.modeViaInteger)
    let nibble = String(format: "%02x", (mode & 0o170000) >> 12)
    print("DECODE  \(label): OK Mode=\(probe.modeViaInteger) 0o\(String(mode, radix: 8)) "
        + "type-nibble=\(nibble) via decodeInteger/decodeInt32/decodeInt64")
    if mode & 0o170000 == 0 {
        print("        ^^ NO FILE-TYPE BITS — this is what the device answers with "
            + "\"Invalid file type: 00\"")
    }
}

print("\n--- 2. what a reader gets back (real NSKeyedUnarchiver) ---")
decodeCheck("ours  file", fileBlob)
decodeCheck("ours   dir", dirBlob)

// MARK: - 3. contrast against the device's own blobs

let defaultManifest = ("~/Library/Application Support/MobileSync/Backup/"
    + "00008130-001431082E40001C/Manifest.db" as NSString).expandingTildeInPath
let manifestPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultManifest

print("\n--- 3. contrast against a device-produced manifest ---")
var db: OpaquePointer?
// The device's manifest is in WAL mode; a plain read-only open cannot create the
// `-shm` sidecar, and the first query then fails with SQLITE_CANTOPEN.
guard FileManager.default.fileExists(atPath: manifestPath),
      sqlite3_open_v2("file:\(manifestPath)?immutable=1", &db,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
    print("CONTRAST  skipped: no readable Manifest.db at \(manifestPath)")
    exit(0)
}
defer { sqlite3_close(db) }

var stmt: OpaquePointer?
guard sqlite3_prepare_v2(db, "SELECT file FROM Files WHERE file IS NOT NULL", -1, &stmt, nil)
        == SQLITE_OK, let stmt else {
    print("CONTRAST  failed: \(String(cString: sqlite3_errmsg(db)))")
    exit(1)
}
defer { sqlite3_finalize(stmt) }

var rows = 0
var unreadable = 0
var referencedScalar = 0
var shapes: [String: Int] = [:]
// The scalars the device always writes inline.  A reference for any of them is
// the bug this harness exists for; `RelativePath` / `ExtendedAttributes` /
// `Digest` / `Target` are real objects and are referenced legitimately.
let scalars: Set<String> = ["Birth", "LastModified", "LastStatusChange", "Flags",
                            "GroupID", "UserID", "Mode", "ProtectionClass", "Size",
                            "InodeNumber"]

while sqlite3_step(stmt) == SQLITE_ROW {
    let count = sqlite3_column_bytes(stmt, 0)
    guard count > 0, let raw = sqlite3_column_blob(stmt, 0) else { continue }
    let blob = Data(bytes: raw, count: Int(count))
    rows += 1
    let shape = mbFileBlobShape(blob)
    shapes[shape, default: 0] += 1
    if mbFileBlobMode(blob) == nil { unreadable += 1 }
    let references = shape.split(separator: "[").last.map {
        $0.replacingOccurrences(of: "]", with: "").split(separator: ",").map(String.init)
    } ?? []
    if references.contains(where: { scalars.contains($0) }) { referencedScalar += 1 }
}

print("CONTRAST  \(rows) device blob(s), \(unreadable) with UNREADABLE Mode, "
    + "\(referencedScalar) with a referenced scalar")
for (shape, count) in shapes.sorted(by: { $0.value > $1.value }).prefix(6) {
    print("          \(count)\t\(shape)")
}
print(unreadable == 0 && referencedScalar == 0
    ? "CONTRAST  OK — the device writes every scalar inline, and so must we"
    : "CONTRAST  FAIL — the reference implementation disagrees with our encoding")
