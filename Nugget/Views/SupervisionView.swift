import SwiftUI

/// The Supervision page: the device-level supervision switch and the
/// organization name. Deliberately only that.
///
/// The Lithium feature set (github.com/jailbreakdotparty/Lithium) is a
/// configuration-profile generator, and its features are MDM payloads rather
/// than preference writes: iOS only installs them on a supervised device, and
/// this port has no profile installer. A list of features that cannot be
/// installed is a promise the page cannot keep, so it is not here. The one
/// Lithium feature that is a plain preference write — the lockscreen footnote —
/// is an ordinary registry tweak and lives on the Tweaks page like any other.
///
/// What this switch does and does not do is stated on the page itself. It
/// records the intent and the organization name; delivering `IsSupervised` needs
/// a Setup cloud configuration carrying a generated keybag certificate, which
/// this port has no path for yet. Claiming otherwise would be worse than saying
/// so, because a device left believing it is supervised is a device whose MDM
/// profiles cannot be removed.
struct SupervisionView: View {
    @ObservedObject private var settings = SupervisionSettings.shared
    @State private var organizationDraft = ""
    @State private var identity: DeviceIdentity = .unknown

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            supervisionCard
            skipSetupCard
        }
        .navigationTitle("Supervision")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            identity = await DeviceIdentity.read()
            organizationDraft = settings.organizationName
        }
    }

    // MARK: - Supervision

    private var supervisionCard: some View {
        GoldenSection(
            title: "Device supervision",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenActionRow(
                        title: "Enable Supervision",
                        systemImage: settings.isSupervised ? "checkmark.shield.fill" : "shield",
                        tone: settings.isSupervised ? .success : .primary
                    ) {
                        settings.setSupervised(!settings.isSupervised)
                    }
                    organizationRow
                    GoldenMutedNote(text: supervisionNote)
                }
            )
        )
    }

    private var organizationRow: some View {
        VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
            GoldenLabeledField(label: "Organization Name") {
                TextField("Organization", text: $organizationDraft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .onSubmit { commitOrganization() }
            }
            GoldenActionRow(title: "Save organization name",
                            systemImage: "square.and.arrow.down",
                            tone: organizationDraft == settings.organizationName ? .secondary : .primary) {
                commitOrganization()
            }
            .disabled(organizationDraft == settings.organizationName)
        }
    }

    private var supervisionNote: String {
        var lines = [
            "Records the intent only. The cloud configuration upstream delivers "
                + "is not written here, so the device is unchanged until it is.",
        ]
        if settings.isSupervised && !settings.hasOrganization {
            lines.append("Supervised with no organization name: upstream drops the "
                         + "keybag fields in that case, so a name is needed first.")
        }
        if !identity.version.isEmpty {
            lines.append("Connected device: iOS \(identity.version).")
        }
        return lines.joined(separator: "\n\n")
    }

    private var skipSetupCard: some View {
        GoldenSection(
            title: "Skip Setup",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    HStack(spacing: 12) {
                        Text("Write the skip-setup files on every apply")
                            .font(GoldenFont.rowTitle)
                            .foregroundColor(GoldenTheme.textPrimary)
                        Spacer(minLength: 12)
                        GoldenSwitch(isOn: skipSetupBinding)
                    }
                    .goldenRowSurface()
                    GoldenMutedNote(text: skipSetupNote)
                }
            )
        )
    }

    private var skipSetupBinding: Binding<Bool> {
        Binding(get: { settings.skipSetupEnabled }, set: { settings.setSkipSetup($0) })
    }

    /// What the switch does, in the order the two files are written.  Upstream's
    /// own name for this is `pref_manager.skip_setup`; the enforcement point is
    /// `SkipSetup.build`, which the engine prepends to the tweak payloads.
    private var skipSetupNote: String {
        var lines = [
            "Off: an apply carries only the tweaks (upstream defaults this to on; this port "
                + "leaves it off until a run has confirmed the files land).",
            "On: an apply adds two files ahead of the tweaks, in this order —",
            "1. SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/"
                + "Library/ConfigurationProfiles/CloudConfigurationDetails.plist, "
                + "\(SkipSetup.panes.count) setup panes marked skipped;",
            "2. ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist, setup marked done.",
            "The device's existing cloud configuration is not merged in (reading it needs a "
                + "lockdown service this port has no path for), and no keybag certificate is "
                + "generated, so this writes the unsupervised shape.",
        ]
        if settings.isSupervised {
            lines.append("Supervision is on: the run will assert IsSupervised = true and warn that "
                + "SupervisorHostCertificates is missing. Upstream's own note is that a device left "
                + "believing it is supervised cannot have its profiles removed — turn supervision "
                + "off here unless that is what you want.")
        }
        return lines.joined(separator: "\n")
    }

    private func commitOrganization() {
        settings.setOrganizationName(
            organizationDraft.trimmingCharacters(in: .whitespaces))
    }
}
