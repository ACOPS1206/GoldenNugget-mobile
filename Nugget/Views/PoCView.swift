import SwiftUI
import UniformTypeIdentifiers
import Minimuxer
import Foundation

struct RootView: View {
    var body: some View {
        NavigationStack {
            PoCView()
        }
        // The reference ships a single palette (`theme.colors.DARK`) and builds
        // its whole iOS GUI on it, so this app is dark-only by design.  Saying so
        // once here keeps every platform control it cannot restyle — text fields,
        // alerts, the share sheet, the document picker — on the same surface as
        // the cards instead of rendering light-on-dark.
        .preferredColorScheme(.dark)
        .tint(GoldenTheme.accent)
    }
}

/// The home page in the GoldenNugget Mobile layout:
/// logo header → feature-card grid → one section per concern → primary action.
///
/// Where the reference puts its six feature cards this app has one destination,
/// so the grid renders one card; the reflow rule behind it is the reference's
/// (`MIN_CARD_WIDTH = 200`, 12 pt gutters), which is what makes the page behave
/// the same on a phone and on the iPad this PoC actually runs on.
///
/// Every control below is the same control it was before — same bindings, same
/// actions, same text.  Only the chrome, spacing and type now come from
/// `GoldenTheme` / `GoldenComponents`.
struct PoCView: View {
    @AppStorage("PairingFile") var pairingFileRaw: String?
    @State var pairingFileURL: String?
    @State var bundleID: String = "com.goldens.victim"
    @State var fileName: String = "poc.txt"
    @State var contents: String = "PoC: iOS 27 app container restore OK"
    @State var running: Bool = false
    @State var showPairingImporter: Bool = false
    @State var showTargetImporter: Bool = false
    @State var showRebootNotice: Bool = false
    @State var logs: [String] = []
    @State var errorText: String?
    @State var runStarted: Date?
    @State var tweakSelection = TweakSelection()

    var body: some View {
        GoldenPage(spacing: GoldenTheme.sectionSpacing) {
            header
            tweakCards
            connectionSection
            targetSection
            runSection
            diagnosticsSection
            if !logs.isEmpty { logSection }
        }
        .navigationTitle("GoldenNugget")
        .navigationBarTitleDisplayMode(.inline)
        // The home page carries its own 80 pt logo header, so the platform bar
        // would be a second, empty one.  Hiding it *here* — not on the pushed
        // page — keeps the Tweaks page's bar, and with it the interactive
        // swipe-back gesture, exactly as the reference's `IOSNavBar` has them.
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            spawnLogPrinter()
            // Claim the process-wide Rust logger before anything can call
            // setLogging()/start(): the Rust side latches the first
            // idevice_init_logger call and would otherwise keep file logging off.
            PoCEngine.shared.enableRustFileLogging()
            if let alt = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String, alt.count > 5000, pairingFileRaw == nil {
                pairingFileRaw = alt
                pairingFileURL = AppPaths.pairingFile.path
                startMinimuxer()
            } else {
                pairingFileURL = pairingFileRaw != nil ? AppPaths.pairingFile.path : nil
            }
        }
        .onOpenURL { url in
            if ["mobiledevicepairing", "mobiledevicepair", "mobiledeviceconfig"].contains(url.pathExtension.lowercased()) {
                do {
                    try loadPairingFile(from: url)
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "?")
        }
        .alert("Apply complete", isPresented: $showRebootNotice) {
            Button("OK") {}
        } message: {
            Text("Reboot the target device so the injected file takes effect.")
        }
    }

    // MARK: - Sections

    /// `home.py`'s header row, with its device/status line folded into the
    /// subtitle — the two states the page already distinguished.
    private var header: some View {
        GoldenHeader(title: "GoldenNugget Mobile",
                     subtitle: paired ? "Pairing file loaded" : "Not connected",
                     subtitleTone: paired ? .accent : .secondary)
    }

    private var tweakCards: some View {
        GoldenCardGrid(itemCount: 1) { _ in
            NavigationLink {
                TweaksView(selection: $tweakSelection)
            } label: {
                GoldenFeatureCardLabel(
                    title: "Tweaks",
                    subtitle: "Customize system settings",
                    // The count that used to be this row's trailing badge.
                    detail: "\(tweakSelection.enabledCount) enabled")
            }
            .buttonStyle(.plain)
        }
    }

