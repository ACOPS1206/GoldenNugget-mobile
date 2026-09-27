import Foundation
import Minimuxer
import SQLite3

/// Fetches the device's **own** PosterBoard database.
///
/// A port of `src/restore/posterboard_backup.py` (`targeted_posterboard_database_backup`)
/// plus `protective.extract_posterboard_db` and `posterboard_structure_version`.
///
/// This is the one piece of the PosterBoard feature that has no alternative.
/// The store's database is where a wallpaper *is*: its descriptor directory is
/// inert on its own, and the row set (provider registrations, role memberships,
/// usage metadata) cannot be synthesised because the device's own rows carry
/// values the host cannot invent. So the device has to hand its store over.
///
/// Two facts make that possible, and both are in the reference:
///
///   1. The device uploads an app's container only when the host names that app
///      in the backup's `FactoryInfo`. The protective backup this app already
///      runs passes an **empty** `Applications`, which is exactly why it never
///      sees PosterBoard. A targeted backup naming `com.apple.PosterBoard`
///      (with the record the device itself gave us) makes it upload the store.
///   2. A mid-stream filter drains everything else, so the run stays small: no
///      photos, no other app's data, nothing but the database is ever written.
///
/// The database is then pulled out of the backup's own `Manifest.db` — matched
/// by **file name**, not by path. iOS 26 uploads it as
/// `AppDomain-com.apple.PosterBoard/…`, iOS 27 under the raw file tree
/// (`/.b/<n>/Containers/…`) where the store directory's name does not always
/// appear; only the file's own name is common to both.
enum PosterBoardBackup {
    struct Result {
        /// The consolidated database, cached under `Documents/PosterBoard/`.
        let database: URL
        /// The store directory version parsed out of the database's own path.
        let structureVersion: Int
        /// The manifest path it was found at, for the log.
        let manifestPath: String
    }

    /// Where a fetched database is kept between runs.
    static func cachedDatabase(udid: String) -> URL {
        URL.documents.appendingPathComponent("PosterBoard/\(udid).sqlite3", conformingTo: .data)
    }

    /// Run the targeted backup and return the consolidated database.
    static func fetch(backupRoot: URL,
                      udid: String,
                      onProgress: ((Double) -> Void)? = nil,
                      log: @escaping @Sendable (String) -> Void) async throws -> Result {
        let fm = FileManager.default
        try? fm.removeItem(at: backupRoot)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)

        // 1. The app record the device itself gave us. Forwarded, not composed:
        //    the entry's shape is the device's contract, and the reference's own
        //    fallbacks (`ApplicationSINF` → b"", `iTunesMetadata` → {}) are only
        //    correct for a record the device produced.
        log("PosterBoard: asking the device for the \(PosterBoard.bundleID) container…")
        let entry = try await Minimuxer.shared().appFactoryEntry(bundleId: PosterBoard.bundleID)
        log("PosterBoard: container \(entry["Container"] as? String ?? "<not reported>") "
            + "(\(entry.keys.count) field(s) from the device's own record)")

        // 2. Host-side metadata. `isFullBackup: true` is the same marker the
        //    protective pull uses and for the same reason: a sparse marker asks
        //    the device to send whatever the manifest lists, which is nothing.
        try HostManifests.ensure(deviceDir: deviceDir, udid: udid, isFullBackup: true,
                                 applications: [PosterBoard.bundleID: entry])
        try HostManifests.writeSQLiteManifest(deviceDir: deviceDir, ios27: true)

        // 3. The backup itself. The filter keeps the database and its WAL
        //    companions — `…sqlite3-wal` contains the name too — plus the backup
        //    metadata files, which must never be drained or the backup is
        //    un-restorable.
        let counter = Counter()
        try await Minimuxer.shared().backupBackup(
            backupRoot: backupRoot.path(percentEncoded: false),
            sourceIdentifier: udid,
            applications: [PosterBoard.bundleID: entry],
            shouldPreserve: { _, file in
                let keep = ProtectiveBackup.isMetadataFile(file)
                    || file.contains(PosterBoard.databaseFileName)
                counter.note(file: file, keep: keep)
                return keep
            },
            onProgress: { overall in
                if let step = counter.noteProgress(overall) {
                    log("PosterBoard backup stream: \(step)% — \(counter.summary)")
                }
                onProgress?(overall)
            },
            delegateLog: { line in AppLog.write(line) }
        )
        log("PosterBoard: backup done — \(counter.summary)")
        guard counter.kept > 0 else {
            throw GoldenNuggetError(
                "The device uploaded nothing for \(PosterBoard.bundleID) (\(counter.total) file(s) "
                + "offered, 0 kept). Names it did offer: \(counter.sample()) — a container the "
                + "device refuses to upload is answered this way, and it is the one failure the "
                + "reference's own docstring describes: the device decides what to send, from the "
                + "factory info it was given.")
        }

