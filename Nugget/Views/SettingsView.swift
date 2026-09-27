import SwiftUI
import Minimuxer

/// Settings: what this build is, and the switches that change what a run does.
///
/// The About half is the part a bug report actually needs — version, build, and the
/// two log files with their sizes, because "attach goldennugget.log" is only a usable
/// sentence if the reader knows which build produced it and whether it is the file
/// that has anything in it.
///
/// The Apply half is the one switch that is not a development switch: Skip Setup,
/// which rides every run (see `SkipSetupSettings` for what it can and cannot do).
///
/// The Development half sits behind a master switch because every row on it changes
/// a real device: the branch a run takes, whether the protocol is recorded, whether
/// minutes of AFC work happen at all. None of that is discoverable by looking, and
/// all of it is fine to have — it just should not be one row away from the page a
/// user opens by accident. `DevSettings` owns the rules; this page only draws them.
struct SettingsView: View {
    // Reactive mirrors of `DevSettings.Key`, so a toggle redraws the page. The
    // engine reads the same strings through `DevSettings.effective`.
    @AppStorage(DevSettings.Key.enabled) private var devModeOn = false
    @AppStorage(DevSettings.Key.forcePartialRestore) private var forcePartialRestore = false
    @AppStorage(DevSettings.Key.verboseLog) private var verboseLog = true
    @AppStorage(DevSettings.Key.skipAfcMedia) private var skipAfcMedia = false

    /// Skip Setup's switch. Observed rather than mirrored with a second
    /// `@AppStorage` on the same key: the store is what the engine reads, and one
    /// object owning the value is the whole point of it being an `ObservableObject`.
    @ObservedObject private var skipSetup = SkipSetupSettings.shared

    /// Read through `engine` rather than recomputed in the body, because a log is
    /// written by another thread while this page is open — the sizes and the share
    /// rows have to be the same number, and a value captured at `body` time is stale
    /// by the time the row is drawn.
    @State private var logs = LogSizes()

    /// Sizes and existence of the two files a report is built from.
    private struct LogSizes: Equatable {
        var appBytes: UInt64 = 0
        var rustBytes: UInt64 = 0
        /// The vendor's own explanation, shown only when there is nothing to share —
        /// it is a long path-bearing string that earns its place exactly when the
        /// question is "why is this empty".
        var rustStatus: String = ""

        var appKB: UInt64 { appBytes / 1024 }
        var rustKB: UInt64 { rustBytes / 1024 }
        var hasApp: Bool { appBytes > 0 }
        var hasRust: Bool { rustBytes > 0 }
    }

    var body: some View {
        GoldenPage(spacing: GoldenTheme.rowSpacing) {
            aboutCard
            creditsCard
            logsCard
            applyCard
            developmentCard
        }
        .navigationTitle("Settings")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(GoldenTheme.backgroundSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            refreshLogs()
        }
        .onChange(of: devModeOn) { _, _ in DevSettings.applyLoggingPreference() }
        .onChange(of: verboseLog) { _, _ in DevSettings.applyLoggingPreference() }
    }

    // MARK: - About

