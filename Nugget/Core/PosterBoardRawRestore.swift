import Foundation
import ZIPFoundation

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
