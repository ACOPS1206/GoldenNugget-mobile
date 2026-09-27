import SwiftUI
import Minimuxer

@main
struct GoldenNuggetApp: App {
    init() {
        // Development mode's logging switch, applied at launch rather than when the
        // settings page is opened: it governs the protocol half of every run, and a
        // stored preference that only took effect once the user visited a page would
        // mean a session's minimuxer.log was recorded under the wrong setting.
        DevSettings.applyLoggingPreference()

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