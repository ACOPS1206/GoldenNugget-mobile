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
/// Which PosterBoard extension a descriptor pack belongs to.
///
/// A pack that ships a bare `descriptors/<UUID>` tree does not say which
/// extension owns it — the path on the device does, and the pack has no copy of
/// that path. The reference asks the user at import time and remembers the
/// answer (`TendieItem.posterType`, `TendiesModel.swift`), because the injection
/// target is built from it:
/// `…/PRBPosterExtensionDataStore/<version>/Extensions/<extensionBundleId>/descriptors`.
///
/// Getting this wrong does not fail loudly. A descriptor injected under the
/// wrong extension id lands in a folder PosterBoard's provider never reads, so
/// the wallpaper simply does not appear.
enum PosterBoardPosterType: String, CaseIterable, Identifiable, Codable {
    case collections
    case suggestedPhotos
    case mercury
    case container

    var id: String { rawValue }

    /// The reference's `TendiePosterType.extensionBundleId`.
    var extensionBundleID: String {
        switch self {
        case .collections: return "com.apple.WallpaperKit.CollectionsPoster"
        case .suggestedPhotos: return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        case .mercury: return "com.apple.MercuryPoster"
        case .container: return "com.apple.PosterBoard"
        }
    }

    var label: String {
        switch self {
        case .collections: return "Collections"
        case .suggestedPhotos: return "Suggested Photos"
        case .mercury: return "Mercury"
        case .container: return "App Container"
        }
    }

    var systemImage: String {
        switch self {
        case .collections: return "paintpalette.fill"
        case .suggestedPhotos: return "photo.fill"
        case .mercury: return "sparkles"
        case .container: return "shippingbox.fill"
        }
    }

    /// A `container/` snapshot is its own kind of pack, so it defaults to the
    /// type named after it rather than to Collections.
    static func defaultForContainer(_ isContainer: Bool) -> PosterBoardPosterType {
        isContainer ? .container : .collections
    }
}

struct PosterBoardTendie: Identifiable, Hashable {
    let id = UUID()
    /// Where the pack lives in this app's container, so it survives a launch.
    let url: URL
    /// The file name the reference would show (`os.path.basename`).
    let name: String
    let descriptorCount: Int
    let isContainer: Bool
    let isUnsafeContainer: Bool
    /// Which extension this pack's descriptors are injected under. User-chosen,
    /// because the pack does not carry it; see `PosterBoardPosterType`.
    var posterType: PosterBoardPosterType

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
        // The provider this pack is *for*, read off its own paths, and nil when
        // nothing said. The reference does this in the same walk
        // (`TendiesEngine.swift`: a `/container/` path sets `.container`, then a
        // descriptor path overrides it with mercury or photos). Order matters
        // there and it is preserved here: the container rule runs on the way down
        // and the descriptor rule on the way into the payload, so a snapshot
        // ends up as the provider it snapshots rather than as `.container`.
        var detected: PosterBoardPosterType?
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
            if lower.contains("/container/") || lower.hasSuffix("/container") {
                detected = .container
            }
            // `descriptor/` and `descriptors/` are mutually exclusive as
            // substrings (`"descriptor/"` is not in `"descriptors/…"`), and the
            // reference tests them in that order — so the second is only reached
            // by the plural spelling.
            let marker = lower.contains("descriptor/") ? "descriptor/"
                : (lower.contains("descriptors/") ? "descriptors/" : nil)
            guard let marker else { continue }
            if lower.contains("video") || lower.contains("photos") {
                detected = .suggestedPhotos
            } else if lower.contains("mercury") {
                detected = .mercury
            } else if detected != .container {
                detected = .collections
            }
            if let tail = lower.components(separatedBy: marker).dropFirst().first {
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
        self.posterType = PosterBoardPreferences.posterTypes[url.lastPathComponent]
            ?? detected ?? .defaultForContainer(container)
    }

