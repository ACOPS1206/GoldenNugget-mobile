import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Apple Wallet card skins.
///
/// A card's artwork is not a preference — it lives inside the pass, and Passbook
/// caches the rendered layers next to it, so writing a skin is two operations and
/// both have to happen. That, and the fact that neither can be carried by a
/// backup, is why this page exists next to the other AirLift pages rather than
/// inside the tweaks list.
///
/// The page is deliberately explicit about the one thing it cannot do for the
/// user: a card identifier has to come from somewhere, and the only source is
/// Passbook's own log while a card is held to the reader. There is no "read my
/// cards" button, because there is no API for it.
struct WalletView: View {
    @State private var identity: DeviceIdentity = .unknown
    @State private var cards: [WalletCard] = []
    @State private var log: [String] = []
    @State private var status: String?
    @State private var tone: GoldenTone = .secondary
    @State private var running = false
    @State private var scanning = false
    @State private var stopScan: (() -> Void)?
    /// The picker's delegate, held here.
    ///
    /// `UIImagePickerController.delegate` is a weak reference, and the controller
    /// does not retain it either — a delegate created inline is deallocated
    /// before the picker ever appears, which is why the compiler points at
    /// `[weak self]` and says the capture is always nil. Holding it in `@State`
    /// is what makes the callback reachable; it is released when the pick
    /// finishes.
    @State private var pickerDelegate: ImagePickerDelegate?

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            deviceCard
            if !cards.isEmpty { cardsSection }
            scanSection
            applyCard
            if let status { GoldenStatusText(text: status, tone: tone) }
            if !log.isEmpty { runLog }
        }
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            identity = await DeviceIdentity.read()
            // The identifiers are worth keeping across launches; see
            // `WalletCardStore`. A card that is found twice is not added twice,
            // and a stored skin is kept for a card that is found again.
            cards = WalletCardStore.load()
        }
        .onDisappear { stopScan?(); stopScan = nil; scanning = false }
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
            GoldenMutedNote(text: "Card artwork is written straight into the pass at "
                + "/var/mobile/Library/Passes/Cards, and Passbook's cached rendering of the card is "
                + "invalidated afterwards. Both steps need the AirTraffic tunnel.")
            if !blocker.isEmpty {
                GoldenMutedNote(text: blocker)
            }
        }
    }

    private var selectedCount: Int {
        cards.filter { $0.isSelected && $0.hasImage }.count
    }

    private var cardsSection: some View {
        GoldenSection(
            title: "Cards (\(selectedCount)/\(cards.count) selected)",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    ForEach($cards) { $card in
                        cardRow($card)
                    }
                    GoldenActionRow(title: "Apply the same skin to every card",
                                    systemImage: "rectangle.on.rectangle",
                                    tone: selectedCount == 0 ? .disabled : .primary) {
                        applyToAll()
                    }
                    .disabled(selectedCount == 0 || running)
                }
            )
        )
    }

    private func cardRow(_ card: Binding<WalletCard>) -> some View {
        HStack(spacing: 12) {
            GoldenSwitch(isOn: card.isSelected)
            if let data = card.wrappedValue.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 74, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(GoldenTheme.backgroundTertiary)
                    .frame(width: 74, height: 46)
                    .overlay(Text("no skin").font(GoldenFont.value)
                        .foregroundColor(GoldenTheme.textDisabled))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.wrappedValue.id)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(card.wrappedValue.hasImage ? "skin ready" : "no skin selected")
                    .font(GoldenFont.cardSubtitle)
                    .foregroundColor(GoldenTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Button {
                pickImage(for: card.wrappedValue.id)
            } label: {
                Image(systemName: "photo.badge.plus")
            }
            .buttonStyle(.borderless)
            .tint(GoldenTheme.accent)
        }
        .goldenRowSurface()
    }

    // MARK: - Scanning

    private var scanSection: some View {
        GoldenSection(
            title: "Find cards",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    GoldenActionRow(
                        title: scanning ? "Listening for cards…" : "Scan for cards",
                        value: scanning ? "live" : nil,
                        systemImage: "antenna.radiowaves.left.and.right",
                        tone: canScan ? .primary : .disabled
                    ) { toggleScan() }
                    .disabled(!canScan)
                    GoldenMutedNote(text: "Hold a card against the reader while this listens: "
                        + "Passbook logs the card it sees, and that log is the only place the "
                        + "identifier exists. Cards found this way are listed above, without a "
                        + "skin — pick an image for each one.")
                }
            )
        )
    }

    private var canScan: Bool {
        blocker.isEmpty && !running
    }

    private func toggleScan() {
        if scanning {
            stopScan?()
            stopScan = nil
            scanning = false
            return
        }
        scanning = true
        log = []
        Task { @MainActor in
            do {
                // The syslog callback is not on the main actor, so the hop is where
                // the card is recorded rather than in the delegate: `add` writes
                // `@State`, and `@State` is main-actor state.
                let stop = try await WalletEngine.scanCards(
                    pairingPath: AppPaths.pairingFile.path
                ) { identifier in
                    Task { @MainActor in self.add(identifier) }
                }
                stopScan = stop
                status = "Listening. Hold a card against the reader."
                tone = .secondary
            } catch {
                scanning = false
                status = error.localizedDescription
                tone = .error
            }
        }
    }

    private func add(_ identifier: String) {
        guard !cards.contains(where: { $0.id == identifier }) else { return }
        cards.append(WalletCard(id: identifier))
        WalletCardStore.save(cards)
        status = "Found \(identifier.prefix(10))…"
        tone = .primary
    }

    // MARK: - Apply

    private var applyCard: some View {
        GoldenCard {
            GoldenActionRow(
                title: running ? "Applying…" : "Apply \(selectedCount) skin(s)",
                value: running ? "…" : nil,
                systemImage: "creditcard.fill",
                tone: running || selectedCount == 0 ? .disabled : .primary
            ) { apply() }
            .disabled(running || selectedCount == 0)
            GoldenMutedNote(text: "Force-quit the Wallet app on the device afterwards: a pass that "
                + "is already open keeps the rendering it started with.")
        }
    }

    private func applyToAll() {
        let image = cards.first(where: { $0.hasImage })?.imageData
        guard let image else { return }
        for index in cards.indices { cards[index].imageData = image }
        WalletCardStore.save(cards)
    }

    private func apply() {
        running = true
        log = []
        Task { @MainActor in
            defer { running = false }
            do {
                try await WalletEngine.apply(
                    cards: cards,
                    pairingPath: AppPaths.pairingFile.path,
                    log: { line in Task { @MainActor in log.append(line) } },
                    progress: { _ in }
                )
                status = "Card skins applied."
                tone = .primary
            } catch {
                status = error.localizedDescription
                tone = .error
            }
        }
    }

    // MARK: - Image picking

    private func pickImage(for identifier: String) {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        let delegate = ImagePickerDelegate { image in
            pickerDelegate = nil
            guard let image,
                  let data = WalletSkinEngine.prepareForStorage(image),
                  let index = cards.firstIndex(where: { $0.id == identifier }) else { return }
            cards[index].imageData = data
            WalletCardStore.save(cards)
        }
        picker.delegate = delegate
        pickerDelegate = delegate
        PickerHost.present(picker)
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
}

/// Bridges a `UIImagePickerController` into the SwiftUI tree.
///
/// The page cannot hold the controller itself — a `UIViewControllerRepresentable`
/// has to own it, and the picker must be presented from the key window's top
/// view controller, which a SwiftUI page does not have a handle on.
private final class ImagePickerDelegate: NSObject, UIImagePickerControllerDelegate,
                                      UINavigationControllerDelegate {
    private let onPick: (UIImage?) -> Void
    init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        onPick(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onPick(nil)
    }
}

enum PickerHost {
    static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}
