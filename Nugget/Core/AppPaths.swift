import Foundation

/// Every on-device path this app owns, in one place.
///
/// These used to be spelled out inline at nine call sites —
/// `FileManager.default.urls(for: .documentDirectory, …)` appeared in the
/// engine, the diagnostics writer, the two log sinks and the view — which made
/// "which file is actually being read?" a grep exercise and left two spellings
/// of the same directory (`URL.documents` and the inline form) side by side.
enum AppPaths {
    /// `<Documents>/poc.log` — the app-side log sink.
    static let appLog = URL.documents.appendingPathComponent("poc.log")

    /// `<Documents>/minimuxer.log` — the Rust `tracing` sink installed by
    /// `enableRustFileLogging()`.
    static let rustLog = URL.documents.appendingPathComponent("minimuxer.log")

    /// `<Documents>/diagnostics.txt` — the last dumped diagnostics block, so it
    /// can be shared as a FILE instead of hand-selecting text in the log list.
    static let diagnostics = URL.documents.appendingPathComponent("diagnostics.txt")

    /// `<Documents>/pairingfile.mobiledevicepairing` — the imported pairing file.
    /// minimuxer reads it from Documents too, so this is the canonical location.
    static let pairingFile = URL.documents.appendingPathComponent("pairingfile.mobiledevicepairing")

    /// `<Documents>/<udid>/` — the full protective backup pulled from the device.
    static func fullBackupRoot(udid: String) -> URL {
        URL.documents.appendingPathComponent(udid, conformingTo: .data)
    }

    /// `<Documents>/<udid>-partial/` — the backup built for the partial-restore
    /// flow.  Deliberately separate from `fullBackupRoot`: the two flows write
    /// different manifest trees and must never stomp each other's baseline.
    static func partialBackupRoot(udid: String) -> URL {
        URL.documents.appendingPathComponent("\(udid)-partial", conformingTo: .data)
    }

    /// `<backupRoot>/<udid>/` — the per-device directory inside a backup root.
    static func deviceDir(backupRoot: URL, udid: String) -> URL {
        backupRoot.appendingPathComponent(udid)
    }
}
