import CryptoKit
import Foundation
import SQLite3

let MODE_DEFAULT = S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH

class BackupFile {
    var path: String
    var domain: String
    init(path: String, domain: String) {
        self.path = path
        self.domain = domain
    }

    public func toRecord() -> MBDBRecord {
        fatalError("Subclass must implement this function")
    }

    func sha1Hex() -> String {
        let id = domain + "-" + path
        return Data(Insecure.SHA1.hash(data: id.data(using: .utf8)!))
            .map { String(format: "%02hhx", $0) }.joined()
    }
}

class ConcreteFile: BackupFile {
    var contents: Data
    var owner: Int32
    var group: Int32
    var inode: UInt64?
    var mode: UInt16

    init(path: String, domain: String, contents: Data, owner: Int32 = 0, group: Int32 = 0, inode: UInt64? = nil, mode: UInt16 = MODE_DEFAULT) {
        self.contents = contents
        self.owner = owner
        self.group = group
        self.inode = inode
        self.mode = mode
        super.init(path: path, domain: domain)
    }

    override public func toRecord() -> MBDBRecord {
        let time = UInt32(Date().timeIntervalSince1970)
        return MBDBRecord(
            domain: domain,
            filename: path,
            link: "",
            hash: Data(Insecure.SHA1.hash(data: contents)),
            key: Data(),
            mode: mode | S_IFREG,
            inode: inode ?? UInt64(Date().timeIntervalSince1970*10000000),
            user_id: owner,
            group_id: group,
            mtime: time,
            atime: time,
            ctime: time,
            size: UInt64(contents.count),
            flags: 4,
            properties: [:])
    }
}

class SymbolicLink: BackupFile {
    var target: String
    var owner: Int32
    var group: Int32
    var inode: UInt64?
    var mode: UInt16

    init(path: String, domain: String, target: String, owner: Int32 = 0, group: Int32 = 0, inode: UInt64? = nil, mode: UInt16 = MODE_DEFAULT) {
        self.target = target
        self.owner = owner
        self.group = group
        self.inode = inode
        self.mode = mode
        super.init(path: path, domain: domain)
    }

    override public func toRecord() -> MBDBRecord {
        let time = UInt32(Date().timeIntervalSince1970)
        return MBDBRecord(
            domain: domain,
            filename: path,
            link: target,
            hash: Data(),
            key: Data(),
            mode: mode | S_IFLNK,
            inode: inode ?? UInt64(Date().timeIntervalSince1970*10000000),
            user_id: owner,
            group_id: group,
            mtime: time,
            atime: time,
            ctime: time,
            size: 0,
            flags: 4,
            properties: [:])
    }
}

class Directory: BackupFile {
    var owner: Int32
    var group: Int32
    var mode: UInt16

    init(path: String, domain: String, owner: Int32 = 0, group: Int32 = 0, mode: UInt16 = MODE_DEFAULT) {
        self.owner = owner
        self.group = group
        self.mode = mode
        super.init(path: path, domain: domain)
    }

    override public func toRecord() -> MBDBRecord {
        let time = UInt32(Date().timeIntervalSince1970)
        return MBDBRecord(
            domain: domain,
            filename: path,
            link: "",
            hash: Data(),
            key: Data(),
            mode: mode | S_IFDIR,
            inode: 0,
            user_id: owner,
            group_id: group,
            mtime: time,
            atime: time,
            ctime: time,
            size: 0,
            flags: 4,
            properties: [:])
    }
}

struct BackupApp {
    let identifier: String
    let path: String
    let version: String
    let containerContentClass: String
}

// MARK: - NSKeyedArchiver MBFile blob

@objc(MBFile) private class MBFileArchiver: NSObject, NSCoding {
    var relativePath: String = ""
    var digest: Data?
    var mode: UInt32 = 0
    var size: Int = 0
    var userID: Int = 501
    var groupID: Int = 501
    var protectionClass: Int = 0
    var birth: Int = 0
    var lastModified: Int = 0
    var lastStatusChange: Int = 0
    var flags: Int = 0
    var inodeNumber: Int = 0
    var extendedAttributes: Data?
    var isDirectory: Bool = false

    override init() { super.init() }

    required init?(coder: NSCoder) { super.init() }

