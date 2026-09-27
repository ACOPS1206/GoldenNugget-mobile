import SwiftUI
import UniformTypeIdentifiers
import Minimuxer
import Foundation

/// The home page, laid out the way the reference's iOS home page lays it out
/// (`src/gui/ios/home.py`): logo header carrying the device line and a refresh
/// button → the connection status line → the feature-card grid → Apply Tweaks →
/// the danger action → the centred process-status line.  What this app needs on
/// top of that (pairing file, tunnel, diagnostics, log) sits below, because the
/// reference keeps all of it on its own pages.
///
/// The reference draws six feature cards; five of them — PosterBoard, Daemons,
/// Status Bar, Icon Themes, Passcode Theme — are not ported, so the grid renders
/// the one that is.  The reflow rule behind the grid is the reference's
/// (`MIN_CARD_WIDTH = 200`, 12 pt gutters), which is what makes the page behave
/// the same on a phone and on the iPad this app actually runs on.
struct GoldenNuggetView: View {
    /// The pairing record.  **Not** page state: whether the app is paired is a
    /// process-wide fact (`PairingStore`), because a re-created view cannot be
    /// allowed to forget it.  See that file for why the `@AppStorage` +
    /// `@State` pair it replaces lost the pairing on a relaunch.
    @ObservedObject private var pairing = PairingStore.shared
    // The tunnel addressing, persisted under the same keys `Tunnel` reads (see
    // `Tunnel.Key`), so the fields below and every probe are looking at one set
    // of values.  `@AppStorage` rather than `@State` because the tunnel is
    // probed from background queues and from `NuggetApp.init` — a value that
    // only lived in the view would not be there when it is read.
    @AppStorage(Tunnel.Key.ifaceIP) var tunnelIfaceIP = Tunnel.defaultIfaceIP
    @AppStorage(Tunnel.Key.peerIP) var tunnelPeerIP = Tunnel.defaultPeerIP
    @AppStorage(Tunnel.Key.port) var tunnelPort = String(Tunnel.defaultServicePort)
    @AppStorage(Tunnel.Key.prefixLength) var tunnelPrefixLength = String(Tunnel.defaultPrefixLength)
    /// Whether the sidebar is a column of its own or a stack behind the detail —
    /// see `navBarVisibility`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Launch auto-start bookkeeping, **owned by `RootView`**: `startMinimuxer`'s
    /// lock only rejects *concurrent* attempts, so this has to outlive the view
    /// that reads it even though what it guards is process-wide.  It keeps a
    /// second `.task` pass from starting the core twice.
    ///
    /// The companion it used to have here — "the user said no to the embedded
    /// pairing record" — moved into `PairingStore`, because "Reset pairing file"
    /// has to survive the relaunch that would otherwise undo it.
    @Binding var didAutoStart: Bool
    @State private var running = false
    @State private var showPairingImporter = false
    @State private var showRebootNotice = false
    // The run log is not page state any more: `RunLog` owns it and `RunLogCard`
    // is the only observer, so a logged line no longer re-evaluates this
    // page's `body` (see `RunLog`'s note — that is where the per-line disk
    // read came from).

    @State private var errorText: String?
    @State private var runStarted: Date?
    /// The tweak selection, owned by `RootView` because a `NavigationSplitView`
    /// replaces its detail view on every sidebar selection: as page state it
    /// would have been discarded the moment another destination was picked.
    @Binding var tweakSelection: TweakSelection
    /// The pending debounced autosave, cancelled and replaced on every change.
    @State private var autosaveTask: Task<Void, Never>?
    @State private var identity = DeviceIdentity.unknown
    @State private var readingDevice = false
    /// `home.py: process_status_lbl` — the coloured line under the buttons, which
    /// the reference hides again six seconds after it was set.
    @State private var status = ""
    @State private var statusTone: GoldenTone = .primary
    /// Bumped by every status write so a hide scheduled for an older message
    /// cannot wipe the one that replaced it.
    @State private var statusToken = 0
    @State private var progress: Double?
    @State private var tunnelExpanded = false
    /// The tunnel status line's two halves, **cached** rather than computed in
    /// the body.
    ///
    /// `Tunnel.describe()` and — much worse — `Tunnel.probePeer()` used to be
    /// interpolated straight into the disclosure's `Text`.  `probePeer` is a
    /// non-blocking connect followed by a `poll()` that waits **up to two
    /// seconds** (`timeout: 2.0`) for the peer's lockdown port, and it ran on the
    /// main thread on **every** body pass: scrolling the page, any state change,
    /// or tapping a `NavigationLink` (the page re-renders while the destination is
    /// pushed).  A two-second stall inside body evaluation is the reported freeze.
    ///
    /// `refreshTunnelStatus()` fills both, off the main actor, and only while the
    /// disclosure is open.
    @State private var tunnelSummary = "not probed"
    @State private var peerReachable: Bool?

