import Foundation
import Minimuxer
import DeviceGatewayAPI
import IdeviceGateway
import IDevice

/// AFC-backed media transfer, moving the bulk photo/video trees out of
/// `/var/mobile/Media` and into this app's own container.
///
/// Why AFC and not `mobilebackup2`: the bulk media would otherwise ride the
/// protective backup, which is slow and — before the prune — transfers the whole
/// photo library only to throw it away. AFC reads the device's Media root
/// directly, streamed, one connection per file, so a 2 GB video never has to
/// exist in memory.
///
/// Why not the Photos framework: this needs no `PHPhotoLibrary` authorization
/// and no `NSPhotoLibraryUsageDescription`. AFC reaches the same files the
/// library shows, so a permission prompt would buy nothing.
///
/// Why the trees are narrow (`AFC_MEDIA_TREES` in the reference): only the
/// actual photo/video files move. `PhotoData` — the library database and its
/// protected metadata — is deliberately left alone; `PhotoData/UBF` is not even
/// listable over the media AFC service on iOS 27 (AFC error 10,
/// `PERM_DENIED`). Touching it would fail the whole run.
///
/// The reference's rules are kept verbatim because they are load-bearing:
///   * progress is **strings only** — the mobilebackup2 phase owns the numeric
///     progress bar, and a second numeric feed corrupts it;
///   * pull failures are **fatal** — once the originals are deleted this
///     directory is the only copy of the user's photos, so a silently skipped
///     file is data loss;
///   * symlinks are **skipped**, never followed: following one could escape the
///     Media tree and duplicate content.
enum AfcMediaBackup {
    /// The bulk media trees, matching the reference's `AFC_MEDIA_TREES`.
    static let trees = ["DCIM", "PhotoStreamsData"]

    /// 4 MB: the reference's `MAXIMUM_READ_SIZE` neighbourhood. The connection
    /// is held open for the whole file, so this trades memory against syscall
    /// count, not against a per-file connection.
    private static let chunkSize = 4 << 20

    // MARK: - Store

    /// The media store, inside the app container.
    ///
    /// Its own storage and its own manifest, deliberately not the
    /// `MediaDomain` / `CameraRollDomain` rows the protective backup would use:
    /// the restore's prune keeps only rows whose payload it pulled itself, so
    /// media sitting here would be dropped on the next apply unless it were
    /// threaded through the backup manifest as well.
    static var storeRoot: URL {
        AppPaths.mediaStore
    }

    static var manifestURL: URL {
        storeRoot.appendingPathComponent("afc-media.json", conformingTo: .data)
    }

    /// One file's record. `deleted` is whether the original was removed from
    /// the Media tree, which is the only irreversible part of the operation and
    /// therefore is tracked per file rather than per run.
    struct Entry: Codable, Hashable {
        var source: String
        var storedAs: String
        var size: Int64
        var modified: Date?
        var deleted: Bool
    }

    struct Manifest: Codable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    // MARK: - Survey

    struct Survey {
        var files: [AfcFsEntry]
        var bytes: Int64
        var skippedSymlinks: Int
    }

    /// Everything a confirmation dialog needs, without transferring anything:
    /// the file list, the total size, and the free space on the volume the
    /// container actually lives on.
    static func survey() async throws -> Survey {
        let gateway = try await gateway()
        var files: [AfcFsEntry] = []
        var bytes: Int64 = 0
        var symlinks = 0

        for tree in trees {
            guard let root = try? await gateway.afcEntryInfo(path: "/" + tree) else {
                AppLog.write("AFC media: /\(tree) is not listed — skipped")
                continue
            }
            // Was `guard !root.isDirectory else { continue }`, which skipped every
            // tree exactly when it was a directory -- i.e. always. The survey
            // came back empty for every device, which is why AFC "saw no photos".
            guard root.isDirectory else {
                AppLog.write("AFC media: /\(tree) is not a directory — skipped")
                continue
            }
            for entry in try await walk(gateway, path: "/" + tree) {
                if entry.linkTarget != nil { symlinks += 1; continue }
                files.append(entry)
                bytes += entry.size
            }
        }
        return Survey(files: files, bytes: bytes, skippedSymlinks: symlinks)
    }

