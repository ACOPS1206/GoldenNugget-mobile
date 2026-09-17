import Foundation
import zlib

// Target-app selection: the file picker picks a packaged app (.app directory
// or .ipa archive) and we read the CFBundleIdentifier out of its Info.plist.
// Only the bundle ID is used — the on-device path/version still come from
// InstProxy at restore time.
enum AppPackage {
    static func bundleID(from url: URL) throws -> String {
        try url.withSecurityScopedAccess {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let plistData: Data
            if isDir {
                // .app bundle: Info.plist sits at the bundle root.
                let infoPlist = url.appendingPathComponent("Info.plist")
                guard FileManager.default.fileExists(atPath: infoPlist.path) else {
                    throw PoCError("No Info.plist in \(url.lastPathComponent)")
                }
                plistData = try Data(contentsOf: infoPlist)
            } else {
                // .ipa: it is a zip; pull 'Payload/<Name>.app/Info.plist'.
                guard let data = try zipInfoPlist(Data(contentsOf: url)) else {
                    throw PoCError("No Payload/*.app/Info.plist inside \(url.lastPathComponent)")
                }
                plistData = data
            }
            return try bundleID(fromInfoPlist: plistData, source: url.lastPathComponent)
        }
    }

    // MARK: - Info.plist parsing

    private static func bundleID(fromInfoPlist data: Data, source: String) throws -> String {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw PoCError("CFBundleIdentifier not found in \(source)")
        }
        return bundleID
    }

    // MARK: - Minimal ZIP reader (.ipa)

    private static let centralSignature: UInt32 = 0x02014b50
    private static let localSignature: UInt32 = 0x04034b50
    private static let eocdSignature: UInt32 = 0x06054b50

    private struct CentralEntry {
        let name: String
        let method: UInt16
        let compressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private static func zipInfoPlist(_ data: Data) throws -> Data? {
        guard let eocd = findEOCD(data) else {
            throw PoCError("Not a zip archive (no end-of-central-directory)")
        }
        let entryCount = u16(data, eocd + 10)
        let cdOffset = u32(data, eocd + 16)

        var entries: [CentralEntry] = []
        var offset = Int(cdOffset)
        for _ in 0..<Int(entryCount) {
            guard offset + 46 <= data.count, u32(data, offset) == centralSignature else { break }
            let nameLen = Int(u16(data, offset + 28))
            let extraLen = Int(u16(data, offset + 30))
            let commentLen = Int(u16(data, offset + 32))
            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count else { break }
            let name = String(decoding: data[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            entries.append(CentralEntry(
                name: name,
                method: u16(data, offset + 10),
                compressedSize: u32(data, offset + 20),
                localHeaderOffset: u32(data, offset + 42)
            ))
            offset = nameStart + nameLen + extraLen + commentLen
        }

        // Match top-level .app inside Payload/ by suffix, ignore case (watch
        // apps can nest another Info.plist inside PlugIns/ — we want the root one).
        guard let target = entries.first(where: {
            $0.name.lowercased().hasPrefix("payload/") &&
            $0.name.lowercased().range(of: #"/[^/]+\.app/info\.plist$"#, options: .regularExpression) != nil &&
            $0.name.split(separator: "/").count == 3
        }) else {
            return nil
        }

        guard let localOffset = Int(exactly: target.localHeaderOffset),
              localOffset + 30 <= data.count, u32(data, localOffset) == localSignature else {
            throw PoCError("Bad local header for \(target.name)")
        }
        let nameLen = Int(u16(data, localOffset + 26))
        let extraLen = Int(u16(data, localOffset + 28))
        let dataStart = localOffset + 30 + nameLen + extraLen
        let compressedSize = Int(target.compressedSize)
        guard dataStart + compressedSize <= data.count else {
            throw PoCError("Truncated file data for \(target.name)")
        }
        let raw = data[dataStart..<(dataStart + compressedSize)]

        switch target.method {
        case 0:
            return Data(raw) // stored uncompressed
        case 8:
            guard let inflated = inflateRaw(Data(raw)) else {
                throw PoCError("Could not inflate \(target.name)")
            }
            return inflated
        default:
            throw PoCError("Unsupported compression method \(target.method) for \(target.name)")
        }
    }

    private static func findEOCD(_ data: Data) -> Int? {
        // EOCD is the last record; scan backwards from the end (max 65k comment).
        let tail = max(data.count - 65557, 0)
        guard data.count >= 22 else { return nil }
        for i in stride(from: data.count - 22, through: tail, by: -1) where u32(data, i) == eocdSignature {
            return i
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        data[offset...].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset...].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    // Raw DEFLATE (windowBits = -MAX_WBITS), as used by zip method 8.
    private static func inflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 65536
        var result = Z_OK
        data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            let src = rawBuf.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
            stream.avail_in = uInt(data.count)
            var chunk = [Bytef](repeating: 0, count: chunkSize)
            chunk.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
                let dst = buf.bindMemory(to: Bytef.self)
                while result == Z_OK || result == Z_BUF_ERROR {
                    guard stream.avail_in > 0 else { break }
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    result = inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        // Read via raw pointer copy before 'chunk' goes out of
                        // exclusive scope (avoids overlap with withUnsafeMutableBytes).
                        var producedBytes = [Bytef](repeating: 0, count: produced)
                        producedBytes.withUnsafeMutableBytes { pb in
                            pb.copyBytes(from: UnsafeRawBufferPointer(start: dst.baseAddress, count: produced))
                        }
                        output.append(contentsOf: producedBytes)
                    }
                    if result == Z_STREAM_END { break }
                    if result != Z_OK { break }
                }
            }
        }
        return result == Z_STREAM_END ? output : nil
    }
}

private extension URL {
    func withSecurityScopedAccess<T>(_ body: () throws -> T) rethrows -> T {
        let accessing = startAccessingSecurityScopedResource()
        defer { if accessing { stopAccessingSecurityScopedResource() } }
        return try body()
    }
}