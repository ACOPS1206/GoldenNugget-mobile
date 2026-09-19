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

        let fileDigest = Data(Insecure.SHA1.hash(data: contents))
        let dataprotection = buildDataprotectionExtendedAttributes()

        for row in rows {
            let isFile = row.flags == 1
            let blob = buildMBFileBlob(
                relativePath: row.path,
                mode: isFile
                    ? (UInt32(MODE_DEFAULT) | UInt32(S_IFREG))
                    : (UInt32(MODE_DEFAULT) | UInt32(S_IFDIR)),
                size: isFile ? contents.count : 0,
                isDirectory: !isFile,
                digest: isFile ? fileDigest : nil,
                extendedAttributes: isFile ? dataprotection : nil
            )
            try store.upsert(
                fileID: ManifestStore.fileID(domain: domain, relativePath: row.path),
                domain: domain,
                relativePath: row.path,
                flags: row.flags,
                blob: blob
            )
        }

        // 3. Register the app so the restore daemon accepts the domain.
        try HostManifests.registerApp(deviceDir: deviceDir, app: appInfo)

        AppLog.write("Injected \(domain)/\(relativePath) (fileID=\(fileID))")
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