    /// Explicit, so `AppShell.swift` gets a signature it can depend on.
    ///
    /// The synthesized memberwise initializer covers these two (they are the
    /// only stored properties without a default), but its parameters come out in
    /// **declaration order** — `didAutoStart:tweakSelection:` — so the call site
    /// would silently depend on where each one happens to sit among a dozen
    /// other properties, and moving one breaks a different file.
    /// Everything else keeps its default.
    ///
    /// Note this initializer is also why one was needed at all: a custom `init()`
    /// suppresses the memberwise one, and the only `init()` this struct used to
    /// have (a `UIDocumentPickerViewController` swizzle) could not initialize
    /// these — which surfaced as "return from initializer without initializing
    /// all stored properties".
    init(tweakSelection: Binding<TweakSelection>,
         didAutoStart: Binding<Bool>) {
        _tweakSelection = tweakSelection
        _didAutoStart = didAutoStart
    }

    var body: some View {
        GoldenPage(spacing: GoldenTheme.sectionSpacing) {
            header
            connectionLine
            tweakCards
            applyCard
            clearCard
            if !status.isEmpty { processStatus }
            connectionSection
            diagnosticsSection
            RunLogCard()
        }
        .navigationTitle("GoldenNugget")
        .navigationBarTitleDisplayMode(.inline)
        // The home page carries its own logo header, so the platform bar would be
        // a second, empty one.  Hiding it *here* — not on the pushed page — keeps
        // the Tweaks page's bar, and with it the interactive swipe-back gesture,
        // exactly as the reference's `IOSNavBar` has them.
        //
        // Except when the split view is collapsed (`.compact`: Slide Over, a
        // third of the screen): there the same bar is the **only** way back to
        // the sidebar, and hiding it would strand the user on this page.
        .toolbar(navBarVisibility, for: .navigationBar)
        // Owned here, next to the selection itself, rather than inside one of the
        // pages that can change it. It was on TweaksView, which made persistence
        // depend on navigation: a daemon switched on the Daemons page changed the
        // selection while the only observer sat in a view that was not in the
        // hierarchy, so nothing was written. It looked intermittent, because
        // touching any tweak afterwards swept the daemon along with it.
        .onChange(of: tweakSelection) { _, _ in scheduleAutosave() }
        // Probe only while the tunnel details are open, and never in a body: the
        // probe can wait two seconds for the peer, and two seconds on the main
        // thread is a frozen scroll.  `.task(id:)` cancels the loop when the
        // disclosure closes.
        .task(id: tunnelExpanded) {
            guard tunnelExpanded else { return }
            while !Task.isCancelled {
                await refreshTunnelStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task {
            spawnLogPrinter()
            // The Rust progress callbacks fire on their own queues; the handler
            // hops to the main actor itself.  `NaN` is the "run finished, drop
            // the percentage" signal — see `GoldenNuggetEngine.clearProgress`.
            GoldenNuggetEngine.shared.onProgress = { value in
                Task { @MainActor in progress = value.isNaN ? nil : value }
            }
            // Claim the process-wide Rust logger before anything can call
            // setLogging()/start(): the Rust side latches the first
            // idevice_init_logger call and would otherwise keep file logging off.
            GoldenNuggetEngine.shared.enableRustFileLogging()
            // `PairingStore.bootstrap()` is idempotent, so this is also the
            // self-heal: a view handed a fresh identity re-reads the same
            // durable record instead of coming up unpaired.  It is what the
            // old `reimportPairingFile()` did, minus the two in-memory flags
            // that decided whether it ran at all.
            let havePairing = pairing.bootstrap()
            if havePairing, !didAutoStart {
                didAutoStart = true
                startMinimuxer()
            }
            await readDevice()
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
        .alert("Applied", isPresented: $showRebootNotice) {
            Button("OK") {}
        } message: {
            Text("Reboot the target device so the injected preferences take effect.")
        }
    }

    // MARK: - Sections

    /// `.hidden` in a regular width, where the sidebar is already on screen;
    /// `.automatic` in a compact one, where the bar carries the control that
    /// reveals it.
    private var navBarVisibility: Visibility {
        horizontalSizeClass == .compact ? .automatic : .hidden
    }


    /// `home.py`'s header row: logo, title, and the device line under it.
    ///
    /// The reference puts a device picker next to the title and a refresh button
    /// after it.  There is no picker to put here — this app drives exactly one
    /// device — so the refresh button is the whole control, and it is worth
    /// having: the device line is read from lockdown, and a page that was opened
    /// before the tunnel was up kept saying "unknown device" until it was left
    /// and re-entered.
    private var header: some View {
        GoldenHeader(title: "GoldenNugget", subtitle: identity.describe) {
            GoldenIconButton(systemImage: "arrow.clockwise",
                             enabled: paired && !readingDevice) {
                Task {
                    await readDevice()
                    await refreshTunnelStatus()
                }
            }
        }
    }

    /// `home.py: update_status` — the same three states in the same colours:
    /// green "Supported!", amber "Partially Supported" when a pairing file is
    /// loaded but lockdown has not said what the device is, plain
    /// "Not connected" otherwise.
    private var connectionLine: some View {
        GoldenStatusText(text: connectionState.text, tone: connectionState.tone)
    }

    private var connectionState: (text: String, tone: GoldenTone) {
        guard paired else { return ("Not connected", .secondary) }
        guard !identity.version.isEmpty else { return ("Partially Supported", .warning) }
        return ("Supported!", .success)
    }

    /// The trailing badge on the Media card: what the local store is holding,
    /// read from the manifest rather than from a directory walk, so it costs
    /// nothing on every body pass.
    private var mediaDetail: String {
        let m = try? AfcMediaBackup.read()
        let n = m?.entries.count ?? 0
        if n == 0 { return "Empty" }
        let bytes = m?.entries.reduce(Int64(0)) { $0 + $1.size } ?? 0
        return "\(n) file(s), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    /// The cards and the sidebar drive the **same** stack, so they cannot
    /// disagree about what is showing: these are `NavigationLink(value:)` with
    /// the destination declared once, in `RootView`'s `navigationDestination`,
    /// rather than links carrying their own view.  A view-carrying link pushed a
    /// page the path knew nothing about, and in a split view that left the
    /// sidebar still highlighting "GoldenNugget" over a Tweaks page.
    private var tweakCards: some View {
        GoldenCardGrid(itemCount: 5) { index in
            switch index {
            case 0:
                NavigationLink(value: AppDestination.tweaks) {
                    GoldenFeatureCardLabel(
                        title: "Tweaks",
                        subtitle: "Customize system settings",
                        // The count that used to be this row's trailing badge.
                        detail: "\(registryTweakCount) enabled")
                }
                .buttonStyle(.plain)
            case 1:
                NavigationLink(value: AppDestination.daemons) {
                    GoldenFeatureCardLabel(
                        title: "Daemons",
                        subtitle: "Launchd services",
                        detail: "\(enabledDaemonCount) of \(DaemonGroups.all.count) groups")
                }
                .buttonStyle(.plain)
            case 2:
                NavigationLink(value: AppDestination.supervision) {
                    GoldenFeatureCardLabel(
                        title: "Supervision",
                        subtitle: "Device supervision",
                        detail: supervisionDetail)
                }
                .buttonStyle(.plain)
            case 3:
                NavigationLink(value: AppDestination.media) {
                    GoldenFeatureCardLabel(
                        title: "Media",
                        subtitle: "Photos and videos",
                        detail: mediaDetail)
                }
                .buttonStyle(.plain)
            default:
                NavigationLink(value: AppDestination.files) {
                    GoldenFeatureCardLabel(
                        title: "Files",
                        subtitle: "Browse the device",
                        detail: "Over AFC")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Only the registry tweaks carry this badge; daemons are counted by group
    /// because that is the unit their switches work in.
    private var registryTweakCount: Int {
        tweakSelection.enabledCount - enabledDaemonCount
    }

    private var enabledDaemonCount: Int {
        DaemonGroups.all.filter { group in
            tweakSelection.isOn(TweakCatalog.byID["Daemon.\(group.name)"]!)
        }.count
    }

    private var supervisionDetail: String {
        SupervisionSettings.shared.isSupervised ? "supervised" : "not supervised"
    }

    /// The reference's apply card (`IOSApplyPage`: a description, the button, and
    /// a progress line) in the place its home page puts the button — under the
    /// cards.
    private var applyCard: some View {
        GoldenCard {
            GoldenMutedNote(text: "Applies every enabled tweak to the device. "
                + "Reboot it when this is done — the injected preferences are read at boot.")
            GoldenPrimaryButton(title: running ? "Applying…" : "Apply Tweaks",
                                running: running,
                                disabled: !canApply) {
                applyTweaks()
            }
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = Int(ctx.date.timeIntervalSince(runStarted ?? ctx.date))
                    GoldenStatusText(text: elapsedText(secs), tone: .secondary)
                }
                // A stall guard that waits minutes for a device that may be
                // wedged is only safe if it can be stopped by hand. A blocked
                // Rust read cannot be interrupted, so this abandons the call
                // and unwinds: the guard notices the flag at its next poll.
                GoldenDangerButton(title: "Stop run") {
                    GoldenNuggetEngine.shared.requestCancel()
                }
            }
        }
    }

    /// Named for the reference's button, but not the reference's behaviour: that
    /// one restores the original values on the device, and undoing an apply here
    /// would mean putting back a backup taken before it. So the title is the
    /// familiar one and the card says what this actually does.
    private var clearCard: some View {
        GoldenCard {
            GoldenMutedNote(text: "Turns every tweak off in this app. The device is not "
                + "touched: to undo an apply, restore a backup from before it.")
            GoldenDangerButton(title: "Reset Tweaks",
                               disabled: tweakSelection.enabledCount == 0) {
                tweakSelection.removeAll()
                showStatus("Tweaks reset.", .warning)
            }
        }
    }

    /// `home.py: process_status_lbl` — centred, coloured by outcome.
    @ViewBuilder
    private var processStatus: some View {
        GoldenStatusText(text: status, tone: statusTone, centered: true)
    }

    private var connectionSection: some View {
        GoldenSection(
            title: "Connection",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    if paired {
                        GoldenActionRow(title: "Reset pairing file",
                                        systemImage: "arrow.counterclockwise") { resetPairing() }
                    } else {
                        GoldenActionRow(title: "Select Pairing File",
                                        systemImage: "doc.badge.plus") {
                            showPairingImporter.toggle()
                        }
                    }
                    tunnelDisclosure
                }
            )
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

    /// The tunnel addressing, folded away by default.
    ///
    /// It is four fields and two paragraphs of explanation, and the reference's
    /// home page carries nothing of the kind — this app's stand-in for the
    /// device picker is the pairing file above it.  Open, it is the same editor
    /// with the same validation; closed, it states the values in use, which is
    /// the part a session that already works never needs to look at twice.
    private var tunnelDisclosure: some View {
        DisclosureGroup(isExpanded: $tunnelExpanded) {
            VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                GoldenMutedNote(text: "How this app finds the LocalDevVPN tunnel: it waits for the "
                    + "tunnel IP on an interface, then probes the peer's lockdown port. "
                    + "\(Tunnel.isCustomised ? "Custom values in use." : "Defaults in use.") "
                    + "These steer this app only — the vendored library finds the peer from the "
                    + "route table and always dials 62078.")
                GoldenLabeledField(label: "Tunnel IP (this device)") {
                    TextField(Tunnel.defaultIfaceIP, text: $tunnelIfaceIP)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                }
                if !tunnelIfaceIPOK {
                    GoldenSafetyNote(text: "Not an IPv4 address — \(Tunnel.defaultIfaceIP) is being probed instead.")
                }
                GoldenLabeledField(label: "Peer IP (the VPN server)") {
                    TextField(Tunnel.defaultPeerIP, text: $tunnelPeerIP)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                }
                if !tunnelPeerIPOK {
                    GoldenSafetyNote(text: "Not an IPv4 address — \(Tunnel.defaultPeerIP) is being probed instead.")
                }
                GoldenLabeledField(label: "Lockdown port") {
                    TextField(String(Tunnel.defaultServicePort), text: $tunnelPort)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // `.numberPad` has no Return key, so on a phone this
                        // keyboard could not be dismissed at all.
                        .keyboardType(.numberPad)
                        .goldenKeyboardDone()
                }
                if !tunnelPortOK {
                    GoldenSafetyNote(text: "Not a port in 1…65535 — \(Tunnel.defaultServicePort) is being probed instead.")
                }
                GoldenLabeledField(label: "Tunnel IP prefix length") {
                    TextField(String(Tunnel.defaultPrefixLength), text: $tunnelPrefixLength)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // `.numberPad` has no Return key, so on a phone this
                        // keyboard could not be dismissed at all.
                        .keyboardType(.numberPad)
                        .goldenKeyboardDone()
                }
                if !tunnelPrefixOK {
                    GoldenSafetyNote(text: "Not 0…32 — LocalDevVPN's tunnel-IP field takes a CIDR, and this is the part after the slash.")
                }
                GoldenMutedNote(text: "Copy into LocalDevVPN: tunnel IP \(Tunnel.ifaceIP)/\(Tunnel.ifacePrefixLength), peer \(Tunnel.peerIP), port \(Tunnel.servicePort).")
                // Both values come from state — see `tunnelSummary`.  The probe
                // is a 2 s `poll()` and must never run in a body.
                GoldenStatusText(text: "tunnel: \(tunnelSummary) · peer \(Tunnel.peerIP):\(Tunnel.servicePort) "
                    + "reachable: \(peerReachable.map(String.init) ?? "…")")
                GoldenActionRow(title: "Reset tunnel addresses", systemImage: "arrow.counterclockwise") {
                    Tunnel.resetToDefaults()
                    tunnelIfaceIP = Tunnel.defaultIfaceIP
                    tunnelPeerIP = Tunnel.defaultPeerIP
                    tunnelPort = String(Tunnel.defaultServicePort)
                    tunnelPrefixLength = String(Tunnel.defaultPrefixLength)
                    GoldenNuggetEngine.shared.log("tunnel addresses reset to defaults: \(Tunnel.requirements)")
                    Task { await refreshTunnelStatus() }
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunnel settings")
                    .font(GoldenFont.cardTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                GoldenValueLabel(text: Tunnel.requirements)
            }
        }
        .tint(GoldenTheme.accent)
        .goldenRowSurface()
    }

    // A value is only "in use" when it survives the same validator `Tunnel`
    // applies before probing, so the field cannot claim to be set to something
    // the app is silently ignoring.
    private var tunnelIfaceIPOK: Bool { Tunnel.isValidIPv4(tunnelIfaceIP) != nil }
    private var tunnelPeerIPOK: Bool { Tunnel.isValidIPv4(tunnelPeerIP) != nil }
    private var tunnelPortOK: Bool { Tunnel.validPort(tunnelPort) != nil }
    private var tunnelPrefixOK: Bool { Tunnel.validPrefixLength(tunnelPrefixLength) != nil }

    private var diagnosticsSection: some View {
        GoldenSection(
            title: "Diagnostics",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenActionRow(title: "Dump Diagnostics Into Log",
                                    systemImage: "doc.text.magnifyingglass",
                                    tone: running ? .disabled : .primary) {
                        Task {
                            let block = await GoldenNuggetEngine.shared.diagnostics()
                            RunLog.shared.append(block)
                        }
                    }
                    .disabled(running)
                    // Share sheets beat hand-selecting text: the diagnostics block and
                    // the full Rust log are files in Documents.  AirDrop / Save to
                    // Files gets them off the device intact.
                    shareRow(title: "Share diagnostics.txt",
                             systemImage: "square.and.arrow.up",
                             url: GoldenNuggetEngine.diagnosticsURL,
                             available: hasDiagnostics)
                    shareRow(title: "Share minimuxer.log (\(GoldenNuggetEngine.rustLogSize() / 1024) KB)",
                             systemImage: "doc.text.magnifyingglass",
                             url: GoldenNuggetEngine.rustLogURL,
                             available: GoldenNuggetEngine.rustLogSize() > 0)
                    // The app-side log is a separate file because it is a separate
                    // half of the evidence: the Rust log shows what the protocol did,
                    // this one shows what the host decided (filter keeps, commit
                    // accounting, staging leftovers).
                    shareRow(title: "Share goldennugget.log (\(GoldenNuggetEngine.appLogSize() / 1024) KB)",
                             systemImage: "doc.plaintext",
                             url: GoldenNuggetEngine.appLogURL,
                             available: GoldenNuggetEngine.appLogSize() > 0)
                    GoldenMutedNote(text: "The dump carries a keyword slice of the Rust log "
                        + "(mobilebackup2 protocol + jktcp flow verdict) scoped to this run, plus "
                        + "the app log tail (host-side decisions).")
                }
            )
        )
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

    private var paired: Bool { pairing.isPaired }

    private var canApply: Bool { paired && tweakSelection.enabledCount > 0 && !running }

    private var hasDiagnostics: Bool {
        FileManager.default.fileExists(atPath: GoldenNuggetEngine.diagnosticsURL.path)
    }

    // MARK: - Behaviour

    func resetPairing() {
        // The store deletes the file in Documents as well as the mirror and the
        // in-memory record.  Deleting the file is what makes the reset survive
        // a relaunch: the restore path reads Documents first, so leaving it
        // behind used to bring the record straight back.
        pairing.reset()
        didAutoStart = false
        RunLog.shared.clear()
    }

    // Extensions accepted by the pairing-file picker and onOpenURL handler.
    static let pairingFileTypes: [UTType] = ["mobiledevicepairing", "mobiledevicepair", "mobiledeviceconfig"].compactMap {
        UTType(filenameExtension: $0, conformingTo: .data)
    }

    func loadPairingFile(from url: URL) throws {
        // Copies into Documents, validates, and publishes — see `PairingStore`.
        try pairing.importFrom(url)
        startMinimuxer()
    }

    /// Re-read the device line.  Called on entry and by the header's refresh
    /// button, so a page that was opened before the tunnel came up does not sit
    /// on "unknown device" until it is navigated away from.
    /// Write the selection 500 ms after the last change -- the reference's
    /// `_on_tweak_changed` debounce (`QTimer.singleShot(500, ...)`).
    ///
    /// A pending save is replaced, not queued, so dragging a number field writes
    /// once at the end rather than once per keystroke. The document is 130+ specs
    /// of JSON written into Documents, so it goes off the main actor; the snapshot
    /// and the identity are value types, and only the resulting flag comes back.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = tweakSelection
        let device = identity
        autosaveTask = Task {
            try? await Task.sleep(for: GoldenNuggetAutosave.debounce)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                GoldenNuggetAutosave.save(snapshot, identity: device)
            }.value
        }
    }

    /// Fill the tunnel status line, off the main actor.
    ///
    /// `Task.detached` on purpose: `probePeer` waits up to two seconds for the
    /// peer's lockdown port, and both halves read process-wide state (`Tunnel`'s
    /// addresses come from `@AppStorage`), so nothing here needs the main actor
    /// until the two assignments.
    private func refreshTunnelStatus() async {
        let (summary, reachable) = await Task.detached(priority: .utility) {
            (Tunnel.describe(), Tunnel.probePeer())
        }.value
        tunnelSummary = summary
        peerReachable = reachable
    }

    private func readDevice() async {
        guard paired else { return }
        readingDevice = true
        // Wait for the device before reading it.  `.task` starts minimuxer and
        // calls this immediately after, so the first read races the gateway
        // coming up and comes back `.unknown` — which used to be logged as "the
        // device has not answered lockdown yet" and then kept for the rest of
        // the session.  An empty identity is not harmless here: it *disables*
        // the registry's version bounds (`TweakSpec.isCompatible` skips them on
        // an empty version, as the reference does) and it parses to major 0,
        // which is how a 27.0 device ended up on the engine's iOS 26 branch and
        // died with `205 — No keybag in manifest` (2026-09-26).  Same bounded
        // poll the rest of the app waits with: fast at first, then backing off.
        var read = await DeviceIdentity.read()
        if read == .unknown {
            let deadline = Date().addingTimeInterval(15)
            var attempt = 0
            var delay: UInt64 = 300_000_000              // 0.3 s -> doubles -> 2 s cap
            while read == .unknown, Date() < deadline {
                attempt += 1
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 2_000_000_000)
                read = await DeviceIdentity.read()
            }
            if read != .unknown {
                GoldenNuggetEngine.shared.log("device identity: lockdownd answered on attempt "
                    + "\(attempt + 1), after the first read raced minimuxer's start")
            }
        }
        identity = read
        readingDevice = false
        if read == .unknown {
            GoldenNuggetEngine.shared.log("device identity unavailable — the device has not answered lockdown yet")
        } else {
            GoldenNuggetEngine.shared.log("device identity: \(read.describe)")
        }
        // Load the selection here rather than when the Tweaks tab is built, so
        // the cards above count the restored selection instead of zero.
        if let report = AutoSaveBootstrap.apply(into: &tweakSelection, identity: read) {
            for line in report.logLines { GoldenNuggetEngine.shared.log(line) }
        }
    }

    private func applyTweaks() {
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        showStatus("Applying tweaks…", .accent, autoHide: false)
        let snapshot = tweakSelection
        let device = identity
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            var succeeded = false
            do {
                try await GoldenNuggetEngine.shared.applyTweaks(selection: snapshot,
                                                                deviceVersion: device.version,
                                                                isIPhone: device.isIPhone)
                text = "Applied. Reboot the device."
                tone = .success
                succeeded = true
            } catch let failure as TransportFailure where failure.isCancellation {
                // Stopping on purpose is not a failure — say so, and do not let it
                // read like the device did something wrong.
                text = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                showStatus(text, tone)
                showRebootNotice = succeeded
            }
        }
    }

    /// `styles.py: process_status_*` fades the status line out again
    /// (`home.py`: a 6 s single-shot timer).  The token is what keeps an older
    /// message's timer from clearing a newer one.
    private func showStatus(_ text: String, _ tone: GoldenTone, autoHide: Bool = true) {
        status = text
        statusTone = tone
        statusToken &+= 1
        let token = statusToken
        guard autoHide else { return }
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run { if statusToken == token { status = "" } }
        }
    }

    /// Elapsed time, not just a spinner: this run has stages that legitimately
    /// take minutes, and a spinner alone cannot tell "working" from "hung".
    /// The percentage is the backup stage's own, which is the only stage that
    /// reports one.
    private func elapsedText(_ seconds: Int) -> String {
        let clock = "Elapsed \(seconds / 60)m \(seconds % 60)s"
        guard let progress, !progress.isNaN else { return clock }
        return "\(clock) · backup \(Int(progress))%"
    }

    // MARK: - Connection

    /// Set while a `startMinimuxer()` is running, cleared when it finishes.
    ///
    /// `startMinimuxer` is reachable from `.onAppear`, from every pairing-file
    /// load and from a pairing reset, and each call used to dispatch its own
    /// 60 s tunnel wait onto the global queue.  Four pairing loads in one session
    /// meant four parallel probes writing "waiting for iface…" into the same log
    /// and four `tunnel probe: 60.4s — FAILED` lines — and each of them had to be
    /// picked apart by hand to see there was only ever one tunnel failure.
    private static let startLock = NSLock()
    private static var startInFlight = false

    func startMinimuxer() {
        guard let pairingFileRaw = pairing.raw else { return }
        Self.startLock.lock()
        if Self.startInFlight {
            Self.startLock.unlock()
            GoldenNuggetEngine.shared.log("minimuxer start already in progress — ignoring this request")
            return
        }
        Self.startInFlight = true
        Self.startLock.unlock()

        let docs = URL.documents.path(percentEncoded: false)
        DispatchQueue.global(qos: .userInitiated).async { [pairingFileRaw] in
            defer {
                Self.startLock.lock()
                Self.startInFlight = false
                Self.startLock.unlock()
            }
            // SideStore-style pre-start guard: the LocalDevVPN tunnel routes to
            // the emulated peer (10.7.0.1:62078). Probe the tunnel first so the
            // RSD adapter/handshake can reach the device before we start.
            let tunnelStage = StageTimer("tunnel probe")
            guard Tunnel.waitForTunnel(log: { line in GoldenNuggetEngine.shared.log(line) }) else {
                tunnelStage.done("FAILED")
                DispatchQueue.main.async {
                    errorText = "Tunnel not ready: \(Tunnel.peerIP):\(Tunnel.servicePort) unreachable.\n\n\(Tunnel.requirements)"
                }
                return
            }
            tunnelStage.done("reachable")
            Task {
                do {
                    // FIRST, before setLogging()/start(): the Rust logger latches
                    // on the first idevice_init_logger call in the process, and
                    // setLogging(true) below installs console=Error/file=OFF.
                    GoldenNuggetEngine.shared.enableRustFileLogging()
                    let minimuxer = Minimuxer.shared()
                    minimuxer.core.setLogging(true)
                    minimuxer.core.setDeviceProbeTimeout(3000)
                    // Bind the localVPN connection mode.
                    //
                    // The setters used to be `{ _ in }`: the connection manager
                    // auto-discovers the utun peer from the route table, so
                    // whatever it resolved was dropped on the floor.  They are
                    // recorded now (see `Tunnel.reported`) — the diagnostics block
                    // prints them next to the app's own probe, which is the only
                    // way to tell "the VPN is on another subnet" from "the library
                    // looked at a different address than the app did".
                    Tunnel.resetReported()
                    await minimuxer.core.bindConnectionConfig(ConnectionConfigBinding(
                        setTunnelIfaceIp: { value in Tunnel.noteReported { $0.ifaceIP = value } },
                        setTunnelPeerIp: { value in Tunnel.noteReported { $0.peerIP = value } },
                        setTunnelPeerSubnetMask: { value in Tunnel.noteReported { $0.peerSubnetMask = value } },
                        setTunnelPeerReachable: { value in Tunnel.noteReported { $0.peerReachable = value } },
                        setTunnelIfaceSubnetMask: { value in Tunnel.noteReported { $0.ifaceSubnetMask = value } },
                        getRemoteServerIp: { "" },
                        setRemoteReachable: { _ in },
                        getOverrideTunnelPeerIp: { "" },
                        setOverrideTunnelPeerReachable: { _ in },
                        getConnectionMode: { .localVPN }
                    ))
                    // Diagnostic: minimuxer's start() requires a top-level "UDID"
                    // string key in the pairing-file plist. Show the real keys so
                    // a wrong pairing file is obvious instead of a bare error.
                    if let keys = PairingStore.topLevelKeys(pairingFileRaw) {
                        let hasUDID = keys.contains("UDID")
                        GoldenNuggetEngine.shared.log("pairing file top-level keys: \(keys.isEmpty ? "(empty)" : keys.sorted().joined(separator: ", ")) \(hasUDID ? "[UDID OK]" : "[NO UDID — start() will fail]")")
                    } else {
                        GoldenNuggetEngine.shared.log("pairing file: NOT a parseable XML/JSON plist")
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
                    GoldenNuggetEngine.shared.log("minimuxer started. ready=\(isReady)")
                    if !isReady {
                        let tail = RustLog.tail()
                        GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(tail)")
                        DispatchQueue.main.async {
                            errorText = "minimuxer started but never became ready.\n\nLast minimuxer.log lines:\n\(tail)"
                        }
                    }
                } catch {
                    let tail = RustLog.tail()
                    GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(tail)")
                    DispatchQueue.main.async {
                        errorText = "\(error.localizedDescription)\n\nLast minimuxer.log lines:\n\(tail)"
                    }
                }
            }
        }
    }

    /// Route engine log lines into `RunLog`.
    ///
    /// This used to append to `@State logs` on this view, one full-page
    /// invalidation per line; the store coalesces a burst into one main-thread
    /// flush and only `RunLogCard` observes it.
    func spawnLogPrinter() {
        GoldenNuggetEngine.shared.onLog = { line in
            RunLog.shared.append(line)
        }
    }
}
