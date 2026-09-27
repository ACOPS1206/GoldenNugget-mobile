import SwiftUI
import UniformTypeIdentifiers

/// Passcode (lock screen keypad) themes.
///
/// The page imports a `.passthm`, shows what is in it, and writes it into
/// TelephonyUI's caches. The two settings that look like a preference —
/// language and weight — are the part worth explaining: the device picks a file
/// by name, encoding the locale, the weight and the key's subtext, so a theme is
/// a matrix of files rather than a single image, and these two settings decide
/// how much of that matrix gets written.
struct PasscodeThemeView: View {
    @State private var identity: DeviceIdentity = .unknown
    @State private var theme: PasscodeThemeInfo?
    @State private var language: PasscodeLanguageTarget = .all
    @State private var weight: PasscodeBoldTarget = .both
    @State private var log: [String] = []
    @State private var status: String?
    @State private var tone: GoldenTone = .secondary
    @State private var running = false
    @State private var showImporter = false

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            deviceCard
            importCard
            if let theme { previewCard(theme) }
            optionsCard
            applyCard
            if let status { GoldenStatusText(text: status, tone: tone) }
            if !log.isEmpty { runLog }
        }
        .navigationTitle("Passcode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { identity = await DeviceIdentity.read() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            importTheme(result)
        }
    }

    private var blocker: String {
        let reason = Airlift.unsupportedReason(deviceVersion: identity.version)
        if !reason.isEmpty { return reason }
        if !FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) {
            return "AirLift needs a pairing record and none is stored. Import one on the home page."
        }
        return ""
    }

    // MARK: - Cards

    private var deviceCard: some View {
        GoldenCard {
            Text(identity.describe)
                .font(GoldenFont.cardTitle)
                .foregroundColor(GoldenTheme.textPrimary)
            GoldenMutedNote(text: "The keypad's artwork is written into "
                + "/var/mobile/Library/Caches/TelephonyUI-…, which is a cache rather than a "
                + "preference, so a backup cannot carry it. Lock the device to see the result.")
            if !blocker.isEmpty { GoldenMutedNote(text: blocker) }
        }
    }

    private var importCard: some View {
        GoldenCard {
            GoldenActionRow(title: theme == nil ? "Import a .passthm" : "Import another",
                            systemImage: "square.and.arrow.down",
                            tone: .primary) {
                showImporter = true
            }
            if let theme {
                GoldenMutedNote(text: "\(theme.name) — \(theme.fileCount) file(s), "
                    + "\(theme.keysPreview.count) key(s) found.")
            }
        }
    }

    private func previewCard(_ theme: PasscodeThemeInfo) -> some View {
        GoldenSection(
            title: "Keys",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { column in
                                keySlot(theme, row: row, column: column)
                            }
                        }
                    }
                }
            )
        )
    }

    private func keySlot(_ theme: PasscodeThemeInfo, row: Int, column: Int) -> some View {
        let digit = KeypadLayout.digits.first {
            KeypadLayout.row(for: $0) == row && KeypadLayout.column(for: $0) == column
        }
        return VStack(spacing: 4) {
            if let digit, let image = theme.keysPreview[digit] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 44)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(GoldenTheme.backgroundTertiary)
                    .frame(height: 44)
            }
            Text(digit ?? "")
                .font(GoldenFont.value)
                .foregroundColor(GoldenTheme.textDisabled)
        }
        .frame(maxWidth: .infinity)
    }

    private var optionsCard: some View {
        GoldenCard {
            optionRow(title: "Language", selection: $language, choices: PasscodeLanguageTarget.allCases)
            optionRow(title: "Weight", selection: $weight, choices: PasscodeBoldTarget.allCases)
            GoldenMutedNote(text: "The device asks for one file per locale, weight and key "
                + "subtext. \"All languages\" writes every variant — it is the only setting that "
                + "works on a device whose language you do not know — while the device's own "
                + "locale and the fallback are always included either way.")
        }
    }

    /// A titled picker row.
    ///
    /// The platform control is used rather than a hand-drawn one: a picker on iOS
    /// *is* the wheel-and-menu the reference draws, and a switch would be the
    /// wrong shape for a seventeen-value choice.
    private func optionRow<Option: Identifiable & Hashable & RawRepresentable>(
        title: String,
        selection: Binding<Option>,
        choices: [Option]
    ) -> some View where Option.RawValue == String, Option.ID == String {
        HStack(spacing: 12) {
            Text(title)
                .font(GoldenFont.rowTitle)
                .foregroundColor(GoldenTheme.textPrimary)
            Spacer(minLength: 12)
            Picker(title, selection: selection) {
                ForEach(choices) { option in
                    Text(option.id).tag(option)
                }
            }
            .labelsHidden()
            .tint(GoldenTheme.accent)
        }
        .goldenRowSurface()
    }

    private var applyCard: some View {
        GoldenCard {
            GoldenActionRow(
                title: running ? "Applying…" : "Apply theme",
                value: running ? "…" : nil,
                systemImage: "lock.rectangle.stack.fill",
                tone: running || theme == nil || !blocker.isEmpty ? .disabled : .primary
            ) { apply() }
            .disabled(running || theme == nil || !blocker.isEmpty)
            if !blocker.isEmpty { GoldenMutedNote(text: blocker) }
        }
    }

    private var runLog: some View {
        GoldenCard {
            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(GoldenFont.value)
                    .foregroundColor(GoldenTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func importTheme(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            // The importer hands back a security-scoped URL; the archive is read on
            // this side of the boundary, so the scope has to be open for the read —
            // and for the whole unpack, which is where the time goes.
            let scoped = url.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let loaded = try await PasscodeThemeReader.inspect(url: url)
                    theme = loaded
                    status = "Loaded \(loaded.name)."
                    tone = .primary
                } catch {
                    status = error.localizedDescription
                    tone = .error
                }
            }
        case .failure(let error):
            status = error.localizedDescription
            tone = .error
        }
    }

    private func apply() {
        guard let theme else { return }
        running = true
        log = []
        Task { @MainActor in
            defer { running = false }
            do {
                try await PasscodeThemeEngine.apply(
                    theme: theme,
                    language: language,
                    weight: weight,
                    pairingPath: AppPaths.pairingFile.path,
                    log: { line in Task { @MainActor in log.append(line) } },
                    progress: { _ in }
                )
                status = "Theme applied. Lock the device to see it."
                tone = .primary
            } catch {
                status = error.localizedDescription
                tone = .error
            }
        }
    }
}
