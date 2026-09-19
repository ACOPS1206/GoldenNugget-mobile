import Foundation

// The bytes of a backup 3.3 file record.
//
// These three symbols are the only survivors of the old `Backup.swift`: the
// rest of that file (`BackupFile` / `ConcreteFile` / `SymbolicLink` /
// `Directory` / `Backup` / `MobileBackupDatabase` / `MBDBRecord`) had zero
// references outside itself and was carried in the build for the sparserestore
// route this app no longer takes.
//
// What remains is the part the injector actually needs: the NSKeyedArchiver
// `MBFile` blob that goes in a Files row, plus the data-protection extended
// attribute the restore daemon expects on an app-container file.

/// Default permission bits (0o755) for a synthetic record.
let MODE_DEFAULT: UInt16 = UInt16(S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)

/// The `MBFile` object graph the device decodes out of a Files row's `file` blob.
///
/// The `@objc` name is load-bearing: `NSKeyedArchiver` writes the class name
/// into the archive and the device-side parser looks for `MBFile` literally.
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
            // A directory record has an inode but no digest and no xattrs.
            coder.encode(inodeNumber, forKey: "InodeNumber")
        } else {
            if let digest { coder.encode(digest, forKey: "Digest") }
            if let ea = extendedAttributes { coder.encode(ea, forKey: "ExtendedAttributes") }
        }
    }
}

/// Build the archived `MBFile` blob for one manifest row.
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
    // Force-try is safe here: the class name is registered on the line above and
    // the graph is a single flat object with no nested containers, so archiving
    // cannot fail for this input.
    return try! NSKeyedArchiver.archivedData(withRootObject: obj, requiringSecureCoding: false)
}

/// The `com.apple.dataprotection.policy.exception-applied-by` attribute that
/// lets SpringBoard write into the container being restored.
func buildDataprotectionExtendedAttributes() -> Data {
    let ea: [String: Any] = [
        "com.apple.dataprotection.policy.exception-applied-by": Data("com.apple.springboard".utf8)
    ]
    return (try? PropertyListSerialization.data(fromPropertyList: ea, format: .binary, options: 0)) ?? Data()
}
