import CryptoKit
import Foundation
import Minimuxer

/// The Lock Screen Footnote tweak, ported from GoldenNugget's
/// "Lock Screen Footnote Text" (`src/tweaks/`).
///
/// Reference chain: `registry.py` defines it as a `BasicPlistTweak` against
/// `FileLocation.footnote`, whose only consumer is the key `LockScreenFootnote`
/// in `SharedDeviceConfiguration.plist`; the file is emitted as
/// `plistlib.dumps({"LockScreenFootnote": text})` — a WHOLE-file replacement —
/// and mapped to a backup domain by `path_mapping.py`:
///
///     /var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/...
///       → SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles
///       +  Library/ConfigurationProfiles/SharedDeviceConfiguration.plist
///
/// The text shows at the bottom of the Lock Screen under the clock. Long text
/// is cut off — keep it short. An empty value clears an existing footnote,
/// which is also how GoldenNugget's "leave empty to remove" works.
///
/// `BackupInjector.injectSystemPlist` is the only delivery channel: it injects
/// these bytes into the pulled protective backup's manifest. The domain, the
/// path and the plist encoding are stated once, here.
enum LockScreenFootnoteTweak {
    static let domain = "SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles"
    static let relativePath = "Library/ConfigurationProfiles/SharedDeviceConfiguration.plist"

    /// The whole-file plist for one footnote text. `text` may be empty (explicit
    /// reset) — the caller decides whether to send the file at all.
    static func contents(text: String) throws -> Data {
        let plist: [String: Any] = ["LockScreenFootnote": text]
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml, options: 0)
    }
}

/// Builds the rows and payload that turn "one file for one app" into a restorable
/// backup.
///
/// The whole point of the PoC: take the backup the device just gave us, make the
/// manifest agree with what is actually on disk, then add a single
/// `AppDomain-<bundleId>/Documents/<file>` on top and restore.
///
/// Two file classes are injected, and they do **not** share a row shape: an app
/// container (`inject` — needs the bundle registered, 501/501, protection class
/// 3) and a system-container plist (`injectSystemPlist` — no registration,
/// `nobody`, class 4).  The split is not cosmetic; the shapes come from the
/// device's own rows for each class.
enum BackupInjector {
    /// Inject one file into an existing backup directory.
    ///
    /// Writes the payload, creates the directory + file rows in Manifest.db, and
    /// registers the app in Manifest.plist / Info.plist.
    static func inject(
        into deviceDir: URL,
        domain: String,
        relativePath: String,
        contents: Data,
        appInfo: NuggetAppInfo
    ) throws {
        let fileID = ManifestStore.fileID(domain: domain, relativePath: relativePath)
        let store = ManifestStore(deviceDir: deviceDir)
        let fm = FileManager.default

        // 1. Write the payload where the fileID says it lives.
        let payloadDir = store.payloadURL(forFileID: fileID).deletingLastPathComponent()
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try contents.write(to: store.payloadURL(forFileID: fileID))

        // 2. Insert rows.
        //
        //    One flags=2 directory row per parent path component (domain root
        //    first), each keyed by sha1("<domain>-<dirRel>"), then one flags=1
        //    file row keyed by sha1("<domain>-<relativePath>").
        //
        //    The dir rows MUST NOT reuse the file row's ID: on a fresh empty
        //    Manifest.db a PRIMARY KEY collision would make the file-row INSERT
        //    fail and the restore would silently do nothing.
        let parentComponents = (relativePath as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)

        var rows: [(path: String, flags: Int32)] = [("", 2)]   // domain root dir
        var accumulated = ""
        for component in parentComponents {
            accumulated = accumulated.isEmpty ? component : "\(accumulated)/\(component)"
            rows.append((accumulated, 2))
        }
        rows.append((relativePath, 1))                          // the file itself

        let dataprotection = buildDataprotectionExtendedAttributes()

        for row in rows {
            let isFile = row.flags == 1
            let rowID = ManifestStore.fileID(domain: domain, relativePath: row.path)
            // Every field below is copied from the shape the device writes for
            // the same kind of row — see `MBFileBlob`'s constants for the
            // measurement. A record the device did not write itself is the one
            // place a wrong value cannot be repaired by re-uploading, which is
            // why these are not "reasonable defaults" but the observed values.
            let blob = buildMBFileBlob(
                relativePath: row.path,
                // `Int`, not `UInt32`: the archived `Mode` has to be an inline
                // integer or the device cannot read the file type out of the row
                // (MBErrorDomain/205 — "Invalid file type: 00").  See
                // `MBFileArchiver.mode`.
                mode: isFile
                    ? (Int(MODE_FILE_DEFAULT) | Int(S_IFREG))
                    : (Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)),
                size: isFile ? contents.count : 0,
                protectionClass: isFile ? PROTECTION_CLASS_FILE : PROTECTION_CLASS_DIR,
                inodeNumber: inode(for: rowID),
                extendedAttributes: isFile ? dataprotection : nil
            )
            try store.upsert(
                fileID: rowID,
                domain: domain,
                relativePath: row.path,
                flags: row.flags,
                blob: blob
            )
        }

