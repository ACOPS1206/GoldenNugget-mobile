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

    func log(_ msg: String) {
        print(msg)
        pendingLog.append(msg)
        DispatchQueue.main.async {
            self.onLog?(msg)
        }
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

        // pymobiledevice3 pre-creates the host-side backup metadata BEFORE the
        // backup: the device's first DL message is a DownloadFiles request for
        // <udid>/Status.plist, and the backup aborts instantly if it's missing.
        let deviceDir = backupRoot.appendingPathComponent(udid)
        try Self.ensureHostSideManifests(deviceDir: deviceDir, udid: udid)

        try await minimuxer.backupBackup(
            backupRoot: backupRoot.path(percentEncoded: false),
            sourceIdentifier: udid,
            skipAppContainers: true,
            shouldPreserve: { deviceName, file in
                if PoCEngine.isMetadataFile(file) { return true }
                return PoCEngine.isProtectiveFile(deviceName)
            },
            onProgress: onProgress
        )
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
        try Self.ensureHostSideManifests(deviceDir: deviceDir, udid: udid)

        // Prune
        log("Pruning Manifest.db…")
        Self.pruneManifestDb(deviceDir: deviceDir)

        // Lookup target app
        let appInfo = try await InstProxy.lookup(bundleID: bundleID)
        log("Target app: \(bundleID) v\(appInfo.version)")

        // Inject poc.txt
        let domain = "AppDomain-\(bundleID)"
        log("Injecting \(domain)/Documents/\(fileName)…")
        try Self.injectFile(
            into: deviceDir,
            domain: domain,
            relativePath: "Documents/\(fileName)",
            contents: contents,
            appInfo: appInfo
        )
    }

    // MARK: - Stage 4: Restore

    @discardableResult
    func runRestore(backupRoot: URL, sourceIdentifier: String) async throws -> Int32 {
        let minimuxer = Minimuxer.shared()
        log("Restoring backup at \(backupRoot.path) (source \(sourceIdentifier)) via mobilebackup2…")
        try await minimuxer.restoreBackup(
            backupRoot: backupRoot.path(percentEncoded: false),
            sourceIdentifier: sourceIdentifier,
            shouldReboot: false,
            systemFiles: true,
            onProgress: { overall in
                let pct = overall < 0 ? 0 : min(overall, 100)
                PoCEngine.shared.log(String(format: "restore progress: %.0f%%", pct))
            }
        )
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
        var code: Int32 = -1
        var restoreAttempt = 0
        let maxRestoreAttempts = 3
        while restoreAttempt < maxRestoreAttempts {
            restoreAttempt += 1
            do {
                code = try await runRestore(backupRoot: backupRoot, sourceIdentifier: udid)
                break
            } catch {
                if restoreAttempt >= maxRestoreAttempts || !Self.isTransientRestoreError(error) {
                    throw error
                }
                log("Restore attempt \(restoreAttempt)/\(maxRestoreAttempts) hit transient channel-closed; waiting 3 s...")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
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

        // Stage 4: restore
        let code = try await runRestore(backupRoot: backupRoot, sourceIdentifier: udid)

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