        // 4. Pull it out, merge the WAL, and hand back the version it was found
        //    at so the restored copy lands in the same store directory.
        let extracted = try extract(backupRoot: backupRoot, udid: udid, log: log)
        let destination = cachedDatabase(udid: udid)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let consolidated = try consolidate(main: extracted.main,
                                           wal: extracted.wal,
                                           destination: destination,
                                           log: log)
        guard PosterBoardStore.validate(consolidated, strict: false) else {
            throw GoldenNuggetError("The PosterBoard database fetched from the device did not "
                + "validate (\(PosterBoardStore.describeTables(consolidated))). Fetch it again.")
        }
        log("PosterBoard: database ready — \(extracted.manifestPath), structure version "
            + "\(extracted.structureVersion), "
            + ByteCountFormatter.string(fromByteCount: fileSize(consolidated), countStyle: .file))
        return Result(database: consolidated,
                      structureVersion: extracted.structureVersion,
                      manifestPath: extracted.manifestPath)
    }

    // MARK: - Extraction

    private struct Extracted {
        let main: URL
        let wal: URL?
        let manifestPath: String
        let structureVersion: Int
    }

    /// `extract_posterboard_db`: find the database's row, then its payload.
    private static func extract(backupRoot: URL, udid: String,
                                log: @escaping @Sendable (String) -> Void) throws -> Extracted {
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        let manifest = deviceDir.appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw GoldenNuggetError("The PosterBoard backup produced no Manifest.db — the device "
                + "did not commit a backup, so there is nothing to read the database out of.")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(manifest.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            throw GoldenNuggetError("The backup's Manifest.db could not be opened.")
        }
        defer { sqlite3_close(db) }

        // Match on the file name, and take the **highest** path that ends with
        // it: the store directory's numeric version sorts, so this picks the
        // newest layout when a device somehow carries more than one.
        let sql = "SELECT fileID, relativePath FROM Files WHERE relativePath LIKE ? "
            + "ORDER BY relativePath DESC"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GoldenNuggetError("Could not query the backup's Manifest.db.")
        }
        let pattern = "%\(PosterBoard.databaseFileName)%"
        sqlite3_bind_text(statement, 1, pattern, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var rows: [(fileID: String, path: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let pathText = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: idText), String(cString: pathText)))
        }

        guard let candidate = rows.first(where: { $0.path.hasSuffix(PosterBoard.databaseFileName) }) else {
            let sample = rows.prefix(5).map(\.path).joined(separator: ", ")
            throw GoldenNuggetError("The backup carries no \(PosterBoard.databaseFileName)"
                + (rows.isEmpty
                   ? " — and no PosterBoard rows at all. The device uploaded the container but "
                     + "not the store, which is what a factory-info it did not accept looks like."
                   : ". PosterBoard-ish rows it does carry: \(sample)"))
        }
        let payload = deviceDir.appendingPathComponent(String(candidate.fileID.prefix(2)))
            .appendingPathComponent(candidate.fileID)
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw GoldenNuggetError("The manifest lists \(candidate.path) but its payload is not "
                + "on disk — the mid-stream filter dropped it.")
        }
        let walID = rows.first { $0.path == candidate.path + "-wal" }
        let wal = walID.map {
            deviceDir.appendingPathComponent(String($0.fileID.prefix(2)))
                .appendingPathComponent($0.fileID)
        }
        let walOnDisk = wal.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        log("PosterBoard: found \(candidate.path) (fileID \(candidate.fileID.prefix(12))…"
            + (walOnDisk == nil ? ", no WAL companion)" : ", with a WAL companion)"))
        return Extracted(main: payload, wal: walOnDisk,
                         manifestPath: candidate.path,
                         structureVersion: structureVersion(of: candidate.path))
    }

    /// `posterboard_structure_version`: the digits right after the store
    /// directory's name, 61 when the name is absent from the path.
    ///
    /// 61 is the oldest supported layout, and it is the reference's own fallback
    /// — it is only reachable from a path that omits the store directory, which
    /// some iOS 27 upload paths do.
    static func structureVersion(of manifestPath: String) -> Int {
        let marker = "\(PosterBoard.storeDirectoryName)/"
        guard let range = manifestPath.range(of: marker) else {
            return PosterBoard.fallbackStructureVersion
        }
        let digits = manifestPath[range.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? PosterBoard.fallbackStructureVersion
    }

    // MARK: - Consolidation

    /// Fold the `-wal` companion into the main file, if there is one.
    ///
    /// The store runs in WAL mode, so recent wallpaper data can live in the WAL
    /// rather than the main file — and copying the bare main file would lose it.
    /// The `-shm` is deliberately **not** copied: a stale shared-memory file
    /// desyncs against the WAL and is a classic "database disk image is
    /// malformed".
    ///
    /// SQLite's own backup API does the fold, which is what the reference's
    /// `src.backup(merged)` is; on any failure this falls back to the plain
    /// file, exactly as the reference does.
    private static func consolidate(main: URL,
                                    wal: URL?,
                                    destination: URL,
                                    log: @escaping @Sendable (String) -> Void) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard let wal else {
            try fm.copyItem(at: main, to: destination)
            return destination
        }

        let work = fm.temporaryDirectory.appendingPathComponent("posterboard-\(UUID().uuidString)",
                                                                conformingTo: .data)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let scratch = work.appendingPathComponent("posterboard.sqlite3")
        try fm.copyItem(at: main, to: scratch)
        try fm.copyItem(at: wal, to: URL(fileURLWithPath: scratch.path + "-wal"))

        let folded = fold(source: scratch, into: destination)
        if !folded || !PosterBoardStore.validate(destination, strict: false) {
            log("PosterBoard: WAL consolidation did not produce a healthy database "
                + "(\(folded ? "validation failed" : "the backup API refused")) — using the "
                + "plain file, which is what the reference falls back to as well")
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: main, to: destination)
        }
        return destination
    }

    /// SQLite's online-backup API, the Swift spelling of the reference's
    /// `src.backup(merged)`.
    ///
    /// Both handles are closed before this returns: the destination's connection
    /// holds the `journal_mode` pragma, and a reader opened while it is still
    /// live is not guaranteed to see the copy.
    private static func fold(source sourcePath: URL, into destination: URL) -> Bool {
        var source: OpaquePointer?
        var merged: OpaquePointer?
        defer {
            sqlite3_close(source)
            sqlite3_close(merged)
        }
        guard sqlite3_open_v2(sourcePath.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open(destination.path, &merged) == SQLITE_OK,
              let source, let merged else { return false }
        guard let backup = sqlite3_backup_init(merged, "main", source, "main") else { return false }
        sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        sqlite3_exec(merged, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        return true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

/// What the targeted backup offered and what the filter did with it.
///
/// The device decides what to upload, so a run that keeps nothing has to say
/// what it was offered — that sample is the only record of how this iOS names
/// the container's files.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _total = 0
    private var _kept = 0
    private var _samples: [String] = []
    private var _lastStep = -1
    private var _posterBoardOffers: [String] = []

    func note(file: String, keep: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _total += 1
        if keep { _kept += 1 }
        if _samples.count < 20 { _samples.append(keep ? "+ \(file)" : "- \(file)") }
        // The names that mention PosterBoard at all are the ones worth seeing
        // when nothing matched: they say whether the container was uploaded
        // under a name the filter did not expect.
        let lower = file.lowercased()
        if _posterBoardOffers.count < 10
            && (lower.contains("poster") || lower.contains("prb")) {
            _posterBoardOffers.append(file)
        }
    }

    func noteProgress(_ overall: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let step = Int(overall / 5) * 5
        guard step != _lastStep else { return nil }
        _lastStep = step
        return step
    }

    var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
    var kept: Int { lock.lock(); defer { lock.unlock() }; return _kept }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(_kept) kept of \(_total) offered"
    }

    func sample() -> String {
        lock.lock()
        defer { lock.unlock() }
        let poster = _posterBoardOffers.isEmpty
            ? "no name mentioning PosterBoard"
            : _posterBoardOffers.joined(separator: " | ")
        return _samples.joined(separator: " | ") + " // posterboard-ish: " + poster
    }
}
