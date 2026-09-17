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
    @State var bundleID: String = "com.apple.PosterBoard"
    @State var fileName: String = "poc.txt"
    @State var contents: String = "PoC: iOS 27 app container restore OK"
    @State var partialOnly: Bool = true
    @State var running: Bool = false
    @State var showPairingImporter: Bool = false
    @State var showTargetImporter: Bool = false
    @State var logs: [String] = []
    @State var errorText: String?

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
                Picker("Restore mode", selection: $partialOnly) {
                    Text("Partial — minimal 3.3, no backup").tag(true)
                    Text("Full — protective backup → inject").tag(false)
                }
                .pickerStyle(.segmented)
                Text(partialOnly
                     ? "Builds a minimal Manifest.db (backup 3.3) host-side with only the injected app-container file and restores it. No device backup, no photos pulled."
                     : "Runs a real mobilebackup2 protective backup, prunes it, injects the app-container file, then restores the whole pruned backup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                if pairingFileURL != nil {
                    Button("Reset pairing file") { resetPairing() }
                } else {
                    Button("Select Pairing File") { showPairingImporter.toggle() }
                        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: [UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!, UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!]) { result in
                            switch result {
                            case .success(let url):
                                do {
                                    pairingFileRaw = try String(contentsOf: url)
                                    pairingFileURL = url.path
                                    startMinimuxer()
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
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(partialOnly ? "Run Partial Restore (3.3)" : "Run Backup → Inject → Restore")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(running || pairingFileURL == nil)
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
            if let alt = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String, alt.count > 5000, pairingFileRaw == nil {
                pairingFileRaw = alt
                pairingFileURL = URL.documents.appendingPathComponent("pairingfile.mobiledevicepairing").path
                startMinimuxer()
            } else {
                pairingFileURL = pairingFileRaw != nil ? URL.documents.appendingPathComponent("pairingfile.mobiledevicepairing").path : nil
            }
        }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "mobiledevicepairing" {
                do {
                    pairingFileRaw = try String(contentsOf: url)
                    pairingFileURL = url.path
                    startMinimuxer()
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
    }

    func resetPairing() {
        pairingFileRaw = nil
        pairingFileURL = nil
        logs = []
    }

    func startMinimuxer() {
        guard let pairingFileRaw else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path(percentEncoded: false)
        DispatchQueue.global(qos: .userInitiated).async {
            // SideStore-style pre-start guard: the LocalDevVPN tunnel routes to
            // the emulated peer (10.7.0.1:62078). Probe the tunnel first so the
            // RSD adapter/handshake can reach the device before we start.
            guard Tunnel.waitForTunnel(log: { line in PoCEngine.shared.log(line) }) else {
                DispatchQueue.main.async {
                    errorText = "Tunnel not ready: \(Tunnel.peerIP):\(Tunnel.servicePort) unreachable. Enable LocalDevVPN and retry."
                }
                return
            }
            Task {
                do {
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
                    var isReady = false
                    if case .success(true) = await minimuxer.core.isReady() {
                        isReady = true
                    }
                    var attempts = 1
                    while !isReady && attempts < 20 {
                        attempts += 1
                        PoCEngine.shared.log("minimuxer not ready (attempt \(attempts)/20), retrying…")
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        if case .success(true) = await minimuxer.core.isReady() {
                            isReady = true
                        }
                    }
                    PoCEngine.shared.log("minimuxer started. ready=\(isReady)")
                    if !isReady {
                        let tail = Self.minimuxerLogTail()
                        PoCEngine.shared.log("minimuxer.log tail:\n\(tail)")
                        DispatchQueue.main.async {
                            errorText = "minimuxer started but never became ready.\n\nLast minimuxer.log lines:\n\(tail)"
                        }
                    }
                } catch {
                    let tail = Self.minimuxerLogTail()
                    PoCEngine.shared.log("minimuxer.log tail:\n\(tail)")
                    DispatchQueue.main.async {
                        errorText = "\(error.localizedDescription)\n\nLast minimuxer.log lines:\n\(tail)"
                    }
                }
            }
        }
    }

    // minimuxer writes <docs>/minimuxer.log; print the last lines so a
    // stopping point (e.g. "Couldn't get UDID" = bad pairing file) is visible
    // directly in the UI instead of a bare MinimuxerError number.
    static func minimuxerLogTail(_ lines: Int = 30) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("minimuxer.log")
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return "(no minimuxer.log at \(url.path))"
        }
        let parts = data.split(separator: "\n")
        return parts.suffix(lines).joined(separator: "\n")
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
        }
    }

    func run() {
        running = true
        logs = []
        Task {
            do {
                if partialOnly {
                    try await PoCEngine.shared.runPartialRestore(bundleID: bundleID, fileName: fileName, contents: contents)
                } else {
                    try await PoCEngine.shared.runPoC(bundleID: bundleID, fileName: fileName, contents: contents)
                }
            } catch {
                PoCEngine.shared.log("❌ \(error.localizedDescription)")
            }
            await MainActor.run { running = false }
        }
    }

    init() {
        if let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, Selector(("fix_initForOpeningContentTypes:asCopy:"))), let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))) {
            method_exchangeImplementations(origMethod, fixMethod)
        }
    }
}