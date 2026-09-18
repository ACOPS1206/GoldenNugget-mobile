import CryptoKit
import Foundation
import Minimuxer
import SQLite3

struct PoCError: Error, LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var errorDescription: String? { message }
}

// On-device PoC: prove that iOS 27's "safe state recovery" wipe does NOT
// trigger when restoring a single app container (no tweak plists involved).
//
// Flow (mirrors GoldenNugget but without photos/video):
//   1. Real protective backup via mobilebackup2 — triggers the iOS
//      backup-password/trust popup and establishes an authorized session.
//      FactoryInfo {Applications: {}} skips app containers device-side.
//      shouldPreserve drains photos/movies mid-stream.
//   2. Prune Manifest.db to the protective keep-set (drained files still
//      have rows — they must be removed or restore requests them).
//   3. Inject AppDomain-<bundleId>/Documents/<fileName> into the backup
//      (Manifest.db row + payload file).
//   4. Restore via mobilebackup2.
//
// If the device does NOT erase, iOS 27 app-container restores are safe.
class PoCEngine {
    static let shared = PoCEngine()

    var pendingLog: [String] = []
    var onLog: ((String) -> Void)?

    /// Result of the one-time Rust logger init (`idevice_init_logger`).
    /// `nil` = never attempted, 0 = file sink live, -2 = someone else won the
    /// race and the Rust log goes to console only (invisible on iOS).
    private(set) var rustLogInitResult: Int32?

    /// Byte offset into `minimuxer.log` taken at the start of a run, so excerpts
    /// only contain this run's Rust output.
    private(set) var rustLogMark: UInt64?

    private let logLock = NSLock()

    func log(_ msg: String) {
        print(msg)
        logLock.lock()
        pendingLog.append(msg)
        logLock.unlock()
        DispatchQueue.main.async {
            self.onLog?(msg)
        }
    }

    /// Point the Rust logger at `<Documents>/minimuxer.log` at DEBUG level.
    ///
    /// MUST run before `setLogging(true)` / `core.start()`: the Rust side
    /// latches on the first `idevice_init_logger` call for the whole process
    /// (`Once`), and the existing call site installs console=Error / file=OFF.
    /// That is why `minimuxer.log` never existed and a failed mobilebackup2
    /// backup produced no Rust-side evidence.  Safe to call repeatedly — every
    /// call after the first returns -2 without changing anything.
    @discardableResult
    func enableRustFileLogging() -> Int32 {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent("minimuxer.log").path

        let rc: Int32
        if let gateway = Minimuxer.shared().ideviceGateway {
            rc = gateway.enableRustFileLogging(to: path)
        } else {
            rc = -99
        }
        rustLogInitResult = rc

        let meaning: String
        switch rc {
        case 0:   meaning = "file sink active (DEBUG)"
        case -1:  meaning = "file error — path rejected by Rust"
        case -2:  meaning = "already initialized — a previous idevice_init_logger call won, Rust logs stay on console(Error) and never reach the file"
        case -3:  meaning = "invalid path string"
        case -99: meaning = "no ideviceGateway available"
        default:  meaning = "unknown"
        }
        log("rust log → \(path): rc=\(rc) (\(meaning))")
        return rc
    }

    // MARK: - Backup-encryption precondition

    /// Reads `com.apple.mobile.backup / WillEncrypt` from the device.
    ///
    /// This is the one precondition that silently breaks the whole PoC and the
    /// one we could never read before: the gateway's `getLockdownValue(key:)`
    /// passes a NULL domain (so this domain-scoped key is invisible) and reads
    /// through `plist_get_string_val` (a no-op on a boolean node).
    ///
    /// With "Encrypted Local Backup" enabled the device hands the host an
    /// ENCRYPTED Manifest.db, while `pruneManifestDb` / `injectFile` rewrite it
    /// with bare sqlite3 — pymobiledevice3's path decrypts with the password,
    /// prunes, then re-encrypts.  There is no encrypt/keybag handling anywhere
    /// in the vendored Rust lib either, so the premise breaks at both ends.
    ///
    /// - Returns: `true`/`false`, or `nil` when the device could not be asked.
    func backupEncryptionEnabled() async -> Bool? {
        guard let gateway = Minimuxer.shared().ideviceGateway else { return nil }
        return try? await gateway.getLockdownBool(key: "WillEncrypt",
                                                 domain: "com.apple.mobile.backup")
    }

    /// Fail fast when the device would hand us an encrypted Manifest.db.
    func preflightBackupEncryption() async throws {
        switch await backupEncryptionEnabled() {
        case .some(true):
            throw PoCError("""
                设备「加密本地备份」已开启（lockdown com.apple.mobile.backup / WillEncrypt = true）。
                这个 PoC 的前提是明文 Manifest.db：pruneManifestDb / injectFile 用裸 sqlite3 直接改写它，
                而 vendored 的 Rust 库完全没有 encrypt/keybag 处理（pymobice3 那条路要先解密、修剪、再加密）。
                请先在 设置 → 你的名字 → iCloud → 设备备份 里关掉「加密本地备份」，
                或用 Finder/iTunes 设备页取消勾选「加密本地备份」，然后再跑。
                """)
        case .some(false):
            log("preflight: 加密本地备份 = OFF（明文 Manifest.db，PoC 前提成立）")
        case .none:
            log("preflight: WillEncrypt 读取失败（domain/key 不可用）——继续，但请注意加密备份会让 prune/inject 失效")
        }
    }

