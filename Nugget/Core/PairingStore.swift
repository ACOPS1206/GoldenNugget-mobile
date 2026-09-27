import Foundation
import SwiftUI

/// The imported pairing record: one app-wide store, not page state.
///
/// Why this exists.  The record itself was durable all along —
/// `Documents/pairingfile.mobiledevicepairing` plus a `PairingFile` mirror in
/// `UserDefaults` — but **whether the app considered itself paired was not**.
/// That lived in `@State private var pairingFileURL: String?` on
/// `GoldenNuggetView`, filled in by `reimportPairingFile()` from the view's own
/// `.task`.  So the durable data and the flag that made the UI say "paired"
/// were two separate things, and only one of them survived a view being
/// re-created.  Every way SwiftUI can hand the home page a new identity — a
/// relaunch, and the split view rebuilding its detail column when the window's
/// size class changes (Slide Over, Split View, iPadOS 26's free resize) —
/// dropped the flag while the file stayed on disk, which reads exactly as "the
/// pairing file is gone after a restart / after switching tabs".
///
/// The store removes the second thing.  `raw` and `url` live in a process-wide
/// singleton no view owns, so a re-created view reads the same answer the last
/// one did, and `bootstrap()` is cheap and idempotent enough to also serve as
/// a self-heal on every appearance.
///
/// Main thread, like the rest of the app's view-facing state.
final class PairingStore: ObservableObject {
    static let shared = PairingStore()

    /// The canonical file.  minimuxer reads the record out of Documents too, so
    /// this path — not the `UserDefaults` copy — is what "imported" means.
    private let destination = AppPaths.pairingFile

    private let defaults = UserDefaults.standard
    /// The pre-existing key.  A mirror of the record, so a Documents file that
    /// went missing (container migration, a wipe) is survivable.
    private static let rawKey = "PairingFile"
    /// Persisted on purpose.  "Reset pairing file" has to outlive the process:
    /// the installer's embedded `ALTPairingFile` is a build-time artefact, and
    /// without a durable flag the next launch picks it straight back up and
    /// silently re-pairs a device the user just unpaired.
    private static let embeddedDisabledKey = "PairingFileEmbeddedImportDisabled"

    /// The record's contents, or nil when there is none.
    @Published private(set) var raw: String?
    /// The canonical file — non-nil exactly when `raw` is.
    @Published private(set) var url: URL?

    private init() {}

    var isPaired: Bool { raw != nil }

    // MARK: - Restore

    /// Make the store agree with what is actually persisted, and report whether
    /// there is a usable record.
    ///
    /// Cheap and idempotent: when the in-memory record is already the one on
    /// disk it reads nothing else, so calling it on every appearance costs one
    /// file read rather than a plist parse per candidate.
    @discardableResult
    func bootstrap() -> Bool {
        if let raw, Self.normalized(try? String(contentsOf: destination, encoding: .utf8)) == raw {
            return true
        }

        let embeddedDisabled = defaults.bool(forKey: Self.embeddedDisabledKey)
        let embedded = embeddedDisabled
            ? nil
            : (Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String)

        // On disk first, then the mirror, then the installer's record: a file
        // the user imported outranks a build-time artefact, because re-pairs
        // are per-device.  Each is validated before use, so a corrupt file on
        // disk falls through to the next one instead of blocking the launch.
        let candidates: [(source: String, raw: String?)] = [
            ("Documents/\(destination.lastPathComponent)",
             try? String(contentsOf: destination, encoding: .utf8)),
            ("stored PairingFile", defaults.string(forKey: Self.rawKey)),
            ("Info.plist ALTPairingFile", embedded),
        ]

        for (source, candidate) in candidates {
            guard let value = Self.normalized(candidate) else { continue }
            guard Self.usablePairingRecord(value) else {
                GoldenNuggetEngine.shared.log("pairing record rejected (\(source)): "
                                              + "\(Self.sourceLabel(value))")
                continue
            }
            publish(value, source: source)
            return true
        }

        // Nothing usable anywhere.  Do not leave a stale record behind: it
        // would make `isPaired` true and the UI promise a connection that
        // cannot exist.
        let hadStored = defaults.string(forKey: Self.rawKey) != nil
        url = nil
        raw = nil
        if hadStored {
            defaults.removeObject(forKey: Self.rawKey)
            GoldenNuggetEngine.shared.log("stored pairing record was unusable — cleared, "
                                          + "import a pairing file to connect")
        } else if !embeddedDisabled && embedded == nil {
            GoldenNuggetEngine.shared.log("no pairing record: none on disk, none stored, "
                                          + "and the installer embedded no ALTPairingFile")
        }
        return false
    }

    // MARK: - Import

