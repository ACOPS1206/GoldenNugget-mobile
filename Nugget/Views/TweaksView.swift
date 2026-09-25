import SwiftUI
import UniformTypeIdentifiers

/// The tweaks page: GoldenNugget's three registry sections, rendered from the
/// generated catalog with the registry's own editors, defaults and gating.
///
/// The reference renders the same three sections from the same table
/// (`src/gui/ios/tweaks.py`), hides a tweak the device cannot run
/// (`gui/ios/compat.py`), and switches it on as soon as its editor is touched
/// (`Tweak.set_value(..., toggle_enabled: True)`).  All three behaviours are
/// reproduced here; what is *not* reproduced is the five un-ported features —
/// see `docs/tweak-port.md`.
///
/// The layout is the reference's `IOSTweaksPage`: a 56 pt nav bar over a scroll
/// body with 16 pt margins, an uppercase section header per registry section,
/// and **one card per tweak** — the switch rows as `IOSCard` + `IOSSwitch`, the
/// value rows as `IOSSettingsRow` with the current value echoed beside the
/// title.  The two extra lines this app renders (the tweak id and the registry's
/// description) ride inside the same card instead of moving to a tooltip, so the
/// page still shows everything it showed before.
struct TweaksView: View {
    @Binding var selection: TweakSelection