    func encode(with coder: NSCoder) {
        coder.encode(birth, forKey: "Birth")
        coder.encode(lastModified, forKey: "LastModified")
        coder.encode(lastStatusChange, forKey: "LastStatusChange")
        coder.encode(flags, forKey: "Flags")
        coder.encode(groupID, forKey: "GroupID")
        coder.encode(userID, forKey: "UserID")
        coder.encode(mode, forKey: "Mode")
        coder.encode(protectionClass, forKey: "ProtectionClass")
        coder.encode(size, forKey: "Size")
        coder.encode(relativePath, forKey: "RelativePath")
        if isDirectory {
            coder.encode(inodeNumber, forKey: "InodeNumber")
        } else {
            if let digest = digest { coder.encode(digest, forKey: "Digest") }
            if let ea = extendedAttributes { coder.encode(ea, forKey: "ExtendedAttributes") }
        }
    }
}

func buildMBFileBlob(relativePath: String, mode: UInt32, size: Int,
                              userID: Int = 501, groupID: Int = 501, protectionClass: Int = 0,
                              inodeNumber: Int = 0, isDirectory: Bool = false,
                              digest: Data? = nil, extendedAttributes: Data? = nil) -> Data {
    let obj = MBFileArchiver()
    obj.relativePath = relativePath
    obj.mode = mode
    obj.size = size
    obj.userID = userID
    obj.groupID = groupID
    obj.protectionClass = protectionClass
    obj.inodeNumber = inodeNumber
    obj.isDirectory = isDirectory
    obj.digest = digest
    obj.extendedAttributes = extendedAttributes
    NSKeyedArchiver.setClassName("MBFile", for: MBFileArchiver.self)
    let data = try! NSKeyedArchiver.archivedData(withRootObject: obj, requiringSecureCoding: false)
    return data
}

func buildDataprotectionExtendedAttributes() -> Data {
    let ea: [String: Any] = [
        "com.apple.dataprotection.policy.exception-applied-by": Data("com.apple.springboard".utf8)
    ]
    return (try? PropertyListSerialization.data(fromPropertyList: ea, format: .binary, options: 0)) ?? Data()
}

// MARK: - Backup

class Backup {
    var files: [BackupFile]
    var apps: [BackupApp]

    init(files: [BackupFile], apps: [BackupApp] = []) {
        self.files = files
        self.apps = apps
    }

    func writeTo(directory: URL) throws {
        let deviceDir = directory

        for file in files {
            if let concrete = file as? ConcreteFile {
                let fileID = file.sha1Hex()
                let subDir = deviceDir.appendingPathComponent(String(fileID.prefix(2)), isDirectory: true)
                try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
                let payloadPath = subDir.appendingPathComponent(fileID, conformingTo: .data)
                try concrete.contents.write(to: payloadPath)
            }
        }

        let manifestPath = deviceDir.appendingPathComponent("Manifest.db", conformingTo: .data)
        try generateManifestSQLite().write(to: manifestPath)

        let statusPath = deviceDir.appendingPathComponent("Status.plist", conformingTo: .data)
        try PropertyListSerialization.data(fromPropertyList: generateStatus(), format: .xml, options: 0)
            .write(to: statusPath)

        let manifestPlistPath = deviceDir.appendingPathComponent("Manifest.plist", conformingTo: .data)
        try PropertyListSerialization.data(fromPropertyList: generateManifest(), format: .xml, options: 0)
            .write(to: manifestPlistPath)

        let infoPlistPath = deviceDir.appendingPathComponent("Info.plist", conformingTo: .data)
        try PropertyListSerialization.data(fromPropertyList: generateInfo(), format: .xml, options: 0)
            .write(to: infoPlistPath)
    }

    func generateManifestSQLite() throws -> Data {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("Manifest-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var db: OpaquePointer?
        guard sqlite3_open(tmpURL.path, &db) == SQLITE_OK, let db = db else {
            throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite database"])
        }
        defer { sqlite3_close(db) }

        var errMsg: UnsafeMutablePointer<CChar>?
        let execSQL: (String) -> Bool = { sql in
            sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK
        }

        guard execSQL("CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)") else {
            throw NSError(domain: "Backup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create Files table"])
        }
        _ = execSQL("CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB)")

        let insertSQL = "INSERT INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw NSError(domain: "Backup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare INSERT statement"])
        }
        defer { sqlite3_finalize(stmt) }

