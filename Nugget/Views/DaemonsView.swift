import SwiftUI

/// The Daemons page — a port of GoldenNugget's `IOSDaemonsContent`
/// (`src/gui/ios/daemons.py`).
///
/// Everything a group switch does is a `TweakSpec` in the catalog, so Apply,
/// autosave and preset import work on it unchanged. This view is only the
/// reference's arrangement: a master switch, the one-tap Recommended set, the
/// two switch groups, and the ScreenTime nullify underneath.
///
/// The six groups upstream marks interface-visible but gives no switch
/// (`showsSwitch == false`) are deliberately not rendered — they belong to the
/// Recommended set, and the reference offers no way to toggle them alone.
struct DaemonsView: View {
    @Binding var selection: TweakSelection

    /// The master switch, upstream's `daemons_tweak.enabled`. Kept out of the
    /// selection on purpose: it gates every group rather than being one, and
    /// turning it off is the same observable state as having no group on.
    @State private var masterEnabled = true
    @State private var identity = DeviceIdentity.unknown

    /// Same disclosure behaviour as the Tweaks page: a section the user has not
    /// touched is open when something in it is on. Forty groups of switches is a
    /// page you cannot scan, but a section that is folded hides the one group you
    /// came to change, so the fold follows the state rather than a blanket
    /// default.
    @State private var collapsedSections: Set<DaemonSection> = []
    @State private var foldedByHand: Set<DaemonSection> = []

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            headerCard
            coverageCard
            ForEach(DaemonSection.allCases) { section in
                let groups = visibleGroups(in: section)
                if !groups.isEmpty {
                    GoldenCollapsibleSection(
                        title: "\(section.rawValue) (\(onCount(in: groups))/\(groups.count))",
                        isCollapsed: collapsedBinding(for: section, groups: groups),
                        content: AnyView(
                            VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                                ForEach(groups, id: \.name) { group in
                                    groupRow(group)
                                }
                            }
                        )
                    )
                }
            }
            screenTimeCard
        }
        .navigationTitle("Daemons")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            // Upstream's master switch reads the stored `enabled` flag. There is
            // no separate flag here, so the page reports the state that actually
            // reaches the device: master is on exactly when a group is on.
            masterEnabled = DaemonGroups.all.contains { isOn($0) }
            identity = await DeviceIdentity.read()
        }
    }

    // MARK: - Sections

    /// The device line and the count, in the Tweaks page's shape. The counts
    /// differ deliberately: this page has no "applicable" filter, so a group that
    /// is missing is missing for good, not because the device cannot run it.
    private var coverageCard: some View {
        GoldenCard {
            Text(identity.describe)
                .font(GoldenFont.cardTitle)
                .foregroundColor(GoldenTheme.textPrimary)
            GoldenMutedNote(text: "\(onCount(in: DaemonGroups.all.filter { $0.showsSwitch })) "
                + "of \(DaemonGroups.all.filter { $0.showsSwitch }.count) daemon group(s) on. "
                + "The groups upstream marks interface-visible but gives no switch are in the "
                + "Recommended set only.")
        }
    }

    private func onCount(in groups: [DaemonGroup]) -> Int {
        groups.filter(isOn).count
    }

    private func collapsedBinding(for section: DaemonSection,
                                  groups: [DaemonGroup]) -> Binding<Bool> {
        Binding(
            get: {
                if foldedByHand.contains(section) { return collapsedSections.contains(section) }
                return onCount(in: groups) == 0
            },
            set: { collapsed in
                foldedByHand.insert(section)
                if collapsed { collapsedSections.insert(section) } else { collapsedSections.remove(section) }
            })
    }

    private var headerCard: some View {
        GoldenCard {
            VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                masterRow
                recommendedRow
                GoldenMutedNote(text: "Writes "
                    + "/var/db/com.apple.xpc.launchd/disabled.plist. Disabling a "
                    + "daemon stops its service. Only the "
                    + "\(DaemonGroups.allowedKeys.count) labels shown here can "
                    + "ever reach the file.")
            }
        }
    }

    private var masterRow: some View {
        GoldenActionRow(title: "Enable Daemon Modifications",
                        systemImage: "switch.2",
                        tone: masterEnabled ? .primary : .secondary) {
            masterEnabled.toggle()
            // The reference's master switch is a gate, not a group: flipping it
            // off leaves the per-group choices alone and only stops the write.
            if !masterEnabled { setAllRecommended(false) }
        }
    }

    private var recommendedRow: some View {
        GoldenActionRow(title: "Recommended (analytics, tracking & logging)",
                        systemImage: "wand.and.stars",
                        tone: isAllRecommendedOn ? .primary : .secondary) {
            let turnOn = !isAllRecommendedOn
            for group in DaemonGroups.recommended {
                setGroup(group, on: turnOn)
            }
        }
    }

    private var screenTimeCard: some View {
        GoldenSection(
            title: "Other",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    let spec = TweakCatalog.screenTimeSpec
                    TweakRow(spec: spec, selection: $selection,
                             isOn: { isOn(spec) }, setOn: { setOn($0, for: spec) })
                    GoldenMutedNote(text: "Writes a 0-byte file over "
                        + "\(DaemonGroups.screenTime.path). Upstream models this as "
                        + "a NullifyFileTweak: it removes a plist rather than "
                        + "writing one.")
                }
            )
        )
    }

    // MARK: - Rows

    /// The Tweaks page's row, given the daemon meaning of "on": a group is on
    /// when every launchd label in it is written as disabled, which needs the
    /// value dict written alongside the flag, not just the flag.
    @ViewBuilder
    private func groupRow(_ group: DaemonGroup) -> some View {
        if let spec = spec(group) {
            TweakRow(spec: spec, selection: $selection,
                     isOn: { isOn(spec) }, setOn: { setOn($0, for: spec) })
        } else {
            // A group with no spec would be a switch that does nothing. Say so
            // rather than rendering a row that cannot be tapped.
            Text(group.title)
                .font(GoldenFont.rowTitle)
                .foregroundColor(GoldenTheme.textDisabled)
        }
    }

    // MARK: - Selection

    private func visibleGroups(in section: DaemonSection) -> [DaemonGroup] {
        DaemonGroups.all.filter { $0.section == section && $0.showsSwitch }
    }

    private func spec(_ group: DaemonGroup) -> TweakSpec? {
        TweakCatalog.byID["Daemon.\(group.name)"]
    }

    private func isOn(_ group: DaemonGroup) -> Bool {
        spec(group).map(isOn) ?? false
    }

    private func isOn(_ spec: TweakSpec) -> Bool { selection.isOn(spec) }

    private var isAllRecommendedOn: Bool {
        DaemonGroups.recommended.allSatisfy(isOn)
    }

    /// One group on means "disable every launchd label in it", which is what
    /// upstream's `set_multiple_values(sorted(keys), value=True)` does.
    private func setGroup(_ group: DaemonGroup, on: Bool) {
        guard let spec = spec(group) else { return }
        setOn(on, for: spec)
    }

    /// A daemon group is "on" when its labels must be *disabled*, so the switch
    /// writes `true` for every label in it — the launchd plist reads
    /// `label: true` as "do not start this". The registry defaults in the spec
    /// are all-false, so setting only the on-flag would write a file that
    /// disables nothing.
    private func setOn(_ on: Bool, for spec: TweakSpec) {
        if on, let group = DaemonGroups.all.first(where: { "Daemon.\($0.name)" == spec.id }) {
            selection.restore(enabled: true, value: nil, multiValues: trueValues(for: group),
                              for: spec)
        } else {
            selection.setOn(on, for: spec)
            selection.removeValue(for: spec)
        }
    }

    private func trueValues(for group: DaemonGroup) -> [String: TweakValue] {
        Dictionary(uniqueKeysWithValues: group.labels.map { ($0, TweakValue.bool(true)) })
    }

    private func setAllRecommended(_ on: Bool) {
        for group in DaemonGroups.recommended { setGroup(group, on: on) }
    }
}
