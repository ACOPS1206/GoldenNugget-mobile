import SwiftUI
import DeviceGatewayAPI

/// A file browser for whatever the device's AFC service publishes.
///
/// The tree it walks is the device's, not a whitelist: the root is asked for
/// rather than assumed, and every listing is whatever `afcList` returns. That
/// matters because the service publishes different roots on different devices,
/// and a browser that hardcoded `/var/mobile/Media` would look broken on one
/// that publishes containers instead.
///
/// The two things worth reading before using it: this deletes, with no trash and
/// no undo, and it writes through a single-call AFC write capped at 64 MiB. Both
/// limits are stated at the point of action rather than discovered.
struct FilesView: View {
    @State private var path: [String] = []
    @State private var entries: [AfcFsEntry] = []
    @State private var volume: AfcFsVolumeInfo?
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var pullProgress: Double?

    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: AfcFsEntry?
    @State private var renameText = ""
    @State private var deleting: AfcFsEntry?

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            breadcrumbCard
            actionsCard
            listingCard
            if let volume {
                volumeCard(volume)
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): Task { await push(url) }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await performRename() } }
            Button("Cancel", role: .cancel) { renaming = nil; renameText = "" }
        }
        .confirmationDialog(
            deleting.map { "Delete \($0.name)?" } ?? "Delete?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            if let deleting {
                Text(deleting.isDirectory
                     ? "A folder. Nothing goes through a trash here — this is the device's own delete."
                     : "\(AfcFileExplorer.format(deleting.size)) on the device, removed with no trash "
                        + "and no undo.")
            }
        }
    }

    // MARK: - Cards

    private var breadcrumbCard: some View {
        GoldenCard {
            // Horizontal instead of wrapping.  A device path is deeper than any
            // window this app can be given — `/var/mobile/Containers/Data/
            // Application/<UUID>/…` alone is over 300 pt — and letting it wrap
            // made the card grow a line per component while each "/" drifted
            // away from the name it separates.  One line each at natural width,
            // scrolled: a short path looks exactly as before, a long one is
            // reachable without the card changing height.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(path.enumerated()), id: \.offset) { index, component in
                        if index > 0 {
                            Text("/").foregroundColor(GoldenTheme.textDisabled)
                        }
                        Button {
                            path = Array(path.prefix(index + 1))
                            Task { await load() }
                        } label: {
                            Text(component)
                                .font(GoldenFont.rowTitle)
                                .foregroundColor(index == path.count - 1
                                                 ? GoldenTheme.textPrimary
                                                 : GoldenTheme.accent)
                                // Natural width, never compressed: the scroll
                                // view is what absorbs the overflow.
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                    }
                    if loading { ProgressView().goldenField() }
                }
            }
            if let error {
                GoldenMutedNote(text: error)
            } else if let status {
                GoldenMutedNote(text: status)
            }
        }
    }

    private var actionsCard: some View {
        GoldenCard {
            GoldenActionRow(title: "Upload here", systemImage: "square.and.arrow.up",
                            tone: busy ? .disabled : .primary) {
                showImporter = true
            }
            GoldenActionRow(title: "New folder", systemImage: "folder.badge.plus",
                            tone: busy ? .disabled : .primary) {
                newFolderName = ""
                showNewFolder = true
            }
            GoldenActionRow(title: "Up one level", systemImage: "arrow.up.to.line",
                            tone: busy || path.isEmpty ? .disabled : .secondary) {
                guard !path.isEmpty else { return }
                path.removeLast()
                Task { await load() }
            }
            GoldenMutedNote(text: "Writes are capped at "
                + "\(AfcFileExplorer.format(AfcFileExplorer.pushSizeLimit)): the AFC write is a single "
                + "call with no streaming form, so a larger file is refused rather than truncated.")
        }
    }

    /// The header and the rows are **siblings** on purpose: a `GoldenSection`
    /// wraps its content in a `VStack`, which the page's lazy stack treats as one
    /// child — so every entry in the listing (three rows each) was built on the
    /// first pass, however long the directory is.  Emitting the header and a bare
    /// `ForEach` instead lets a row be built when it scrolls into view.  Same
    /// reason the tweaks page's sections were split (see `GoldenCollapsibleHeader`).
    @ViewBuilder
    private var listingCard: some View {
        GoldenSectionHeader(text: "Contents (\(entries.count))")
        if entries.isEmpty, !loading {
            GoldenMutedNote(text: "Nothing here.")
        }
        ForEach(entries) { entry in
            row(entry)
        }
        if let pullProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: pullProgress)
                GoldenMutedNote(text: "Pulling \(Int(pullProgress * 100))%")
            }
        }
    }

    private func row(_ entry: AfcFsEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if entry.isDirectory {
                    Button { open(entry) } label: {
                        label(entry, tint: GoldenTheme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    label(entry, tint: GoldenTheme.textPrimary)
                }
                Spacer(minLength: 8)
                if entry.isDirectory {
                    Button { renaming = entry; renameText = entry.name } label: {
                        Image(systemName: "pencil").foregroundColor(GoldenTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                Button { deleting = entry } label: {
                    Image(systemName: "trash").foregroundColor(GoldenTheme.error)
                }
                .buttonStyle(.plain)
            }
            if let link = entry.linkTarget {
                GoldenMutedNote(text: "Symlink → \(link). Not followed, not pulled.")
            }
            if !entry.isDirectory {
                HStack(spacing: 10) {
                    GoldenActionRow(title: "Pull", systemImage: "arrow.down.to.line",
                                    tone: busy ? .disabled : .secondary) {
                        Task { await pull(entry) }
                    }
                    GoldenActionRow(title: "Rename", systemImage: "pencil",
                                    tone: busy ? .disabled : .secondary) {
                        renaming = entry
                        renameText = entry.name
                    }
                }
            }
        }
        .goldenRowSurface()
    }

    private func label(_ entry: AfcFsEntry, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: entry.isDirectory
                      ? "folder.fill"
                      : (entry.linkTarget != nil ? "link" : "doc"))
                // One line, truncated in the middle.  A device filename is
                // routinely 40+ characters, which in a 288 pt window wrapped to
                // two or three lines and made every long entry a block — the
                // list stopped scanning as a list.  Middle truncation keeps the
                // extension, which is the part a browser is usually read for.
                Text(entry.name)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(entry.isDirectory
                 ? "folder"
                 : AfcFileExplorer.format(entry.size))
                .font(GoldenFont.caption)
                .foregroundColor(GoldenTheme.textDisabled)
        }
    }

    private func volumeCard(_ volume: AfcFsVolumeInfo) -> some View {
        GoldenCard {
            GoldenRowLabel(title: "Volume",
                           value: "\(AfcFileExplorer.format(volume.freeBytes)) free of "
                            + "\(AfcFileExplorer.format(volume.totalBytes))",
                           systemImage: "internaldrive")
            GoldenMutedNote(text: volume.model)
        }
    }

    // MARK: - Actions

    private func open(_ entry: AfcFsEntry) {
        guard entry.isDirectory else { return }
        path.append(entry.name)
        Task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await AfcFileExplorer.children(of: AfcFileExplorer.join(path))
            volume = try? await AfcFileExplorer.volume()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pull(_ entry: AfcFsEntry) async {
        busy = true
        pullProgress = 0
        defer { busy = false; pullProgress = nil }
        do {
            let local = try await AfcFileExplorer.pull(entry) { fraction in
                Task { @MainActor in pullProgress = fraction }
            }
            status = "Pulled \(entry.name) → \(local.lastPathComponent)"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func push(_ url: URL) async {
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let entry = try await AfcFileExplorer.push(url, to: AfcFileExplorer.join(path))
            status = "Uploaded \(entry.name)"
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createFolder() async {
        busy = true
        defer { busy = false }
        let name = newFolderName
        newFolderName = ""
        do {
            try await AfcFileExplorer.makeDirectory(named: name, in: AfcFileExplorer.join(path))
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performRename() async {
        guard let entry = renaming else { return }
        let text = renameText
        renaming = nil
        renameText = ""
        busy = true
        defer { busy = false }
        do {
            try await AfcFileExplorer.rename(entry, to: text)
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performDelete() async {
        guard let entry = deleting else { return }
        deleting = nil
        busy = true
        defer { busy = false }
        do {
            try await AfcFileExplorer.delete(entry)
            status = "Deleted \(entry.name)"
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
