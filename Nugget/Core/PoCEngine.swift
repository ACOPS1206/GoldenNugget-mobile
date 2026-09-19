import Foundation
import Minimuxer

/// An error whose message is meant for the operator, not for a stack trace.
struct PoCError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// On-device PoC: prove that iOS 27's "safe state recovery" wipe does NOT
// trigger when restoring a single app container (no tweak plists involved).
//
// Flow (mirrors GoldenNugget but without photos/video):
//   1. Real protective backup via mobilebackup2 — triggers the iOS 27
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
//
// This type is the run orchestrator and the app-facing facade.  The work itself
// lives in `Core/`: `ProtectiveBackup` (stage 1), `BackupInjector` (stages 2-3),
// `RestoreRunner` (stage 4), with `ChannelRecovery` / `StallGuard` /
// `TransportFailure` handling the retry and silence verdicts, `ManifestStore`
// owning the manifest, `RustLog` + `WireCensus` reading the Rust evidence, and
// `AppLog` being the process-wide log bus.  The facade is kept so the SwiftUI
// layer does not have to know any of that.
class PoCEngine {
    static let shared = PoCEngine()

    private init() {}

    // MARK: - Logging facade

    /// Every line this run produced, in order — the in-memory sink.
    var pendingLog: [String] { AppLog.shared.memory.snapshot }

    /// Route engine log lines into the UI list.
    var onLog: ((String) -> Void)? {
        didSet { AppLog.shared.setUIHandler(onLog) }
    }

    func log(_ msg: String) {
        AppLog.shared.log(msg)
    }

    /// Result of the one-time Rust logger init; see `RustLog.initResult`.
    var rustLogInitResult: Int32? { RustLog.initResult }

    /// Byte offset into `minimuxer.log` taken at the start of the current run.
    var rustLogMark: UInt64? { RustLog.mark }

    // MARK: - Cancellation facade

    var cancelRequested: Bool { CancelFlag.shared.isRequested }

    func requestCancel() { CancelFlag.shared.request() }

    func clearCancel() { CancelFlag.shared.clear() }

    // MARK: - Paths facade

    static var appLogURL: URL { AppPaths.appLog }
    static var rustLogURL: URL { AppPaths.rustLog }
    static var diagnosticsURL: URL { AppPaths.diagnostics }

    static func rustLogSize() -> UInt64 { RustLog.size() }
    static func appLogSize() -> UInt64 { AppLog.shared.file.size() }
    static func rustLogStatus() -> String { RustLog.status() }

    /// Remember the log offset so the next excerpt covers only THIS run.
    @discardableResult
    func markRustLog() -> UInt64 { RustLog.markStart() }

    // MARK: - Rust logging

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
        let path = AppPaths.rustLog.path

        let rc: Int32
        if let gateway = Minimuxer.shared().ideviceGateway {
            rc = gateway.enableRustFileLogging(to: path)
        } else {
            rc = -99
        }
        RustLog.noteInitResult(rc)

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

    // MARK: - Diagnostics

    /// The failure dump; see `Diagnostics.report()`.
    func diagnostics() async -> String {
        await Diagnostics.report()
    }

    // MARK: - Run: full backup → inject → restore

    func runPoC(
        bundleID: String,
        fileName: String = "poc.txt",
        contents: String = "PoC: iOS 27 app container restore OK"
    ) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
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
        try await Diagnostics.preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        let data = contents.data(using: .utf8) ?? Data(contents.utf8)
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)

        // Clean previous backup
        try? FileManager.default.removeItem(at: backupRoot)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // Stage 1: real protective backup
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid) { overall in
            let pct = overall < 0 ? 0 : min(overall, 100)
            self.log(String(format: "backup progress: %.0f%%", pct))
        }
        log("Protective backup complete.")

        // Stage 2+3: prune + inject
        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            bundleID: bundleID,
            fileName: fileName,
            contents: data
        )

        // Stage 4: restore (same transient channel-drop handling as the
        // partial path — the device can drop the channel here too).
        let code = try await ChannelRecovery.retry(
            label: "restore",
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            log("PoC restore succeeded (exit 0).")
            log("If the device did NOT erase, iOS 27 app-container restores are safe.")
        } else {
            log("restore exited \(code). Inspect the log above.")
        }
    }

    // MARK: - Run: partial restore (light protective auth + minimal 3.3 backup)

    /// Restore ONLY the injected app container file via a minimal backup 3.3
    /// built host-side — the full protective data pull is NOT restored.
    ///
    /// Unlike the original "file-only, no backup" design, a *lightweight*
    /// protective backup is still performed FIRST.  On iOS 27 the restore
    /// daemon refuses a mobilebackup2 restore from an un-authorized session
    /// and simply closes the channel (BrokenPipe "channel closed") with NO
    /// popup on the device.  The light protective backup is what triggers the
    /// Trust / backup-password popup and authorizes the session; it is
    /// selective (empty Applications, no photos/videos — see
    /// `ProtectiveBackup.isProtectiveFile`), so it runs fast.  Its uploaded
    /// data is then pruned to the GN keep-set and the injected file is added
    /// on top, which is what actually gets restored.
    ///
    /// Backup layout written to `<Documents>/<udid>-partial/<udid>/`:
    ///   - Manifest.db   pulled from the device, pruned, then one AppDomain row
    ///   - Status.plist  Version 3.3
    ///   - Manifest.plist / Info.plist with the target app registered
    ///   - payload file under `<fileID.prefix(2)>/<fileID>`
    func runPartialRestore(
        bundleID: String,
        fileName: String = "poc.txt",
        contents: String = "PoC: iOS 27 partial container restore OK"
    ) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
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
        try await Diagnostics.preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        let data = contents.data(using: .utf8) ?? Data(contents.utf8)
        let backupRoot = AppPaths.partialBackupRoot(udid: udid)

        // Clean previous partial backup
        try? FileManager.default.removeItem(at: backupRoot)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // Stage 0b: LIGHT protective backup.  On iOS 27 the restore daemon
        // refuses a mobilebackup2 restore from an un-authorized session and
        // just closes the channel (BrokenPipe "channel closed") with NO popup.
        // A protective backup is what triggers the Trust / backup-password
        // popup and authorizes the session.  This one is selective (empty
        // Applications, drains photos/videos) per `ProtectiveBackup.run`, so
        // it is fast — then we keep only its protective keep-set and add the
        // injected file on top.
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid) { overall in
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
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        ManifestStore(deviceDir: deviceDir).pruneToDiskState()

        let appInfo = try await InstProxy.lookup(bundleID: bundleID)
        log("Target app: \(bundleID) v\(appInfo.version)")

        let domain = "AppDomain-\(bundleID)"
        log("Injecting \(domain)/Documents/\(fileName) into minimal 3.3 backup…")
        try BackupInjector.inject(
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
        let code = try await ChannelRecovery.retry(
            label: "partial restore",
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            log("Partial restore succeeded (exit 0).")
            log("No full backup happened — if the device did NOT erase, iOS 27 accepts file-only 3.3 restores.")
        } else {
            log("restore exited \(code). Inspect the log above.")
        }
    }

    // MARK: - Readiness

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