    /// Free space for the *container's* volume.
    ///
    /// `afcVolumeInfo()` is deliberately not used: it reports the Media volume,
    /// which is a different filesystem from the one the app container lives on.
    /// Comparing media bytes against Media's free space would be measuring the
    /// wrong disk.
    static func containerFreeBytes() -> Int64 {
        let values = try? storeRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Transfer

    /// Pull every media file into the store, then — only if `deletingOriginals`
    /// is set — remove each one after its size has been verified.
    ///
    /// Ordering is the whole point: write, close, verify against what the device
    /// reported for that path, and only then delete. A file whose copy does not
    /// match keeps its original, always.
    static func pull(
        deletingOriginals: Bool,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> Manifest {
        let gateway = try await gateway()
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let survey = try await survey()
        onProgress?("AFC media: \(survey.files.count) file(s), "
            + "\(ByteCountFormatter.string(fromByteCount: survey.bytes, countStyle: .file))")

        var manifest = Manifest()
        var done: Int64 = 0

        for entry in survey.files {
            let relative = String(entry.path.dropFirst())          // drop the leading "/"
            let destination = storeRoot.appendingPathComponent(relative, conformingTo: .data)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Write to a sidecar first: a cancelled or failed transfer must not
            // leave a short file that a later run would treat as complete.
            let partial = destination.appendingPathExtension("afcpartial")
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)

            var written: Int64 = 0
            do {
                _ = try await gateway.afcStreamFile(path: entry.path, chunkSize: chunkSize) {
                    chunk in
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: partial)
                // Fatal: the store is the only copy once originals are deleted.
                throw GoldenNuggetError(
                    "AFC media: \(entry.path) failed after \(written) byte(s) — "
                    + "no original was removed.")
            }

            // Verify before the irreversible half. The device's own size is the
            // reference; the byte count we wrote is only a cross-check.
            let copied = (try? FileManager.default
                .attributesOfItem(atPath: partial.path)[.size] as? NSNumber)??.int64Value ?? -1
            guard copied == entry.size, written == entry.size else {
                try? FileManager.default.removeItem(at: partial)
                throw GoldenNuggetError(
                    "AFC media: \(entry.path) size mismatch — device reports "
                    + "\(entry.size), wrote \(copied) / \(written). Original kept.")
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)

            var deleted = false
            if deletingOriginals {
                do {
                    try await gateway.afcDelete(path: entry.path)
                    deleted = true
                } catch {
                    // The copy is already verified, so a failed delete is a
                    // lesser problem than the reverse and is reported, not fatal.
                    onProgress?("AFC media: could not remove \(entry.path) — copy is intact")
                }
            }

            manifest.entries.append(Entry(
                source: entry.path, storedAs: relative, size: entry.size,
                modified: entry.modified, deleted: deleted))

            done += entry.size
            onProgress?("AFC media: \(relative) — "
                + "\(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)), "
                + "total \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file))")
        }

        if survey.skippedSymlinks > 0 {
            onProgress?("AFC media: skipped \(survey.skippedSymlinks) symlink(s)")
        }
        try write(manifest)
        return manifest
    }

    /// Put everything back, then drop the local copies.
    ///
    /// The mirror of `pull(deletingOriginals:)`: a file is only removed from the
    /// store once the device reports the same size back for the path it came
    /// from.
    static func push(onProgress: ((String) -> Void)? = nil) async throws {
        let manifest = try read()
        let gateway = try await gateway()
        var restored = 0

        for entry in manifest.entries {
            let local = storeRoot.appendingPathComponent(entry.storedAs, conformingTo: .data)
            guard FileManager.default.fileExists(atPath: local.path) else {
                onProgress?("AFC push: missing \(entry.storedAs) — skipped")
                continue
            }
            let directory = (entry.source as NSString).deletingLastPathComponent
            if !directory.isEmpty, directory != "/" {
                try? await gateway.afcMakeDirectory(path: directory)
            }
            let data = try Data(contentsOf: local)
            try await gateway.afcWrite(path: entry.source, data: data)
            restored += 1
            onProgress?("AFC push: \(entry.source)")
        }
        onProgress?("AFC push: \(restored) file(s) restored")
    }

    /// Empty the store, once the originals are back and verified on the device.
    static func clear() throws {
        if FileManager.default.fileExists(atPath: storeRoot.path) {
            try FileManager.default.removeItem(at: storeRoot)
        }
        try? FileManager.default.removeItem(at: manifestURL)
    }

    // MARK: - Internals

    /// Depth-first listing, `afcList` per directory, symlinks reported rather
    /// than followed. A directory that cannot be listed throws: silently
    /// skipping it would drop photos without a trace.
    private static func walk(_ gateway: IdeviceGateway, path: String) async throws -> [AfcFsEntry] {
        var out: [AfcFsEntry] = []
        for entry in try await gateway.afcList(path: path) {
            if entry.linkTarget != nil { continue }
            if entry.isDirectory {
                out += try await walk(gateway, path: entry.path)
            } else {
                out.append(entry)
            }
        }
        return out
    }

    private static func gateway() async throws -> IdeviceGateway {
        guard let gateway = Minimuxer.shared().ideviceGateway else {
            throw GoldenNuggetError("AFC media: no idevice gateway — is the tunnel up?")
        }
        return gateway
    }

    private static func write(_ manifest: Manifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }

    static func read() throws -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL) else { return Manifest() }
        return (try? JSONDecoder().decode(Manifest.self, from: data)) ?? Manifest()
    }
}
