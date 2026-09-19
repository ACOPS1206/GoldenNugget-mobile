import Foundation
import Minimuxer

/// Stage 4: hand the prepared backup back to the device.
enum RestoreRunner {
    /// Run one mobilebackup2 restore of `backupRoot`.
    ///
    /// Always returns 0 on success — the exit code the original code path
    /// propagated was never anything else, and the failure case throws.
    @discardableResult
    static func run(backupRoot: URL, sourceIdentifier: String) async throws -> Int32 {
        let minimuxer = Minimuxer.shared()
        AppLog.write("Restoring backup at \(backupRoot.path) (source \(sourceIdentifier)) via mobilebackup2…")

        let beat = Heartbeat()
        let stage = StageTimer("restore")
        // The restore progress callback fires per file.  Logging every callback
        // appended thousands of lines to the UI list (janky to scroll, and the
        // interesting lines get pushed out) — throttle to 5 % steps like the
        // backup path.
        let progress = PercentThrottle()
        beat.start("restore") {
            progress.livenessLine() + ", " + WireCensus.healthLine()
        }

        // Same missing-deadline problem as the backup path.  Longer idle window
        // than the backup: a restore negotiates, rewrites the manifest and
        // reboots, and several of those phases report no per-file progress.
        // Same two-part verdict as the backup: quiet with the device still
        // answering lockdown is waited out (up to 10 min), quiet and gone is not.
        try await StallGuard.run(
            label: "restore",
            idleSeconds: 180,
            maxIdleSeconds: 600,
            idle: { progress.lastActivityAt },
            wire: { WireCensus.totals() },
            probe: { await Diagnostics.deviceLivenessProbe() },
            handshakeSilent: { RustLog.deviceSilentAtHandshake() }
        ) {
            try await minimuxer.restoreBackup(
                backupRoot: backupRoot.path(percentEncoded: false),
                sourceIdentifier: sourceIdentifier,
                shouldReboot: false,
                systemFiles: true,
                onProgress: { overall in
                    let pct = overall < 0 ? 0 : min(overall, 100)
                    if let step = progress.step(pct) {
                        AppLog.write("restore progress: \(step)%")
                    }
                },
                // Without this the host-side half of the exchange is invisible:
                // a file the device asked for and the host could not read is
                // answered with an error code the device may well sit on, and
                // nothing anywhere said so.
                delegateLog: { line in AppLog.write(line) }
            )
        }

        beat.stop()
        stage.done()
        return 0
    }
}
