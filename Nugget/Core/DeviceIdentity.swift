import Foundation
import Minimuxer

/// The two device facts the tweak registry's compatibility bounds need.
///
/// GoldenNugget reads them off lockdown (`get_current_device_version` /
/// `get_current_device_model`) and hands them to
/// `gui/ios/compat.py:is_tweak_compatible`.  This is the same pair, read the
/// same way — `ProductVersion` and `ProductType` through
/// `getLockdownValue`, which is the call `Vendor/MinimuxerSources/Services/
/// Mounter.swift` already uses for `ProductVersion`.
struct DeviceIdentity: Equatable, Sendable {
    /// Lockdown `ProductVersion`, e.g. `27.0`.
    let version: String
    /// Lockdown `ProductType`, e.g. `iPad16,2`.
    let productType: String

    /// The reference's device test (`src/gui/ios/tweaks.py:107`):
    /// `model.startswith("iPhone")`.
    var isIPhone: Bool { productType.hasPrefix("iPhone") }

    var describe: String {
        if productType.isEmpty && version.isEmpty { return "unknown device" }
        if productType.isEmpty { return "iOS \(version)" }
        if version.isEmpty { return productType }
        return "\(productType) / iOS \(version)"
    }

    /// Used when the read fails.  An empty version deliberately *disables* the
    /// registry's version bounds rather than failing them: the reference's
    /// `if device_version and spec.min_version` does the same, so a device we
    /// cannot identify shows the full list instead of an empty one.
    static let unknown = DeviceIdentity(version: "", productType: "")

    static func read() async -> DeviceIdentity {
        guard let gateway = Minimuxer.shared().ideviceGateway else { return .unknown }
        let version = ((try? await gateway.getLockdownValue(key: "ProductVersion")) ?? nil) ?? ""
        let productType = ((try? await gateway.getLockdownValue(key: "ProductType")) ?? nil) ?? ""
        return DeviceIdentity(version: version, productType: productType)
    }
}