    /// Status of the Rust log sink for the diagnostics block.
    static func rustLogStatus() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("minimuxer.log")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int
        let initResult = PoCEngine.shared.rustLogInitResult.map { String(describing: $0) } ?? "not called"
        return "minimuxer.log: init rc=\(initResult), size=\(size.map { "\($0) B" } ?? "MISSING")"
    }

    // MARK: - Rust log (Rust-side evidence, run-scoped)

    /// `<Documents>/minimuxer.log` — the Rust `tracing` sink installed by
    /// `enableRustFileLogging()`.
    static var rustLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("minimuxer.log")
    }

    static func rustLogSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: rustLogURL.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Remember the log offset so the next excerpt covers only THIS run.
    ///
    /// The file is append-only and shared by every run plus all RSD chatter, so
    /// a plain tail mostly shows whatever ran last — which is why the first
    /// diagnostics block came back with 25 lines of the probe itself and not one
    /// line about the backup.  Reading from a byte offset fixes that.
    @discardableResult
    func markRustLog() -> UInt64 {
        let size = Self.rustLogSize()
        rustLogMark = size
        log("rust log mark: byte \(size) (excerpts from here cover only this run)")
        return size
    }

    /// Lines worth reading in the Rust log, grouped by the layer they identify.
    ///
    /// Every entry is a literal from the actual upstream source, not a guess:
    /// `idevice/src/services/mobilebackup2.rs` (protocol layer) and
    /// `jktcp/src/{adapter,handle}.rs` (the userspace TCP stack the RSD tunnel
    /// runs on — the layer that produces "channel closed").
    static let rustLogVerdictKeywords: [String] = [
        // ── mobilebackup2 protocol layer ────────────────────────────────────
        "DeviceLink version exchange",   // dl_version_exchange() entered
        "expected DLMessageVersionExchange",   // device sent something else
        "expected DLMessageDeviceReady",
        "Invalid DL message format",
        "mobilebackup2 version exchange",
        "Negotiated protocol version",
        "Version exchange failed",
        "Sending device link message",
        "Received DL message",
        "Backup start",                  // "Backup start failed with error: {error:?}"
        "Backup started successfully",
        "Backup info request failed",
        "Device requested file",         // device started streaming -> protocol got past auth
        "Failed to send file",           // our delegate could not serve a requested file
        "Unsupported DL message",
        "Multi status",
        "ErrorCode",
        // ── jktcp: the verdict on WHY the flow died ────────────────────────
        "RST on hp=",                    // device sent RST
        "timed out after",               // N retransmissions unACKed -> path dead
        "retransmitting",                // first sign of an unACKed write
        "channel closed",                // generic flow-gone (FIN / pump death)
        // ── RSD / session / authorization layer ─────────────────────────────
        "StartService",
        "CreateSession",
        "EnableSession",
        "escrow",
        "InvalidHostID",
        "SessionInactive",
        "PasswordProtected",
        "PairingDialog",
        "GetProhibited",
        "Password",
    ]

    /// Keyword-filtered slice of the Rust log — the evidence the app log cannot
    /// provide on its own.
    ///
    /// - Parameter since: byte offset to start from; defaults to the mark taken
    ///   by `markRustLog()` at the start of the run (nil = whole file).
    static func rustLogExcerpt(
        maxLines: Int = 90,
        since: UInt64? = nil,
        keywords: [String] = PoCEngine.rustLogVerdictKeywords
    ) -> String {
        let offset = since ?? PoCEngine.shared.rustLogMark
        // Read the whole file then drop the prefix: FileHandle's read-to-end API
        // was renamed in the iOS 27 SDK, and this log is a few hundred KB.
        guard let whole = try? Data(contentsOf: rustLogURL) else {
            return "  (no readable minimuxer.log at \(rustLogURL.path))"
        }
        let from = Int(min(offset ?? 0, UInt64(whole.count)))
        let data = whole.dropFirst(from)
        guard let text = String(data: data, encoding: .utf8) else {
            return "  (minimuxer.log unreadable from byte \(from))"
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let lowered = keywords.map { $0.lowercased() }
        let hits = lines.filter { line in
            let low = line.lowercased()
            return lowered.contains { low.contains($0) }
        }

        var out = "  rust log excerpt"
        if offset != nil { out += " after byte \(from)" }
        out += ": \(lines.count) new lines, \(hits.count) match protocol/flow keywords"
        guard !hits.isEmpty else {
            return out + "\n  (nothing matched — the Rust log never reached the mobilebackup2 or jktcp layer)"
        }
        return out + "\n" + hits.suffix(maxLines).map { "  | \($0)" }.joined(separator: "\n")
    }

    // MARK: - Protective filter (GoldenNugget-style, no photos/video)

    /// Returns true if a device-side backup upload name belongs to the
    /// protective keep-set.  Photos, videos, keychain, and everything else
    /// is drained mid-stream and never written to disk.
    static func isProtectiveFile(_ deviceName: String) -> Bool {
        let name = Self.normDeviceName(deviceName)

        // Backup metadata files — the device uploads these in the same stream;
        // they MUST always be preserved or the backup is un-restorable.
        if Self.isMetadataFile(name) { return true }

        // SystemPreferencesDomain / MessagesDomain — keep both.
        if Self.domainMatch(name, "SystemPreferencesDomain") ||
            Self.domainMatch(name, "MessagesDomain") {
            return true
        }

        // iOS 27 raw tree: message data
        if Self.treeMatch(name, "Library/Messages",
                          "Library/SMS",
                          "Library/MessagesMetaData") {
            return true
        }

        // HomeDomain selective paths
        for prefix in (
            ["Library/Accounts",
             "Library/ConfigurationProfiles",
             "Library/Preferences"] +
            ["Library/SpringBoard"] +
            ["Library/ControlCenter"] +
            ["Library/Shortcuts"] +
            ["Library/WebClips",
             "Library/WebApp",
             "Library/WebKit/WebsiteData"] +
            ["Library/AddressBook"]
        ) {
            if Self.pathMatch(name, prefix) { return true }
        }

        return false
    }

    // MARK: - Name helpers (mirror GoldenNugget's _norm/_domain_match/etc.)

    private static func normDeviceName(_ deviceName: String) -> String {
        deviceName.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
    }

    /// Backup metadata files always preserved regardless of the keep-set,
    /// mirroring pymobiledevice3's BACKUP_METADATA_FILES.
    static func isMetadataFile(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return ["Info.plist", "Manifest.plist", "Manifest.db",
                "Manifest.db-shm", "Manifest.db-wal", "Status.plist"].contains(base)
    }

    private static func domainMatch(_ name: String, _ domain: String) -> Bool {
        name == domain || name.hasPrefix("\(domain)/")
    }

    private static func treeMatch(_ name: String, _ trees: String...) -> Bool {
        let stripped = stripIOS27Root(name)
        for tree in trees {
            if stripped == tree || stripped.hasPrefix("\(tree)/") { return true }
        }
        return false
    }

    private static func pathMatch(_ name: String, _ path: String) -> Bool {
        if name == path || name.hasPrefix("\(path)/") { return true }
        if name == "HomeDomain/\(path)" || name.hasPrefix("HomeDomain/\(path)/") { return true }
        return treeMatch(name, path)
    }

    private static func stripIOS27Root(_ name: String) -> String {
        var n = name
        for prefix in ["b", ".b"] {
            if n.hasPrefix("\(prefix)/") {
                let rest = String(n.dropFirst(prefix.count + 1))
                if let slash = rest.firstIndex(of: "/") {
                    let seg = rest[rest.startIndex..<slash]
                    if Int(seg) != nil {
                        return String(rest[rest.index(after: slash)...])
                    }
                }
            }
        }
        return n
    }

    // MARK: - Manifest.db prune

    /// Prune a device backup directory's Manifest.db in place: delete rows
    /// for files not present on disk, remove orphan payload files, and clean
    /// empty directories.  After a filtered backup, rejected files have rows
    /// but no payload — restore would request them and fail.
    static func pruneManifestDb(deviceDir: URL) {
        let dbPath = deviceDir.appendingPathComponent("Manifest.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        // Phase 1: delete File rows whose payload file is missing from disk
        // (directory rows with flags=2 always have no payload — keep them).
        var stmt: OpaquePointer?
        var keepIDs: [String] = []

        if sqlite3_prepare_v2(db,
                              "SELECT fileID, flags FROM Files",
                              -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let fileID = String(cString: sqlite3_column_text(stmt, 0))
                let flags = sqlite3_column_int(stmt, 1)
                if flags == 2 {
                    keepIDs.append(fileID)
                } else {
                    let subdir = String(fileID.prefix(2))
                    let payload = deviceDir.appendingPathComponent(subdir)
                        .appendingPathComponent(fileID).path
                    if FileManager.default.fileExists(atPath: payload) {
                        keepIDs.append(fileID)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)

        // Delete non-keep rows via temp table
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_exec(db, "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT)", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM _keep", nil, nil, nil)
        for fid in keepIDs {
            fid.withCString { cID in
                sqlite3_prepare_v2(db,
                                   "INSERT INTO _keep (fileID) VALUES (?)",
                                   -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, cID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        sqlite3_exec(db,
                     "DELETE FROM Files WHERE fileID NOT IN (SELECT fileID FROM _keep)",
                     nil, nil, nil)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        sqlite3_exec(db, "DROP TABLE _keep", nil, nil, nil)

        // Phase 2: remove orphan payload files not referenced by any keep row
        let fm = FileManager.default
        if let hashes = try? fm.contentsOfDirectory(atPath: deviceDir.path) {
            for hash in hashes {
                let hashDir = deviceDir.appendingPathComponent(hash)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: hashDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if let payloads = try? fm.contentsOfDirectory(atPath: hashDir.path) {
                    for payload in payloads {
                        if !keepIDs.contains(payload) {
                            try? fm.removeItem(at: hashDir.appendingPathComponent(payload))
                        }
                    }
                }
                // Remove empty hash dirs
                if let remaining = try? fm.contentsOfDirectory(atPath: hashDir.path),
                   remaining.isEmpty {
                    try? fm.removeItem(at: hashDir)
                }
            }
        }

        _ = ""
        PoCEngine.shared.log("Pruned Manifest.db")
    }

    /// Mirror pymobiledevice3's host-side backup metadata: the device uploads
    /// Manifest.db in the stream, but Info.plist / Status.plist / Manifest.plist
    /// are normally created by the host.  Write minimal valid ones if missing so
    /// the backup is always restorable.
    static func ensureHostSideManifests(deviceDir: URL, udid: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        // Status.plist
        let statusURL = deviceDir.appendingPathComponent("Status.plist")
        if !fm.fileExists(atPath: statusURL.path) {
            let status: [String: Any] = [
                "BackupState": "new",
                "Date": Date(),
                "IsFullBackup": true,
                "Version": "3.3",
                "SnapshotState": "finished",
                "UUID": UUID().uuidString.uppercased(),
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: status,
                                                              format: .binary, options: 0) {
                try? data.write(to: statusURL)
            }
        }

        // Manifest.plist — seeded empty; injectFile fills Applications.
        let manifestURL = deviceDir.appendingPathComponent("Manifest.plist")
        if !fm.fileExists(atPath: manifestURL.path) {
            try? PropertyListSerialization.data(fromPropertyList: ["DataProtection": true,
                                                                   "Lockdown": [:],
                                                                   "SystemDomainsVersion": "20.0",
                                                                   "Version": "9.1",
                                                                   "Applications": [:]],
                                                format: .xml, options: 0)
                .write(to: manifestURL)
        }

        // Info.plist — minimal identity, only used for display.
        let infoURL = deviceDir.appendingPathComponent("Info.plist")
        if !fm.fileExists(atPath: infoURL.path) {
            let info: [String: Any] = [
                "Unique Identifier": udid.uppercased(),
                "Target Type": "Device",
                "Target Identifier": udid,
                "Build Version": "",
                "Product Version": "",
                "Product Type": "",
                "Serial Number": "",
                "Applications": [:],
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: info,
                                                              format: .xml, options: 0) {
                try? data.write(to: infoURL)
            }
        }
    }

    /// Create a bare 3.3 Manifest.db (Files + Properties tables, no rows).
    /// Used by the partial-restore path which builds a minimal backup from
    /// scratch instead of pulling an on-device backup first.
    static func createEmptyManifestDb(deviceDir: URL) throws {
        let dbPath = deviceDir.appendingPathComponent("Manifest.db").path
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else {
            throw PoCError("Failed to create Manifest.db")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db,
                           "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)",
                           nil, nil, nil) == SQLITE_OK else {
            throw PoCError("Failed to create Files table")
        }
        sqlite3_exec(db, "CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil)
    }

    // MARK: - Inject poc.txt into an existing backup

    /// Inject a file into an existing backup directory's Manifest.db and
    /// payload layout.  Creates domain + directory rows + a file row, writes
    /// the payload, and registers the app in Manifest.plist / Info.plist.
    static func injectFile(
        into deviceDir: URL,
        domain: String,
        relativePath: String,
        contents: Data,
        appInfo: NuggetAppInfo
    ) throws {
        let fileID = sha1Hex("\(domain)-\(relativePath)")

        // 1. Write payload
        let subDir = deviceDir.appendingPathComponent(String(fileID.prefix(2)),
                                                      isDirectory: true)
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try contents.write(to: subDir.appendingPathComponent(fileID))

        // 2. Insert rows into Manifest.db
        //    One flags=2 directory row per parent path component (domain root
        //    first), each keyed by sha1("<domain>-<dirRel>"), then one flags=1
        //    file row keyed by sha1("<domain>-<relativePath>"). The dir rows
        //    MUST NOT reuse the file row's ID: on a fresh empty Manifest.db a
        //    PRIMARY KEY collision would make the file-row INSERT fail and the
        //    restore would silently do nothing.
        let dbPath = deviceDir.appendingPathComponent("Manifest.db").path
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else {
            throw PoCError("Failed to open Manifest.db for injection")
        }
        defer { sqlite3_close(db) }

        let dirParts = (relativePath as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        var rel = ""
        var ingestSQL: [(String, Int32)] = [("", 2)]     // domain root dir
        for comp in dirParts {
            rel = rel.isEmpty ? comp : "\(rel)/\(comp)"
            ingestSQL.append((rel, 2))
        }
        ingestSQL.append((relativePath, 1))              // the file itself

        for (relPath, flags) in ingestSQL {
            let blob = buildMBFileBlob(
                relativePath: relPath,
                mode: flags == 2 ? (UInt32(MODE_DEFAULT) | UInt32(S_IFDIR))
                    : (UInt32(MODE_DEFAULT) | UInt32(S_IFREG)),
                size: flags == 1 ? contents.count : 0,
                isDirectory: flags == 2,
                digest: flags == 1 ? Data(Insecure.SHA1.hash(data: contents)) : nil,
                extendedAttributes: flags == 1 ? buildDataprotectionExtendedAttributes() : nil
            )
            let relPathKey = flags == 1 ? relativePath : relPath
            let fileIDForRow = sha1Hex("\(domain)-\(relPathKey)")
            try ingestFileRow(db: db,
                              fileID: fileIDForRow,
                              domain: domain,
                              relPath: relPath,
                              flags: flags,
                              blob: blob)
        }

        // 3. Register in Manifest.plist Applications
        let manifestPlistURL = deviceDir.appendingPathComponent("Manifest.plist")
        var manifest = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: manifestPlistURL),
            options: [], format: nil)) as? [String: Any] ?? [:]
        var apps = manifest["Applications"] as? [String: Any] ?? [:]
        apps[appInfo.bundleID] = [
            "CFBundleIdentifier": appInfo.bundleID,
            "CFBundleVersion": appInfo.version,
            "Path": appInfo.path,
            "ContainerContentClass": appInfo.container
        ]
        manifest["Applications"] = apps
        try PropertyListSerialization.data(fromPropertyList: manifest,
                                          format: .xml, options: 0)
            .write(to: manifestPlistURL)

        // 4. Register in Info.plist Applications
        let infoPlistURL = deviceDir.appendingPathComponent("Info.plist")
        var info = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoPlistURL),
            options: [], format: nil)) as? [String: Any] ?? [:]
        var infoApps = info["Applications"] as? [String: Any] ?? [:]
        infoApps[appInfo.bundleID] = [
            "CFBundleIdentifier": appInfo.bundleID,
            "CFBundleVersion": appInfo.version,
            "Path": appInfo.path,
            "ContainerContentClass": appInfo.container
        ]
        info["Applications"] = infoApps
        try PropertyListSerialization.data(fromPropertyList: info,
                                          format: .xml, options: 0)
            .write(to: infoPlistURL)

        PoCEngine.shared.log("Injected \(domain)/\(relativePath) (fileID=\(fileID))")
    }

    // MARK: - Stage 1: Real protective backup

    func runProtectiveBackup(
        backupRoot: URL,
        udid: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let minimuxer = Minimuxer.shared()
        log("Creating protective backup (no photos/video) at \(backupRoot.path)…")

        // The Rust delegate callbacks are the ONLY host-side window into the
        // mobilebackup2 conversation.  Counting what the device streamed and
        // how far progress got separates "died before the first file" (request
        // / version-exchange / authorization phase) from "died mid-stream"
        // (transfer phase) — two completely different root causes that look
        // identical in the thrown error string.
        let trace = BackupTrace()
        let beat = Heartbeat()
        let stage = StageTimer("protective backup")
        // Prove the transfer is alive: the counters only move when the device
        // actually streams a file, so a heartbeat that stops changing = stalled.
        beat.start("protective backup") { trace.summary() }

        // The device drops the mobilebackup2 channel as soon as the Trust /
        // backup-password dialog is answered ("Backup failed, error:
        // (Socket(... BrokenPipe, channel closed))").  Retry with escalating
        // recovery instead of aborting.
        do {
            try await withChannelRetry(
                label: "protective backup",
                attempts: 3,
                // Wipe ONLY on the first attempt.  The device decides what to
                // upload, so wiping the manifest baseline makes every retry a
                // FULL re-upload of the whole protective set — the single most
                // expensive thing this app does.  A retry on top of the partial
                // baseline is incremental instead.
                beforeAttempt: { attempt in
                    if attempt == 1 {
                        try Self.resetDeviceDir(backupRoot: backupRoot, udid: udid)
                    } else {
                        self.log("keeping the partial baseline from attempt \(attempt - 1) "
                            + "(wiping it would force a full re-upload)")
                        try Self.ensureHostSideManifests(
                            deviceDir: backupRoot.appendingPathComponent(udid), udid: udid)
                    }
                }
            ) {
                // 120 s of total silence = the device is wedged, not slow.  The
                // idle clock is fed by the Rust delegate callbacks (i.e. actual
                // file traffic), so a genuinely long upload never trips this.
                try await Self.withStallGuard(
                    label: "protective backup",
                    idleSeconds: 120,
                    idle: { trace.lastActivityAt },
                    handshakeSilent: { Self.deviceSilentAtHandshake() }
                ) {
                    try await minimuxer.backupBackup(
                        backupRoot: backupRoot.path(percentEncoded: false),
                        sourceIdentifier: udid,
                        skipAppContainers: true,
                        shouldPreserve: { deviceName, file in
                            let keep = PoCEngine.isMetadataFile(file)
                                || PoCEngine.isProtectiveFile(deviceName)
                            trace.note(file: file, domain: deviceName, keep: keep)
                            return keep
                        },
                        onProgress: { overall in
                            if let step = trace.noteProgress(overall) {
                                self.log("backup stream: \(step)% — \(trace.summary())")
                            }
                            onProgress?(overall)
                        }
                    )
                }
            }
            log("protective backup finished — \(trace.summary())")
            beat.stop()
            stage.done(trace.summary())
        } catch {
            beat.stop()
            stage.done("FAILED — \(trace.summary())")
            log("protective backup FAILED — \(trace.summary())")
            for line in trace.sampleLines() { log(line) }
            // The Rust side is the only place that knows WHY the flow died, and
            // every candidate has its own literal: RST (device reset), "timed
            // out after N retransmissions" (our writes unACKed -> dead path),
            // FIN (silent), or a delegate failure ("Failed to send file").
            log(Self.rustLogExcerpt())
            // `Socket(... BrokenPipe, "channel closed")` is jktcp's generic
            // report for "that TCP flow is gone" — the userspace stack drops its
            // per-port sender when the connection is torn down, so a
            // DEVICE-SIDE close and a local pump failure look identical here.
            // It therefore cannot be read as "the device refused us".
            log("note: \"channel closed\" is jktcp's generic flow-closed report — it does not distinguish "
                + "a device-side teardown from a local stack failure. See minimuxer.log (Rust, DEBUG) for the real step.")
            throw error
        }
    }

    /// Wipe `<backupRoot>/<udid>/` and re-seed the host-side manifests.
    ///
    /// pymobiledevice3 pre-creates the host-side backup metadata BEFORE the
    /// backup: the device's first DL message is a DownloadFiles request for
    /// `<udid>/Status.plist`, and the backup aborts instantly if it's missing.
    static func resetDeviceDir(backupRoot: URL, udid: String) throws {
        let deviceDir = backupRoot.appendingPathComponent(udid)
        try? FileManager.default.removeItem(at: deviceDir)
        try ensureHostSideManifests(deviceDir: deviceDir, udid: udid)
    }

    // MARK: - Stage 2+3: Prune + inject

    func pruneAndInject(
        backupRoot: URL,
        udid: String,
        bundleID: String,
        fileName: String,
        contents: Data
    ) async throws {
        let deviceDir = backupRoot.appendingPathComponent(udid)

        // Fallback: if the device did not upload the host-side backup
        // metadata (Info.plist / Status.plist / Manifest.plist), write
        // minimal valid ones — pymobiledevice3 pre-creates these before
        // the backup, and restore refuses a backup without them.
        let manifestStage = StageTimer("ensure host-side manifests")
        try Self.ensureHostSideManifests(deviceDir: deviceDir, udid: udid)
        manifestStage.done()

        // Prune
        log("Pruning Manifest.db…")
        let pruneStage = StageTimer("prune Manifest.db")
        Self.pruneManifestDb(deviceDir: deviceDir)
        pruneStage.done()

        // Lookup target app
        let lookupStage = StageTimer("InstProxy lookup \(bundleID)")
        let appInfo = try await InstProxy.lookup(bundleID: bundleID)
        lookupStage.done("v\(appInfo.version)")
        log("Target app: \(bundleID) v\(appInfo.version)")

        // Inject poc.txt
        let domain = "AppDomain-\(bundleID)"
        log("Injecting \(domain)/Documents/\(fileName)…")
        let injectStage = StageTimer("inject")
        try Self.injectFile(
            into: deviceDir,
            domain: domain,
            relativePath: "Documents/\(fileName)",
            contents: contents,
            appInfo: appInfo
        )
        injectStage.done()
    }

    // MARK: - Stage 4: Restore

    @discardableResult
    func runRestore(backupRoot: URL, sourceIdentifier: String) async throws -> Int32 {
        let minimuxer = Minimuxer.shared()
        log("Restoring backup at \(backupRoot.path) (source \(sourceIdentifier)) via mobilebackup2…")
        let beat = Heartbeat()
        let stage = StageTimer("restore")
        // The restore progress callback fires per file.  Logging every callback
        // appended thousands of lines to the UI list (janky to scroll, and the
        // interesting lines get pushed out) — throttle to 5 % steps like the
        // backup path.
        let progress = PercentThrottle()
        beat.start("restore") { "5 %-step progress logging" }
        // Same missing-deadline problem as the backup path.  Longer idle window
        // than the backup: a restore negotiates, rewrites the manifest and
        // reboots, and several of those phases report no per-file progress.
        try await Self.withStallGuard(
            label: "restore",
            idleSeconds: 180,
            idle: { progress.lastActivityAt },
            handshakeSilent: { Self.deviceSilentAtHandshake() }
        ) {
            try await minimuxer.restoreBackup(
                backupRoot: backupRoot.path(percentEncoded: false),
                sourceIdentifier: sourceIdentifier,
                shouldReboot: false,
                systemFiles: true,
                onProgress: { overall in
                    let pct = overall < 0 ? 0 : min(overall, 100)
                    if let step = progress.step(pct) {
                        PoCEngine.shared.log("restore progress: \(step)%")
                    }
                }
            )
        }
        beat.stop()
        stage.done()
        return 0
    }

    /// GoldenNugget `_is_transient_restore_error` mirror: on iOS 27 the
    /// device can drop the mobilebackup2 channel mid-restore (SpringBoard
    /// restart tearing down the tunnel -> BrokenPipe "channel closed" /
    /// ConnectionTerminated); that is EXPECTED and ridden out by retrying
    /// (GN: 18x3s; PoC: 3x3s).  Only truly-transient errors get retried.
    static func isTransientRestoreError(_ error: Error) -> Bool {
        let desc = String(describing: error).lowercased()
        return desc.contains("brokenpipe") || desc.contains("channel closed") ||
            desc.contains("connectionterminated") || desc.contains("ssleof") ||
            desc.contains("mobilebackup2")
    }

    /// Socket-level "the channel died" predicate.  Distinct from
    /// `isTransientRestoreError`, which also matches any error mentioning
    /// mobilebackup2 (too broad for the backup stage: a device-side validation
    /// rejection such as "Unknown domain name in file record" must NOT be
    /// retried forever).
    static func isTransientChannelError(_ error: Error) -> Bool {
        let desc = String(describing: error).lowercased()
        return desc.contains("brokenpipe") || desc.contains("channel closed") ||
            desc.contains("connectionterminated") || desc.contains("ssleof") ||
            desc.contains("connection reset") || desc.contains("connectionreset")
    }

    /// Run `body`, retrying on a dropped device channel.
    ///
    /// A single `invalidateConnection()` is NOT always enough — the Swift
    /// gateway caches its RSD adapter/handshake **and** the `deviceEndpointIp`
    /// the Rust tunnel dials, while the em_proxy/muxer plumbing is never
    /// recreated.  So recovery escalates with the attempt number (see
    /// `recoverChannel(level:)`), and every failure dumps a diagnostics block
    /// so the failing layer is identifiable from the app log alone.
    ///
    /// - Parameter beforeAttempt: receives the 1-based attempt number, so a
    ///   caller can do the expensive reset only on the first try.
    @discardableResult
    func withChannelRetry<T>(
        label: String,
        attempts: Int = 3,
        delaySeconds: UInt64 = 1,
        beforeAttempt: ((Int) async throws -> Void)? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                if let beforeAttempt { try await beforeAttempt(attempt) }
                return try await body()
            } catch {
                // A stall is NOT a dropped channel: the device accepted the
                // connection and then simply stopped answering.  A fresh RSD
                // tunnel does not help — the Rust log shows the retry getting a
                // brand-new tunnel and then not even receiving the DeviceLink
                // version exchange reply — so fail fast instead of spending
                // another whole attempt (and another 2 minutes) to arrive at the
                // same place.  Worst case for `.handshakeSilent`: the device
                // daemon is wedged and only a device reboot clears it.
                if error is DeviceStallError {
                    log("\(label) aborted: \(error.localizedDescription)")
                    log(await diagnostics())
                    throw error
                }
                let transient = Self.isTransientChannelError(error)
                if !transient {
                    log("\(label) failed (not a channel drop, not retrying): \(error.localizedDescription)")
                    log(await diagnostics())
                    throw error
                }
                if attempt >= attempts {
                    log("\(label) still dropping the channel after \(attempt) attempts — giving up.")
                    log(await diagnostics())
                    throw error
                }
                // Short first wait, then double.  A flat 3 s cost 12 s of pure
                // sleep over 5 attempts for nothing: the retry either lands on a
                // freshly authorized session immediately or not at all.
                let delay = min(delaySeconds << UInt64(attempt - 1), 8)
                log("\(label) attempt \(attempt)/\(attempts) hit a dropped channel "
                    + "(\(error.localizedDescription)); recovering and retrying in \(delay)s…")
                await recoverChannel(level: attempt)
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    /// Escalating recovery between retry attempts.  Each level releases one
    /// more layer of cached state, because a dropped channel can be caused by
    /// any of them being stale.
    ///
    /// 1. RSD adapter + handshake         → `invalidateConnection()`
    /// 2. tunnel peer IP (route change)   → `network.refreshEndpoint()`
    /// 3. endpoint pin + muxer plumbing   → `setDeviceEndpointIp` + `core.restart()`
    func recoverChannel(level: Int) async {
        let minimuxer = Minimuxer.shared()
        log("recover(level \(level)): dropping cached RSD tunnel…")
        minimuxer.ideviceGateway?.invalidateConnection()
        guard level > 1 else { return }

        log("recover(level \(level)): re-discovering tunnel endpoint…")
        await minimuxer.network.refreshEndpoint()
        guard level > 2 else { return }

        // The Rust tunnel dials `deviceEndpointIp`. If a tunnel flap left that
        // cached IP stale, every attempt dies identically no matter how often
        // the adapter is dropped. Pin the LocalDevVPN peer the app probes and
        // rebuild the muxer plumbing on top of it.
        log("recover(level \(level)): pinning endpoint to \(Tunnel.peerIP) and restarting minimuxer…")
        minimuxer.gateway.setDeviceEndpointIp(Tunnel.peerIP)
        let stage = StageTimer("recover restart")
        do {
            try await minimuxer.core.restart()
            // Bounded at ~4 s: this runs between retry attempts, so a 10 s
            // readiness poll here is dead time on top of the retry backoff.
            var ready = false
            for _ in 0..<14 {
                if case .success(true) = await minimuxer.core.isReady(withNetworkCheck: true) {
                    ready = true
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            stage.done("ready=\(ready)")
            log("recover(level \(level)): minimuxer restarted, endpoint pinned (ready=\(ready))")
        } catch {
            stage.done("restart failed")
            log("recover(level \(level)): minimuxer restart failed (\(error.localizedDescription)) — continuing anyway")
        }
    }

    /// One-block snapshot of every layer a channel drop can come from, so the
    /// app log alone tells us where the failure lives.  Order matters: each
    /// line is a strictly deeper layer than the previous one.
    func diagnostics() async -> String {
        let minimuxer = Minimuxer.shared()
        var lines: [String] = ["── diagnostics ──"]

        // Snapshot the Rust evidence FIRST.  The probes below (fetchUDID /
        // isReady / WillEncrypt) drive their own RSD + lockdown traffic into the
        // very same log, and reading it afterwards is what made the first dump
        // contain nothing but the probe's own lines.
        let logStatus = Self.rustLogStatus()
        let excerpt = Self.rustLogExcerpt()
        let tail = Self.minimuxerLogTail(30, since: rustLogMark)

        lines.append("  tunnel: \(Tunnel.describe())")
        lines.append("  peer \(Tunnel.peerIP):\(Tunnel.servicePort) reachable: \(Tunnel.probePeer())")
        if let gw = minimuxer.ideviceGateway {
            lines.append("  gateway endpoint IP: \(gw.deviceEndpointIp ?? "nil")")
        } else {
            lines.append("  gateway: not IdeviceGateway")
        }
        lines.append("  pairing type: \(minimuxer.core.getPairingFileType())")
        // Proves whether RSD itself survived: if this works while mobilebackup2
        // keeps dying, the drop is mobilebackup2-specific (device side), not
        // the tunnel.
        let udid = try? await minimuxer.core.fetchUDID()
        lines.append("  lockdown fetchUDID: \(udid.flatMap { $0 } ?? "FAILED")")
        if case .success(let ready) = await minimuxer.core.isReady(withNetworkCheck: true) {
            lines.append("  isReady: \(ready)")
        } else {
            lines.append("  isReady: FAILED")
        }
        lines.append("  rust log: \(logStatus)")
        let encrypt = await backupEncryptionEnabled()
        lines.append("  backup encryption (com.apple.mobile.backup/WillEncrypt): "
            + (encrypt.map { $0 ? "ON — PoC premise broken (encrypted Manifest.db)" : "off" } ?? "unknown"))
        // Keyword slice first (the actual evidence), raw tail last (proves the
        // sink is live and shows an unclassified failure).  Both were captured
        // before the probes above wrote a single line.
        lines.append(excerpt)
        lines.append("  rust log raw tail (last 30 lines):\n\(tail)")
        lines.append("── end diagnostics ──")
        let block = lines.joined(separator: "\n")
        // Persist next to the log so it can be shared as a FILE (AirDrop / Save
        // to Files) instead of hand-selecting text in the app's log list.
        try? block.write(to: Self.diagnosticsURL, atomically: true, encoding: .utf8)
        return block
    }

    /// `<Documents>/diagnostics.txt` — the last dumped diagnostics block.
    static var diagnosticsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics.txt")
    }

    /// minimuxer writes <docs>/minimuxer.log; its tail shows the layer that
    /// stopped first (tunnel, handshake, or the mobilebackup2 stream).
    ///
    /// - Parameter since: byte offset to start from (a `markRustLog()` snapshot
    ///   confines it to the current run).  nil = whole file.
    static func minimuxerLogTail(_ count: Int = 30, since: UInt64? = nil) -> String {
        let url = rustLogURL
        guard let whole = try? Data(contentsOf: url) else {
            return "(no minimuxer.log at \(url.path))"
        }
        let from = Int(min(since ?? 0, UInt64(whole.count)))
        guard let text = String(data: whole.dropFirst(from), encoding: .utf8) else {
            return "(minimuxer.log unreadable from byte \(from))"
        }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    // MARK: - Partial restore (light protective auth + minimal 3.3 backup)

    /// Restore ONLY the injected app container file via a minimal backup 3.3
    /// built host-side — the full protective data pull is NOT restored.
    ///
    /// Unlike the original "file-only, no backup" design, a *lightweight*
    /// protective backup is still performed FIRST.  On iOS 27 the restore
    /// daemon refuses a mobilebackup2 restore from an un-authorized session
    /// and simply closes the channel (BrokenPipe "channel closed") with NO
    /// popup on the device.  The light protective backup is what triggers the
    /// Trust / backup-password popup and authorized the session; it is
    /// selective (empty Applications, no photos/videos — see
    /// `isProtectiveFile`), so it runs fast.  All of its uploaded data is
    /// then discarded and replaced by a minimal 3.3 manifest with a single
    /// AppDomain row, which is what actually gets restored.
    ///
    /// Backup layout written to `backupRoot/<udid>/`:
    ///   - Manifest.db   born empty (Files/Properties) then one AppDomain row
    ///   - Status.plist  Version 3.3
    ///   - Manifest.plist / Info.plist with the target app registered
    ///   - payload file under `<fileID.prefix(2)>/<fileID>`
    func runPartialRestore(
        bundleID: String,
        fileName: String = "poc.txt",
        contents: String = "PoC: iOS 27 partial container restore OK"
    ) async throws {
        pendingLog = []
        let runStage = StageTimer("RUN partial restore")
        defer { runStage.done() }
        let minimuxer = Minimuxer.shared()
        guard await testReady(minimuxer) else {
            throw PoCError("minimuxer is not ready. Ensure WiFi and a working tunnel (LocalDevVPN or WireGuard + em_proxy), then select a pairing file.")
        }
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PoCError("Enter a bundle identifier to target (e.g. com.apple.PosterBoard)")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw PoCError("Could not fetch device UDID")
        }
        log("UDID: \(udid)")
        log("Target bundle: \(bundleID)")
        log("Tunnel: \(Tunnel.describe())")
        try await preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        let data = contents.data(using: .utf8) ?? Data(contents.utf8)
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupRoot = docsDir.absoluteURL.appendingPathComponent("\(udid)-partial", conformingTo: .data)

        // Clean previous partial backup
        try? FileManager.default.removeItem(at: backupRoot)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // Stage 0b: LIGHT protective backup.  On iOS 27 the restore daemon
        // refuses a mobilebackup2 restore from an un-authorized session and
        // just closes the channel (BrokenPipe "channel closed") with NO popup.
        // A protective backup is what triggers the Trust / backup-password
        // popup and authorizes the session.  This one is selective (empty
        // Applications, drains photos/videos) per `runProtectiveBackup`, so
        // it is fast — then we discard everything it pulled and restore only
        // the injected file below.
        try await runProtectiveBackup(backupRoot: backupRoot, udid: udid) { overall in
            let pct = overall < 0 ? 0 : min(overall, 100)
            self.log(String(format: "protective backup progress: %.0f%%", pct))
        }
        log("Light protective backup complete — session authorized, popup handled.")
        // iOS 27 (and GN's restore_files) does NOT accept a synthetic file-only
        // rebuild: it rejects it PERMANENTLY (validation, not transient).  GN
        // keeps the pulled protective keep-set (springboard + system prefs +
        // home domain + addressbook/messages/posterboard), prunes Manifest.db to
        // that keep-set (clean_backup_for_restore mirror), then on restore it
        // re-prunes the pulled payload the same way and injects the new file.
        log("Keeping the pulled protective keep-set (no discard) and pruning Manifest.db "
            + "to the GN keep-set...")
        let deviceDir = backupRoot.appendingPathComponent(udid)
        try Self.pruneManifestDb(deviceDir: deviceDir)

        let appInfo = try await InstProxy.lookup(bundleID: bundleID)
        log("Target app: \(bundleID) v\(appInfo.version)")

        let domain = "AppDomain-\(bundleID)"
        log("Injecting \(domain)/Documents/\(fileName) into minimal 3.3 backup…")
        try Self.injectFile(
            into: deviceDir,
            domain: domain,
            relativePath: "Documents/\(fileName)",
            contents: data,
            appInfo: appInfo
        )
        log("Partial backup ready (one AppDomain row, no device data pulled).")

        // Stage 2b: restore with iOS-27 TRANSIENT retry.  The device drops
        // the mobilebackup2 channel mid-restore (SpringBoard restart ->
        // BrokenPipe "channel closed" / ConnectionTerminated); that is the
        // EXPECTED transient that GoldenNugget rides out (18x3s).  PoC: 3x3s.
        let code = try await withChannelRetry(label: "partial restore", attempts: 3) {
            try await runRestore(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            log("Partial restore succeeded (exit 0).")
            log("No full backup happened — if the device did NOT erase, iOS 27 accepts file-only 3.3 restores.")
        } else {
            log("restore exited \(code). Inspect the log above.")
        }
    }

    // MARK: - Full PoC

    func runPoC(
        bundleID: String,
        fileName: String = "poc.txt",
        contents: String = "PoC: iOS 27 app container restore OK"
    ) async throws {
        pendingLog = []
        let runStage = StageTimer("RUN full backup→inject→restore")
        defer { runStage.done() }
        let minimuxer = Minimuxer.shared()
        guard await testReady(minimuxer) else {
            throw PoCError("minimuxer is not ready. Ensure WiFi and a working tunnel (LocalDevVPN or WireGuard + em_proxy), then select a pairing file.")
        }
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PoCError("Enter a bundle identifier to target (e.g. com.apple.PosterBoard)")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw PoCError("Could not fetch device UDID")
        }
        log("UDID: \(udid)")
        log("Target bundle: \(bundleID)")
        log("Tunnel: \(Tunnel.describe())")
        try await preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        let data = contents.data(using: .utf8) ?? Data(contents.utf8)
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupRoot = docsDir.absoluteURL.appendingPathComponent(udid, conformingTo: .data)

        // Clean previous backup
        try? FileManager.default.removeItem(at: backupRoot)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // Stage 1: real protective backup
        try await runProtectiveBackup(backupRoot: backupRoot, udid: udid) { overall in
            let pct = overall < 0 ? 0 : min(overall, 100)
            self.log(String(format: "backup progress: %.0f%%", pct))
        }
        log("Protective backup complete.")

        // Stage 2+3: prune + inject
        try await pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            bundleID: bundleID,
            fileName: fileName,
            contents: data
        )

        // Stage 4: restore (same transient channel-drop handling as the
        // partial path — the device can drop the channel here too).
        let code = try await withChannelRetry(label: "restore", attempts: 3) {
            try await runRestore(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            log("PoC restore succeeded (exit 0).")
            log("If the device did NOT erase, iOS 27 app-container restores are safe.")
        } else {
            log("restore exited \(code). Inspect the log above.")
        }
    }

    // MARK: - Helpers

    private func testReady(_ minimuxer: Minimuxer) async -> Bool {
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        return false
    }
}

// MARK: - Backup.swift helpers reused here

private let fm = FileManager.default

private func sha1Hex(_ id: String) -> String {
    Data(Insecure.SHA1.hash(data: id.data(using: .utf8)!))
        .map { String(format: "%02hhx", $0) }.joined()
}

private func ingestFileRow(
    db: OpaquePointer,
    fileID: String,
    domain: String,
    relPath: String,
    flags: Int32,
    blob: Data
) throws {
    var stmt: OpaquePointer?
    let rc = sqlite3_prepare_v2(
        db,
        "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)",
        -1, &stmt, nil
    )
    guard rc == SQLITE_OK, let stmt = stmt else {
        throw PoCError("Failed to prepare INSERT for \(domain)/\(relPath)")
    }
    defer { sqlite3_finalize(stmt) }
    fileID.withCString { cID in
        domain.withCString { cDom in
            relPath.withCString { cRel in
                sqlite3_bind_text(stmt, 1, cID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, cDom, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 3, cRel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int(stmt, 4, flags)
                blob.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blob.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                sqlite3_step(stmt)
            }
        }
    }
}

// MARK: - mobilebackup2 stream trace

/// Thread-safe tally of the Rust delegate traffic during a backup.
///
/// `shouldPreserve` and `onProgress` are invoked from the Rust streaming
/// threads, so every counter sits behind a lock and this type never touches the
/// UI — the caller logs `summary()` / `sampleLines()` from its own flow.
///
/// Diagnostic value: `total == 0` means the device never streamed a single
/// file, i.e. the channel died in the request / version-exchange / session
/// authorization phase.  A non-zero total with a stalled `lastProgress` means
/// the drop happened mid-transfer.  Those two point at different subsystems.
final class BackupTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var keptCount = 0
    private var droppedCount = 0
    private var totalCount = 0
    private var lastPct: Double = -1
    private var lastStep = -1
    private var samples: [String] = []
    private var lastActivity = Date()

    var kept: Int { lock.lock(); defer { lock.unlock() }; return keptCount }
    var dropped: Int { lock.lock(); defer { lock.unlock() }; return droppedCount }

    /// Timestamp of the last sign of life from the device.
    ///
    /// The Rust DeviceLink read has no timeout of its own, so this is the only
    /// thing that separates a slow-but-alive transfer from a wedged one; see
    /// `PoCEngine.withStallGuard`.
    var lastActivityAt: Date { lock.lock(); defer { lock.unlock() }; return lastActivity }

    /// Records one keep/drop decision.  Keeps the first decisions for the log
    /// (the head of the stream is where an unexpected domain shows up first).
    func note(file: String, domain: String, keep: Bool) {
        lock.lock()
        defer { lock.unlock() }
        totalCount += 1
        if keep { keptCount += 1 } else { droppedCount += 1 }
        lastActivity = Date()
        if samples.count < 12 {
            samples.append("  stream[\(totalCount)] \(keep ? "KEEP" : "DROP") \(domain)/\(file)")
        }
    }

    /// Records a progress sample; returns the new 5 % step the first time it is
    /// crossed, else nil (so the caller only logs once per step).
    func noteProgress(_ pct: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        lastPct = pct
        guard pct >= 0 else { return nil }
        let step = Int(pct / 5) * 5
        guard step > lastStep else { return nil }
        lastStep = step
        lastActivity = Date()
        return step
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let progress = lastPct < 0 ? "never reported" : "\(Int(lastPct))%"
        return "streamed=\(totalCount) kept=\(keptCount) dropped=\(droppedCount) progress=\(progress)"
    }

    func sampleLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return ["  (device never streamed a single file)"] }
        return samples
    }
}

// MARK: - Stage timing + heartbeat

/// Wall-clock cost of one stage, reported in the app log.
///
/// Added because "it takes forever" is unactionable: the run has several
/// multi-second-or-multi-minute stages (tunnel probe, minimuxer readiness,
/// each backup attempt, the restore itself) and without per-stage numbers there
/// is no way to tell a slow transfer from a stage that is merely sleeping.
///
/// `done()` is idempotent-ish by convention: call it exactly once per stage.
struct StageTimer {
    private let label: String
    private let start = Date()

    init(_ label: String) { self.label = label }

    func done(_ extra: String = "") {
        let secs = Date().timeIntervalSince(start)
        PoCEngine.shared.log("⏱ \(label): \(String(format: "%.1f", secs))s"
            + (extra.isEmpty ? "" : " — \(extra)"))
    }
}

/// Logs a line every `every` seconds while a long stage runs, so the log shows
/// "still moving" instead of looking hung.
///
/// A stalled backup and a slow one look identical in the UI; the heartbeat
/// separates them (a heartbeat whose detail string never changes = stalled).
final class Heartbeat: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private let start = Date()

    /// - Parameter detail: evaluated on each tick; should be cheap and ideally
    ///   show forward motion (counters, bytes, percentage).
    func start(_ label: String, every seconds: UInt64 = 10,
               detail: @escaping @Sendable () -> String) {
        stop()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { break }
                let secs = Int(Date().timeIntervalSince(self.start))
                PoCEngine.shared.log("⏱ \(label): \(secs)s elapsed — \(detail())")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// Throttles a 0–100 progress callback down to one log line per 5 % step.
///
/// Both the backup and the restore progress callbacks fire per file; the
/// restore one used to be logged verbatim, which appended thousands of lines to
/// the UI list and buried the lines that matter.
final class PercentThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = -1
    private var lastActivity = Date()

    /// Timestamp of the last progress sample; see `PoCEngine.withStallGuard`.
    var lastActivityAt: Date { lock.lock(); defer { lock.unlock() }; return lastActivity }

    /// - Returns: the new 5 % step the first time it is crossed, else nil.
    func step(_ pct: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = Date()
        guard pct >= 0 else { return nil }
        let step = Int(pct / 5) * 5
        guard step > lastStep else { return nil }
        lastStep = step
        return step
    }
}

// MARK: - Stall guard (the Rust read has no timeout of its own)

/// Thrown when the device accepted a connection and then stopped answering.
///
/// Distinct from a dropped channel on purpose: a fresh tunnel does not fix it
/// (attempt 2 in the Rust log proves that — the device accepted the new RSD
/// session and then ignored even the DeviceLink version exchange), so this must
/// fail fast instead of burning another full attempt.
struct DeviceStallError: Error, LocalizedError {
    /// Which silence was detected.  The two have different causes and different
    /// remedies, and the log line should not have to be interpreted by hand.
    enum Kind {
        /// Parked in `dl_version_exchange()` waiting for the device's FIRST
        /// DeviceLink message.  This side has not sent anything yet.
        case handshakeSilent
        /// Handshake completed, then the stream went quiet mid-operation.
        case noProgress
    }

    let label: String
    let idleSeconds: Int
    var kind: Kind = .noProgress

    var errorDescription: String? {
        switch kind {
        case .handshakeSilent:
            return "device never sent its first DeviceLink message during \(label) "
            + "(silent for \(idleSeconds)s). The mobilebackup2 client is a pure reader at this point "
            + "— the device initiates with DLMessageVersionExchange and we only answer — so nothing "
            + "the app sends can cause this, and the currently loaded binary is not a suspect. "
            + "The device-side backup daemon is the one not talking: it wedges on a request it cannot "
            + "process and stays wedged across app restarts, so REBOOT THE DEVICE (重启设备) before "
            + "retrying. Background: scripts/patch-idevice-target-identifier.sh"
        case .noProgress:
            return "the device stopped responding during \(label) — nothing for \(idleSeconds)s "
            + "(it accepted the connection, then went silent: the mobilebackup2 daemon was "
            + "handed a request it cannot process; see scripts/patch-idevice-target-identifier.sh)"
        }
    }
}

/// Resumes a continuation at most once, so whichever of the two racers finishes
/// first wins and the loser is a no-op.
///
/// `withThrowingTaskGroup` cannot express this: leaving the group's scope awaits
/// every child, and the racing body sits in a non-cancellable FFI call, so the
/// group would block exactly where we are trying to escape.
final class OnceResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled = false

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuation = c
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !settled, let c = continuation else {
            lock.unlock()
            return
        }
        settled = true
        continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}

extension PoCEngine {
    /// True when the mobilebackup2 client is parked in the handshake *waiting for
    /// the device to speak first*.
    ///
    /// `dl_version_exchange()` is a pure receive: the device initiates with
    /// `["DLMessageVersionExchange", major, minor]`, our side answers
    /// `DLVersionsOk`, and only then does the device send `DLMessageDeviceReady`.
    /// So a Rust log whose last handshake line is "Starting DeviceLink version
    /// exchange" with no "Received DL message" after it means the client is
    /// blocked in `socket.read_exact` on a device that has said nothing at all.
    ///
    /// That distinction is what makes this check worth having: at this point the
    /// app has sent NOTHING on the DeviceLink channel, so no client-side change
    /// (including a patched FFI library) can be the cause — it can only be the
    /// device-side daemon.  The generic idle guard would take the full 120 s to
    /// notice the same thing, and would not say why.
    ///
    /// - Parameter offset: byte offset to read from; nil = the current run mark.
    static func deviceSilentAtHandshake(since offset: UInt64? = nil) -> Bool {
        let from = offset ?? PoCEngine.shared.rustLogMark
        guard let whole = try? Data(contentsOf: rustLogURL) else { return false }
        let start = Int(min(from ?? 0, UInt64(whole.count)))
        guard let text = String(data: whole.dropFirst(start), encoding: .utf8) else { return false }
        guard let lastStart = text.range(of: "Starting DeviceLink version exchange",
                                         options: .backwards) else {
            return false
        }
        return !text[lastStart.upperBound...].contains("Received DL message")
    }

    /// Runs `body`, but stops *waiting* for it once `idle()` has not moved for
    /// `idleSeconds`.
    ///
    /// Why this is needed: `mobilebackup2_backup` awaits the device's next
    /// DeviceLink message with no deadline, so a device that goes silent leaves
    /// the call blocked forever — no progress, no error, no retry, and a UI that
    /// looks hung.  The activity clock is the transfer itself (the Rust delegate
    /// callbacks), not the clock on the wall, so a legitimately slow upload is
    /// never mistaken for a stuck one.
    ///
    /// `handshakeSilent` is the second, tighter clock: a healthy version exchange
    /// is over in milliseconds, so if the log still shows "waiting for the
    /// device's first DL message" after `silentHandshakeSeconds`, the device is
    /// wedged and there is no point waiting out the long idle window.
    ///
    /// The abandoned call is safe to walk away from: `withFFIDispatch` runs it on
    /// `DispatchQueue.global()`, so other gateway traffic keeps flowing (lockdown
    /// answers throughout the wedged run in the logs).  The thread leaks until the
    /// app restarts, which is acceptable — it only ever happens on a lost run.
    @discardableResult
    static func withStallGuard<T>(
        label: String,
        idleSeconds: Int,
        pollSeconds: UInt64 = 5,
        silentHandshakeSeconds: Int = 45,
        idle: @escaping @Sendable () -> Date,
        handshakeSilent: (@Sendable () -> Bool)? = nil,
        _ body: @escaping () async throws -> T
    ) async throws -> T {
        let once = OnceResumer<T>()
        return try await withCheckedThrowingContinuation { cont in
            once.attach(cont)
            Task {
                do { once.resume(.success(try await body())) }
                catch { once.resume(.failure(error)) }
            }
            Task {
                var silentSince: Date? = nil
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
                    if once.isSettled { return }

                    // Device never opened its side of the DeviceLink conversation:
                    // the request/authorization phase never started, so this is a
                    // device-daemon problem, not a slow transfer.
                    if let handshakeSilent {
                        if handshakeSilent() {
                            let from = silentSince ?? Date()
                            silentSince = from
                            let held = Int(Date().timeIntervalSince(from))
                            if held >= silentHandshakeSeconds {
                                PoCEngine.shared.log("⏱ \(label): device has not sent its first "
                                    + "DeviceLink message for \(held)s — the mobilebackup2 daemon is "
                                    + "not answering (nothing has been sent from this side yet)")
                                once.resume(.failure(DeviceStallError(label: label,
                                                                     idleSeconds: held,
                                                                     kind: .handshakeSilent)))
                                return
                            }
                        } else {
                            silentSince = nil
                        }
                    }

                    let idleFor = Int(Date().timeIntervalSince(idle()))
                    guard idleFor >= idleSeconds else { continue }
                    PoCEngine.shared.log("⏱ \(label): device silent for \(idleFor)s — abandoning the call "
                        + "(the Rust DeviceLink read has no timeout of its own)")
                    once.resume(.failure(DeviceStallError(label: label, idleSeconds: idleFor)))
                    return
                }
            }
        }
    }
}