    /// Import a pairing record the user picked.
    ///
    /// Document-picker URLs are security-scoped: reading one without
    /// `startAccessingSecurityScopedResource` fails with "you don't have
    /// permission to view it".  So the file is copied into Documents and only
    /// that stable path is used afterwards — minimuxer reads from Documents too.
    ///
    /// The record is validated **here**, not only on the way back in.  The old
    /// import path accepted anything, while `bootstrap()` accepted only a plist
    /// carrying a UDID — so a file the restore path would reject was imported
    /// happily, showed "paired" for the rest of the session, and then came back
    /// from the next launch as "no pairing file".
    func importFrom(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let value = try String(contentsOf: source, encoding: .utf8)
        guard let normalized = Self.normalized(value) else {
            throw PairingStoreError.empty
        }
        guard Self.usablePairingRecord(normalized) else {
            let detail = Self.sourceLabel(normalized)
            GoldenNuggetEngine.shared.log("pairing file rejected at import: \(detail)")
            throw PairingStoreError.unusable(detail)
        }
        // An explicit import is the user's answer to a previous reset.
        defaults.set(false, forKey: Self.embeddedDisabledKey)
        publish(normalized, source: "imported \(source.lastPathComponent)")
    }

    /// Drop the record for good: in memory, in `UserDefaults`, and on disk.
    ///
    /// Deleting the file is the part that used to be missing.  `bootstrap()`
    /// reads Documents *first*, so leaving the file behind meant a relaunch —
    /// which starts again from "the user has not said no" — picked the record
    /// straight back up and undid the reset.
    func reset() {
        defaults.set(true, forKey: Self.embeddedDisabledKey)
        defaults.removeObject(forKey: Self.rawKey)
        raw = nil
        url = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            do {
                try fm.removeItem(at: destination)
                GoldenNuggetEngine.shared.log("pairing file reset: "
                                              + "\(destination.lastPathComponent) deleted")
            } catch {
                GoldenNuggetEngine.shared.log("pairing file reset: could not delete "
                                              + "\(destination.lastPathComponent): "
                                              + "\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Plumbing

    /// Adopt a validated record: write the canonical file when it differs, then
    /// mirror it into `UserDefaults` and publish both halves.
    private func publish(_ value: String, source: String) {
        let onDisk = Self.normalized(try? String(contentsOf: destination, encoding: .utf8))
        if onDisk == value {
            GoldenNuggetEngine.shared.log("pairing record: \(source) (\(Self.sourceLabel(value)))")
        } else {
            do {
                try value.write(to: destination, atomically: true, encoding: .utf8)
                GoldenNuggetEngine.shared.log("pairing record re-imported from \(source) into "
                                              + "\(destination.lastPathComponent) "
                                              + "(\(Self.sourceLabel(value)))")
            } catch {
                // Not fatal to *this* session: the record is published below
                // and minimuxer is handed the string directly.  What is lost is
                // the durable Documents copy, which is worth saying out loud
                // because that is the file the next launch reads first.
                GoldenNuggetEngine.shared.log("pairing record found (\(source)) but could not "
                                              + "be written to Documents: \(error.localizedDescription)")
            }
        }
        defaults.set(value, forKey: Self.rawKey)
        raw = value
        url = destination
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// A record is usable only if it is a plist with a non-empty top-level
    /// `UDID` — that key is what minimuxer's `start()` reads first, and it logs
    /// "Couldn't get UDID" and stops when it is missing.
    static func usablePairingRecord(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data,
                                                                    options: [],
                                                                    format: nil),
              let dict = obj as? [String: Any]
        else { return false }
        return (dict["UDID"] as? String)?.isEmpty == false
    }

    /// What a candidate record actually contains, for the log line: a rejected
    /// record has to be diagnosable from the log alone, because the alternative
    /// on a phone is "minimuxer did not start" with nothing to go on.
    private static func sourceLabel(_ raw: String) -> String {
        guard let keys = topLevelKeys(raw) else { return "not a parseable plist" }
        let listed = keys.isEmpty ? "(no keys)" : keys.sorted().joined(separator: ", ")
        return "keys: \(listed)\(keys.contains("UDID") ? " [UDID]" : " [no UDID]")"
    }

    /// The record's top-level keys.  minimuxer's `start()` demands a top-level
    /// "UDID" string; if it is absent the library logs "Couldn't get UDID" and
    /// fails before any device or tunnel work.
    static func topLevelKeys(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data,
                                                                    options: [],
                                                                    format: nil),
              let dict = obj as? [String: Any]
        else { return nil }
        return Array(dict.keys)
    }
}

/// What the import can refuse, in words the alert can show.
enum PairingStoreError: LocalizedError {
    case empty
    case unusable(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "That file is empty."
        case .unusable(let detail):
            return "Not a usable pairing record (\(detail)). A pairing file has to be a "
                + "plist carrying a top-level UDID string — that key is what minimuxer "
                + "reads first, and it stops without it."
        }
    }
}
