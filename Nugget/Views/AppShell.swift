import SwiftUI
import UIKit

/// The app's shell: a sidebar next to a detail column.
///
/// It is a `NavigationSplitView` on purpose, and the reason is the iPad itself —
/// this app runs in a window whose width the system picks (Slide Over 320,
/// Split View, iPadOS 26's free resizing), so the navigation has to survive a
/// window that is a third of the screen.  A split view does that **by itself**:
/// in a compact width it collapses to one column with the sidebar reachable from
/// the detail's bar, and in a regular width both columns are on screen at once.
/// A plain `NavigationStack` can only do the second of those.
///
/// The home page stays the **root of the detail column** rather than becoming one
/// of the sidebar's selections.  That is what keeps it alive: a split view
/// destroys the detail view when the selection changes, and the home page owns
/// the run (Apply, progress, log) and the launch bootstrap — losing it mid-run
/// would drop the progress and re-run the auto-start.  Selecting a destination
/// pushes onto the detail stack instead, so home is never removed, only covered.
enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case tweaks
    case posterBoard
    case daemons
    case supervision
    case media
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "GoldenNugget"
        case .tweaks: "Tweaks"
        case .posterBoard: "PosterBoard"
        case .daemons: "Daemons"
        case .supervision: "Supervision"
        case .media: "Media"
        case .files: "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .tweaks: "slider.horizontal.3"
        case .posterBoard: "photo.artframe"
        case .daemons: "server.rack"
        case .supervision: "lock.shield"
        case .media: "photo.on.rectangle"
        case .files: "folder"
        }
    }
}

struct RootView: View {
    /// The detail column's stack.  The single source of truth for what is
    /// showing: empty means home, which is also why the sidebar's "current" is
    /// `path.last ?? .home` and there is no second variable to keep in sync.
    @State private var path: [AppDestination] = []
    /// A phone opens on the detail column alone; a tablet gets both.
    ///
    /// On a phone the collapsed split view still reaches the sidebar from the
    /// detail's bar, so `.detailOnly` costs nothing but gives the page its full
    /// width back — a 240 pt sidebar next to a 393 pt content column would leave
    /// every card grid at one column anyway.  A tablet has the room, and
    /// `.automatic` is what remembers the user's last choice there.
    @State private var columnVisibility: NavigationSplitViewVisibility = Self.visibilityForThisDevice

    private static var visibilityForThisDevice: NavigationSplitViewVisibility {
        UIDevice.current.userInterfaceIdiom == .pad ? .automatic : .detailOnly
    }
    /// Owned here, above the split view, because two columns need it at once:
    /// the home page counts and applies it, and Tweaks/Daemons edit it.  It was
    /// `@State` on the home page, which worked only while that page was the one
    /// thing in the hierarchy — in a split view the detail is replaced on every
    /// selection change, and the selection would have gone with it.
    @State private var tweakSelection = TweakSelection()
    /// Launch auto-start bookkeeping, hoisted for the same reason as the
    /// selection: `didAutoStart` guards a process-wide singleton
    /// (`startMinimuxer`'s lock rejects *concurrent* attempts only), so it has
    /// to outlive the view that reads it.  See `GoldenNuggetView`.
    @State private var didAutoStart = false
    /// "Reset pairing file" saying no, and **persisted on purpose**.
    ///
    /// It used to be `@State` alongside `didAutoStart`, which made the reset
    /// only half-work: `resetPairing()` cleared the record in memory and in
    /// `UserDefaults` but left `Documents/pairingfile.mobiledevicepairing` in
    /// place, and the restore path reads that file *first*.  So the next launch
    /// — which started again from "the user has not said no" — picked the
    /// record straight back up and re-paired a device the user had just
    /// unpaired, with nothing in the log to say why.
    ///
    /// Persisting the flag makes the reset stick without **deleting** anything:
    /// the record stays on disk untouched, and only the automatic load of it is
    /// suppressed.  That is deliberate — the pairing file may be the user's only
    /// copy, and a button labelled "Reset pairing file" must not destroy it.
    /// A successful import clears the flag again (see `loadPairingFile`), so
    /// importing after a reset restores the normal launch behaviour.
    @AppStorage("PairingFileAutoImportDisabled") private var autoImportDisabled = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AppSidebar(current: path.last ?? .home) { destination in
                path = destination == .home ? [] : [destination]
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                // `tweakSelection`, not `selection` — that label belongs to
                // TweaksView's own binding.  The order is the explicit
                // initializer's, not the property declaration order.
                GoldenNuggetView(tweakSelection: $tweakSelection,
                                 didAutoStart: $didAutoStart,
                                 autoImportDisabled: $autoImportDisabled)
                    .navigationDestination(for: AppDestination.self) { destination in
                        switch destination {
                        case .home:
                            // Unreachable: home is the stack's root, so the path
                            // never carries it.  The switch has to be exhaustive.
                            EmptyView()
                        case .tweaks:
                            TweaksView(selection: $tweakSelection)
                        case .posterBoard:
                            PosterBoardView()
                        case .daemons:
                            DaemonsView(selection: $tweakSelection)
                        case .supervision:
                            SupervisionView()
                        case .media:
                            MediaView()
                        case .files:
                            FilesView()
                        }
                    }
            }
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

/// The sidebar column: seven destinations, drawn with the design system's own row
/// metrics rather than the platform's, so it matches the pages next to it.
private struct AppSidebar: View {
    let current: AppDestination
    let select: (AppDestination) -> Void

    var body: some View {
        List {
            ForEach(AppDestination.allCases) { destination in
                Button { select(destination) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: destination.systemImage)
                            .font(.system(size: 15))
                            .frame(width: 20)
                        Text(destination.title)
                            .font(GoldenFont.rowTitle)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(destination == current
                                     ? GoldenTheme.textPrimary
                                     : GoldenTheme.textSecondary)
                }
                .listRowBackground(destination == current
                                   ? GoldenTheme.backgroundTertiary
                                   : Color.clear)
            }
        }
        .listStyle(.sidebar)
        // The platform sidebar style draws its own grouped background; hiding it
        // puts the page surface underneath back, so the column is the same
        // `backgroundPrimary` the pages are.
        .scrollContentBackground(.hidden)
        .background(GoldenTheme.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("GoldenNugget")
    }
}