    /// Remember a poster type for this pack, and return the pack with it set.
    ///
    /// The pack is re-read from its archive on every launch, so the answer cannot
    /// live in the pack — it goes to the one store that outlives a launch, keyed
    /// by file name. Losing it is not catastrophic: the type falls back to
    /// Collections. A wallpaper that silently stops appearing is, so it is written
    /// the moment it changes rather than at Apply time.
    func settingPosterType(_ type: PosterBoardPosterType) -> PosterBoardTendie {
        var copy = self
        copy.posterType = type
        var types = PosterBoardPreferences.posterTypes
        types[url.lastPathComponent] = type
        PosterBoardPreferences.posterTypes = types
        return copy
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


// MARK: - Mac raw descriptor restore

/// Byte-preserving PosterBoard descriptor restore.
///
/// Direct port of the macOS GoldenNugget RawDescriptorTendie recovery path:
/// - accepts only descriptor/descriptors-root archives
/// - verifies one supported provider from suggestionMetadata
/// - preserves descriptor UUIDs, embedded identifiers, paths and file bytes
/// - emits AppDomain-com.apple.PosterBoard payloads under the iOS 26 store
enum PosterBoardRawRestore {
    private static let structureVersion = 61
    private static let descriptorRoots: Set<String> = ["descriptor", "descriptors"]
    private static let suggestionMetadata =
        "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist"

    private static let allowedProviders: Set<String> = [
        "com.apple.WallpaperKit.CollectionsPoster",
        "com.apple.MercuryPoster",
        "com.apple.PhotosUIPrivate.PhotosPosterProvider",
    ]

    private struct ExtractedFile {
        let local: URL
        let relativePath: String
    }

    static func compile(
        packs: [PosterBoardTendie],
        workingDirectory: URL,
        log: @escaping (String) -> Void
    ) throws -> [TweakPayload] {
        guard !packs.isEmpty else {
            throw GoldenNuggetError("No PosterBoard packs were selected for raw restore.")
        }

        let fm = FileManager.default
        try? fm.removeItem(at: workingDirectory)
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        var payloads: [TweakPayload] = []
        var descriptorTotal = 0

        for (index, pack) in packs.enumerated() {
            let stage = workingDirectory.appendingPathComponent(
                String(format: "%03d-%@", index, PosterBoard.sanitised(pack.name)),
                isDirectory: true
            )
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)

            let compiled = try compilePack(pack, stage: stage, log: log)
            descriptorTotal += compiled.descriptorCount
            guard descriptorTotal <= PosterBoardImports.descriptorLimit else {
                throw GoldenNuggetError(
                    "Raw restore would carry \(descriptorTotal) descriptors; the limit is "
                    + "\(PosterBoardImports.descriptorLimit)."
                )
            }

            let restoreRoot = PosterBoard.storePath(structureVersion)
                + "/Extensions/\(compiled.provider)/descriptors"
            for file in compiled.files {
                payloads.append(TweakPayload(
                    domain: PosterBoard.domain,
                    relativePath: restoreRoot + "/" + file.relativePath,
                    source: file.local
                ))
            }

            log("Raw restore: \(pack.name) → \(compiled.provider), "
                + "\(compiled.descriptorCount) descriptor(s), "
                + "\(compiled.files.count) file(s), UUIDs/IDs preserved")
        }

        guard !payloads.isEmpty else {
            throw GoldenNuggetError("The selected packs contained no raw descriptor files.")
        }
        log("Raw restore: \(payloads.count) byte-preserving payload(s) ready.")
        return payloads
    }

    private static func compilePack(
        _ pack: PosterBoardTendie,
        stage: URL,
        log: @escaping (String) -> Void
    ) throws -> (provider: String, descriptorCount: Int, files: [ExtractedFile]) {
        let archive: Archive
        do {
            archive = try Archive(url: pack.url, accessMode: .read)
        } catch {
            throw GoldenNuggetError(
                "\(pack.name) is not a readable .tendies archive: \(error.localizedDescription)"
            )
        }

        var descriptorNames = Set<String>()
        var extracted: [ExtractedFile] = []
        var metadataByDescriptor: [String: Set<String>] = [:]
        var seenDestinations = Set<String>()

        for entry in archive {
            let rawPath = entry.path
            guard !rawPath.contains("\\"),
                  !rawPath.hasPrefix("/") else {
                throw GoldenNuggetError("\(pack.name): unsafe archive path \(rawPath)")
            }

            let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            if parts.isEmpty { continue }
            if parts.contains("..") {
                throw GoldenNuggetError("\(pack.name): '..' path components are not allowed.")
            }

            if parts[0].lowercased() == "__macosx"
                || parts.contains(".DS_Store")
                || parts.contains(where: { $0.hasPrefix("._") }) {
                continue
            }

            guard descriptorRoots.contains(parts[0].lowercased()) else {
                throw GoldenNuggetError(
                    "\(pack.name): Mac raw restore accepts only descriptor/descriptors-root packs."
                )
            }
            guard parts.count >= 2 else { continue }

            let descriptorName = parts[1]
            descriptorNames.insert(descriptorName)
            guard descriptorNames.count <= PosterBoardImports.descriptorLimit else {
                throw GoldenNuggetError(
                    "\(pack.name): raw restore accepts at most "
                    + "\(PosterBoardImports.descriptorLimit) descriptors."
                )
            }

            if entry.type == .directory { continue }
            guard entry.type == .file else {
                throw GoldenNuggetError(
                    "\(pack.name): symbolic links or special ZIP entries are not allowed."
                )
            }

            let relativeComponents = Array(parts.dropFirst())
            let relativePath = relativeComponents.joined(separator: "/")
            let destinationKey = relativePath.lowercased()
            guard seenDestinations.insert(destinationKey).inserted else {
                throw GoldenNuggetError(
                    "\(pack.name): duplicate raw descriptor path: \(relativePath)"
                )
            }

            var local = stage
            for component in relativeComponents {
                local.appendPathComponent(component)
            }
            try fm.createDirectory(
                at: local.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fm.removeItem(at: local)
            _ = try archive.extract(entry, to: local)
            extracted.append(ExtractedFile(local: local, relativePath: relativePath))

            if parts.count == 3 && parts[2] == suggestionMetadata {
                let data = try Data(contentsOf: local)
                let plist = try PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                )
                metadataByDescriptor[descriptorName] = Set(plistStrings(plist))
            }
        }

        guard !descriptorNames.isEmpty, !extracted.isEmpty else {
            throw GoldenNuggetError("\(pack.name): no descriptors were found.")
        }

        var providers = Set<String>()
        for descriptor in descriptorNames.sorted() {
            let strings = metadataByDescriptor[descriptor] ?? []
            let matches = allowedProviders.intersection(strings)
            guard matches.count == 1, let provider = matches.first else {
                throw GoldenNuggetError(
                    "\(pack.name): \(descriptor) is not verified as exactly one supported "
                    + "PosterBoard provider in suggestionMetadata."
                )
            }
            providers.insert(provider)
        }

        guard providers.count == 1, let provider = providers.first else {
            throw GoldenNuggetError(
                "\(pack.name): one raw archive cannot mix PosterBoard providers."
            )
        }

        log("Raw restore validation: provider=\(provider), descriptors="
            + descriptorNames.sorted().joined(separator: ", "))
        return (provider, descriptorNames.count, extracted)
    }

    private static func plistStrings(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let dict = value as? [AnyHashable: Any] {
            var result: [String] = []
            for (key, item) in dict {
                result += plistStrings(key)
                result += plistStrings(item)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.flatMap { plistStrings($0) }
        }
        return []
    }
}

