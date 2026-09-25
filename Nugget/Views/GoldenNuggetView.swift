import SwiftUI
import UniformTypeIdentifiers
import Minimuxer
import Foundation

struct RootView: View {
    var body: some View {
        NavigationStack {
            GoldenNuggetView()
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
    @AppStorage("PairingFile") var pairingFileRaw: String?
    // The tunnel addressing, persisted under the same keys `Tunnel` reads (see
    // `Tunnel.Key`), so the fields below and every probe are looking at one set
    // of values.  `@AppStorage` rather than `@State` because the tunnel is
    // probed from background queues and from `NuggetApp.init` — a value that
    // only lived in the view would not be there when it is read.
    @AppStorage(Tunnel.Key.ifaceIP) var tunnelIfaceIP = Tunnel.defaultIfaceIP
    @AppStorage(Tunnel.Key.peerIP) var tunnelPeerIP = Tunnel.defaultPeerIP
    @AppStorage(Tunnel.Key.port) var tunnelPort = String(Tunnel.defaultServicePort)
    @AppStorage(Tunnel.Key.prefixLength) var tunnelPrefixLength = String(Tunnel.defaultPrefixLength)
    @State private var pairingFileURL: String?
    /// Launch auto-start bookkeeping for `reimportPairingFile()`.
    ///
    /// `didAutoStart` keeps a second `.task` pass (the view is re-created when
    /// the page comes back) from starting the core twice — `startMinimuxer`'s
    /// lock only rejects *concurrent* attempts, so a sequential second start
    /// would probe the tunnel again for no reason.  `autoImportDisabled` is the
    /// user's "Reset pairing file" saying no: without it the next `.task` pass
    /// would fall straight back to the `ALTPairingFile` the installer embedded
    /// and re-pair a device the user just unpaired.
    @State private var didAutoStart = false
    @State private var autoImportDisabled = false
    @State private var running = false
    @State private var showPairingImporter = false
    @State private var showRebootNotice = false
    @State private var logs: [String] = []
    @State private var errorText: String?
    @State private var runStarted: Date?
    @State private var tweakSelection = TweakSelection()
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
            if !logs.isEmpty { logSection }
        }
        .navigationTitle("GoldenNugget")
        .navigationBarTitleDisplayMode(.inline)
        // The home page carries its own logo header, so the platform bar would be
        // a second, empty one.  Hiding it *here* — not on the pushed page — keeps
        // the Tweaks page's bar, and with it the interactive swipe-back gesture,
        // exactly as the reference's `IOSNavBar` has them.
        .toolbar(.hidden, for: .navigationBar)
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
            if !autoImportDisabled, reimportPairingFile(), !didAutoStart {
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
                Task { await readDevice() }
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

    private var tweakCards: some View {
        GoldenCardGrid(itemCount: 4) { index in
            switch index {
            case 0:
                NavigationLink {
                    TweaksView(selection: $tweakSelection)
                } label: {
                    GoldenFeatureCardLabel(
                        title: "Tweaks",
                        subtitle: "Customize system settings",
                        // The count that used to be this row's trailing badge.
                        detail: "\(registryTweakCount) enabled")
                }
                .buttonStyle(.plain)
            case 1:
                NavigationLink {
                    DaemonsView(selection: $tweakSelection)
                } label: {
                    GoldenFeatureCardLabel(
                        title: "Daemons",
                        subtitle: "Launchd services",
                        detail: "\(enabledDaemonCount) of \(DaemonGroups.all.count) groups")
                }
                .buttonStyle(.plain)
            case 2:
                NavigationLink {
                    SupervisionView(selection: $tweakSelection)
                } label: {
                    GoldenFeatureCardLabel(
                        title: "Supervision",
                        subtitle: "Device supervision",
                        detail: supervisionDetail)
                }
                .buttonStyle(.plain)
            default:
                NavigationLink {
                    MediaView()
                } label: {
                    GoldenFeatureCardLabel(
                        title: "Media",
                        subtitle: "Photos and videos",
                        detail: mediaDetail)
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

    /// The reference's "Reset Tweaks" restores the original values on the device.
    /// That is not something this button can do — undoing an apply means putting
    /// back a backup taken before it — so it says what it actually does instead
    /// of borrowing the reference's name for it.
    private var clearCard: some View {
        GoldenCard {
            GoldenMutedNote(text: "Turns every tweak off in this app. The device is not "
                + "touched: to undo an apply, restore a backup from before it.")
            GoldenDangerButton(title: "Clear Selection",
                               disabled: tweakSelection.enabledCount == 0) {
                tweakSelection.removeAll()
                showStatus("Selection cleared.", .warning)
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
                        .keyboardType(.numberPad)
                }
                if !tunnelPortOK {
                    GoldenSafetyNote(text: "Not a port in 1…65535 — \(Tunnel.defaultServicePort) is being probed instead.")
                }
                GoldenLabeledField(label: "Tunnel IP prefix length") {
                    TextField(String(Tunnel.defaultPrefixLength), text: $tunnelPrefixLength)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                }
                if !tunnelPrefixOK {
                    GoldenSafetyNote(text: "Not 0…32 — LocalDevVPN's tunnel-IP field takes a CIDR, and this is the part after the slash.")
                }
                GoldenMutedNote(text: "Copy into LocalDevVPN: tunnel IP \(Tunnel.ifaceIP)/\(Tunnel.ifacePrefixLength), peer \(Tunnel.peerIP), port \(Tunnel.servicePort).")
                GoldenStatusText(text: "tunnel: \(Tunnel.describe()) · peer \(Tunnel.peerIP):\(Tunnel.servicePort) reachable: \(Tunnel.probePeer())")
                GoldenActionRow(title: "Reset tunnel addresses", systemImage: "arrow.counterclockwise") {
                    Tunnel.resetToDefaults()
                    tunnelIfaceIP = Tunnel.defaultIfaceIP
                    tunnelPeerIP = Tunnel.defaultPeerIP
                    tunnelPort = String(Tunnel.defaultServicePort)
                    tunnelPrefixLength = String(Tunnel.defaultPrefixLength)
                    GoldenNuggetEngine.shared.log("tunnel addresses reset to defaults: \(Tunnel.requirements)")
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
                            await MainActor.run { logs.append(block) }
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

    private var canApply: Bool { paired && tweakSelection.enabledCount > 0 && !running }

    private var hasDiagnostics: Bool {
        FileManager.default.fileExists(atPath: GoldenNuggetEngine.diagnosticsURL.path)
    }

    // MARK: - Behaviour

    func resetPairing() {
        pairingFileRaw = nil
        pairingFileURL = nil
        // Also stop the launch auto-import for the rest of this session, or the
        // installer's embedded record would undo this on the next `.task` pass.
        autoImportDisabled = true
        didAutoStart = false
        logs = []
    }

    // Extensions accepted by the pairing-file picker and onOpenURL handler.
    static let pairingFileTypes: [UTType] = ["mobiledevicepairing", "mobiledevicepair", "mobiledeviceconfig"].compactMap {
        UTType(filenameExtension: $0, conformingTo: .data)
    }

    /// A pairing record is usable only if it is a plist with a non-empty
    /// top-level `UDID` — that key is what minimuxer's `start()` reads first
    /// and it logs "Couldn't get UDID" and stops when it is missing.
    static func usablePairingRecord(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any]
        else { return false }
        return (dict["UDID"] as? String)?.isEmpty == false
    }

    /// What a candidate record actually contains, for the log line — a rejected
    /// record has to be diagnosable from the log alone, because the alternative
    /// on a phone is "minimuxer did not start" with nothing to go on.
    private static func pairingSourceLabel(_ raw: String) -> String {
        guard let keys = pairingFileTopLevelKeys(raw) else { return "not a parseable plist" }
        let listed = keys.isEmpty ? "(no keys)" : keys.sorted().joined(separator: ", ")
        return "keys: \(listed)\(keys.contains("UDID") ? " [UDID]" : " [no UDID]")"
    }

    /// Make sure a usable pairing record exists on disk, and report whether one
    /// does.  Run on every launch, before `startMinimuxer()`.
    ///
    /// This used to be an `ALTPairingFile` lookup that only fired on a *first*
    /// launch, which broke the app in three ways at once:
    ///
    ///   * `@AppStorage("PairingFile")` is set by that first launch, so on the
    ///     second and every later launch the `pairingFileRaw == nil` guard
    ///     skipped the whole branch — `pairingFileURL` was set, so the UI said
    ///     "connected" while nothing had started the core.  The app looked fine
    ///     and did nothing until the user re-imported by hand.
    ///   * The embedded record was only assigned to a variable, never written to
    ///     `Documents/pairingfile.mobiledevicepairing`, so the file the rest of
    ///     the app (and `AppPaths`) treats as canonical did not exist.
    ///   * `alt.count > 5000` was the only test applied to it.  A real pairing
    ///     record is a few KB, so the threshold silently rejected a perfectly
    ///     good one and accepted a truncated multi-KB blob.  It is replaced by
    ///     `usablePairingRecord`, which checks what actually matters.
    ///
    /// Precedence is deliberate: a pairing file the user imported wins over the
    /// one the installer embedded, because re-pairs are per-device and an
    /// embedded record is a build-time artefact.  Each candidate is validated
    /// before use, so a corrupt file on disk falls through to the next one
    /// instead of blocking the launch.
    @discardableResult
    func reimportPairingFile() -> Bool {
        let dest = AppPaths.pairingFile
        let embedded = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String
        // On disk first, then the persisted copy, then the installer's record.
        let candidates: [(source: String, raw: String?)] = [
            ("Documents/pairingfile.mobiledevicepairing", try? String(contentsOf: dest, encoding: .utf8)),
            ("stored PairingFile", pairingFileRaw),
            ("Info.plist ALTPairingFile", embedded),
        ]

        for (source, rawOpt) in candidates {
            guard let raw = rawOpt?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            guard Self.usablePairingRecord(raw) else {
                GoldenNuggetEngine.shared.log("pairing record rejected (\(source)): \(Self.pairingSourceLabel(raw))")
                continue
            }
            let onDisk = (try? String(contentsOf: dest, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if onDisk == raw {
                GoldenNuggetEngine.shared.log("pairing record: \(source) (\(Self.pairingSourceLabel(raw)))")
            } else {
                do {
                    try raw.write(to: dest, atomically: true, encoding: .utf8)
                    GoldenNuggetEngine.shared.log("pairing record re-imported from \(source) into \(dest.lastPathComponent) (\(Self.pairingSourceLabel(raw)))")
                } catch {
                    GoldenNuggetEngine.shared.log("pairing record found (\(source)) but could not be written to Documents: \(error.localizedDescription)")
                }
            }
            pairingFileRaw = raw
            pairingFileURL = dest.path
            return true
        }

        // Nothing usable anywhere.  Do not leave a stale path behind: it would
        // make `paired` true and the UI promise a connection that cannot exist.
        pairingFileURL = nil
        if pairingFileRaw != nil {
            pairingFileRaw = nil
            GoldenNuggetEngine.shared.log("stored pairing record was unusable — cleared, import a pairing file to connect")
        } else if embedded == nil {
            GoldenNuggetEngine.shared.log("no pairing record: none on disk, none stored, and the installer embedded no ALTPairingFile")
        }
        return false
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

    /// Re-read the device line.  Called on entry and by the header's refresh
    /// button, so a page that was opened before the tunnel came up does not sit
    /// on "unknown device" until it is navigated away from.
    private func readDevice() async {
        guard paired else { return }
        readingDevice = true
        let read = await DeviceIdentity.read()
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
        logs = []
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
        guard let pairingFileRaw else { return }
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
                    if let keys = await Self.pairingFileTopLevelKeys(pairingFileRaw) {
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
        GoldenNuggetEngine.shared.onLog = { line in
            logs.append(line)
            // A long run appends a lot (RSD chatter, retries, diagnostics).
            // Keeping the array bounded keeps the list responsive while
            // scrolling through a run.
            if logs.count > 600 {
                logs.removeFirst(logs.count - 600)
            }
        }
    }

    init() {
        if let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, Selector(("fix_initForOpeningContentTypes:asCopy:"))), let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))) {
            method_exchangeImplementations(origMethod, fixMethod)
        }
    }
}
