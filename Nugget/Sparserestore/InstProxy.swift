import Foundation

struct InstalledAppInfo {
    let bundleID: String
    let path: String
    let version: String
    let container: String
}

class InstProxy {
    // Query the installation proxy for a single app's details.
    // Needed to register AppDomain bundles in Manifest.plist's Applications
    // dict, otherwise the restore daemon rejects the domain (MBErrorDomain/205).
    static func lookup(bundleID: String) throws -> InstalledAppInfo {
        var device: idevice_t?
        let ret = idevice_new(&device, nil)
        guard ret == IDEVICE_E_SUCCESS, let device = device else {
            throw PoCError("Failed to get device (idevice_new) \(ret)")
        }
        defer { idevice_free(device) }

        var client: instproxy_client_t?
        let csRet = instproxy_client_start_service(device, &client, "PoC")
        guard csRet == INSTPROXY_E_SUCCESS, let client = client else {
            throw PoCError("Failed to start installation_proxy service \(csRet)")
        }
        defer { instproxy_client_free(client) }

        let cBundle = strdup(bundleID)
        var appids: [UnsafePointer<CChar>?] = [cBundle, nil]
        var result: plist_t? = nil
        let lookRet = instproxy_lookup(client, &appids, nil, &result)
        free(cBundle)
        guard lookRet == INSTPROXY_E_SUCCESS, let result = result else {
            throw PoCError("instproxy_lookup failed \(lookRet)")
        }
        defer { plist_free(result) }

        var xml: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        let xmlRet = plist_to_xml(result, &xml, &length)
        guard xmlRet == PLIST_ERR_SUCCESS, let xml = xml else {
            throw PoCError("plist_to_xml failed \(xmlRet)")
        }
        defer { free(xml) }

        let data = Data(bytes: xml, count: Int(length))
        guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw PoCError("Could not parse instproxy result plist")
        }
        guard let appDict = dict[bundleID] as? [String: Any] else {
            throw PoCError("Bundle \(bundleID) not found in installed apps")
        }
        let container = (appDict["Container"] as? String) ?? ""
        let path = (appDict["Path"] as? String) ?? container
        let version = (appDict["CFBundleVersion"] as? String) ?? "1.0"
        return InstalledAppInfo(bundleID: bundleID, path: path, version: version, container: container)
    }
}