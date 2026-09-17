//
//  MobileBackup2Delegate.swift
//  IdeviceGateway
//
//  Swift C-compatible delegate + context for the mobilebackup2 restore FFI.
//  Membrane contract: buffers/errors returned to Rust are allocated with the
//  system allocator (malloc/free) because idevice frees both via its global
//  allocator (System == malloc on Apple platforms).
//

import Foundation
import IDevice

public struct InstalledAppInfo: Sendable {
    public let bundleID: String
    public let path: String
    public let version: String
    public let container: String
    public let executableName: String?

    public init(
        bundleID: String,
        path: String,
        version: String,
        container: String,
        executableName: String? = nil
    ) {
        self.bundleID = bundleID
        self.path = path
        self.version = version
        self.container = container
        self.executableName = executableName
    }
}

/// Opaque context forwarded to every mobilebackup2 delegate callback.
public final class MobileBackup2BackupContext: @unchecked Sendable {
    let onProgress: (@Sendable (Double) -> Void)?
    /// Optional mid-stream backup filter. When set, files streamed by the
    /// device during backup are stored only if this returns true; otherwise
    /// their payload is drained and never written to disk.
    let shouldPreserve: (@Sendable (String, String) -> Bool)?
    var isCancelled = false

    private let handlesLock = NSLock()
    private var writeHandles: [String: UnsafeMutableRawPointer] = [:]

    public init(
        onProgress: (@Sendable (Double) -> Void)? = nil,
        shouldPreserve: (@Sendable (String, String) -> Bool)? = nil
    ) {
        self.onProgress = onProgress
        self.shouldPreserve = shouldPreserve
    }

    func reportProgress(_ overall: Double) {
        onProgress?(overall)
    }

    func handle(for path: String) -> UnsafeMutableRawPointer? {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        return writeHandles[path]
    }

    func set(handle: UnsafeMutableRawPointer, for path: String) {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        writeHandles[path] = handle
    }

    func clearHandle(for path: String) {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        writeHandles.removeValue(forKey: path)
    }
}

// MARK: - Error construction (system-allocator compatible)

@inline(__always)
private func makeFFIError(_ message: String, code: Int32 = -1) -> UnsafeMutablePointer<IdeviceFfiError> {
    let size = MemoryLayout<IdeviceFfiError>.size
    let raw = malloc(size)
    memset(raw, 0, size)
    let error = raw!.assumingMemoryBound(to: IdeviceFfiError.self)
    error.pointee = IdeviceFfiError(code: code, sub_code: 0, message: strdup(message)) 
    return error
}

@inline(__always)
private func context(_ ctx: UnsafeMutableRawPointer?) -> MobileBackup2BackupContext? {
    guard let ctx = ctx else { return nil }
    return Unmanaged<MobileBackup2BackupContext>.fromOpaque(ctx).takeUnretainedValue()
}

@inline(__always)
private func statBuffers(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?,
    _ op: (MobileBackup2BackupContext, String) -> Void
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    op(c, String(cString: path))
    return nil
}

// MARK: - C delegate callbacks

private func mb2_get_free_disk_space(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UInt64 {
    guard context(ctx) != nil else { return 0 }
    return UInt64(1) << 40
}

private func mb2_open_file_read(
    _ path: UnsafePointer<CChar>?,
    _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outLen: UnsafeMutablePointer<UInt>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let outData = outData, let outLen = outLen, context(ctx) != nil else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    guard let data = FileManager.default.contents(atPath: pathStr) else {
        return makeFFIError("no such file: \(pathStr)", code: -6)
    }
    if data.isEmpty {
        outData.pointee = nil
        outLen.pointee = 0
        return nil
    }
    let buf = malloc(data.count)
    guard let buf = buf else { return makeFFIError("out of memory") }
    data.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: data.count)
    outData.pointee = buf.assumingMemoryBound(to: UInt8.self)
    outLen.pointee = UInt(data.count)
    return nil
}

private func mb2_create_file_write(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    statBuffers(path, ctx) { c, path in
        guard path.hasSuffix("/") == false else { return } // dirs are handled by create_dir_all
        if let f = fopen(path, "wb") {
            c.set(handle: f, for: path)
        }
    }
}

