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

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            headerCard
            ForEach(DaemonSection.allCases) { section in
                let groups = visibleGroups(in: section)
                if !groups.isEmpty {
                    GoldenSection(
                        title: section.rawValue,
                        content: AnyView(
                            VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                                ForEach(groups, id: \.name) { group in
                                    daemonRow(group)
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
        }
    }

    // MARK: - Sections

    private var headerCard: some View {
        GoldenCard {
            VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                masterRow
                recommendedRow
                GoldenMutedNote(text: "Writes /var/db/com.apple.xpc.launchd/disabled.plist. "
                    + "Disabling a daemon stops its service; upstream ships no "
                    + "deny-list because entries are removed from the reference "
                    + "rather than blocked at runtime, and only the "
                    + "\(DaemonGroups.allowedKeys.count) interface-visible labels "
                    + "can ever reach the file.")
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
                    GoldenActionRow(title: spec.title,
                                    systemImage: "clock.badge.xmark",
                                    tone: isOn(spec) ? .error : .secondary) {
                        setOn(!isOn(spec), for: spec)
                    }
                    GoldenMutedNote(text: "Writes a 0-byte file over "
                        + "\(DaemonGroups.screenTime.path). Upstream models this as "
                        + "a NullifyFileTweak — it does not write a plist, it removes one.")
                }
            )
        )
    }

    // MARK: - Rows

    private func daemonRow(_ group: DaemonGroup) -> some View {
        let spec = TweakCatalog.byID["Daemon.\(group.name)"]
        let on = spec.map(isOn) ?? false
        return GoldenActionRow(title: group.title,
                               systemImage: on ? "checkmark.circle.fill" : "circle",
                               tone: on ? .error : .primary) {
            guard let spec else { return }
            setOn(!on, for: spec)
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