    @State private var identity: DeviceIdentity = .unknown
    @State private var showImporter = false
    /// The pending debounced autosave, cancelled and replaced on every change.
    @State private var autosaveTask: Task<Void, Never>?
    /// Whether an autosave is on disk right now, for the note under the rows.
    @State private var autosaveSaved = false
    @State private var importReport: TweakImportReport?
    @State private var importError: String?
    /// Bumped by an import so every row is rebuilt from the imported values.
    /// A row's numeric editor seeds its draft when it is created, so without this
    /// the fields kept showing the registry defaults while the selection — the
    /// thing Apply compiles and writes — held something else entirely.
    @State private var formEpoch = 0
    @State private var running = false
    @State private var outcome: String?
    /// The reference colours its status line by outcome (`process_status_green`
    /// / `_red` / `_blue`), so the outcome carries its tone rather than being
    /// pattern-matched back out of the string.
    @State private var outcomeTone: GoldenTone = .primary
    @State private var tail: [String] = []

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            identityCard
            importSection
            tweakSections
            applySection
            if let importReport { reportSection(importReport) }
            if let importError { errorSection(importError) }
            if !tail.isEmpty { logSection }
        }
        .navigationTitle("Tweaks")
        .navigationBarTitleDisplayMode(.inline)
        // The reference's `IOSNavBar` is `bg_secondary` with a bottom divider;
        // on iOS that is the platform bar with its background pinned visible.
        // `.visible` is stated rather than inherited: the home page hides its
        // bar (it has its own logo header), and visibility is only reliably
        // per-page when both ends say what they want.
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            identity = await DeviceIdentity.read()
            // The reference loads AutoSave at startup (`_load_last_preset`) and
            // rewrites it right after, so a stale entry cannot survive a launch.
            restoreAutosave()
        }
        .onChange(of: selection) { _, _ in scheduleAutosave() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importAutosave(from: url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    // MARK: - Sections

    /// The device line + coverage count, as one card (`home_card_title` +
    /// `home_card_subtitle` sizes).
    private var identityCard: some View {
        GoldenCard {
            Text(identity.describe)
                .font(GoldenFont.cardTitle)
                .foregroundColor(GoldenTheme.textPrimary)
            GoldenMutedNote(text: "\(selection.enabledCount) of \(visibleSpecs.count) applicable tweak(s) enabled. "
                + "Incompatible and un-ported tweaks are hidden, the same way the reference hides them.")
        }
    }

    private var importSection: some View {
        GoldenSection(
            title: "Saved state",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenActionRow(title: "Import autosave.json",
                                    systemImage: "square.and.arrow.down",
                                    tone: running ? .disabled : .primary) {
                        showImporter = true
                    }
                    .disabled(running)
                    GoldenActionRow(title: "Clear all tweaks",
                                    systemImage: "xmark.circle",
                                    tone: .error) {
                        selection.removeAll()
                        importReport = nil
                        importError = nil
                        // Delete it rather than leaving it to be re-read: an
                        // all-off autosave and no autosave are the same state,
                        // and the latter cannot resurrect a cleared tweak.
                        GoldenNuggetAutosave.clear()
                    }
                    .disabled(running || selection.enabledCount == 0)
                    GoldenMutedNote(text: autosaveNote)
                }
            )
        )
    }

    @ViewBuilder
    private var tweakSections: some View {
        ForEach(TweakSection.allCases.filter { $0 != .daemons }) { section in
            let specs = visibleSpecs.filter { $0.section == section }
            if !specs.isEmpty {
                let on = specs.filter { selection.isOn($0) }.count
                GoldenSection(
                    title: "\(section.rawValue) (\(on)/\(specs.count))",
                    content: AnyView(
                        VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                            ForEach(specs, id: \.id) { spec in
                                TweakRow(spec: spec, selection: $selection)
                                    .id("\(spec.id)#\(formEpoch)")
                            }
                        }
                    )
                )
            }
        }
    }

    private var applySection: some View {
        GoldenSection(
            title: "Apply",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenPrimaryButton(title: running ? "Applying…"
                                                       : "Apply \(selection.enabledCount) tweak(s)",
                                        running: running,
                                        disabled: selection.enabledCount == 0) {
                        apply()
                    }
                    if let outcome {
                        GoldenStatusText(text: outcome, tone: outcomeTone)
                    }
                    GoldenMutedNote(text: "Runs the same protective backup → prune → inject → restore the "
                        + "app-container flow uses, carrying the compiled plists instead. Reboot the device "
                        + "afterwards.")
                }
            )
        )
    }

    private func reportSection(_ report: TweakImportReport) -> some View {
        GoldenSection(
            title: "Import result",
            content: AnyView(
                GoldenCard {
                    ForEach(Array(report.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(GoldenFont.log)
                            .foregroundColor(GoldenTheme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            )
        )
    }

    private func errorSection(_ message: String) -> some View {
        GoldenSection(title: "Import failed",
                      content: AnyView(GoldenMutedNote(text: message)))
    }

    private var logSection: some View {
        GoldenSection(title: "Run log (last 30 lines)",
                      content: AnyView(GoldenLogView(lines: tail, height: 260)))
    }

    // MARK: - Behaviour

    /// The specs this device can run, in registry order.
    ///
    /// A tweak the device cannot run is hidden, not disabled — that is what
    /// `gui/ios/tweaks.py` does with `is_tweak_compatible`, and an always-inert
    /// switch would be a worse lie than an absent one.
    /// The registry tweaks only. `daemons` is a section of its own with a page
    /// of its own (`DaemonsView`), because upstream renders it from
    /// `load_daemons()` and a hand-built widget list rather than from the
    /// registry, and folding it in here would show 40 rows with no master
    /// switch and no Recommended set.
    private var visibleSpecs: [TweakSpec] {
        TweakCatalog.all.filter {
            $0.section != .daemons
                && $0.isCompatible(deviceVersion: identity.version, isIPhone: identity.isIPhone)
        }
    }

    // MARK: - Autosave

    /// Write the selection 500 ms after the last change — the reference's
    /// `_on_tweak_changed` debounce (`QTimer.singleShot(500, …)`).
    ///
    /// A pending save is replaced, not queued, so dragging a number field
    /// writes once at the end rather than once per keystroke.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = selection
        let device = identity
        autosaveTask = Task {
            try? await Task.sleep(for: GoldenNuggetAutosave.debounce)
            guard !Task.isCancelled else { return }
            autosaveSaved = GoldenNuggetAutosave.save(snapshot, identity: device)
        }
    }

    /// Startup load of the AutoSave preset, followed by the reference's
    /// immediate rewrite so stale entries cannot survive a launch.
    private func restoreAutosave() {
        autosaveSaved = GoldenNuggetAutosave.exists
        guard let report = GoldenNuggetAutosave.restore(into: &selection, identity: identity)
        else { return }
        // Logged rather than shown: this runs on every launch, so a report card
        // would greet the user on a perfectly normal run.  The reference logs
        // the same way, and the run log is the durable half of the report.
        for line in report.logLines { GoldenNuggetEngine.shared.log(line) }
        formEpoch &+= 1
    }

    /// The autosave line: where the file lives and that the import row is the
    /// manual path for a preset that came from somewhere else.
    private var autosaveNote: String {
        let path = "Documents/GoldenNugget/Presets/\(GoldenNuggetAutosave.presetName).json"
        let state = autosaveSaved ? "saved" : "nothing saved yet"
        return "Your selection is saved to \(path) on every change and restored on "
            + "launch, exactly as the desktop app's AutoSave preset does (\(state)). "
            + "Import is for a preset from elsewhere; entries this port does not carry "
            + "are listed below rather than guessed at."
    }

    private func importAutosave(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let preset = try GoldenNuggetPreset.parse(data)
            let report = GoldenNuggetPresetImport.apply(preset, to: &selection,
                                                        deviceVersion: identity.version,
                                                        isIPhone: identity.isIPhone)
            // The log is the durable half of the report: the sheet can be
            // dismissed, the run log cannot.
            for line in report.logLines { GoldenNuggetEngine.shared.log(line) }
            formEpoch &+= 1
            importReport = report
            importError = nil
        } catch {
            importError = error.localizedDescription
            importReport = nil
        }
    }

    private func apply() {
        running = true
        outcome = nil
        let snapshot = selection
        let device = identity
        Task {
            var result: String
            var tone: GoldenTone
            do {
                try await GoldenNuggetEngine.shared.applyTweaks(selection: snapshot,
                                                       deviceVersion: device.version,
                                                       isIPhone: device.isIPhone)
                result = "Applied. Reboot the device so the injected preferences take effect."
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                result = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                result = "❌ \(error.localizedDescription)"
                tone = .error
            }
            let lines = Array(GoldenNuggetEngine.shared.pendingLog.suffix(30))
            await MainActor.run {
                outcome = result
                outcomeTone = tone
                tail = lines
                running = false
            }
        }
    }
}

/// One tweak as one card: the control band on top, then the id and the
/// registry's description — see `TweaksView`'s note on why those two stay.
///
/// The copy comes from the registry (`TweakSpec.detail`, GoldenNugget's
/// `description=`), not from a second hand-written table — one source of truth
/// for "what does this switch do".
private struct TweakRow: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch spec.kind {
            case .toggle:
                HStack(spacing: 12) {
                    Text(spec.title)
                        .font(GoldenFont.rowTitle)
                        .foregroundColor(GoldenTheme.textPrimary)
                    Spacer(minLength: 12)
                    GoldenSwitch(isOn: toggleBinding)
                }
            case .text:
                Text(spec.title)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                TextField("(empty = clear)", text: textBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .goldenField()
            case .number:
                Text(spec.title)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                TweakNumberField(spec: spec, selection: $selection)
                GoldenMutedNote(text: spec.numberHint)
            }
            Text(spec.id)
                .font(GoldenFont.caption)
                .foregroundColor(GoldenTheme.textDisabled)
            if let detail = spec.detail {
                GoldenMutedNote(text: detail)
            }
        }
        .goldenRowSurface()
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { selection.isOn(spec) },
                set: { selection.setOn($0, for: spec) })
    }

    private var textBinding: Binding<String> {
        Binding(get: {
            if case .string(let value) = selection.value(for: spec) { return value }
            return selection.value(for: spec).display
        }, set: { selection.setValue(.string($0), for: spec) })
    }
}

