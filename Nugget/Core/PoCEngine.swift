import Foundation
import Minimuxer
import SwiftUI
import Observation

// `@Observable` is the iOS 17 Observation macro, and this target is iOS 16, so
// the type has to be gated or the whole target stops compiling:
//   error: 'Observable()' is only available in iOS 17.0 or newer
//   error: 'ObservationRegistrar' is only available in iOS 17.0 or newer
// Gating it keeps the macro (rather than rewriting it as ObservableObject) and
// costs nothing while nothing uses the type.  If the deployment target is ever
// raised to 17 — `IPHONEOS_DEPLOYMENT_TARGET` in project.yml plus `.iOS(.v17)`
// in Package.swift — this attribute is the one line to delete.
@available(iOS 17.0, *)
@Observable
class Status {
    
}

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
        warnIfPreviousCallStillRunning()
        clearCancel()
        let runStage = StageTimer("RUN full backup→inject→restore")
        defer { runStage.done() }

        let (udid, data) = try await prepareRun(bundleID: bundleID, contents: contents)
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)

        // Stage 1: real protective backup
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid) { overall in
            self.logProgress("backup progress", overall)
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

        // Stage 4: restore.  The device can drop the channel here too.
        try await runRestore(backupRoot: backupRoot, udid: udid, label: "restore") {
            log("PoC restore succeeded: the device confirmed it finished.")
            log("If the device did NOT erase, iOS 27 app-container restores are safe.")
        }
    }

    // MARK: - Shared run plumbing
    //
    // The sequence below is order-sensitive, so it lives in one place.

    /// A run must not start on top of one that was cancelled but is still
    /// running, and this makes that state visible.
    ///
    /// A blocking FFI call cannot be interrupted, so Stop only walks away from
    /// it — and `clearCancel()` at the top of a run clears the very flag that
    /// was going to make the abandoned call unwind. A second mobilebackup2
    /// exchange started in that window is two sessions on one RSD adapter, which
    /// is the hazard `InFlightCall` exists to record.
    ///
    /// This WARNS rather than blocks, deliberately. Blocking is the safer
    /// default, but an abandoned call may never drain at all, which would turn
    /// "press Stop" into "press Stop, then force-quit the app" — a worse failure
    /// than the one it prevents. The state is logged instead, so it is never
    /// invisible; flip it to `InFlightCall.waitUntilDrained(seconds:)` if that
    /// trade ever looks wrong.
    ///
    /// Must run BEFORE `clearCancel()`: clearing first erases the signal the
    /// previous run is still waiting on.
    private func warnIfPreviousCallStillRunning() {
        guard InFlightCall.shared.isBusy else { return }
        log("⚠️ a previous device call is still running "
            + "(\(InFlightCall.shared.abandonedDescription)) — starting a new run on top of it. "
            + "If that call was cancelled it may still hold the session, so a failure from here that "
            + "looks like a device problem may be two sessions sharing one RSD adapter: force-quit "
            + "the app, then run again.")
    }

    /// Everything both flows do before touching the device.
    ///
    /// Returns the device UDID (needed to name the backup root) and the payload
    /// already encoded.  Throws `PoCError` for the operator-facing failures.
    private func prepareRun(
        bundleID: String,
        contents: String
    ) async throws -> (udid: String, data: Data) {
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

        return (udid, contents.data(using: .utf8) ?? Data(contents.utf8))
    }

    /// Start from an empty backup root.  Both flows need this: the manifest is
    /// merged into, not replaced, so a leftover Manifest.db from a previous run
    /// would leak its rows (and its pruned keep-set) into this one.
    private func resetDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Clamp and throttle a Rust progress callback down to whole percent.
    ///
    /// The callback fires per file; logging every call appended thousands of
    /// lines and pushed the interesting ones out of the UI list.
    private func logProgress(_ prefix: String, _ overall: Double) {
        let pct = overall < 0 ? 0 : min(overall, 100)
        log(String(format: "\(prefix): %.0f%%", pct))
    }

    /// Stage 4: one mobilebackup2 restore, with the iOS-27 transient-channel
    /// retry in front of it.
    ///
    /// `onSuccess` carries only the success wording — the two flows describe
    /// their outcome differently, but the failure line is the same.
    private func runRestore(
        backupRoot: URL,
        udid: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // Say what is being offered before offering it.  Every recorded "the
        // restore said success but only part came back" run so far has had to be
        // reconstructed from the prune / inject / placeholder lines after the
        // fact; this puts the same numbers in one place, at the moment they are
        // still actionable.
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        log(ManifestStore(deviceDir: deviceDir).auditAgainstDisk())

        let code = try await ChannelRecovery.retry(
            label: label,
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            onSuccess()
        } else {
            // Unreachable while RestoreRunner verifies its own outcome, but kept
            // so a future path that stops doing so cannot fail silently.
            log("restore returned \(code) without confirming completion — inspect the log above.")
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
