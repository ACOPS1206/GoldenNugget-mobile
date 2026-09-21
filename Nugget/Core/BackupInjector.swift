import CryptoKit
import Foundation
import Minimuxer

/// Builds the rows and payload that turn "one file for one app" into a restorable
/// backup.
///
/// The whole point of the PoC: take the backup the device just gave us, make the
/// manifest agree with what is actually on disk, then add a single
/// `AppDomain-<bundleId>/Documents/<file>` on top and restore.
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

    /// A stable, plausible inode for one manifest row.
    ///
    /// The device writes an `InodeNumber` on every row it creates (4000/4000
    /// sampled `AppDomain-*` file rows) and never 0, and two rows sharing an
    /// inode would be a lie about the tree.  Derived from the `fileID`, so a
    /// re-run reproduces the same numbers, and mapped into the band the device's
    /// own inodes occupy (87278…1306390 in that backup) rather than an obviously
    /// synthetic value.
    private static func inode(for fileID: String) -> Int {
        let head = Insecure.SHA1.hash(data: Data(fileID.utf8))
            .prefix(4)
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return 100_000 + Int(head % 900_000)
    }

    /// Stage 2+3 of the full flow: ensure the host-side metadata, prune the
    /// device's manifest down to what is on disk, then inject the target file.
    static func pruneAndInject(
        backupRoot: URL,
        udid: String,
        bundleID: String,
        fileName: String,
        contents: Data
    ) async throws {
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)

        // Fallback: if the device did not upload the host-side backup metadata
        // (Info.plist / Status.plist / Manifest.plist), write minimal valid ones
        // — restore refuses a backup without them.
        let manifestStage = StageTimer("ensure host-side manifests")
        try HostManifests.ensure(deviceDir: deviceDir, udid: udid)
        manifestStage.done()

        AppLog.write("Pruning Manifest.db…")
        let pruneStage = StageTimer("prune Manifest.db")
        ManifestStore(deviceDir: deviceDir).pruneToDiskState()
        pruneStage.done()

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
}
