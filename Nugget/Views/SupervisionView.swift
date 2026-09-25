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

    private func commitOrganization() {
        settings.setOrganizationName(
            organizationDraft.trimmingCharacters(in: .whitespaces))
    }
}