    private var aboutCard: some View {
        GoldenSection(
            title: "About",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    VStack(spacing: 10) {
                        // The real artwork, not a stand-in: `GoldenLogo` loads the
                        // same Logo@1x/@2x the home screen header uses. It used to
                        // resolve `UIImage(named: "AppIcon")` out of the compiled
                        // catalog so this would follow the light/dark appearance --
                        // but an app-icon name is not a loadable image and that
                        // lookup aborts the process. See `GoldenLogo.bundledIcon`.
                        GoldenLogo(size: 96)
                        Text("GoldenNugget")
                            .font(GoldenFont.cardTitle)
                            .foregroundColor(GoldenTheme.textPrimary)
                        Text(Self.versionText)
                            .font(GoldenFont.cardSubtitle)
                            .foregroundColor(GoldenTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                    GoldenDivider()

                    // The line the whole screen exists to say, kept as its own
                    // centred line rather than a row: it is a credit, not a setting,
                    // and it should not read as one.
                    Text("Made with ❤️ by\nGoldenNugget Development Team")
                        .font(GoldenFont.rowTitle)
                        .foregroundColor(GoldenTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    GoldenMutedNote(text: "GoldenNugget for desktop is the original this app is "
                        + "a port of. It runs the same protocols over its own Rust and Swift "
                        + "stack instead of driving pymobiledevice3, and speaks to iOS 26 and "
                        + "27 rather than only to tethered devices.")
                }
            )
        )
    }

    // MARK: - Credits

    /// What the app is built on, and by whom. Every row is a component that is
    /// really in the binary — the two static Rust/C archives are linked into the
    /// executable rather than embedded as frameworks (only `EMProxy.framework`
    /// ships as a dynamic framework in the IPA), so this says "built on" and
    /// leaves the linkage type out rather than stating one it cannot show.
    private var creditsCard: some View {
        GoldenSection(
            title: "Credits",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    creditRow("GoldenNugget", "Desktop app · this is a port of it",
                              systemImage: "desktopcomputer")
                    creditRow("idevice", "Rust device and backup stack",
                              systemImage: "shippingbox")
                    creditRow("libimobiledevice", "C protocol core",
                              systemImage: "chevron.left.forwardslash.chevron.right")
                    creditRow("Minimuxer", "SideStore · tunnel and usbmux",
                              systemImage: "network")
                    creditRow("ZIPFoundation", "Archive handling",
                              systemImage: "archivebox")
                    GoldenMutedNote(text: "The vendored copies carry local patches, listed with "
                        + "the reason for each in Vendor/patches/README.md. SideStore's minimuxer "
                        + "is © 2026 SideStore.")
                }
            )
        )
    }

    private func creditRow(_ title: String, _ role: String, systemImage: String) -> some View {
        GoldenRowLabel(title: title,
                       value: role,
                       systemImage: systemImage,
                       trailingGlyph: nil)
    }

    // MARK: - Logs

    private var logsCard: some View {
        GoldenSection(
            title: "Logs",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    // The two halves of a report's evidence, kept as two rows because
                    // they answer two different questions: this one is what the host
                    // decided, the other is what the protocol did.
                    shareRow(title: "goldennugget.log",
                             size: logs.appKB,
                             systemImage: "doc.plaintext",
                             url: GoldenNuggetEngine.appLogURL,
                             available: logs.hasApp)
                    shareRow(title: "minimuxer.log",
                             size: logs.rustKB,
                             systemImage: "doc.text.magnifyingglass",
                             url: GoldenNuggetEngine.rustLogURL,
                             available: logs.hasRust)
                    if !logs.hasRust, !logs.rustStatus.isEmpty {
                        GoldenMutedNote(text: logs.rustStatus)
                    }
                    GoldenMutedNote(text: logs.hasApp
                        ? "A report wants both files: the app log says what was decided, "
                          + "minimuxer.log says what the device answered."
                        : "No app log yet — it is written from the first run in this session.")
                }
            )
        )
    }

    // MARK: - Apply

    /// Skip Setup, on its own page rather than behind the Development master: it is
    /// not a switch for working around a bug, it is part of what a run writes, and it
    /// was the one thing on the deleted Supervision page that did anything. It used to
    /// live there because the reference keeps `skip_setup` / `supervised` /
    /// `organization_name` in one settings object on one screen; only the first of the
    /// three survived the port, and it does not need company.
    private var applyCard: some View {
        GoldenSection(
            title: "Apply",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    switchRow("Skip Setup",
                              note: skipSetupNote,
                              isOn: Binding(
                                  get: { skipSetup.skipSetupEnabled },
                                  set: { skipSetup.setSkipSetup($0) }))
                }
            )
        )
    }

    /// What the switch does, in the order the two files are written. Upstream's own
    /// name for it is `pref_manager.skip_setup`; the enforcement point is
    /// `SkipSetup.build`, which the engine prepends to the tweak payloads.
    ///
    /// The last sentence is the honest limit rather than a caveat bolted on: the
    /// upstream shape of this feature also takes `IsSupervised`, an organization name
    /// and a keybag certificate, and this port has never written the certificate. The
    /// switch therefore writes the unsupervised shape and only that.
    private var skipSetupNote: String {
        [
            "Off: an apply carries only the tweaks (upstream defaults this to on; this "
                + "port leaves it off until a run has confirmed the files land).",
            "On: an apply adds two files ahead of the tweaks, in this order —",
            "1. SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/"
                + "Library/ConfigurationProfiles/CloudConfigurationDetails.plist, "
                + "\(SkipSetup.panes.count) setup panes marked skipped;",
            "2. ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist, setup marked done.",
            "The device's existing cloud configuration is not merged in (reading it needs "
                + "a lockdown service this port has no path for), and no keybag certificate "
                + "is generated.",
        ].joined(separator: "\n")
    }

    // MARK: - Development

    private var developmentCard: some View {
        GoldenSection(
            title: "Development",
            content: AnyView(
                VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Development mode")
                                .font(GoldenFont.rowTitle)
                                .foregroundColor(devModeOn ? GoldenTheme.accent : GoldenTheme.textPrimary)
                            GoldenMutedNote(text: devModeOn
                                ? "The switches below are live for the next run."
                                : "Off: runs take the normal path. Stored switches are ignored.")
                        }
                        Spacer(minLength: 12)
                        GoldenSwitch(isOn: $devModeOn)
                    }

                    if devModeOn {
                        GoldenDivider()

                        switchRow("Force Partial Restore",
                                  note: "Takes the iOS 26 branch — a Partial Restore built "
                                      + "from nothing — even on a device that reports iOS 27+, "
                                      + "and skips the protective backup entirely.",
                                  isOn: $forcePartialRestore)

                        switchRow("Verbose log",
                                  note: verboseLog
                                    ? "Recording the protocol detail into minimuxer.log. "
                                      + "Off keeps the app log and the run itself, and drops "
                                      + "the per-frame lines."
                                    : "Protocol detail is not being recorded. The app log still is.",
                                  isOn: $verboseLog)

                        switchRow("Skip AFC media",
                                  note: "A run normally copies camera-roll media between the "
                                      + "backup and the prune. This leaves it out, which on a full "
                                      + "camera roll is the difference between minutes and seconds.",
                                  isOn: $skipAfcMedia)

                        GoldenDivider()
                        GoldenActionRow(title: "Reset switches",
                                        systemImage: "arrow.counterclockwise",
                                        tone: .primary) {
                            DevSettings.resetSwitches()
                            DevSettings.applyLoggingPreference()
                        }
                        GoldenSafetyNote(text: "These are switches, not fixes. Force Partial Restore "
                            + "against a real iOS 27 device is expected to fail at the restore step, "
                            + "because a synthesised manifest carries no domain registration.")
                    }
                }
            )
        )
    }

    // MARK: - Rows

    /// A labelled switch with the explanation underneath, the shape the media page's
    /// "Delete originals" row uses.
    private func switchRow(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                GoldenMutedNote(text: note)
            }
            Spacer(minLength: 12)
            GoldenSwitch(isOn: isOn)
        }
    }

    private func shareRow(title: String, size: UInt64, systemImage: String,
                          url: URL, available: Bool) -> some View {
        ShareLink(item: url) {
            GoldenRowLabel(title: "\(title) (\(size) KB)",
                           systemImage: systemImage,
                           tone: available ? .primary : .disabled)
        }
        .buttonStyle(.plain)
    }

    private func refreshLogs() {
        logs = LogSizes(appBytes: GoldenNuggetEngine.appLogSize(),
                        rustBytes: GoldenNuggetEngine.rustLogSize(),
                        rustStatus: GoldenNuggetEngine.rustLogStatus())
    }

    // MARK: - Bundle facts

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private static var versionText: String {
        "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))"
    }
}
