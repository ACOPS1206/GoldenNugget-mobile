import SwiftUI

/// The Supervision page: the device-level supervision switch and the Lithium
/// feature set that depends on it.
///
/// Why the two are on one page: Lithium
/// (github.com/jailbreakdotparty/Lithium) is a configuration-profile
/// generator built entirely on MDM payloads, and its README says outright that
/// "you're gonna need to supervise your device beforehand for these profiles to
/// install, which is pretty easy with Nugget". A supervised device is the
/// precondition, so the switch is not an unrelated setting next to the
/// features — it is what makes them installable.
///
/// What this page does and does not do is stated on the page itself. The
/// supervision switch records the intent and the organization name; the
/// delivery of `IsSupervised` needs a Setup cloud configuration carrying a
/// generated keybag certificate, which this port has no path for yet. Claiming
/// otherwise would be worse than saying so, because a device left believing it
/// is supervised is a device whose MDM profiles cannot be removed.
struct SupervisionView: View {
    @Binding var selection: TweakSelection

    @ObservedObject private var settings = SupervisionSettings.shared
    @State private var organizationDraft = ""
    @State private var identity: DeviceIdentity = .unknown

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            supervisionCard
            lithiumCard
            footnoteCard
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

    // MARK: - Lithium

    private var lithiumCard: some View {
        GoldenSection(
            title: "Lithium features",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    ForEach(LithiumFeature.allCases) { feature in
                        featureRow(feature)
                    }
                    GoldenMutedNote(text: lithiumNote)
                }
            )
        )
    }

    private func featureRow(_ feature: LithiumFeature) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GoldenRowLabel(title: feature.title,
                           value: feature.state(settings.isSupervised),
                           systemImage: feature.systemImage,
                           tone: .secondary)
            Text(feature.detail)
                .font(GoldenFont.rowTitle)
                .foregroundColor(GoldenTheme.textSecondary)
        }
    }

    private var lithiumNote: String {
        "Listed, not applied: these are MDM configuration profiles and iOS only "
            + "accepts them on a supervised device. This port has no profile "
            + "installer."
    }

    // MARK: - Footnotes

    private var footnoteCard: some View {
        let spec = TweakCatalog.all.first {
            $0.location == .footnote
        }
        return GoldenSection(
            title: "Lockscreen footnotes",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    if let spec {
                        GoldenActionRow(
                            title: spec.title,
                            systemImage: selection.isOn(spec) ? "checkmark.circle.fill" : "circle",
                            tone: selection.isOn(spec) ? .primary : .secondary
                        ) {
                            selection.setOn(!selection.isOn(spec), for: spec)
                        }
                    }
                    GoldenMutedNote(text: "The one Lithium feature this port "
                        + "carries, because it is a plain preference write: "
                        + "\(TweakFileLocation.footnote.rawValue).")
                }
            )
        )
    }
}

/// The Lithium feature set, and what this port can do with each.
enum LithiumFeature: String, CaseIterable, Identifiable, Sendable {
    case restrictions
    case appNotifications
    case blockedApps
    case lockscreenFootnotes
    case webclip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restrictions: return "Restriction Toggles"
        case .appNotifications: return "App Notifications"
        case .blockedApps: return "Blocked Applications"
        case .lockscreenFootnotes: return "Lockscreen Footnotes"
        case .webclip: return "Webclip Generator"
        }
    }

    var systemImage: String {
        switch self {
        case .restrictions: return "hand.raised"
        case .appNotifications: return "bell.slash"
        case .blockedApps: return "app.dashed"
        case .lockscreenFootnotes: return "text.badge.checkmark"
        case .webclip: return "safari"
        }
    }

    var detail: String {
        switch self {
        case .restrictions:
            return "Disable features iOS would not otherwise let you disable, "
                + "through the com.apple.restrictions payload."
        case .appNotifications:
            return "Block notifications completely for chosen apps."
        case .blockedApps:
            return "Remove chosen apps from every place on the device without "
                + "deleting them."
        case .lockscreenFootnotes:
            return "Custom label at the bottom of the lockscreen — see the "
                + "section below, this one works."
        case .webclip:
            return "Add a webpage to the home screen as if it were an app."
        }
    }

    /// What the row shows on the right: carried here, or blocked on the switch.
    func state(_ supervised: Bool) -> String {
        self == .lockscreenFootnotes ? "available" : (supervised ? "needs a profile installer" : "needs supervision")
    }
}