        var inodeCounter = 1
        let now = Int(Date().timeIntervalSince1970)
        let ea = buildDataprotectionExtendedAttributes()

        for file in files {
            let fileID = file.sha1Hex()
            let isDir = file is Directory
            let isSymlink = file is SymbolicLink
            let flags: Int32 = isDir ? 2 : 1

            var blob = Data()
            if let concrete = file as? ConcreteFile {
                let fileMode = UInt32(concrete.mode) | UInt32(S_IFREG)
                let digest = Data(Insecure.SHA1.hash(data: concrete.contents))
                inodeCounter += 1
                blob = buildMBFileBlob(
                    relativePath: concrete.path,
                    mode: fileMode,
                    size: concrete.contents.count,
                    userID: Int(concrete.owner),
                    groupID: Int(concrete.group),
                    protectionClass: 4,
                    inodeNumber: inodeCounter,
                    isDirectory: false,
                    digest: digest,
                    extendedAttributes: ea
                )
            } else if isDir {
                let dir = file as! Directory
                let dirMode = UInt32(dir.mode) | UInt32(S_IFDIR)
                inodeCounter += 1
                blob = buildMBFileBlob(
                    relativePath: dir.path,
                    mode: dirMode,
                    size: 0,
                    userID: Int(dir.owner),
                    groupID: Int(dir.group),
                    protectionClass: 0,
                    inodeNumber: inodeCounter,
                    isDirectory: true
                )
            } else if isSymlink {
                let sym = file as! SymbolicLink
                let linkMode = UInt32(sym.mode) | UInt32(S_IFLNK)
                inodeCounter += 1
                blob = buildMBFileBlob(
                    relativePath: sym.path,
                    mode: linkMode,
                    size: 0,
                    userID: Int(sym.owner),
                    groupID: Int(sym.group),
                    protectionClass: 0,
                    inodeNumber: inodeCounter,
                    isDirectory: false
                )
            }

            fileID.withCString { cID in
                file.domain.withCString { cDomain in
                    file.path.withCString { cPath in
                        sqlite3_bind_text(stmt, 1, cID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 2, cDomain, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 3, cPath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_int(stmt, 4, flags)
                        blob.withUnsafeBytes { ptr in
                            sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        }
                        sqlite3_step(stmt)
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                    }
                }
            }
        }

        var serializedSize: sqlite3_int64 = 0
        guard let serializedPtr = sqlite3_serialize(db, "main", &serializedSize, 0),
              serializedSize > 0 else {
            throw NSError(domain: "Backup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize SQLite database"])
        }
        let data = Data(bytes: serializedPtr, count: Int(serializedSize))
        sqlite3_free(serializedPtr)
        return data
    }

    func generateStatus() -> [String : Any] {
        return [
            "BackupState": "new",
            "Date": Date(),
            "IsFullBackup": false,
            "SnapshotState": "finished",
            "UUID": "00000000-0000-0000-0000-000000000000",
            "Version": "2.4"
        ]
    }

    func generateManifest() -> [String : Any] {
        var manifest: [String: Any] = [
            "BackupKeyBag": Data(base64Encoded: """
            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
            Z8FDgd7YoALY1g==
            """, options: .ignoreUnknownCharacters)!,
            "Lockdown": [:],
            "SystemDomainsVersion": "20.0",
            "Version": "9.1"
        ]
        if !apps.isEmpty {
            var appDict: [String: Any] = [:]
            for app in apps {
                appDict[app.identifier] = [
                    "CFBundleIdentifier": app.identifier,
                    "CFBundleVersion": app.version,
                    "Path": app.path,
                    "ContainerContentClass": app.containerContentClass
                ]
            }
            manifest["Applications"] = appDict
        }
        return manifest
    }

    func generateInfo() -> [String : Any] {
        var info: [String: Any] = [:]
        if !apps.isEmpty {
            var appDict: [String: Any] = [:]
            for app in apps {
                appDict[app.identifier] = [
                    "CFBundleIdentifier": app.identifier,
                    "CFBundleVersion": app.version,
                    "Path": app.path,
                    "ContainerContentClass": app.containerContentClass
                ]
            }
            info["Applications"] = appDict
        }
        return info
    }
}