/// A numeric editor that keeps its own draft text.
///
/// Binding the field straight to the selection would fight the user: the value
/// is clamped and re-typed on every keystroke, so an intermediate `""` or `1`
/// would snap the field back mid-edit.  The draft holds what was typed, the
/// selection holds what is valid, and committing on submit shows the latter.
private struct TweakNumberField: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection
    @State private var draft: String

    /// The draft is seeded here, once, and never re-seeded.
    ///
    /// It used to be seeded in `onAppear` — and that assignment is a *change*
    /// like any other, so `onChange(of: draft)` read it as "the user typed this"
    /// and `setValue`, which switches the tweak on the way the reference's
    /// `toggle_enabled=True` does, switched on every number tweak whose row
    /// scrolled into view.  The page then reported 42 tweaks enabled after two
    /// switches were flipped, 38 of them Liquid Glass: 39 of the 41 value-shaped
    /// Liquid Glass specs are numbers, and the row that had not been scrolled to
    /// yet was the difference.  The count grew as the user scrolled, which is
    /// why it was the number on the way *out* that looked wrong.
    ///
    /// A flag set in the same `onAppear` cannot guard this, because `onChange`
    /// runs in the update *after* it, when the flag is already set.  The only
    /// way to keep the seed out of `onChange` is to not make it a change at all.
    init(spec: TweakSpec, selection: Binding<TweakSelection>) {
        self.spec = spec
        self._selection = selection
        self._draft = State(initialValue: selection.wrappedValue.value(for: spec).display)
    }

    var body: some View {
        TextField("value", text: $draft)
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .goldenField()
            .onChange(of: draft) { newValue in
                if let value = spec.numberValue(from: newValue) {
                    selection.setValue(value, for: spec)
                }
            }
            .onSubmit { draft = selection.value(for: spec).display }
    }
}
