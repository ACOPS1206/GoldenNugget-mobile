import Foundation
import ZIPFoundation

/// An imported `.tendies` wallpaper pack, as the reference reads it.
///
/// A port of `src/tweaks/posterboard/tendie_file.py`. The file is a ZIP whose
/// entries decide three things the UI and the apply both need:
///
///   * how many descriptors it carries — the reference caps a selection at 10
///     (`PosterboardTweak.verify_tendie`), because PosterBoard's picker gets
///     unusable past that;
///   * whether it carries a `container/` — a full data-store snapshot rather
///     than a descriptor, which is a different delivery path (`recursive_add`'s
///     `container` branch);
///   * whether that container carries the PosterBoard **database** itself, in
///     which case the reference calls it `unsafe_container` and tells the user
///     they may need a full wallpaper reset first.  That is not a scare: a
///     database stitched from a stale snapshot lands on the device with row
///     sets the live store does not have.
///
/// The counting rules are the reference's, including the two case-sensitivity
/// quirks in it — `__MACOSX` is matched on the lowercased name, the database
/// file name on the raw one.  Both are reproduced rather than tidied, because
/// either could be load-bearing for a pack in the wild.
struct PosterBoardTendie: Identifiable, Hashable {
    let id = UUID()
    /// Where the pack lives in this app's container, so it survives a launch.
    let url: URL
    /// The file name the reference would show (`os.path.basename`).
    let name: String
    let descriptorCount: Int
    let isContainer: Bool
    let isUnsafeContainer: Bool

    /// The exact name `TendieFile` looks for inside a `container/` pack.
    static let databaseEntryName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

    init(url: URL) throws {
        self.url = url
        self.name = url.lastPathComponent

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw GoldenNuggetError("\(url.lastPathComponent) is not a readable .tendies "
                + "archive: \(error.localizedDescription)")
        }

        var descriptors = 0
        var container = false
        var unsafeContainer = false
        for entry in archive {
            let path = entry.path
            let lower = path.lowercased()
            if lower.contains("__macosx/") { continue }
            if lower.contains("container") {
                container = true
                // Raw case, as in the reference: the entry it is looking for is
                // spelled exactly this way inside a container dump.
                if path.contains(Self.databaseEntryName) { unsafeContainer = true }
            }
            // `descriptor/` and `descriptors/` are mutually exclusive as
            // substrings (`"descriptor/"` is not in `"descriptors/…"`), and the
            // reference tests them in that order — so the second is only reached
            // by the plural spelling.
            let marker = lower.contains("descriptor/") ? "descriptor/"
                : (lower.contains("descriptors/") ? "descriptors/" : nil)
            if let marker, let tail = lower.components(separatedBy: marker).dropFirst().first {
                // One level under the marker, and a directory: `UUID/`.
                if tail.filter({ $0 == "/" }).count == 1 && tail.hasSuffix("/") {
                    descriptors += 1
                }
            }
        }

        if descriptors == 0 && !container {
            throw GoldenNuggetError("\(url.lastPathComponent) holds no descriptor and no "
                + "container — it does not look like a .tendies pack.")
        }
        self.descriptorCount = descriptors
        self.isContainer = container
        self.isUnsafeContainer = unsafeContainer
    }

    /// A one-line description for the row, including the reference's warning.
    var summary: String {
        if isContainer {
            return isUnsafeContainer
                ? "container, carries the database — upstream says reset all wallpapers first"
                : "container snapshot"
        }
        return descriptorCount == 1 ? "1 descriptor" : "\(descriptorCount) descriptors"
    }

    /// Unpack into `destination`, exactly as `TendieFile.extract` does.
    ///
    /// Every entry is written under `destination` and a path that would escape
    /// it is refused: the reference hands the archive straight to
    /// `zipfile.extractall`, which is safe only because CPython sanitises entry
    /// names — reproducing that with `URL(fileURLWithPath:)` needs the check
    /// spelled out.
    func extract(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive {
            let relative = entry.path
            guard !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else {
                throw GoldenNuggetError("\(name): the archive holds an entry that escapes the "
                    + "extraction directory (\(relative)).")
            }
            let target = URL(fileURLWithPath: root + "/" + relative)
            guard target.standardizedFileURL.path.hasPrefix(root) else {
                throw GoldenNuggetError("\(name): refusing to write \(relative) outside the "
                    + "extraction directory.")
            }
            // A directory entry can legitimately be repeated or already exist
            // (some zips carry both `a/` and `a/b`), and the reference's
            // `extractall` merges them.
            if entry.type == .directory, fm.fileExists(atPath: target.path) { continue }
            _ = try archive.extract(entry, to: target)
        }
    }
}

/// The imported packs, as files in this app's container.
///
/// The reference keeps its tendie list in memory (`tweaks[TweakID.PosterBoard]`)
/// and loses it on exit.  A pack is tens of megabytes that the user picked by
/// hand through the document picker, so here the **directory is the list**: a
/// pack is imported once, stays on disk, and the page shows what it finds.  That
/// is a deliberate divergence, and the only one in this area — nothing about
/// what reaches the device changes.
enum PosterBoardImports {
    static var directory: URL {
        URL.documents.appendingPathComponent("PosterBoard/Imports", conformingTo: .data)
    }

    /// A name that is not taken yet, so a second import of the same pack does
    /// not overwrite the first.
    static func uniqueDestination(for name: String) -> URL {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return directory.appendingPathComponent(AfcFileExplorer.uniqueName(name, against: existing),
                                                conformingTo: .data)
    }

    /// Copy a picked file into the container and describe it.
    ///
    /// Copies rather than references: the picker's URL is security-scoped and
    /// its access ends with the callback, so a pack kept by reference would be
    /// unreadable on the next apply.
    static func `import`(from source: URL) throws -> PosterBoardTendie {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw GoldenNuggetError("Could not copy \(source.lastPathComponent) into the app: "
                + error.localizedDescription)
        }
        do {
            return try PosterBoardTendie(url: destination)
        } catch {
            // Not a pack: leave nothing behind for the next launch to trip over.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Every imported pack, newest last, in file-name order.
    static func load() -> [PosterBoardTendie] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { try? PosterBoardTendie(url: directory.appendingPathComponent($0)) }
    }

    static func remove(_ tendie: PosterBoardTendie) {
        try? FileManager.default.removeItem(at: tendie.url)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The reference's cap (`PosterboardTweak.verify_tendie`).
    static let descriptorLimit = 10
}
