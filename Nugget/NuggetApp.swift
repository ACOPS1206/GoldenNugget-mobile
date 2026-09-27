import SwiftUI
import Minimuxer

@main
struct GoldenNuggetApp: App {
    init() {
        // Resolve the pairing record **before** any view exists.  The store is
        // a process-wide singleton, so this is what makes "paired" independent
        // of a view's lifetime: a home page that gets re-created (relaunch,
        // or the split view rebuilding its detail column on a size-class
        // change) reads the answer this produced instead of coming up empty.
        PairingStore.shared.bootstrap()

        // LocalDevVPN compatibility: only start our own WireGuard server
        // (em_proxy at 127.0.0.1:51820) when no LocalDevVPN-style tunnel
        // (NEPacketTunnelProvider with iface 10.7.1.1) is already up.
        let tunnelUp = Tunnel.isInterfaceUp()
        // Goes through the app log rather than print(): on device the console is
        // not reachable, and the tunnel verdict is the first thing a failed run
        // needs to show in goldennugget.log.
        AppLog.write("Tunnel status: \(Tunnel.describe()) — em_proxy \(tunnelUp ? "skipped (LocalDevVPN active)" : "starting")")
        if !tunnelUp {
            let emproxy = Minimuxer.shared().emproxy
            emproxy.setHandshakeClient(host: "127.0.0.1", port: 51820, enabled: false)
            Task {
                do {
                    try await emproxy.start(host: "127.0.0.1", port: 51820)
                } catch {
                    AppLog.write("em_proxy failed to start: \(error)")
                }
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}