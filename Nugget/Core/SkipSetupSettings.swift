import Foundation
import SwiftUI

/// Whether every apply adds the two skip-setup files ahead of the tweaks.
///
/// This used to sit beside a `supervised` flag and an organization name, in a
/// store called `SupervisionSettings` and on a page called Supervision. Both are
/// gone: the page only ever *recorded* the intent, and it recorded it wrongly.
/// Upstream (`src/restore/skip_setup27.py` `build_cloud_config`) turns the pair
/// into a Setup cloud configuration carrying `IsSupervised`, `OrganizationName`,
/// a fresh `OrganizationMagic` and `SupervisorHostCertificates` — the public half
/// of a generated keybag x509, which is what makes a supervised device accept
/// profiles at all. This port never wrote the certificates, so a device it
/// "supervised" was in a state the reference never produces on purpose, and the
/// reference's own README warns that a half-applied supervision state is worse
/// than none. Rather than keep a switch that cannot deliver what it claims, the
/// supervised half is gone and what remains is the one part that was true on its
/// own: the two files, written as the un-supervised variant.
final class SkipSetupSettings: ObservableObject {
    static let shared = SkipSetupSettings()

    /// Upstream's `pref_manager.skip_setup`: when it is on, **every** apply adds
    /// the two skip-setup files ahead of the tweaks (`device_manager.add_skip_setup`
    /// → `SkipSetup.build`).
    ///
    /// **Upstream defaults this to `True`** (`preference_manager.py:19`, and its
    /// GUI reads `settings.value("skip_setup", True)`).  This port defaults it to
    /// `False` on purpose: `SkipSetup` has not been through a device run yet, and
    /// defaulting it on would silently add two files to every apply — including
    /// the first run that has to prove the rest of the pipeline.  Once a run has
    /// confirmed it, flipping this one literal restores the reference's file set
    /// exactly.
    @AppStorage("SkipSetupEnabled") private var skipSetup: Bool = false

    private init() {}

    var skipSetupEnabled: Bool { skipSetup }

    func setSkipSetup(_ on: Bool) { skipSetup = on }
}
