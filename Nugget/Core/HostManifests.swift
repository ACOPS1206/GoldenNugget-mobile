import Foundation
import Minimuxer

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
    static func ensure(deviceDir: URL, udid: String, ios27: Bool = true) throws {
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
        if !fm.fileExists(atPath: statusURL.path) {
            let status: [String: Any] = [
                "BackupState": "new",
                "Date": Date(),
                "IsFullBackup": false,
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

    /// Wipe `<backupRoot>/<udid>/` and re-seed the host-side manifests.
    static func reset(backupRoot: URL, udid: String) throws {
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        try? FileManager.default.removeItem(at: deviceDir)
        try ensure(deviceDir: deviceDir, udid: udid)
    }
}
