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
    static func ensure(deviceDir: URL, udid: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

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

        // Manifest.plist — seeded empty; the injector fills Applications.
        let manifestURL = deviceDir.appendingPathComponent("Manifest.plist")
        if !fm.fileExists(atPath: manifestURL.path) {
            try? PropertyListSerialization.data(fromPropertyList: ["DataProtection": true,
                                                                   "Lockdown": [:],
                                                                   "SystemDomainsVersion": "24.0",
                                                                   "Version": "10.0",
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
