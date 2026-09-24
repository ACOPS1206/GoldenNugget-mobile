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
struct TweaksView: View {
    @Binding var selection: TweakSelection

    @State private var identity: DeviceIdentity = .unknown
    @State private var showImporter = false
    @State private var importReport: TweakImportReport?
    @State private var importError: String?
    @State private var running = false
    @State private var outcome: String?
    @State private var tail: [String] = []

    var body: some View {
        List {
            headerSection
            importSection
            tweakSections
            applySection
            if let importReport { reportSection(importReport) }
            if let importError { errorSection(importError) }
            if !tail.isEmpty { logSection }
        }
        .navigationTitle("Tweaks")
        .task { identity = await DeviceIdentity.read() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importAutosave(from: url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(identity.describe).font(.subheadline.bold())
                Text("\(selection.enabledCount) of \(visibleSpecs.count) applicable tweak(s) enabled. "
                    + "Incompatible and un-ported tweaks are hidden, the same way the reference hides them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var importSection: some View {
        Section("Saved state") {
            Button {
                showImporter = true
            } label: {
                Label("Import autosave.json", systemImage: "square.and.arrow.down")
            }
            .disabled(running)
            Button(role: .destructive) {
                selection.removeAll()
                importReport = nil
                importError = nil
            } label: {
                Label("Clear all tweaks", systemImage: "xmark.circle")
            }
            .disabled(running || selection.enabledCount == 0)
            Text("Reads GoldenNugget's preset document (the AutoSave preset it writes on every change). "
                + "Tweaks it names are switched on with their saved values; entries this port does not "
                + "carry are listed below rather than guessed at.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tweakSections: some View {
        ForEach(TweakSection.allCases) { section in
            let specs = visibleSpecs.filter { $0.section == section }
            if !specs.isEmpty {
                let on = specs.filter { selection.isOn($0) }.count
                Section("\(section.rawValue) (\(on)/\(specs.count))") {
                    ForEach(specs, id: \.id) { spec in
                        TweakRow(spec: spec, selection: $selection)
                    }
                }
            }
        }
    }

    private var applySection: some View {
        Section {
            Button {
                apply()
            } label: {
                if running {
                    HStack { ProgressView(); Text("Applying…") }.frame(maxWidth: .infinity)
                } else {
                    Text("Apply \(selection.enabledCount) tweak(s)")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(running || selection.enabledCount == 0)
            if let outcome {
                Text(outcome).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Runs the same protective backup → prune → inject → restore the app-container PoC uses, "
                + "carrying the compiled plists instead. Reboot the device afterwards.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func reportSection(_ report: TweakImportReport) -> some View {
        Section("Import result") {
            ForEach(Array(report.logLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section("Import failed") {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        Section("Run log (last 30 lines)") {
            ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Behaviour

    /// The specs this device can run, in registry order.
    ///
    /// A tweak the device cannot run is hidden, not disabled — that is what
    /// `gui/ios/tweaks.py` does with `is_tweak_compatible`, and an always-inert
    /// switch would be a worse lie than an absent one.
    private var visibleSpecs: [TweakSpec] {
        TweakCatalog.all.filter {
            $0.isCompatible(deviceVersion: identity.version, isIPhone: identity.isIPhone)
        }
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
            for line in report.logLines { PoCEngine.shared.log(line) }
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
            do {
                try await PoCEngine.shared.applyTweaks(selection: snapshot,
                                                       deviceVersion: device.version,
                                                       isIPhone: device.isIPhone)
                result = "Applied. Reboot the device so the injected preferences take effect."
            } catch let failure as TransportFailure where failure.isCancellation {
                result = "⏹ stopped by the user (\(failure.label))"
            } catch {
                result = "❌ \(error.localizedDescription)"
            }
            let lines = Array(PoCEngine.shared.pendingLog.suffix(30))
            await MainActor.run {
                outcome = result
                tail = lines
                running = false
            }
        }
    }
}

/// One tweak row: the editor the registry asks for, plus its description.
///
/// The copy comes from the registry (`TweakSpec.detail`, GoldenNugget's
/// `description=`), not from a second hand-written table — one source of truth
/// for "what does this switch do".
private struct TweakRow: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch spec.kind {
            case .toggle:
                Toggle(isOn: toggleBinding) { Text(spec.title).font(.subheadline) }
            case .text:
                Text(spec.title).font(.subheadline)
                TextField("(empty = clear)", text: textBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            case .number:
                Text(spec.title).font(.subheadline)
                TweakNumberField(spec: spec, selection: $selection)
                Text(spec.numberHint).font(.caption2).foregroundStyle(.secondary)
            }
            Text(spec.id).font(.caption2).foregroundStyle(.tertiary)
            if let detail = spec.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
    @State private var draft: String = ""

    var body: some View {
        TextField("value", text: $draft)
            .keyboardType(.decimalPad)
            .onAppear { draft = selection.value(for: spec).display }
            .onChange(of: draft) { newValue in
                if let value = spec.numberValue(from: newValue) {
                    selection.setValue(value, for: spec)
                }
            }
            .onSubmit { draft = selection.value(for: spec).display }
    }
}
