import Foundation
import Minimuxer

class InstProxy {
    // Query the installation proxy for a single app's details via the
    // IdeviceGateway (installation_proxy_get_apps over the RSD tunnel).
    // Needed to register AppDomain bundles in Manifest.plist's Applications
    // dict, otherwise the restore daemon rejects the domain (MBErrorDomain/205).
    static func lookup(bundleID: String) async throws -> NuggetAppInfo {
        try await Minimuxer.shared().lookupApp(bundleId: bundleID)
    }
}