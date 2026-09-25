import Foundation
import SQLite3
import Minimuxer

/// `SQLITE_TRANSIENT` is a C macro, so the module never sees it. It is `-1`:
/// tell sqlite to copy the bytes rather than keep the pointer, which matters
/// because the Swift string temporaries die the moment the bind returns.
///
/// The cast target is the typedef, so the constant already has the optional
/// function-pointer type the bind functions declare.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The three host-side backup metadata files.
///
/// pymobiledevice3 pre-creates these BEFORE the backup: the device's first DL
/// message is a DownloadFiles request for `<udid>/Status.plist`, and the backup
/// aborts instantly if it is missing.  A restore refuses a backup without them
/// too, so both flows call `ensure` before touching anything else.
enum HostManifests {
    /// Write `Status.plist` / `Manifest.plist` / `Info.plist` if any is missing.
    ///
    /// The device uploads `Manifest.db` in the stream, but never these three —
    /// they are a host responsibility.  Contents are filled in as far as the
    /// host can know them; the injector adds the target app afterwards.
    /// `isFullBackup` is the other half of this, and the two callers genuinely
    /// disagree:
    ///
    /// - The injector synthesises a backup for a *restore*, so it is sparse: the
    ///   manifest lists exactly the payloads being injected and the device
    ///   reconciles against that list. That is what `IsFullBackup: false` means.
    /// - The protective pull wants the opposite. The device streams, and the
    ///   host filter drops what it does not want, so the manifest must not
    ///   constrain the stream to a list -- there is no list yet. A sparse marker
    ///   here asks the device to send "whatever the manifest says", which is
    ///   nothing, which is the very symptom the pull was built to avoid.
    ///
    /// So this is a parameter rather than a constant. Getting it wrong is
    /// silent: the transfer completes, having moved nothing.
    static func ensure(deviceDir: URL,
                       udid: String,
                       ios27: Bool = true,
                       isFullBackup: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        // The version split is the reference's: `Backup.manifest_ios27`
        // (`backup.py:113`), set from the product version at
        // `restore.py:1065-1074`. iOS 26 speaks the legacy MBDB format and
        // declares Status 2.4 / Manifest 9.1+20.0; iOS 27+ uses the sqlite
        // Manifest.db and 3.3 / 10.0+24.0.
        //
        // `IsFullBackup` is the sparse marker and matters most here: this backup
        // is built from nothing, so declaring it full would tell the device to
        // reconcile against content that was never sent.
        let statusURL = deviceDir.appendingPathComponent("Status.plist")
        if !fm.fileExists(atPath: statusURL.path) || isFullBackup {
            let status: [String: Any] = [
                "BackupState": "new",
                "Date": Date(),
                "IsFullBackup": isFullBackup,
                "Version": ios27 ? "3.3" : "2.4",
                "SnapshotState": "finished",
                "UUID": UUID().uuidString.uppercased(),
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: status,
                                                              format: .binary, options: 0) {
                try? data.write(to: statusURL)
            }
        }

        // Manifest.plist — seeded empty; the injector fills Applications.
        let manifestURL = deviceDir.appendingPathComponent("Manifest.plist")
        if !fm.fileExists(atPath: manifestURL.path) {
            try? PropertyListSerialization.data(fromPropertyList: ["DataProtection": true,
                                                                   "Lockdown": [:],
                                                                   "SystemDomainsVersion": ios27 ? "24.0" : "20.0",
                                                                   "Version": ios27 ? "10.0" : "9.1",
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

    /// The sqlite `Manifest.db`, which iOS 27 asks the *host* for.
    ///
    /// The three plists above are the whole host-side story on iOS 26, and this
    /// was written as though that held for 27 too. It does not: on 27 the
    /// device's second DL message is a DownloadFiles request for
    /// `<udid>/Manifest.db`, and a host that cannot serve it fails the request
    /// (`not found (-6)` in the Rust log) and abandons the transfer before a
    /// single payload is offered. That is the whole "kept 0 of 0, 3 seconds"
    /// protective failure -- there was nothing to filter because nothing was
    /// ever sent.
    ///
    /// Schema and properties are libimobiledevice's, and the table is seeded
    /// empty on purpose: this is the "nothing backed up previously" answer, so
    /// the device sends the full set rather than a delta against a backup that
    /// does not exist. A populated table here would be worse than an error --
    /// the device would stream only the rows it finds and stop.
    static func writeSQLiteManifest(deviceDir: URL, ios27: Bool) throws {
        guard ios27 else { return }
        let url = deviceDir.appendingPathComponent("Manifest.db")
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw NSError(domain: "HostManifests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Manifest.db: \(why)"])
        }
        defer { sqlite3_close(db) }

        // SQLite wants the pages written before the handle goes away, and a
        // half-built manifest is worse than none: the device would read it and
        // believe it.
        guard sqlite3_exec(db, """
            PRAGMA journal_mode=DELETE;
            CREATE TABLE ManifestEntry (
                domain TEXT,
                relative_path TEXT,
                flags INTEGER,
                file BLOB
            );
            CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB);
            """, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "HostManifests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Manifest.db schema: \(String(cString: sqlite3_errmsg(db)))"])
        }

        let properties: [(String, String)] = [
            ("Version", "3.3"),
            ("Date", String(Int(Date().timeIntervalSince1970))),
            ("SystemDomainsVersion", "24.0"),
            ("WasPasscodeSet", "false"),
        ]
        // The C function returns a status and hands the statement back through
        // an out-parameter; there is no convenience overlay that returns it.
        var insert: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "INSERT INTO Properties (key, value) VALUES (?, ?)",
                                          -1, &insert, nil)
        guard prepared == SQLITE_OK, let insert else {
            throw NSError(domain: "HostManifests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Manifest.db properties: \(String(cString: sqlite3_errmsg(db)))"])
        }
        for (key, value) in properties {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insert, 2, value, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw NSError(domain: "HostManifests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Manifest.db property \(key): \(String(cString: sqlite3_errmsg(db)))"])
            }
        }

        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "VACUUM;", nil, nil, &err)
        sqlite3_free(err)
    }

    /// Wipe `<backupRoot>/<udid>/` and re-seed the host-side manifests.
    static func reset(backupRoot: URL, udid: String) throws {
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        try? FileManager.default.removeItem(at: deviceDir)
        try ensure(deviceDir: deviceDir, udid: udid)
    }
}