private func mb2_write_chunk(
    _ path: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ len: UInt,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let data = data, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    guard let rawHandle = c.handle(for: pathStr) else {
        return makeFFIError("no open write handle: \(pathStr)")
    }
    let f = rawHandle.assumingMemoryBound(to: FILE.self)
    fwrite(data, 1, Int(len), f)
    return nil
}

private func mb2_close_file(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    if let rawHandle = c.handle(for: pathStr) {
        fclose(rawHandle.assumingMemoryBound(to: FILE.self))
        c.clearHandle(for: pathStr)
    }
    return nil
}

private func mb2_create_dir_all(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    statBuffers(path, ctx) { _, path in
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}

private func mb2_remove(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    statBuffers(path, ctx) { _, path in
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func mb2_rename(
    _ from: UnsafePointer<CChar>?,
    _ to: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let from = from, let to = to, context(ctx) != nil else {
        return makeFFIError("invalid arguments")
    }
    let fromStr = String(cString: from)
    let toStr = String(cString: to)
    let fm = FileManager.default
    if fm.fileExists(atPath: toStr) { try? fm.removeItem(atPath: toStr) }
    if fm.fileExists(atPath: fromStr) == false { return makeFFIError("no such file: \(fromStr)") }
    do {
        try fm.moveItem(atPath: fromStr, toPath: toStr)
    } catch {
        return makeFFIError(error.localizedDescription)
    }
    return nil
}

private func mb2_copy(
    _ src: UnsafePointer<CChar>?,
    _ dst: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let src = src, let dst = dst, context(ctx) != nil else {
        return makeFFIError("invalid arguments")
    }
    let srcStr = String(cString: src)
    let dstStr = String(cString: dst)
    let fm = FileManager.default
    if fm.fileExists(atPath: dstStr) { try? fm.removeItem(atPath: dstStr) }
    do {
        try fm.copyItem(atPath: srcStr, toPath: dstStr)
    } catch {
        return makeFFIError(error.localizedDescription)
    }
    return nil
}

private func mb2_exists(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    guard let path = path, context(ctx) != nil else { return false }
    return FileManager.default.fileExists(atPath: String(cString: path))
}

private func mb2_is_dir(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    guard let path = path, context(ctx) != nil else { return false }
    var isDir: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: String(cString: path), isDirectory: &isDir)
    return isDir.boolValue
}

private func mb2_is_cancelled(
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    context(ctx)?.isCancelled ?? false
}

private func mb2_on_progress(
    _ progress: UnsafePointer<Mobilebackup2BackupProgress>?,
    _ ctx: UnsafeMutableRawPointer?
) {
    guard let progress = progress, let c = context(ctx) else { return }
    c.reportProgress(progress.pointee.overall_progress)
}

private func mb2_should_preserve(
    _ deviceName: UnsafePointer<CChar>?,
    _ fileName: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    guard let c = context(ctx), let filter = c.shouldPreserve else { return true }
    let dn = deviceName.flatMap { String(cString: $0, encoding: .utf8) } ?? ""
    let fn = fileName.flatMap { String(cString: $0, encoding: .utf8) } ?? ""
    return filter(dn, fn)
}

// MARK: - Delegate builders

public func makeRestoreDelegate(
    context: MobileBackup2BackupContext
) -> Mobilebackup2BackupDelegateFFI {
    var delegate = Mobilebackup2BackupDelegateFFI()
    delegate.context = Unmanaged.passUnretained(context).toOpaque()
    delegate.get_free_disk_space = mb2_get_free_disk_space
    delegate.open_file_read = mb2_open_file_read
    delegate.create_file_write = mb2_create_file_write
    delegate.write_chunk = mb2_write_chunk
    delegate.close_file = mb2_close_file
    delegate.create_dir_all = mb2_create_dir_all
    delegate.remove = mb2_remove
    delegate.rename = mb2_rename
    delegate.copy = mb2_copy
    delegate.exists = mb2_exists
    delegate.is_dir = mb2_is_dir
    delegate.is_cancelled = mb2_is_cancelled
    delegate.on_progress = mb2_on_progress
    delegate.should_preserve = mb2_should_preserve
    return delegate
}