import SwiftUI
import UniformTypeIdentifiers
import Minimuxer

struct RootView: View {
    var body: some View {
        NavigationStack {
            PoCView()
        }
    }
}

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

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PoC: iOS 27 app-container restore")
                        .font(.subheadline.bold())
                    Text("Writes a txt file into a target app's Documents and restores via mobilebackup2 (NOT sparse restore). If the device ignores it without wiping, app-only restores are safe on iOS 27.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Mode") {
                Text("Runs a real mobilebackup2 protective backup, prunes it, injects the app-container file, then restores the whole pruned backup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                if pairingFileURL != nil {
                    Button("Reset pairing file") { resetPairing() }
                } else {
                    Button("Select Pairing File") { showPairingImporter.toggle() }
                        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: Self.pairingFileTypes) { result in
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
            }

            Section("Target") {
                TextField("Bundle ID", text: $bundleID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    showTargetImporter.toggle()
                } label: {
                    Label("Select target app (.app / .ipa)", systemImage: "folder")
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
                TextField("File name", text: $fileName)
                    .autocorrectionDisabled()
                TextField("Contents", text: $contents, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section {
                Button {
                    run()
                } label: {
                    if running {
                        // Elapsed time, not just a spinner: this run has stages
                        // that legitimately take minutes, and a spinner alone
                        // cannot tell "working" from "hung".
                        HStack {
                            ProgressView()
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                let secs = Int(ctx.date.timeIntervalSince(runStarted ?? ctx.date))
                                Text("Running… \(secs / 60)m \(secs % 60)s")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Run Backup → Inject → Restore")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(running || pairingFileURL == nil)

                if running {
                    // A stall guard that waits minutes for a device that may be
                    // wedged is only safe if it can be stopped by hand. A blocked
                    // Rust read cannot be interrupted, so this abandons the call
                    // and unwinds: the guard notices the flag at its next poll.
                    Button(role: .destructive) {
                        PoCEngine.shared.requestCancel()
                    } label: {
                        Label("Stop run", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Section("Diagnostics") {
                Button("Dump Diagnostics Into Log") {
                    Task {
                        let block = await PoCEngine.shared.diagnostics()
                        await MainActor.run { logs.append(block) }
                    }
                }
                .disabled(running)
                // Share sheets beat hand-selecting text: the diagnostics block and
                // the full Rust log are files in Documents.  AirDrop / Save to
                // Files gets them off the device intact.
                ShareLink(item: PoCEngine.diagnosticsURL) {
                    Label("Share diagnostics.txt", systemImage: "square.and.arrow.up")
                }
                .disabled(!FileManager.default.fileExists(atPath: PoCEngine.diagnosticsURL.path))
                ShareLink(item: PoCEngine.rustLogURL) {
                    Label("Share minimuxer.log (\(PoCEngine.rustLogSize() / 1024) KB)", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(PoCEngine.rustLogSize() == 0)
                // The app-side log is a separate file because it is a separate
                // half of the evidence: the Rust log shows what the protocol did,
                // this one shows what the host decided (filter keeps, commit
                // accounting, staging leftovers).
                ShareLink(item: PoCEngine.appLogURL) {
                    Label("Share poc.log (\(PoCEngine.appLogSize() / 1024) KB)", systemImage: "doc.plaintext")
                }
                .disabled(PoCEngine.appLogSize() == 0)
                Text("The dump carries a keyword slice of the Rust log (mobilebackup2 protocol + jktcp flow verdict) scoped to this run, plus the app log tail (host-side decisions).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !logs.isEmpty {
                Section("Log") {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("PoC")
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
                    if let keys = Self.pairingFileTopLevelKeys(pairingFileRaw) {
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
            // Keeping the array bounded keeps the List responsive while
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
                try await PoCEngine.shared.runPoC(bundleID: bundleID, fileName: fileName, contents: contents)
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