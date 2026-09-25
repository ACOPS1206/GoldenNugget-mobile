import Foundation
import SwiftUI

/// The two device-level settings GoldenNugget keeps next to the tweak set:
/// whether the device should present itself as supervised, and the
/// organization name that goes with it.
///
/// Upstream (`src/restore/skip_setup27.py` `build_cloud_config`) turns these
/// into a Setup cloud configuration: `IsSupervised = true`, plus
/// `OrganizationName`, a fresh `OrganizationMagic`, and
/// `SupervisorHostCertificates` carrying the public half of a generated keybag
/// x509. That is what Lithium's profiles need in order to install at all.
///
/// The port persists the intent here. Delivery is a separate problem and is
/// deliberately not faked here: see `SupervisionView` for what is and is not
/// applied. The reference's own README warns that toggling Skip Setup off after
/// installing Lithium profiles strands them on the device with no way to
/// remove them, so a half-applied supervision state is worse than none.
final class SupervisionSettings: ObservableObject {
    static let shared = SupervisionSettings()

    @AppStorage("SupervisionEnabled") private var enabled: Bool = false
    @AppStorage("SupervisionOrganization") private var organization: String = ""

    private init() {}

    var isSupervised: Bool { enabled }
    var organizationName: String { organization }

    func setSupervised(_ on: Bool) { enabled = on }
    func setOrganizationName(_ name: String) { organization = name }

    /// Whether the organization half is complete enough to be meaningful.
    /// Upstream only writes the keybag fields when a name is present, and
    /// strips them when it is not, so a supervised device with no name is a
    /// state the reference never produces on purpose.
    var hasOrganization: Bool {
        !organization.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
