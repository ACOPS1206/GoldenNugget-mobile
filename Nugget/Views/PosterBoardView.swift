import SwiftUI
import UniformTypeIdentifiers

/// The PosterBoard page: wallpaper packs, a video wallpaper, and the resets.
///
/// The reference's own page has three tabs — Tendies, Templates, Video — plus a
/// reset dialog.  Templates is not here, and its absence is deliberate: a
/// `.template` is a different file format with its own options engine
/// (`template_file.py` + `template_options/`), and upstream itself lists
/// Templates and PosterBoard as two separate un-ported features.  What *is* here
/// covers everything the other two tabs do, including the video method the reset
/// dialog exists to recover from.
///
/// Three things this page says that the reference does not, all of them because
/// this port has to be honest about what has run on a device:
///
///   * **The database card.** A wallpaper is a descriptor directory *plus* three
///     rows in the store's own sqlite, and the database cannot be synthesised —
///     it has to be fetched from the device.  The card says when that happened
///     last, and the fetch is also the first stage of an apply that needs one.
///   * **The unsafe-container warning** is shown on the pack row rather than in
///     a modal that appears on import: it is a property of the pack, and it stays
///     true for as long as the pack is listed.
///   * **The reset section states what it does not undo.** A reset makes the
///     fetched database stale, so the next apply fetches a fresh one; saying so
///     here is cheaper than the puzzle of a store that half-works.
struct PosterBoardView: View {
    // Options that survive a launch. `@AppStorage` rather than a settings object
    // because there are five of them and none is shared with another page (the
    // contrast is `TweakSelection`, which two pages edit).
    @AppStorage("PosterBoardVideoLoop") private var loop = true
    @AppStorage("PosterBoardVideoReverse") private var reverse = false
    @AppStorage("PosterBoardVideoForeground") private var foreground = false
    @AppStorage("PosterBoardVideoCalculationMode") private var calculationMode = "linear"
    @AppStorage("PosterBoardAutoRefresh") private var autoRefresh = true

    // Per-session, on purpose: these are a one-shot instruction, and a persisted
    // "full reset" would be a loaded gun across launches. Upstream keeps them in
    // memory for the same reason.
    @State private var resetModes: Set<PosterBoardResetMode> = []
    @State private var fullReset = false

    @State private var packs: [PosterBoardTendie] = []
    @State private var video: URL?
    @State private var thumbnail: URL?
    @State private var identity: DeviceIdentity = .unknown
    @State private var databaseSummary = "not checked yet"
    @State private var pickError: String?
    @State private var status: String?
    @State private var statusTone: GoldenTone = .secondary
    @State private var running = false
    @State private var runStarted: Date?

