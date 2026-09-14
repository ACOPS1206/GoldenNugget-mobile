import CryptoKit
import Foundation

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
// Two stages, exactly like minimuxer's backup+restore cycle:
//   1. Build a synthethic backup holding the target app's Documents container
//      with one injected txt file (AppDomain-<bundleId>/Documents/poc.txt).
//   2. Restore it via the mobilebackup2 protocol (idevicebackup2 restore),
//      NOT via sparse restore. If the device does not wipe -> PoC passes.
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

    // (Stage 1) Build the synthetic backup directory for a single AppDomain
    func writePoCBackup(bundleID: String, fileName: String, contents: Data, udid: String) throws -> URL {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupRoot = docsDir.absoluteURL
        let folder = backupRoot.appendingPathComponent(udid, conformingTo: .data)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let domain = "AppDomain-" + bundleID
        let appInfo = try InstProxy.lookup(bundleID: bundleID)
        log("Registered app: \(bundleID) path=\(appInfo.path) version=\(appInfo.version)")

        var backupFiles: [BackupFile] = []
        backupFiles.append(Directory(path: "", domain: domain))
        backupFiles.append(Directory(path: "Documents", domain: domain))
        backupFiles.append(ConcreteFile(path: "Documents/\(fileName)", domain: domain, contents: contents, owner: 501, group: 501))

        let app = BackupApp(identifier: bundleID, path: appInfo.path,
                            version: appInfo.version,
                            containerContentClass: "Data/Application")
        let backup = Backup(files: backupFiles, apps: [app])
        try backup.writeTo(directory: folder)
        log("Wrote synthetic backup to \(folder.path)")
        return backupRoot
    }

    // (Stage 2) Restore via mobilebackup2 (not sparse restore)
    @discardableResult
    func runRestore(backupRoot: URL) throws -> Int32 {
        let restoreArgs = [
            "idevicebackup2",
            "-n", "restore", "--no-reboot", "--system",
            backupRoot.path(percentEncoded: false)
        ]
        log("Executing: \(restoreArgs.joined(separator: " "))")
        var argv = restoreArgs.map { strdup($0) }
        let result = idevicebackup2_main(Int32(restoreArgs.count), &argv)
        log("idevicebackup2 exited with code \(result)")
        return result
    }

    // Run the whole PoC: write file into <bundleID>'s Documents, then restore.
    func runPoC(bundleID: String, fileName: String = "poc.txt", contents: String = "PoC: iOS 27 app container restore OK") throws {
        pendingLog = []
        guard ready() else {
            throw PoCError("minimuxer is not ready. Ensure WiFi + WireGuard VPN and select a pairing file.")
        }
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PoCError("Enter a bundle identifier to target (e.g. com.apple.PosterBoard)")
        }
        guard let udid = fetch_udid()?.toString() else {
            throw PoCError("Could not fetch device UDID")
        }
        log("UDID: \(udid)")
        log("Target bundle: \(bundleID)")

        let data = contents.data(using: .utf8) ?? Data(contents.utf8)
        let backupRoot = try writePoCBackup(bundleID: bundleID, fileName: fileName, contents: data, udid: udid)
        let code = try runRestore(backupRoot: backupRoot)

        if code == 0 {
            log("✅ PoC restore succeeded (exit 0).")
            log("If the device did NOT erase, iOS 27 app-container restores are safe.")
        } else {
            log("❌ idevicebackup2 exited \(code). Inspect the log above.")
        }
    }
}