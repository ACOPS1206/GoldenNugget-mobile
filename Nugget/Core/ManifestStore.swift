import CryptoKit
import Foundation
import SQLite3

/// The backup 3.3 manifest schema, in one place.
///
/// This used to be spelled out four times: `pruneManifestDb`, the (unused)
/// `createEmptyManifestDb`, `ingestFileRow`, and the dead `Backup
/// .generateManifestSQLite`.  Two of those copies also restated the fileID rule.
/// A schema drift between copies is a silent, device-side validation failure, so
/// there is now exactly one definition.
enum ManifestSchema {
    /// SQLite's destructor sentinel for "copy this buffer now".
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let createFilesTable =
        "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)"

    static let createPropertiesTable =
        "CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB)"

    static let insertOrReplaceRow =
        "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)"
}

/// The single owner of a backup's `Manifest.db`.
///
/// Every mutation of the manifest — pruning it to what is on disk, seeding an
/// empty one, inserting an injected file row — goes through here.  Nothing else
/// in the app opens this database, which is what makes the fileID rule and the
/// schema checkable in one read.
struct ManifestStore {
    /// `<backupRoot>/<udid>/` — the directory holding Manifest.db and the shards.
    let deviceDir: URL

    init(deviceDir: URL) {
        self.deviceDir = deviceDir
    }

