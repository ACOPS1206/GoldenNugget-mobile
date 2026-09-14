import SwiftUI
import UniformTypeIdentifiers

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
    @State var running: Bool = false
    @State var showPairingImporter: Bool = false
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
                        Text("Run Backup → Inject → Restore").frame(maxWidth: .infinity)
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
        target_minimuxer_address()
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].absoluteString
            try start(pairingFileRaw, docs)
            PoCEngine.shared.log("minimuxer started. ready=\(ready())")
        } catch {
            errorText = error.localizedDescription
        }
    }

    func spawnLogPrinter() {
        PoCEngine.shared.onLog = { line in
            logs.append(line)
        }
    }

    func run() {
        running = true
        logs = []
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PoCEngine.shared.runPoC(bundleID: bundleID, fileName: fileName, contents: contents)
            } catch {
                PoCEngine.shared.log("❌ \(error.localizedDescription)")
            }
            DispatchQueue.main.async { running = false }
        }
    }

    init() {
        if let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, Selector(("fix_initForOpeningContentTypes:asCopy:"))), let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))) {
            method_exchangeImplementations(origMethod, fixMethod)
        }
    }
}