    @State private var showPackImporter = false
    @State private var showVideoImporter = false
    @State private var showThumbnailImporter = false

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            deviceCard
            databaseCard
            packsSection
            videoSection
            resetSection
            applyCard
            if let pickError { errorSection(pickError) }
            if !statusText.isEmpty { GoldenStatusText(text: statusText, tone: statusTone) }
            RunLogCard()
        }
        .navigationTitle("PosterBoard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Loading the pack list and the database state is a directory walk and a
        // file stat, so it happens here and not in `body`.
        .task { reload() }
        .fileImporter(isPresented: $showPackImporter, allowedContentTypes: [.data]) { result in
            importPack(result)
        }
        .fileImporter(isPresented: $showVideoImporter,
                      allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie]) { result in
            importMedia(result, into: PosterBoard.videoDirectory) { video = $0 }
        }
        .fileImporter(isPresented: $showThumbnailImporter, allowedContentTypes: [.heic, .image]) { result in
            importMedia(result, into: PosterBoard.thumbnailDirectory) { thumbnail = $0 }
        }
    }

    // MARK: - Device and database

    private var deviceCard: some View {
        GoldenCard {
            Text(identity.describe)
                .font(GoldenFont.cardTitle)
                .foregroundColor(GoldenTheme.textPrimary)
            GoldenMutedNote(text: "Wallpapers are delivered as files into this app's own backup "
                + "of the device, in the \(PosterBoard.domain) domain — the same channel the "
                + "tweaks use. Nothing is written to the device until Apply.")
        }
    }

    private var databaseCard: some View {
        GoldenSection(
            title: "Store database",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    HStack(spacing: 12) {
                        Text("Automatic refresh")
                            .font(GoldenFont.rowTitle)
                            .foregroundColor(GoldenTheme.textPrimary)
                        Spacer(minLength: 12)
                        GoldenSwitch(isOn: $autoRefresh)
                    }
                    .goldenRowSurface()
                    GoldenActionRow(title: "Fetch database from device",
                                    value: running ? "…" : nil,
                                    systemImage: "arrow.down.circle",
                                    tone: running ? .disabled : .primary) {
                        fetchDatabase()
                    }
                    .disabled(running)
                    GoldenMutedNote(text: databaseNote)
                }
            )
        )
    }

    private var databaseNote: String {
        var lines = [
            "Fetched database: \(databaseSummary)",
            "A wallpaper exists in two places at once — its descriptor files, and three rows in "
                + "the store's own sqlite. The rows carry the device's provider registrations "
                + "and the metadata the picker sorts by, so they cannot be invented: the apply "
                + "fetches the store from the device first and adds rows to a copy of it.",
        ]
        if autoRefresh {
            lines.append("Automatic refresh is on (upstream's default): each apply also writes "
                + "PBF_RESET_FILE_PROTECTIONS, which is what makes PosterBoard re-read the "
                + "store at boot. Turn it off to leave the device's preferences alone.")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Packs

    private var packsSection: some View {
        GoldenSection(
            title: "Wallpaper packs (\(packs.count))",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenActionRow(title: "Import .tendies pack",
                                    systemImage: "plus.circle",
                                    tone: running ? .disabled : .primary) {
                        showPackImporter = true
                    }
                    .disabled(running)
                    if packs.isEmpty {
                        GoldenMutedNote(text: "No packs imported yet. A `.tendies` file is a ZIP "
                            + "holding a wallpaper's descriptor; import one from a wallpaper "
                            + "collection (Cowabunga and CaPlayground publish them), then Apply.")
                    } else {
                        ForEach(packs) { pack in
                            packRow(pack)
                        }
                        GoldenActionRow(title: "Remove all packs",
                                            systemImage: "trash",
                                            tone: running ? .disabled : .error) {
                            packs.forEach(PosterBoardImports.remove)
                            reload()
                        }
                        .disabled(running)
                        GoldenMutedNote(text: "Upstream caps a selection at "
                            + "\(PosterBoardImports.descriptorLimit) descriptors. Each pack is "
                            + "copied into this app, so removing one here removes the copy — "
                            + "the file you imported is untouched.")
                    }
                }
            )
        )
    }

    private func packRow(_ pack: PosterBoardTendie) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pack.name)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pack.summary)
                    .font(GoldenFont.caption)
                    .foregroundColor(pack.isUnsafeContainer ? GoldenTheme.warning
                                                            : GoldenTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button {
                PosterBoardImports.remove(pack)
                reload()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(running ? GoldenTheme.textDisabled : GoldenTheme.error)
            }
            .buttonStyle(.plain)
            .disabled(running)
        }
        .goldenRowSurface()
    }

    // MARK: - Video

    private var videoSection: some View {
        GoldenSection(
            title: "Video wallpaper",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenActionRow(title: "Choose video",
                                    value: video?.lastPathComponent,
                                    systemImage: "film",
                                    tone: running ? .disabled : .primary) {
                        showVideoImporter = true
                    }
                    .disabled(running)
                    goldenToggle("Loop (CoreAnimation frame list)", isOn: $loop)
                    if loop {
                        goldenToggle("Reverse on loop", isOn: $reverse)
                        goldenToggle("Cover the clock", isOn: $foreground)
                        calculationModeRow
                    } else {
                        GoldenActionRow(title: "Choose freeze frame (.heic)",
                                        value: thumbnail?.lastPathComponent,
                                        systemImage: "photo",
                                        tone: running ? .disabled : .primary) {
                            showThumbnailImporter = true
                        }
                        .disabled(running)
                    }
                    if video != nil || thumbnail != nil {
                        GoldenActionRow(title: "Clear the video choice",
                                        systemImage: "xmark.circle",
                                        tone: .error) {
                            PosterBoard.clearFiles(in: PosterBoard.videoDirectory)
                            PosterBoard.clearFiles(in: PosterBoard.thumbnailDirectory)
                            video = nil
                            thumbnail = nil
                        }
                    }
                    GoldenMutedNote(text: videoNote)
                }
            )
        )
    }

    private func goldenToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(GoldenFont.rowTitle)
                .foregroundColor(GoldenTheme.textPrimary)
            Spacer(minLength: 12)
            GoldenSwitch(isOn: isOn)
        }
        .goldenRowSurface()
    }

    /// Four options in one row is 288 pt of text at the narrowest window width,
    /// so this is a menu: it keeps its value on screen instead of wrapping.
    private var calculationModeRow: some View {
        HStack(spacing: 12) {
            Text("Calculation mode")
                .font(GoldenFont.rowTitle)
                .foregroundColor(GoldenTheme.textPrimary)
            Spacer(minLength: 12)
            Picker("", selection: $calculationMode) {
                ForEach(PosterBoardCalculationMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(GoldenTheme.accent)
        }
        .goldenRowSurface()
    }

    private var videoNote: String {
        var lines = [String]()
        if loop {
            lines.append("Looping decodes the video to JPEG frames and hands PosterBoard a "
                + "CoreAnimation frame list (up to \(PosterBoardVideo.frameLimit) frames, at the "
                + "video's own resolution). It is slow, and the frames are written into the "
                + "backup, so a long clip makes a large one — trim it first.")
            lines.append("A video that carries a rotation transform is decoded in its stored "
                + "orientation, which is what the reference's decoder does; such a clip may "
                + "appear rotated on the Lock Screen.")
        } else {
            lines.append("The live-photo method writes the video into a Photos poster descriptor "
                + "and needs a freeze frame — the reference raises rather than shipping a "
                + "descriptor with no thumbnail. The video is rewrapped as .mov unless it "
                + "already is one.")
        }
        if loop && reverse {
            lines.append("Reverse on loop plays the clip forwards and then backwards.")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Reset

    private var resetSection: some View {
        GoldenSection(
            title: "Reset",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    goldenToggle("Full reset — wipe everything and start empty",
                                 isOn: $fullReset)
                    ForEach(PosterBoardResetMode.allCases) { mode in
                        goldenToggle(mode.rawValue, isOn: binding(for: mode))
                    }
                    GoldenSafetyNote(text: resetWarning)
                }
            )
        )
    }

    private func binding(for mode: PosterBoardResetMode) -> Binding<Bool> {
        Binding(
            get: { !fullReset && resetModes.contains(mode) },
            set: { isOn in
                if isOn { resetModes.insert(mode) } else { resetModes.remove(mode) }
            })
    }

    private var resetWarning: String {
        if fullReset {
            return "Full reset: the store's Extensions, GalleryCache and Backups directories are "
                + "zeroed and replaced with an empty database. Every wallpaper on the device is "
                + "gone, and the database fetched before this point is stale — the next apply "
                + "fetches a fresh one."
        }
        if resetModes.isEmpty { return "" }
        let names = resetModes.map(\.rawValue).sorted().joined(separator: ", ")
        return "Selected: \(names). A reset is written as a 0-byte file over the folder, which is "
            + "how the reference clears them; it runs without needing the store database, so it "
            + "is the recovery path for a store that is already misbehaving. It does not undo "
            + "anything already applied."
    }

    // MARK: - Apply

    private var applyCard: some View {
        GoldenCard {
            GoldenMutedNote(text: "Applies this page's selection. Reboot the device afterwards — "
                + "the store is read at boot.")
            GoldenPrimaryButton(title: running ? "Applying…" : "Apply PosterBoard",
                                running: running,
                                disabled: !canApply) {
                apply()
            }
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(runStarted ?? context.date))
                    GoldenStatusText(text: "elapsed \(seconds)s", tone: .secondary)
                }
            }
        }
    }

    private var canApply: Bool {
        !running && (fullReset || !resetModes.isEmpty || !packs.isEmpty || video != nil)
    }

    private var statusText: String { status ?? "" }

    private func errorSection(_ message: String) -> some View {
        GoldenSection(title: "Import failed", content: AnyView(GoldenMutedNote(text: message)))
    }

    // MARK: - Behaviour

    /// The selection this page's controls describe.
    private var selection: PosterBoardSelection {
        PosterBoardSelection(tendies: packs,
                             video: video.map {
                                 PosterBoardVideoPlan(
                                    video: $0,
                                    thumbnail: thumbnail,
                                    loop: loop,
                                    reverse: reverse,
                                    foreground: foreground,
                                    calculationMode: PosterBoardCalculationMode(rawValue: calculationMode)
                                        ?? .linear)
                             },
                             resetModes: fullReset ? [] : resetModes,
                             fullReset: fullReset)
    }

    private func reload() {
        packs = PosterBoardImports.load()
        video = PosterBoard.storedFile(in: PosterBoard.videoDirectory)
        thumbnail = PosterBoard.storedFile(in: PosterBoard.thumbnailDirectory)
        refreshDatabaseSummary()
    }

    private func refreshDatabaseSummary() {
        // The cache is keyed by UDID (upstream does the same), but the page has
        // no UDID outside a run — so it shows the newest database in the
        // directory rather than asking the device to render a label. There is
        // one device behind this app at a time.
        let directory = URL.documents.appendingPathComponent("PosterBoard", conformingTo: .data)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasSuffix(".sqlite3") }.sorted()
        guard let name = candidates.last else {
            databaseSummary = "none yet — an apply that adds a wallpaper fetches one"
            return
        }
        let url = directory.appendingPathComponent(name)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int64,
              let date = attributes?[.modificationDate] as? Date else {
            databaseSummary = name
            return
        }
        let when = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        databaseSummary = "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), "
            + "fetched \(when)"
    }

    private func importPack(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                let existing = packs.reduce(0) { $0 + $1.descriptorCount }
                let pack = try PosterBoardImports.import(from: url)
                // Upstream's cap (`verify_tendie`): a container pack carries no
                // descriptor and so is never counted, which is also what its
                // code does.
                guard existing + pack.descriptorCount <= PosterBoardImports.descriptorLimit else {
                    PosterBoardImports.remove(pack)
                    throw GoldenNuggetError("\(pack.name) carries \(pack.descriptorCount) "
                        + "descriptor(s), which would take the selection to "
                        + "\(existing + pack.descriptorCount). PosterBoard's picker gets "
                        + "unusable past \(PosterBoardImports.descriptorLimit) — remove a pack "
                        + "first.")
                }
                pickError = nil
                reload()
                RunLog.shared.append("PosterBoard: imported \(pack.name) (\(pack.summary))")
            } catch {
                pickError = error.localizedDescription
                reload()
            }
        }
    }

    private func importMedia(_ result: Result<URL, Error>,
                             into directory: URL,
                             assign: (URL) -> Void) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                assign(try PosterBoard.store(url, in: directory))
                pickError = nil
            } catch {
                pickError = error.localizedDescription
            }
        }
    }

    private func fetchDatabase() {
        guard !running else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "Fetching the PosterBoard database…"
        statusTone = .accent
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            do {
                try await GoldenNuggetEngine.shared.fetchPosterBoardDatabase()
                text = "Database fetched."
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
                refreshDatabaseSummary()
            }
        }
    }

    private func apply() {
        guard !running else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "Applying PosterBoard…"
        statusTone = .accent
        let snapshot = selection
        let device = identity
        let refresh = autoRefresh
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            var succeeded = false
            do {
                try await GoldenNuggetEngine.shared.applyPosterBoard(selection: snapshot,
                                                                     deviceVersion: device.version,
                                                                     forceRefresh: refresh)
                text = "Applied. Reboot the device."
                tone = .success
                succeeded = true
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
                // A reset clears the store, so the fetched copy is stale and the
                // next apply must not reuse it; the same is true of a run that
                // added wallpapers the device has not booted into yet.
                if succeeded {
                    resetModes = []
                    fullReset = false
                    refreshDatabaseSummary()
                }
            }
        }
    }
}