    private var connectionSection: some View {
        GoldenSection(
            title: "Connection",
            content: paired
                ? AnyView(GoldenActionRow(title: "Reset pairing file",
                                          systemImage: "arrow.counterclockwise") { resetPairing() })
                : AnyView(GoldenActionRow(title: "Select Pairing File",
                                          systemImage: "doc.badge.plus") {
                    showPairingImporter.toggle()
                })
        )
        .fileImporter(isPresented: $showPairingImporter,
                      allowedContentTypes: Self.pairingFileTypes) { result in
            switch result {
            case .success(let url):
                do {
                    try loadPairingFile(from: url)
                } catch {
                    errorText = error.localizedDescription
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }

    private var targetSection: some View {
        GoldenSection(
            title: "Target",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenLabeledField(label: "Bundle ID") {
                        TextField("com.apple.PosterBoard", text: $bundleID)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    GoldenActionRow(title: "Select target app (.app / .ipa)",
                                    systemImage: "folder") {
                        showTargetImporter.toggle()
                    }
                    .fileImporter(isPresented: $showTargetImporter, allowedContentTypes: {
                        var types: [UTType] = [.folder]
                        if let app = UTType(filenameExtension: "app", conformingTo: .folder) { types.append(app) }
                        if let ipa = UTType(filenameExtension: "ipa", conformingTo: .zip) { types.append(ipa) }
                        return types
                    }()) { result in
                        switch result {
                        case .success(let url):
                            do {
                                bundleID = try AppPackage.bundleID(from: url)
                                PoCEngine.shared.log("Target set from package: \(bundleID) (\(url.lastPathComponent))")
                            } catch {
                                errorText = error.localizedDescription
                            }
                        case .failure(let error):
                            errorText = error.localizedDescription
                        }
                    }
                    GoldenLabeledField(label: "File name") {
                        TextField("poc.txt", text: $fileName)
                            .autocorrectionDisabled()
                    }
                    GoldenLabeledField(label: "Contents") {
                        TextField("", text: $contents, axis: .vertical)
                            .lineLimit(1...4)
                    }
                    // Injected as a row into the pulled backup; see
                    // `BackupInjector.injectSystemPlist`.
                }
            )
        )
    }

    private var runSection: some View {
        GoldenSection(
            title: "Run",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenPrimaryButton(title: running ? "Running…" : "Run Backup → Inject → Restore",
                                        running: running,
                                        disabled: pairingFileURL == nil) {
                        run()
                    }
                    // Elapsed time, not just a spinner: this run has stages that
                    // legitimately take minutes, and a spinner alone cannot tell
                    // "working" from "hung".
                    if running {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let secs = Int(ctx.date.timeIntervalSince(runStarted ?? ctx.date))
                            GoldenStatusText(text: "Elapsed \(secs / 60)m \(secs % 60)s",
                                             tone: .secondary)
                        }
                        // A stall guard that waits minutes for a device that may be
                        // wedged is only safe if it can be stopped by hand. A blocked
                        // Rust read cannot be interrupted, so this abandons the call
                        // and unwinds: the guard notices the flag at its next poll.
                        GoldenDangerButton(title: "Stop run") {
                            PoCEngine.shared.requestCancel()
                        }
                    }
                }
            )
        )
    }

    private var diagnosticsSection: some View {
        GoldenSection(
            title: "Diagnostics",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenActionRow(title: "Dump Diagnostics Into Log",
                                    systemImage: "doc.text.magnifyingglass",
                                    tone: running ? .disabled : .primary) {
                        Task {
                            let block = await PoCEngine.shared.diagnostics()
                            await MainActor.run { logs.append(block) }
                        }
                    }
                    .disabled(running)
                    // Share sheets beat hand-selecting text: the diagnostics block and
                    // the full Rust log are files in Documents.  AirDrop / Save to
                    // Files gets them off the device intact.
                    shareRow(title: "Share diagnostics.txt",
                             systemImage: "square.and.arrow.up",
                             url: PoCEngine.diagnosticsURL,
                             available: hasDiagnostics)
                    shareRow(title: "Share minimuxer.log (\(PoCEngine.rustLogSize() / 1024) KB)",
                             systemImage: "doc.text.magnifyingglass",
                             url: PoCEngine.rustLogURL,
                             available: PoCEngine.rustLogSize() > 0)
                    // The app-side log is a separate file because it is a separate
                    // half of the evidence: the Rust log shows what the protocol did,
                    // this one shows what the host decided (filter keeps, commit
                    // accounting, staging leftovers).
                    shareRow(title: "Share poc.log (\(PoCEngine.appLogSize() / 1024) KB)",
                             systemImage: "doc.plaintext",
                             url: PoCEngine.appLogURL,
                             available: PoCEngine.appLogSize() > 0)
                    GoldenMutedNote(text: "The dump carries a keyword slice of the Rust log "
                        + "(mobilebackup2 protocol + jktcp flow verdict) scoped to this run, plus "
                        + "the app log tail (host-side decisions).")
                }
            )
        )
    }

    private var logSection: some View {
        GoldenSection(title: "Log", content: AnyView(GoldenLogView(lines: logs)))
    }

    /// One share action as a row.  Kept in one place so the three cannot drift
    /// apart — including the disabled look, which the reference expresses as
    /// `text_disabled` rather than by hiding the control.
    private func shareRow(title: String, systemImage: String, url: URL, available: Bool) -> some View {
        ShareLink(item: url) {
            GoldenRowLabel(title: title, systemImage: systemImage,
                           tone: available ? .primary : .disabled)
        }
        .buttonStyle(.plain)
        .goldenRowSurface()
        .disabled(!available)
    }

    private var paired: Bool { pairingFileURL != nil }

    private var hasDiagnostics: Bool {
        FileManager.default.fileExists(atPath: PoCEngine.diagnosticsURL.path)
    }

    // MARK: - Behaviour

    func resetPairing() {
        pairingFileRaw = nil
        pairingFileURL = nil
        logs = []
    }

    // Extensions accepted by the pairing-file picker and onOpenURL handler.
    static let pairingFileTypes: [UTType] = ["mobiledevicepairing", "mobiledevicepair", "mobiledeviceconfig"].compactMap {
        UTType(filenameExtension: $0, conformingTo: .data)
    }

    // Document-picker URLs are security-scoped: reading them without
    // startAccessingSecurityScopedResource fails with "you don't have
    // permission to view it". Copy the file into Documents and use that
    // stable path afterwards (minimuxer reads from Documents too).
    func loadPairingFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let raw = try String(contentsOf: url)
        let dest = AppPaths.pairingFile
        try raw.write(to: dest, atomically: true, encoding: .utf8)
        pairingFileRaw = raw
        pairingFileURL = dest.path
        startMinimuxer()
    }

    func startMinimuxer() {
        guard let pairingFileRaw else { return }
        let docs = URL.documents.path(percentEncoded: false)
        DispatchQueue.global(qos: .userInitiated).async {
            // SideStore-style pre-start guard: the LocalDevVPN tunnel routes to
            // the emulated peer (10.7.0.1:62078). Probe the tunnel first so the
            // RSD adapter/handshake can reach the device before we start.
            let tunnelStage = StageTimer("tunnel probe")
            guard Tunnel.waitForTunnel(log: { line in PoCEngine.shared.log(line) }) else {
                tunnelStage.done("FAILED")
                DispatchQueue.main.async {
                    errorText = "Tunnel not ready: \(Tunnel.peerIP):\(Tunnel.servicePort) unreachable. Enable LocalDevVPN and retry."
                }
                return
            }
            tunnelStage.done("reachable")
            Task {
                do {
                    // FIRST, before setLogging()/start(): the Rust logger latches
                    // on the first idevice_init_logger call in the process, and
                    // setLogging(true) below installs console=Error/file=OFF.
                    PoCEngine.shared.enableRustFileLogging()
                    let minimuxer = Minimuxer.shared()
                    minimuxer.core.setLogging(true)
                    minimuxer.core.setDeviceProbeTimeout(3000)
                    // Bind the localVPN connection mode. Setters are no-ops: the
                    // connection manager auto-discovers the utun peer from the
                    // route table and drives the device endpoint by itself.
                    await minimuxer.core.bindConnectionConfig(ConnectionConfigBinding(
                        setTunnelIfaceIp: { _ in },
                        setTunnelPeerIp: { _ in },
                        setTunnelPeerSubnetMask: { _ in },
                        setTunnelPeerReachable: { _ in },
                        setTunnelIfaceSubnetMask: { _ in },
                        getRemoteServerIp: { "" },
                        setRemoteReachable: { _ in },
                        getOverrideTunnelPeerIp: { "" },
                        setOverrideTunnelPeerReachable: { _ in },
                        getConnectionMode: { .localVPN }
                    ))
                    // Diagnostic: minimuxer's start() requires a top-level "UDID"
                    // string key in the pairing-file plist. Show the real keys so
                    // a wrong pairing file is obvious instead of a bare error.
                    if let keys = await Self.pairingFileTopLevelKeys(pairingFileRaw) {
                        let hasUDID = keys.contains("UDID")
                        PoCEngine.shared.log("pairing file top-level keys: \(keys.isEmpty ? "(empty)" : keys.sorted().joined(separator: ", ")) \(hasUDID ? "[UDID OK]" : "[NO UDID — start() will fail]")")
                    } else {
                        PoCEngine.shared.log("pairing file: NOT a parseable XML/JSON plist")
                    }
                    try await minimuxer.core.start(pairingFile: pairingFileRaw, mountPath: docs)
                    // Readiness wait, deadline-bounded.  This used to be
                    // 20 × 1 s of flat sleeps, so every pairing-file load (and
                    // every app launch with ALTPairingFile) paid up to 20 s
                    // before anything else could happen.  Poll fast at first,
                    // then back off, and stop at a hard deadline.
                    let readyStage = StageTimer("minimuxer readiness")
                    var isReady = false
                    let deadline = Date().addingTimeInterval(20)
                    var poll = 0
                    var delay: UInt64 = 200_000_000   // 0.2 s -> doubles -> 2 s cap
                    while Date() < deadline {
                        poll += 1
                        if case .success(true) = await minimuxer.core.isReady() {
                            isReady = true
                            break
                        }
                        try await Task.sleep(nanoseconds: delay)
                        delay = min(delay * 2, 2_000_000_000)
                    }
                    readyStage.done("ready=\(isReady) after \(poll) poll(s)")
                    PoCEngine.shared.log("minimuxer started. ready=\(isReady)")
                    if !isReady {
                        let tail = RustLog.tail()
                        PoCEngine.shared.log("minimuxer.log tail:\n\(tail)")
                        DispatchQueue.main.async {
                            errorText = "minimuxer started but never became ready.\n\nLast minimuxer.log lines:\n\(tail)"
                        }
                    }
                } catch {
                    let tail = RustLog.tail()
                    PoCEngine.shared.log("minimuxer.log tail:\n\(tail)")
                    DispatchQueue.main.async {
                        errorText = "\(error.localizedDescription)\n\nLast minimuxer.log lines:\n\(tail)"
                    }
                }
            }
        }
    }

    // Parse the pairing file plist and return its top-level keys. minimuxer's
    // start() demands a top-level "UDID" string; if it's absent the lib logs
    // "Couldn't get UDID" and fails before any device/tunnel work.
    static func pairingFileTopLevelKeys(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        guard let dict = obj as? [String: Any] else { return nil }
        return Array(dict.keys)
    }

    func spawnLogPrinter() {
        PoCEngine.shared.onLog = { line in
            logs.append(line)
            // A long run appends a lot (RSD chatter, retries, diagnostics).
            // Keeping the array bounded keeps the list responsive while
            // scrolling through a run.
            if logs.count > 600 {
                logs.removeFirst(logs.count - 600)
            }
        }
    }

    func run() {
        running = true
        runStarted = Date()
        logs = []
        Task {
            var succeeded = false
            do {
                try await PoCEngine.shared.runPoC(
                    bundleID: bundleID,
                    fileName: fileName,
                    contents: contents
                )
                succeeded = true
            } catch let failure as TransportFailure where failure.isCancellation {
                // Stopping on purpose is not a failure — say so, and do not let it
                // read like the device did something wrong.
                PoCEngine.shared.log("⏹ run stopped by the user (\(failure.label))")
            } catch {
                PoCEngine.shared.log("❌ \(error.localizedDescription)")
            }
            await MainActor.run {
                running = false
                runStarted = nil
                if succeeded {
                    showRebootNotice = true
                }
            }
        }
    }

    init() {
        if let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, Selector(("fix_initForOpeningContentTypes:asCopy:"))), let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))) {
            method_exchangeImplementations(origMethod, fixMethod)
        }
    }
}