    var dbPath: String {
        deviceDir.appendingPathComponent("Manifest.db").path
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// The fileID of a manifest row: `sha1("<domain>-<relativePath>")` in hex.
    ///
    /// This is the join between the database and the payload tree — the payload
    /// for a row lives at `<deviceDir>/<fileID.prefix(2)>/<fileID>` — so it must
    /// be byte-identical everywhere.  It used to exist twice (an instance method
    /// on the dead `BackupFile` class and a file-private function here).
    static func fileID(domain: String, relativePath: String) -> String {
        sha1Hex("\(domain)-\(relativePath)")
    }

    /// Payload path for a row, i.e. the shard layout the device expects.
    func payloadURL(forFileID fileID: String) -> URL {
        deviceDir.appendingPathComponent(String(fileID.prefix(2)), isDirectory: true)
            .appendingPathComponent(fileID)
    }

    /// SHA-1 in lowercase hex.
    static func sha1Hex(_ value: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    // MARK: - Opening

    /// Open the manifest, or throw if the file is not there.
    private func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw PoCError("Failed to open Manifest.db at \(dbPath)")
        }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let reason = errMsg.map { String(cString: $0) } ?? "unknown error"
            if let errMsg { sqlite3_free(errMsg) }
            throw PoCError("Manifest.db: \(sql) failed — \(reason)")
        }
    }

    // MARK: - Creating

    /// Create a bare 3.3 Manifest.db (Files + Properties tables, no rows).
    ///
    /// Used by a path that builds a minimal backup from scratch instead of
    /// pulling one from the device first.
    func createEmpty() throws {
        let db = try open()
        defer { sqlite3_close(db) }
        try exec(db, ManifestSchema.createFilesTable)
        try exec(db, ManifestSchema.createPropertiesTable)
    }

    // MARK: - Writing rows

    /// Insert (or replace) one file row.
    func upsert(fileID: String, domain: String, relativePath: String,
                flags: Int32, blob: Data) throws {
        let db = try open()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, ManifestSchema.insertOrReplaceRow, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw PoCError("Manifest.db: failed to prepare INSERT for \(domain)/\(relativePath)")
        }
        defer { sqlite3_finalize(stmt) }

        fileID.withCString { cID in
            domain.withCString { cDom in
                relativePath.withCString { cRel in
                    sqlite3_bind_text(stmt, 1, cID, -1, ManifestSchema.transient)
                    sqlite3_bind_text(stmt, 2, cDom, -1, ManifestSchema.transient)
                    sqlite3_bind_text(stmt, 3, cRel, -1, ManifestSchema.transient)
                    sqlite3_bind_int(stmt, 4, flags)
                    _ = blob.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blob.count),
                                          ManifestSchema.transient)
                    }
                }
            }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw PoCError("Manifest.db: INSERT for \(domain)/\(relativePath) failed with code \(rc)")
        }
    }

    // MARK: - Pruning

    /// What `pruneToDiskState()` did, for the log line and for callers that want
    /// to react to a shortfall.
    struct PruneReport {
        let rows: Int
        let kept: Int
        let orphansRemoved: Int
        var dropped: Int { rows - kept }

        var logLine: String {
            "Pruned Manifest.db: \(dropped) of \(rows) row(s) dropped (no payload on disk), "
                + "\(orphansRemoved) orphan payload file(s) removed. "
                + "Dangling rows here are what the device reports as MBErrorDomain/205 "
                + "(\"Manifest references files not in backup\")."
        }
    }

    /// Prune the manifest in place: delete rows for files not present on disk,
    /// remove orphan payload files, and clean empty shard directories.
    ///
    /// This is the second half of the filtered-backup contract.  The device
    /// records every payload it uploaded in the Manifest.db it sends — including
    /// the ones the host filter drained — and the mobilebackup2 delegate keeps a
    /// 0-byte stand-in for each of those on disk only until the backup exchange
    /// is over (see `MobileBackup2BackupContext.cleanupPlaceholders`).  Once the
    /// stand-ins are gone, those rows are exactly the "payload missing on disk"
    /// set this drops, so the manifest and the tree agree again before a restore
    /// is attempted.
    ///
    /// - Returns: nil when there was no Manifest.db to prune.
    @discardableResult
    func pruneToDiskState() -> PruneReport? {
        guard exists else {
            AppLog.write("Prune Manifest.db: no Manifest.db at \(dbPath) — skipped")
            return nil
        }
        guard let db = try? open() else {
            AppLog.write("Prune Manifest.db: could not open \(dbPath) — skipped")
            return nil
        }
        defer { sqlite3_close(db) }

        // Roll the whole rewrite back if any step fails: a half-pruned manifest
        // is worse than an unpruned one, because the device then sees rows whose
        // payloads are gone (MBErrorDomain/205) with no way to tell which
        // failure produced them.
        var stmt: OpaquePointer?
        var keepIDs: [String] = []
        var rowCount = 0

        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: could not begin a transaction — skipped")
            return nil
        }
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                AppLog.write("Prune Manifest.db: rolled back — the manifest is untouched")
            }
        }

        // Phase 1: collect File rows whose payload file is present on disk.
        // Directory rows (flags == 2) never have a payload, so they are kept
        // unconditionally.
        if sqlite3_prepare_v2(db, "SELECT fileID, flags FROM Files", -1, &stmt, nil) == SQLITE_OK,
           let stmt {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cID = sqlite3_column_text(stmt, 0) else { continue }
                let fileID = String(cString: cID)
                let flags = sqlite3_column_int(stmt, 1)
                rowCount += 1
                if flags == 2 {
                    keepIDs.append(fileID)
                } else if FileManager.default.fileExists(atPath: payloadURL(forFileID: fileID).path) {
                    keepIDs.append(fileID)
                }
            }
        }

        // Phase 2: rewrite the table against the keep set.
        guard sqlite3_exec(db,
                           "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT)",
                           nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: could not create the keep table — skipped")
            return nil
        }

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO _keep (fileID) VALUES (?)", -1, &insert, nil) == SQLITE_OK,
              let insert else {
            AppLog.write("Prune Manifest.db: could not prepare the keep insert — skipped")
            return nil
        }
        // Prepared ONCE, outside the loop: the original re-prepared the statement
        // for every kept row, which is a full compile of the INSERT per file on a
        // filtered whole-device backup (tens of thousands of rows).
        for fid in keepIDs {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            _ = fid.withCString { sqlite3_bind_text(insert, 1, $0, -1, ManifestSchema.transient) }
            sqlite3_step(insert)
        }
        sqlite3_finalize(insert)

        guard sqlite3_exec(db, "DELETE FROM Files WHERE fileID NOT IN (SELECT fileID FROM _keep)",
                           nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: the row rewrite failed — skipped")
            return nil
        }
        sqlite3_exec(db, "DROP TABLE _keep", nil, nil, nil)

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: commit failed — skipped")
            return nil
        }
        committed = true

        let orphansRemoved = removeOrphanPayloads(keepIDs: Set(keepIDs))

        let report = PruneReport(rows: rowCount, kept: keepIDs.count, orphansRemoved: orphansRemoved)
        AppLog.write(report.logLine)
        return report
    }

    /// Phase 3: remove payload files that no keep row references.
    ///
    /// Membership is a Set, not an Array scan: a filtered whole-device backup
    /// leaves one entry per stored file, and the reference implementation had to
    /// fix exactly this quadratic walk
    /// (https://github.com/doronz88/pymobiledevice3/issues/1833).
    private func removeOrphanPayloads(keepIDs: Set<String>) -> Int {
        let fm = FileManager.default
        var removed = 0
        guard let shards = try? fm.contentsOfDirectory(atPath: deviceDir.path) else { return 0 }
        for shard in shards {
            let shardDir = deviceDir.appendingPathComponent(shard)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: shardDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let payloads = try? fm.contentsOfDirectory(atPath: shardDir.path) {
                for payload in payloads where !keepIDs.contains(payload) {
                    try? fm.removeItem(at: shardDir.appendingPathComponent(payload))
                    removed += 1
                }
            }
            // Remove shards that are now empty.
            if let remaining = try? fm.contentsOfDirectory(atPath: shardDir.path), remaining.isEmpty {
                try? fm.removeItem(at: shardDir)
            }
        }
        return removed
    }
}