        // 3. Register the app so the restore daemon accepts the domain.
        try HostManifests.registerApp(deviceDir: deviceDir, app: appInfo)

        AppLog.write("Injected \(domain)/\(relativePath) (fileID=\(fileID))")
        // The device reads a "file type" out of these blobs, and the four rows
        // written just above are the only ones in this backup that are not the
        // device's own. Log both key sets side by side so the next run can say
        // whether they differ — see `blobKeySample`.
        AppLog.write(store.blobKeySample(ours: fileID))
    }

    /// Inject one file that is NOT an app container — currently only the Lock
    /// Screen footnote, a `SysSharedContainerDomain` plist.
    ///
    /// `inject` above cannot carry this one, for two independent reasons:
    ///
    ///   1. It registers an app bundle.  Registration exists for exactly one
    ///      reason — the restore daemon answers `MBErrorDomain/205 "Unknown domain
    ///      name in file record"` for an `AppDomain-*` payload whose bundle is
    ///      missing from `Manifest.plist`'s `Applications` dict.  A
    ///      `SysSharedContainerDomain` is not in that family and has no bundle to
    ///      register, which is also why the reference delivers its
    ///      `BasicPlistTweak` files with no registration at all.
    ///   2. It writes the app-container row shape.  The device writes a different
    ///      one for a system-container plist, and a row it did not write itself is
    ///      the one place a wrong value cannot be repaired by re-uploading.
    ///
    /// Measured off the device's own record for the exact file this delivers
    /// (`MobileSync/Backup/00008130-001431082E40001C`, fileID
    /// `0affc9c4722175be11a30bb60e96880ffedf29d5` =
    /// `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles` /
    /// `Library/ConfigurationProfiles/SharedDeviceConfiguration.plist`):
    ///
    ///     file row    Mode 0o100644  UserID -2  GroupID -2  ProtectionClass 4  EA ✓
    ///     inner dirs  Mode 0o40755   UserID -2  GroupID -2  ProtectionClass 4  EA ✗
    ///     domain root Mode 0o40755   UserID  0  GroupID  0  ProtectionClass 0  EA ✗
    ///
    /// `-2` is Darwin's `nobody`, and it is what the device records for this path
    /// (sibling rows in the same domain mix `501` and `-2`, so the value is
    /// per-row, not per-domain — this copies the row for *this* file).  The
    /// extended attribute is the same `com.apple.dataprotection.policy
    /// .exception-applied-by` an app-container row carries, so the "only app
    /// containers get one" rule does not hold for this class either.
    ///
    /// The owner is a deliberate divergence from the Python: GoldenNugget's
    /// `Tweak.__init__` defaults to `owner=501, group=501`, so its synthesized
    /// footnote row says `501` where the device's own row for the same path says
    /// `-2`.  The device's record wins here (nothing else in this repo copies a
    /// Python default against a measurement), and what IS copied from the
    /// reference is the part it does get right: no `Applications` registration
    /// for a non-`AppDomain-*` domain.
    ///
    /// Only regular files carry a payload; the directory rows are the path
    /// scaffolding the restore agent renames into place (dropping them makes it
    /// fail with `renameatx ENOENT` — see the prune's `flags == 2` rule).
    static func injectSystemPlist(
        into deviceDir: URL,
        domain: String,
        relativePath: String,
        contents: Data
    ) throws {
        let fileID = ManifestStore.fileID(domain: domain, relativePath: relativePath)
        let store = ManifestStore(deviceDir: deviceDir)
        let fm = FileManager.default

        // 1. Payload where the fileID says it lives.  Same shard layout as every
        //    other row: this is the join between the database and the tree.
        let payloadDir = store.payloadURL(forFileID: fileID).deletingLastPathComponent()
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try contents.write(to: store.payloadURL(forFileID: fileID))

        // 2. Rows: domain root, one per parent component, then the file itself.
        //    Same ordering rule as `inject` — dirs first, so a PRIMARY KEY
        //    collision with the file row is impossible on a fresh Manifest.db.
        var rows: [(path: String, flags: Int32)] = [("", 2)]
        var accumulated = ""
        for component in relativePath.split(separator: "/").dropLast() {
            accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
            rows.append((accumulated, 2))
        }
        rows.append((relativePath, 1))

        let dataprotection = buildDataprotectionExtendedAttributes()
        let now = Int(Date().timeIntervalSince1970)
        // Darwin's `nobody`, i.e. the -2 the device stores for a system-container
        // file.  A negative id is legitimate here: it is what `uid_t` 4294967294
        // round-trips to in the archive, and the device produced that value
        // itself.
        let systemOwner = -2

        for row in rows {
            let isFile = row.flags == 1
            // The domain root row is the single exception in the measurement
            // above: the device writes 0/0 at protection class 0 there, while
            // every row below it is `nobody` at class 4.
            let isRoot = row.path.isEmpty
            let owner = isRoot ? 0 : systemOwner
            let rowID = ManifestStore.fileID(domain: domain, relativePath: row.path)
            let blob = buildMBFileBlob(
                relativePath: row.path,
                mode: isFile
                    ? (Int(MODE_FILE_DEFAULT) | Int(S_IFREG))
                    : (Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)),
                size: isFile ? contents.count : 0,
                userID: owner,
                groupID: owner,
                protectionClass: isRoot ? PROTECTION_CLASS_DIR : PROTECTION_CLASS_SYSTEM_FILE,
                inodeNumber: inode(for: rowID),
                timestamp: now,
                // Only the file row carries one, per the measurement above.
                extendedAttributes: isFile ? dataprotection : nil)
            try store.upsert(fileID: rowID, domain: domain,
                             relativePath: row.path, flags: row.flags, blob: blob)
        }

        AppLog.write("Injected system plist \(domain)/\(relativePath) "
            + "(fileID=\(fileID), \(contents.count) bytes, owner \(systemOwner), class "
            + "\(PROTECTION_CLASS_SYSTEM_FILE))")
        AppLog.write(store.blobKeySample(ours: fileID))
    }

    /// A stable, plausible inode for one manifest row.
    ///
    /// The device writes an `InodeNumber` on every row it creates (4000/4000
    /// sampled `AppDomain-*` file rows) and never 0, and two rows sharing an
    /// inode would be a lie about the tree.  Derived from the `fileID`, so a
    /// re-run reproduces the same numbers, and mapped into the band the device's
    /// own inodes occupy (87278…1306390 in that backup) rather than an obviously
    /// synthetic value.
    static func inode(for fileID: String) -> Int {
        let head = Insecure.SHA1.hash(data: Data(fileID.utf8))
            .prefix(4)
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return 100_000 + Int(head % 900_000)
    }

    /// Stage 2+3 of the full flow: ensure the host-side metadata, prune the
    /// device's manifest down to what is on disk, then inject what the run is
    /// delivering.
    ///
    /// Three kinds of payload can ride this stage, and each is injected *after*
    /// the prune for the same reason: the prune keeps only the reference's
    /// keep-set, and none of these rows are in it — a row written before the
    /// prune would be deleted on the way past.
    ///
    ///   * the app-container file (`bundleID` given) — needs the bundle
    ///     registered in `Manifest.plist`;
    ///   * the Lock Screen footnote (`footnote` given) — a system-container
    ///     plist, no registration;
    ///   * the compiled plist tweaks (`tweakPayloads`) — a set of files across
    ///     the domains `TweakRowProfile` describes.
    ///
    /// `bundleID` is optional because GoldenNugget's tweak-only apply carries no
    /// app container at all (`device_manager._apply_tweak_pass` builds the file
    /// list from the tweaks alone).
    static func pruneAndInject(
        backupRoot: URL,
        udid: String,
        bundleID: String?,
        fileName: String,
        contents: Data,
        footnote: String? = nil,
        tweakPayloads: [TweakPayload] = []
    ) async throws {
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        let store = ManifestStore(deviceDir: deviceDir)

        // Fallback: if the device did not upload the host-side backup metadata
        // (Info.plist / Status.plist / Manifest.plist), write minimal valid ones
        // — restore refuses a backup without them.
        let manifestStage = StageTimer("ensure host-side manifests")
        try HostManifests.ensure(deviceDir: deviceDir, udid: udid)
        manifestStage.done()

        AppLog.write("Pruning Manifest.db…")
        let pruneStage = StageTimer("prune Manifest.db")
        store.pruneToDiskState()
        pruneStage.done()

        if let bundleID, !bundleID.isEmpty {
            let lookupStage = StageTimer("InstProxy lookup \(bundleID)")
            let appInfo = try await InstProxy.lookup(bundleID: bundleID)
            lookupStage.done("v\(appInfo.version)")
            AppLog.write("Target app: \(bundleID) v\(appInfo.version)")

            let domain = "AppDomain-\(bundleID)"
            AppLog.write("Injecting \(domain)/Documents/\(fileName)…")
            let injectStage = StageTimer("inject")
            try inject(into: deviceDir,
                       domain: domain,
                       relativePath: "Documents/\(fileName)",
                       contents: contents,
                       appInfo: appInfo)
            injectStage.done()
        }

        // No app registration: see `injectSystemPlist`.
        if let footnote, !footnote.isEmpty {
            AppLog.write("Injecting footnote "
                + "\(LockScreenFootnoteTweak.domain)/\(LockScreenFootnoteTweak.relativePath)…")
            let footnoteStage = StageTimer("inject footnote")
            try injectSystemPlist(into: deviceDir, domain: LockScreenFootnoteTweak.domain,
                                  relativePath: LockScreenFootnoteTweak.relativePath,
                                  contents: try LockScreenFootnoteTweak.contents(text: footnote))
            footnoteStage.done()
        }

        if !tweakPayloads.isEmpty {
            let tweakStage = StageTimer("inject tweaks")
            AppLog.write("Injecting \(tweakPayloads.count) tweak file(s)…")
            let report = try TweakInjector.inject(into: deviceDir, payloads: tweakPayloads)
            tweakStage.done(report.summary)
            AppLog.write("Tweaks injected: \(report.summary)")
            for domain in report.unverifiedDomains {
                AppLog.write("note: the \(domain) row shape is measured from the device's own "
                    + "backup but has not been confirmed by a run yet")
            }
        }
    }
}
